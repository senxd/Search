import Foundation

// The Ask consent model's shared vocabulary — types only, the rules live in
// Drive (the gate) and Mind (the cards). Splitting the value types here keeps
// Mind.swift a state contract and Drive.swift an ops file.

/// What a session is allowed to do — Aside's read-only/guard/full-access
/// in this codebase's voice. Chats carry one (consent is already
/// chat-scoped); socket sessions default to .full — the same-uid socket is
/// the trust boundary, the mode is for the agent.
enum AskMode: String, Codable {
    /// Read-class ops only; anything else is refused outright.
    case read
    /// Reads and writes are free; destructive and privileged ops ask first.
    case `guard`
    /// Everything the door allows — door-bound ops still refuse by origin.
    case full

    var label: String {
        switch self {
        case .read: "Read"
        case .guard: "Guard"
        case .full: "Full"
        }
    }

    var icon: String {
        switch self {
        case .read: "eye"
        case .guard: "shield"
        case .full: "bolt.shield"
        }
    }
}

/// How heavy an op is — the gate's axis. Meta is never gated; read never
/// writes; write touches pages/tabs; destructive is irreversible or spends;
/// privileged reaches beyond the page (eval, filesystem, consent, the
/// in-app agent's ear).
enum OpClass: Int {
    case meta, read, write, destructive, privileged
}

/// The card a parked op raises in the chat — "I want to X" with evidence.
struct AskApproval: Identifiable, Equatable, Codable {
    var id = UUID()
    /// The chat the turn belongs to.
    var chat: UUID
    /// The op being asked about ("act.submit").
    var op: String
    /// The deterministic description the gate wrote — "submit the form on
    /// acme.com" — never the model's words, those can't be trusted.
    var summary: String
    /// The model's own reason, when it passed one.
    var why: String?
    /// The tab prefix this acts on, when there is one.
    var tabID: String?
    var host: String?
    /// A screenshot of the tab at ask time, when there is one.
    var shotPath: String?
    var when = Date()
}

/// How a card was answered — `always` remembers (op, host) for the chat.
enum ApprovalVerdict: String, Codable {
    case allow, deny, always
}

/// A question the agent asked mid-turn — rendered as the pending tool row's
/// card, answered by text or a quick pick, settled by timeout or dismissal.
struct AskQuestion: Identifiable, Equatable {
    var id = UUID()
    var chat: UUID
    var text: String
    var options: [String]
}

// MARK: - the gate's arithmetic

/// The rules Drive.serve's gate applies — design/permissions.md §2's table
/// as code. `classify` says how heavy an op is, `describe` writes the
/// card's own words (never the model's), `check` turns a class and a mode
/// into a verdict. Everything here is main-actor work done at request
/// time — the gate itself is synchronous; only the card's evidence (the
/// tab screenshot) is async, and the op's finish is parked meanwhile.
enum Policy {
    /// What a parked op becomes — `allow` dispatches, `deny` answers the
    /// refusal (read mode refuses rather than asks), `ask` parks the
    /// finish on a card.
    enum Verdict: Equatable {
        case allow
        case deny(String)
        case ask
    }

    /// An "Always" click remembered — (op, host) within the session that
    /// answered, so "Always: submit · acme.com" never becomes "always
    /// submit". Dies with the consent it rode on (ungrantAll/leave).
    struct AlwaysKey: Hashable {
        var op: String
        var host: String
    }

    /// Keys the gate reads for itself — the model's `why` on a mutating
    /// op, and the `says` a danger probe folds back in — which must never
    /// reach the page: actArgs forwards everything but `tab`, so these
    /// are stripped there.
    static let gateKeys: Set<String> = ["why", "says"]

    /// Words whose click spends, sends or ends — the lexicon the driving
    /// verbs escalate on (§2's note under act.*).
    private static let dangerLexicon = try! NSRegularExpression(
        pattern: #"\b(buy|pay|order|purchase|subscribe|send|post|delete|transfer|confirm)\b"#,
        options: [.caseInsensitive])

    /// Ops whose `text` arg is the payload, not a locator — Drive.query's
    /// exclusion list, mirrored: a fill or a type is told what to *enter*,
    /// a press is told keys, a clickAt coordinates. "send the report" in
    /// a field can't be read as "click Send" — scanning it would ask on
    /// the act's contents instead of its target.
    private static let payloadTextOps: Set<String> = ["act.fill", "act.type", "act.press", "act.clickAt"]

    /// Best-effort escalation, guard mode only: a locator carries the
    /// target's accessible name in the args — `text=`, `loc=`, `css=`
    /// (except where `text` is the payload, above) and `says`, the words
    /// Drive's probe read off the resolved element itself — so "Buy now"
    /// read off any of them escalates the op write → destructive. A bare
    /// `ref` ("e3") has no words to read here; probeDanger resolves it
    /// page-side before dispatch instead.
    private static func dangerHit(_ op: String, _ args: [String: Any]) -> Bool {
        var keys = ["says", "loc", "css"]
        if !payloadTextOps.contains(op) { keys.append("text") }
        for key in keys {
            guard let said = args[key] as? String else { continue }
            if dangerLexicon.firstMatch(in: said, range: NSRange(said.startIndex..., in: said)) != nil {
                return true
            }
        }
        return false
    }

    /// The op's weight, from the table in permissions.md §2. `tab` is the
    /// tab the request names, when it names one — the same verb on a
    /// granted user tab weighs more than on a bench tab.
    @MainActor
    static func classify(_ op: String, args: [String: Any], tab: Tab?) -> OpClass {
        switch op {
        // Always free — and the door-bound ops too: they're refused inside
        // the op by origin (the wire can't grant), so the gate leaves them
        // alone rather than carding Mind's own ungrantAll on a new chat.
        case "ping", "subscribe", "agent.mode",
             "tabs.grant", "tabs.ungrantAll":
            return .meta
        case "tabs.list", "agent.tabs", "agent.probe":
            return .read
        case "page.wait", "page.text", "page.snapshot", "page.console", "page.frames":
            return .read
        case "page.screenshot":
            // `path` expands ~ and writes anywhere the app can — a
            // filesystem write hiding inside a read op.
            return args["path"] is String ? .write : .read
        case "tabs.open", "tabs.attach", "tabs.detach", "tabs.select", "agent.lease",
             "page.back", "page.forward",
             "act.hover", "act.scroll", "act.click", "act.clickAt", "act.fill",
             "act.type", "act.press", "act.select", "act.check":
            return .write
        case "page.go", "page.reload":
            // On a bench tab: write — it's the agent's own to walk. On a
            // user tab: destructive — it drops page state (and for go,
            // walks the user's session to a new origin). An unknown tab
            // reads as the user's — the card's cheaper than the mistake.
            return tab?.bench == true ? .write : .destructive
        case "act.submit":
            return .destructive    // requestSubmit() is the buy/post vector
        case "tabs.close":
            return .destructive    // bench-only already; loses the tab's state
        case "page.eval", "page.code":
            return .privileged     // arbitrary JS = the tab's whole authority
        case "ui.ask":
            // send/steer post text *as the user* into the in-app agent —
            // cross-session prompt injection into the session that holds
            // the grants — and `new` ends that session's consent outright:
            // Mind.newChat calls tabs.ungrantAll, emptying the grant
            // registry and denying every parked card. open/stop just move
            // the panel.
            return (args["send"] is String || args["steer"] is String
                    || args["new"] as? Bool == true) ? .privileged : .write
        default:
            return .meta           // unknowns dispatch to "unknown op"
        }
    }

    /// The card's own one-line description of the ask — deterministic from
    /// op + args, never the model's words ("submit the form on acme.com").
    @MainActor
    static func describe(_ op: String, args: [String: Any], tab: Tab?) -> String {
        let host = tab?.address?.host() ?? ""
        let on = host.isEmpty ? "" : " on \(host)"
        let id = tab.map { " (tab \(Bench.short($0)))" } ?? ""
        switch op {
        case "page.go":
            let to = (args["url"] as? String).flatMap(Address.url(from:))?.host()
                ?? (args["url"] as? String ?? "")
            return "navigate \(host.isEmpty ? "a tab" : host) to \(to)"
        case "page.reload":
            return "reload\(on)\(id)\(tab?.bench == true ? "" : " — unsaved page state is lost")"
        case "page.eval":
            return "run JavaScript\(on)\(id)"
        case "page.code":
            return "run a JavaScript program\(on)\(id)"
        case "act.submit":
            return "submit the form\(on)"
        case "tabs.close":
            return "close tab \(tab.map(Bench.short) ?? "")"
        case "ui.ask":
            // `new` first when the flags combine — wiping the chat's
            // grants is the part the user most needs named.
            if args["new"] as? Bool == true {
                return "start a fresh Ask chat — its tab grants end with it"
            }
            return args["send"] is String
                ? "post a message to Ask as you"
                : "steer the running Ask turn"
        default:
            let verb = op.hasPrefix("act.") ? String(op.dropFirst(4)) : op
            return "\(verb)\(on)\(id)"
        }
    }

    /// The host an "Always" key is scoped to — the target tab's, empty
    /// when the op doesn't name one (a ui.ask send's card is for the door,
    /// not a site).
    @MainActor
    static func host(of tab: Tab?, args: [String: Any]) -> String {
        (tab?.address?.host() ?? "").lowercased()
    }

    /// The verdict matrix (§3): read allows ≤ read and refuses the rest —
    /// refused, not asked; full allows everything the door does; guard
    /// allows ≤ write and asks on the rest, unless an Always answer
    /// remembered this (op, host) already.
    @MainActor
    static func check(_ op: String, args: [String: Any], mode: AskMode, tab: Tab?,
                      remembered: Set<AlwaysKey>) -> Verdict {
        var klass = classify(op, args: args, tab: tab)
        if mode == .guard, klass == .write, op.hasPrefix("act."), dangerHit(op, args) {
            klass = .destructive
        }
        switch mode {
        case .full:
            return .allow
        case .read:
            return klass.rawValue <= OpClass.read.rawValue
                ? .allow
                : .deny("\(op) is above read mode")
        case .guard:
            if klass.rawValue <= OpClass.write.rawValue { return .allow }
            let key = AlwaysKey(op: op, host: host(of: tab, args: args))
            return remembered.contains(key) ? .allow : .ask
        }
    }

    /// Whether an `.allow` verdict earns a second look: a guard-mode
    /// `act.*` whose locator is an opaque handle — `ref`, `loc` or `css`
    /// — names its target without carrying the words dangerHit reads, so
    /// Drive pays one read-only resolve for the element's {role,name} and
    /// checks again with them folded in as `says`. Never for a remembered
    /// (op, host): the answer kept can't be made stricter by looking.
    @MainActor
    static func probesDanger(_ op: String, args: [String: Any], mode: AskMode,
                             tab: Tab?, remembered: Set<AlwaysKey>) -> Bool {
        guard mode == .guard, op.hasPrefix("act."), let tab,
              classify(op, args: args, tab: tab) == .write,
              args["ref"] is String || args["loc"] is String || args["css"] is String
        else { return false }
        return !remembered.contains(AlwaysKey(op: op, host: host(of: tab, args: args)))
    }
}


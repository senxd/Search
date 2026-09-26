import AppKit
import SwiftUI
import WebKit

// The ops layer behind Ask — the one implementation of Runtime/ask/PROTOCOL.md,
// reached two ways: the in-app harness's bridge and the persistent sessions on
// agent.sock. Both hand `perform` an op and an args object and get one JSON-able
// answer back; events raised in between — a tab navigating, a lease letting go
// — go to whoever set `onEvent`.
//
// The unit of permission is the tab: a tab opened through `tabs.open` is the
// agent's own (the bench kind — ⚗, out of your session and history); any other
// tab can be read or driven only after `tabs.attach` has found it consented —
// the composer's chips being where consent comes from, recorded in
// `grantedTabs` the one way that can ever happen: `tabs.grant`, the in-app
// door's own op, which no tool call may name and no socket may speak. Real
// input — the `event` tier of clicks and keys — is allowed on exactly those
// tabs.

/// Which session a `perform` is for. The in-app harness is one logical
/// session (`.app`) no matter how many turns it runs; each agent.sock
/// connection is its own, keyed by a token rather than the fd — a recycled
/// descriptor must never collide with a dead connection's leftovers.
enum DriveOrigin: Hashable {
    case app
    case socket(UUID)

    /// The routing tag an event's `_session` carries: who it is for. Never
    /// goes on the wire — the socket strips it while fanning out.
    var tag: String {
        switch self {
        case .app: return "app"
        case .socket(let id): return "sock-" + id.uuidString
        }
    }
}

extension Driving {
    /// The in-app door: a call without an origin is the app's own session.
    /// (A protocol requirement can't carry a default argument, so the
    /// three-argument shape the harness already calls lives here.)
    func perform(_ op: String, _ args: [String: Any], done: @escaping ([String: Any]) -> Void) {
        perform(op, args, from: .app, done: done)
    }
}

final class Drive: Driving {
    /// The window's state, never owned: `AskRuntime.drive` is put up in
    /// Browser.init and the browser outlives everything that asks it things.
    unowned let browser: Browser

    /// Events between answers, for `tab.navigated`, `lease.lost` and friends.
    /// Set by whoever is listening — the socket once a session subscribes, the
    /// harness for its own sessions. Written on the main queue.
    var onEvent: ((String, [String: Any]) -> Void)? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.armDiff() }
            }
        }
    }

    /// One session's share of the driver's state: the tabs it attached, the
    /// tabs it opened, the foreground-action leases it holds, and how many
    /// of its ops are still in flight (which is what `done` counts down).
    /// Sessions must never see each other's — a second socket client used
    /// to be able to drive a tab the first had attached and to hear its
    /// lease.lost and done.
    @MainActor private struct Share {
        var attached = Set<UUID>()
        var mine = Set<UUID>()
        var leases = Set<UUID>()
        var pending = 0
    }

    /// The living sessions, by origin. `.app` is the in-app agent; each
    /// socket connection is a session of its own for as long as it lives.
    @MainActor private var sessions: [DriveOrigin: Share] = [:]

    /// Each session's leash (design/permissions.md §1) — what its ops may
    /// do once it holds a tab. Sockets default to `.full`: the same-uid,
    /// chmod-600 wire is already the app's trust level, and the mode is
    /// the agent's own. `.app` is pushed the current chat's mode by Mind
    /// (`setMode`), and defaults to the Settings pick meanwhile.
    @MainActor private var modes: [DriveOrigin: AskMode] = [:]

    /// A request the gate held for a card: the op and its `finish` parked
    /// together, so the verdict — or the session ending — can settle it.
    /// `Share.pending` stays up meanwhile, which is what keeps `done`
    /// honest. No timeout — a parked finish is first-class.
    @MainActor private struct PendingApproval {
        var origin: DriveOrigin
        var op: String
        var args: [String: Any]
        var summary: String
        var host: String
        var finish: ([String: Any]) -> Void
    }
    @MainActor private var pendingApprovals: [UUID: PendingApproval] = [:]

    /// The chat the `.app` session last sent into — learned in `ask`,
    /// the only door a turn comes through. parkApproval needs it when the
    /// panel's `currentID` has gone (a `new` chat landing mid-turn nils
    /// it under the op that was about to ask): minting a bare UUID would
    /// park a card no chat can show.
    @MainActor private var appChat: UUID?

    /// "Always" clicks remembered per session as (op, host) — the card's
    /// `Always: submit · acme.com`, not "always submit". Same lifetime as
    /// every other consent here: gone with the chat, the socket, the app.
    @MainActor private var remembered: [DriveOrigin: Set<Policy.AlwaysKey>] = [:]

    /// The consent registry: tabs the user handed the agent layer through a
    /// composer chip — which arrives as `tabs.grant` on the in-app door
    /// alone, never as an argument `tabs.attach` would read — remembered by
    /// the 8-hex id the protocol speaks in. A socket session may attach a
    /// tab found here; the wire can never write it. Entries die on the tab
    /// closing, with the app, when the last session holding the tab lets
    /// go, and with the chat itself — consent is the chat's, so a new or
    /// deleted one clears them all (`tabs.ungrantAll`).
    @MainActor private var grantedTabs = Set<String>()

    /// What the last row-diff saw — url and title by tab — so a navigation or
    /// a rename between ops still lands as an event.
    @MainActor private var seen: [UUID: (String, String)] = [:]
    @MainActor private var primed = false
    @MainActor private var diffTimer: DispatchSourceTimer?
    /// `drive()` calls whose answer the page owes us, by tab — so a commit
    /// that tears the context down can settle them instead of leaving the
    /// request to die of old age. The flag marks the op a mutation — one
    /// that may legitimately have caused the navigation it dies of.
    @MainActor private var flying: [UUID: [Int: (mutating: Bool, settle: ([String: Any]) -> Void)]] = [:]
    @MainActor private var nextFlight = 0

    /// Bumped while a synthetic event is being handed to a view, so the
    /// user's-own-act lease check doesn't mistake ours for theirs.
    static var injecting = 0
    /// The synthetic events themselves, kept briefly: WebKit hands a key the
    /// page didn't use back up the responder chain — the same event a second
    /// time, possibly after `injecting` has settled — and it is still not the
    /// user's hand. The window is generous — 256, a long typing burst — so a
    /// bounced key can't have been evicted before it comes back through.
    static private var injected: [NSEvent] = []
    static func note(_ event: NSEvent) {
        injected.append(event)
        if injected.count > 256 { injected.removeFirst(injected.count - 256) }
    }

    init(browser: Browser) {
        self.browser = browser
    }

    // MARK: - the door

    /// `Driving`. The work is all main-queue — callers reach us there already
    /// (the socket's reader, the harness's bridge), but the protocol doesn't
    /// promise it, so a stray caller is hopped over rather than trusted.
    func perform(_ op: String, _ args: [String: Any], from origin: DriveOrigin = .app, done: @escaping ([String: Any]) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.serve(op, args, from: origin, done: done) }
        } else {
            Task { @MainActor in self.serve(op, args, from: origin, done: done) }
        }
    }

    /// A session ended — a socket closing, never the app: give back its
    /// leases and attaches and close the tabs it opened, so nothing a gone
    /// agent set up keeps running. The socket calls it while the descriptor
    /// is still its own, before the fd can be handed out again.
    @MainActor
    func leave(_ origin: DriveOrigin) {
        guard let share = sessions.removeValue(forKey: origin) else { return }
        for id in share.mine {
            if let tab = browser.tabs.first(where: { $0.id == id }), tab.bench {
                browser.close(tab)
            }
        }
        // What the departed session was holding lapses the way a detach
        // would: a user tab nobody holds anymore loses its consent and its
        // place on the watched row.
        for id in share.attached {
            let held = sessions.values.contains { $0.attached.contains(id) || $0.mine.contains(id) }
            if !held, let tab = browser.tabs.first(where: { $0.id == id }), !tab.bench {
                grantedTabs.remove(Bench.short(tab))
                seen.removeValue(forKey: id)
            }
        }
        // Its cards, its remembered always-rules and its mode die with it —
        // consent's whole lifetime is the session's.
        denyPending(for: origin, reason: "the session ended")
        remembered[origin] = nil
        modes[origin] = nil
        // The closed rows — if anyone subscribed — announce themselves in
        // the diff, which also sweeps whatever state of theirs remains.
        diff()
    }

    // MARK: - modes

    /// The session's leash for the gate. A socket is `.full` unless it set
    /// its own (`agent.mode`, or `mode` on subscribe) — same-uid clients
    /// already hold the app's trust; a mode on a wire session is that
    /// agent's self-restraint or a test's probe. `.app` is whatever Mind
    /// last pushed — the current chat's mode — falling back to the global
    /// default in Settings ("ask.mode", guard out of the box).
    @MainActor
    func mode(for origin: DriveOrigin) -> AskMode {
        if let set = modes[origin] { return set }
        switch origin {
        case .app:
            return Store.settings.string(forKey: "ask.mode").flatMap(AskMode.init(rawValue:)) ?? .guard
        case .socket:
            return .full
        }
    }

    /// Mind pushes the current chat's mode here on send/select/newChat —
    /// the `.app` session's mode *is* the chat's. (Also how a socket's own
    /// `agent.mode` lands; the op refuses `.app` so the model can't lift
    /// its own leash.)
    @MainActor
    func setMode(_ mode: AskMode, for origin: DriveOrigin) {
        modes[origin] = mode
    }

    /// The session holding a tab, if one does — the download gate in
    /// Browser asks whose bench tab started a file on its way to disk.
    @MainActor
    func holder(of tab: Tab) -> DriveOrigin? {
        sessions.first(where: { $0.value.mine.contains(tab.id) || $0.value.attached.contains(tab.id) })?.key
    }

    /// The card's answer. `allow` dispatches the original op fresh — a tab
    /// that went meanwhile errors the ordinary way through `own`/`view`;
    /// `always` remembers (op, host) for the session first; `deny` settles
    /// the parked call with the honest refusal.
    @MainActor
    func settleApproval(_ id: UUID, _ verdict: ApprovalVerdict) {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        switch verdict {
        case .deny:
            pending.finish(["error": "denied by user — \(pending.summary)", "code": "DENIED"])
        case .allow:
            dispatch(pending.op, pending.args, pending.finish, from: pending.origin)
        case .always:
            remembered[pending.origin, default: []]
                .insert(Policy.AlwaysKey(op: pending.op, host: pending.host))
            dispatch(pending.op, pending.args, pending.finish, from: pending.origin)
        }
        diff()
    }

    /// Every ask one session still holds, settled denied — a stopped or
    /// replaced turn, a dead socket, a chat that ended. A `finish` that
    /// never fires is a pending that never ends and a JS promise that
    /// never resolves, so the seat has to be emptied, not waited out.
    @MainActor
    func denyPending(for origin: DriveOrigin, reason: String = "the turn ended") {
        let ids = pendingApprovals.filter { $0.value.origin == origin }.map(\.key)
        for id in ids {
            guard let pending = pendingApprovals.removeValue(forKey: id) else { continue }
            pending.finish(["error": "denied — \(reason)", "code": "DENIED"])
        }
    }

    @MainActor
    private func serve(_ op: String, _ args: [String: Any], from origin: DriveOrigin, done: @escaping ([String: Any]) -> Void) {
        armDiff()
        // Check the args before they can reach JSONSerialization: a
        // non-finite number or a non-JSON type is an uncatchable
        // NSInvalidArgumentException there, not a throw — the request
        // bounces here instead of the app going down mid-op.
        guard Drive.jsonSafe(args) else {
            done(["error": "args aren't JSON-safe — a number ran off the end, or a non-JSON type came in"])
            return
        }
        sessions[origin, default: Share()].pending += 1
        var fired = false
        let finish: ([String: Any]) -> Void = { [weak self] reply in
            // One answer, and always one — bench's rule, and more load-bearing
            // here where an unanswered request just sits pending forever.
            guard !fired else { return }
            fired = true
            done(reply)
            MainActor.assumeIsolated {
                guard let self, var share = self.sessions[origin], share.pending > 0 else { return }
                share.pending -= 1
                self.sessions[origin] = share
                if share.pending == 0 { self.emit("done", [:], to: origin) }
            }
        }
        // The gate (design/permissions.md §3): after jsonSafe, before
        // dispatch. The op's class against the session's mode decides —
        // allow runs it, deny refuses it (read mode's whole point is that
        // nothing asks), ask parks the finish on a card.
        let subject = tab(args)
        let leash = mode(for: origin)
        let recalled = remembered[origin] ?? []
        switch Policy.check(op, args: args, mode: leash, tab: subject,
                            remembered: recalled) {
        case .allow:
            // Second look for an allowed act.* whose locator is an opaque
            // handle — the escalation reads the target's words, and a
            // `ref`/`loc`/`css` doesn't carry them. probeDanger resolves
            // it page-side (the priced version of the check), then the
            // same gate decides again with `says` folded into the args.
            if let subject, subject.built != nil,
               Policy.probesDanger(op, args: args, mode: leash, tab: subject, remembered: recalled) {
                probeDanger(op, args, subject, finish, from: origin, mode: leash, remembered: recalled)
            } else {
                dispatch(op, args, finish, from: origin)
            }
        case .deny(let why):
            finish(["error": why, "code": "MODE"])
        case .ask:
            parkApproval(op, args, finish, from: origin, tab: subject)
        }
        diff()
    }

    /// The op behind the finish line — split from `serve` so a card's
    /// verdict can run the very same dispatch the gate's `allow` would
    /// have. Re-runs `own`/`view` fresh: a tab that navigated or closed
    /// while its card was up errors the ordinary way.
    @MainActor
    private func dispatch(_ op: String, _ args: [String: Any], _ finish: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        switch op {
        case "ping":
            finish(["pong": true])
        case "subscribe":
            // Subscribing is the socket's business — it decides which clients
            // hear events. In-app there's nothing to mark; AgentSocket owns
            // onEvent today. Either way the op answers. A `mode` arg sets the
            // session's leash along the way — a socket's own, never `.app`'s
            // (that's the chat's, pushed by Mind).
            if origin != .app,
               let mode = (args["mode"] as? String).flatMap(AskMode.init(rawValue:)) {
                modes[origin] = mode
            }
            finish(["subscribed": true])
        case "tabs.list":
            finish(["tabs": browser.tabs.map { Bench.shared.describe($0, in: browser) }])
        case "tabs.open":
            open(args, finish, from: origin)
        case "tabs.attach":
            attach(args, finish, from: origin)
        case "tabs.grant":
            grant(args, finish, from: origin)
        case "tabs.ungrantAll":
            ungrantAll(finish, from: origin)
        case "tabs.detach":
            detach(args, finish, from: origin)
        case "tabs.close":
            closeTab(args, finish, from: origin)
        case "tabs.select":
            selectTab(args, finish, from: origin)
        case "page.go":
            go(args, finish, from: origin)
        case "page.back", "page.forward", "page.reload":
            nav(op, args, finish, from: origin)
        case "page.wait":
            wait(args, finish, from: origin)
        case "page.text":
            text(args, finish, from: origin)
        case "page.snapshot":
            snapshot(args, finish, from: origin)
        case "page.screenshot":
            screenshot(args, finish, from: origin)
        case "page.eval":
            eval(args, finish, from: origin)
        case "page.code":
            code(args, finish, from: origin)
        case "page.console":
            console(args, finish, from: origin)
        case "page.frames":
            frames(args, finish, from: origin)
        case "act.click":
            click(args, finish, from: origin)
        case "act.type":
            type(args, finish, from: origin)
        case "act.press":
            press(args, finish, from: origin)
        case "act.clickAt":
            clickAt(args, finish, from: origin)
        case "act.fill", "act.hover", "act.scroll", "act.select", "act.check", "act.submit":
            actJS(op, args, finish, from: origin)
        case "agent.tabs":
            finish(["tabs": browser.tabs.filter(\.bench).map { Bench.shared.describe($0, in: browser) }])
        case "agent.probe":
            finish(Bench.shared.probeReport(browser))
        case "agent.lease":
            lease(args, finish, from: origin)
        case "agent.mode":
            // A socket session sets its own leash. The app's session can't
            // move its — that's the chat's, pushed by Mind — or the model
            // would just ask for "full" and step out from under the gate.
            guard origin != .app else {
                finish(["error": "the app's mode is its chat's — set it in Ask"])
                return
            }
            guard let to = args["to"] as? String else {
                finish(["mode": mode(for: origin).rawValue])
                return
            }
            guard let parsed = AskMode(rawValue: to) else {
                finish(["error": "agent.mode needs to: read|guard|full"])
                return
            }
            modes[origin] = parsed
            finish(["mode": parsed.rawValue])
        case "ui.ask":
            ask(args, finish)
        default:
            finish(["error": "unknown op “\(op)”"])
        }
        diff()
    }

    /// The escalation's priced half (AskPolicy.dangerHit): a `ref`/`loc`/
    /// `css` locator names the target without carrying its accessible
    /// name, so a guard-mode act.* the args allowed gets one read-only
    /// `resolve` for the element's {role,name} — folded back as `says`,
    /// the gate checked once more, and the op dispatched or parked on the
    /// answer. Any failure — a stale ref, a page that won't say — falls
    /// through to dispatch, where the act's own resolve reports it the
    /// honest way.
    @MainActor
    private func probeDanger(_ op: String, _ args: [String: Any], _ subject: Tab,
                             _ finish: @escaping ([String: Any]) -> Void, from origin: DriveOrigin,
                             mode: AskMode, remembered: Set<Policy.AlwaysKey>) {
        guard let view = subject.built else {
            dispatch(op, args, finish, from: origin)
            return
        }
        let verb = String(op.dropFirst(4))
        drive(view, """
        function (d) {
          var el = d.resolve(\(json(query(verb, args))));
          var dr = el.__driveRef || {};
          var attr = (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('placeholder'))) || '';
          var says = ((dr.role || '') + ' ' + (dr.name || '') + ' ' + attr + ' ' + ((el.innerText || el.value || '') + ''));
          return { says: says.slice(0, 400) };
        }
        """) { [weak self] out in
            MainActor.assumeIsolated {
                guard let self else { return }
                var said = args
                if let words = out["says"] as? String, !words.isEmpty { said["says"] = words }
                switch Policy.check(op, args: said, mode: mode, tab: subject, remembered: remembered) {
                case .allow:
                    self.dispatch(op, args, finish, from: origin)
                case .deny(let why):
                    finish(["error": why, "code": "MODE"])
                case .ask:
                    self.parkApproval(op, args, finish, from: origin, tab: subject)
                }
            }
        }
    }

    /// One event out. `to` scopes it to a single session — a `done` or a
    /// `lease.lost` is the asking session's own business; nothing `to` is a
    /// broadcast, which `tab.*` is: every subscribed session watches the
    /// same tabs, so they all hear it. The tag travels as `_session` in the
    /// data and the socket strips it while fanning out.
    @MainActor
    private func emit(_ event: String, _ data: [String: Any], to origin: DriveOrigin? = nil) {
        var data = data
        if let origin { data["_session"] = origin.tag }
        onEvent?(event, data)
    }

    // MARK: - finding and permitting a tab

    /// A request's tab: `args["tab"]` (the protocol's name for it), with `id`
    /// taken as the same thing for callers that think in bench's spelling.
    @MainActor
    private func tab(_ args: [String: Any]) -> Tab? {
        let ref = ((args["tab"] ?? args["id"]) as? String)?.lowercased() ?? ""
        guard !ref.isEmpty else { return nil }
        return Bench.shared.find(ref, in: browser)
    }

    /// Read and driven alike: the tab is the asking session's own — opened
    /// by it or attached to it. An agent tab one session opened is nobody
    /// else's to drive; a loose one (bench.sock's, the ⚗ menu's) belongs to
    /// no session until attached.
    @MainActor
    private func granted(_ tab: Tab, _ origin: DriveOrigin) -> Bool {
        guard let share = sessions[origin] else { return false }
        return share.mine.contains(tab.id) || share.attached.contains(tab.id)
    }

    /// Resolve the request's tab and its permission, answering the error and
    /// returning nil when either fails.
    @MainActor
    private func own(_ args: [String: Any], _ done: ([String: Any]) -> Void, _ origin: DriveOrigin) -> Tab? {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return nil
        }
        guard granted(tab, origin) else {
            done(["error": "tab \(Bench.short(tab)) is not this session's — attach it first (its chip in Ask)"])
            return nil
        }
        return tab
    }

    /// The tab's page, painted or paintable. A sleeping or never-built tab is
    /// an error, never a reason to stand a view up — `tab.built` is the only
    /// one of the two that doesn't build.
    @MainActor
    private func view(of tab: Tab, _ done: ([String: Any]) -> Void) -> PageView? {
        guard let view = tab.built else {
            done(["error": tab.asleep
                  ? "tab \(Bench.short(tab)) is asleep — page.reload or tabs.select it first"
                  : "tab \(Bench.short(tab)) has no page yet"])
            return nil
        }
        // A page needs a window to lay out and paint in; one nobody is
        // looking at goes to the offscreen room, as bench tabs always have.
        Bench.shared.house(tab)
        return view
    }

    /// The ask path (design/permissions.md §3). The op's `finish` parks in
    /// `pendingApprovals` — `Share.pending` stays up, `done` never fires,
    /// the harness's promise just waits — while the card goes up through
    /// the same door `ui.ask` uses: `Mind.raise`. Socket sessions never
    /// get here: the wire owns no UI and its patience timer answers in 30s
    /// regardless, so their `ask` verdict resolves as the honest error.
    @MainActor
    private func parkApproval(_ op: String, _ args: [String: Any], _ finish: @escaping ([String: Any]) -> Void,
                              from origin: DriveOrigin, tab subject: Tab?) {
        guard origin == .app else {
            finish(["error": "\(op) needs approval — the wire can't be shown a card",
                    "code": "NEEDS_UI"])
            return
        }
        let id = UUID()
        // The chat the card lives in: the panel's current; failing that,
        // the chat this session last sent into (appChat — kept for exactly
        // this gap, currentID nil'd mid-turn); failing that, the newest
        // on record, checked so a deleted chat can't be named. With no
        // chat anywhere the card still raises — invisible but settleable —
        // and the miss is logged rather than silent.
        let chat = Mind.shared.currentID
            ?? appChat.flatMap { id in Mind.shared.chats.contains(where: { $0.id == id }) ? id : nil }
            ?? Mind.shared.chats.first?.id
        if chat == nil {
            NSLog("[drive] approval for %@ found no chat to live in — raising anyway", op)
        }
        var approval = AskApproval(
            id: id,
            chat: chat ?? UUID(),
            op: op,
            summary: Policy.describe(op, args: args, tab: subject),
            why: (args["why"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            tabID: subject.map(Bench.short),
            host: Policy.host(of: subject, args: args))
        pendingApprovals[id] = PendingApproval(
            origin: origin, op: op, args: args,
            summary: approval.summary, host: approval.host ?? "", finish: finish)
        // Evidence: the tab as it stands. `built` only — the card is never
        // the reason a view exists. The shot lands on the card when it
        // can; the raise itself doesn't wait on paint.
        guard let view = subject?.built else {
            Mind.shared.raise(approval)
            return
        }
        let file = shotsFolder().appendingPathComponent("approval-\(id.uuidString).png")
        Bench.shared.shoot(view, to: file, width: 480) { [weak self] out in
            // The ask may have settled while the shot painted — a stop or
            // denyPending answering it mid-flight. Raising now would post
            // a zombie card nobody can settle, so the seat's existence is
            // what the raise checks.
            MainActor.assumeIsolated {
                guard let self, self.pendingApprovals[id] != nil else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                approval.shotPath = out["path"] as? String
                Mind.shared.raise(approval)
            }
        }
    }

    // MARK: - tabs

    @MainActor
    private func open(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let url = (args["url"] as? String).flatMap(Address.url(from:)) else {
            done(["error": "tabs.open needs a url"])
            return
        }
        // Whose cookies the tab carries is a property fixed at open
        // (design/permissions.md §4): `fresh:true` asks for a tab signed in
        // as nobody — Tab(shy:) on a .nonPersistent store — and a read-mode
        // session gets nothing else.
        let fresh = args["fresh"] as? Bool == true || mode(for: origin) == .read
        let tab = browser.benchOpen(url, shy: fresh)
        sessions[origin, default: Share()].mine.insert(tab.id)
        Bench.shared.house(tab)
        // Selecting on the real window is deliberately allowed for a tab the
        // agent opened — the attention was asked for on purpose.
        if args["foreground"] as? Bool == true { browser.select(tab) }
        done(["id": Bench.short(tab)])
    }

    @MainActor
    private func attach(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        // Consent is never this op's argument, on any door: `granted:true`
        // here can only be a model or the wire reaching for a chip nobody
        // gave — the registry is written by `tabs.grant` alone. Refused
        // rather than read, so the flag is dead whoever sends it.
        if args["granted"] as? Bool == true {
            done(["error": "granted isn't an attach argument — grants come through the grant door (tabs.grant, in-app only)"])
            return
        }
        if tab.bench {
            // An agent tab another session opened is its own — not for
            // taking. A loose one attaches to whoever asks first.
            if let holder = sessions.first(where: { $0.value.mine.contains(tab.id) })?.key,
               holder != origin {
                done(["error": "tab \(Bench.short(tab)) is another session's own"])
                return
            }
            sessions[origin, default: Share()].attached.insert(tab.id)
            done(["id": Bench.short(tab), "attached": true])
            return
        }
        // One of the user's own. Consent is the composer's chip, recorded
        // by the grant door — a socket session may attach a tab the chip
        // granted, but the wire itself can never grant.
        guard grantedTabs.contains(Bench.short(tab)) else {
            done(["error": "tab \(Bench.short(tab)) needs its chip in Ask — " +
                  (origin == .app ? "consent isn't an attach argument" : "the wire can't grant it")])
            return
        }
        sessions[origin, default: Share()].attached.insert(tab.id)
        done(["id": Bench.short(tab), "attached": true])
    }

    /// The chip's own door — the one op that writes the consent registry,
    /// and the app's own session is the only caller it takes: the socket
    /// is refused outright, and the harness never routes a `tool` message
    /// here (kind:"grant" is the bridge shape for it, which attachTabs
    /// alone emits). Granting a user tab remembers it in `grantedTabs` and
    /// attaches it to the app's session in one step. A bench tab needs no
    /// consent — a grant on one is just an attach.
    @MainActor
    private func grant(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard origin == .app else {
            done(["error": "tabs.grant is the in-app door — the wire can't grant a tab"])
            return
        }
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        if tab.bench {
            // A grant on an agent tab is just an attach — hand it over
            // without the `granted` key, which attach refuses outright.
            var rest = args
            rest.removeValue(forKey: "granted")
            attach(rest, done, from: origin)
            return
        }
        grantedTabs.insert(Bench.short(tab))
        sessions[.app, default: Share()].attached.insert(tab.id)
        done(["id": Bench.short(tab), "attached": true])
    }

    /// The consent's other half: the chat it was made for is over — a fresh
    /// one started or this one deleted, which is the only way Mind calls
    /// this — so every grant ends at once. The registry empties and each
    /// session's attach on a granted user tab lets go with it, a held lease
    /// announcing its `lease.lost` as ever. The app's own door may say so,
    /// never the wire: the side that can't grant a tab can't ungrant one
    /// either. Tabs a session opened and bench tabs were never the
    /// registry's to give, and stay held.
    @MainActor
    private func ungrantAll(_ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard origin == .app else {
            done(["error": "tabs.ungrantAll is the in-app door — the wire can't end a grant"])
            return
        }
        // The registry speaks the 8-hex id; the sessions keep the tab's
        // UUID — resolve through the live tab list. A granted tab since
        // closed has already left all three by way of `drop`.
        let ended = grantedTabs
        grantedTabs.removeAll()
        let ids = Set(browser.tabs.filter { !$0.bench && ended.contains(Bench.short($0)) }.map(\.id))
        for who in sessions.keys {
            sessions[who]?.attached.subtract(ids)
        }
        for id in ids {
            // A held lease ends with the consent it rode on — `lease.lost`
            // goes to the session that was holding it, as on a real touch.
            release(id)
            // Off the watched row without a `tab.closed` for a tab that is
            // still open — the same forgetting a detach does.
            seen.removeValue(forKey: id)
        }
        // The chat's asks and its remembered always-rules die with its
        // consent — one lifetime.
        denyPending(for: .app, reason: "the chat's consent ended")
        remembered[.app] = nil
        done(["ungranted": ended.count])
    }

    @MainActor
    private func detach(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        // Releasing is the calling session's own business: its attach and
        // its leases on the tab go, and every other session's hold stands —
        // a session can't detach a tab out from under another. Consent
        // lapses only when the last holder lets go: while anyone still
        // holds the tab the chip's grant is in use, and a rider releasing
        // its own attach mustn't burn it. A tab the session opened stays
        // `mine` regardless — detaching isn't disowning.
        sessions[origin]?.attached.remove(tab.id)
        sessions[origin]?.leases.remove(tab.id)
        let held = sessions.values.contains { $0.attached.contains(tab.id) || $0.mine.contains(tab.id) }
        if !held, !tab.bench {
            grantedTabs.remove(Bench.short(tab))
            // The tab leaves the watched row too: forget what the diff last
            // saw so its absence isn't announced as `tab.closed`. A tab
            // still held — and any bench tab — stays watched regardless.
            seen.removeValue(forKey: tab.id)
        }
        done(["id": Bench.short(tab), "attached": false])
    }

    /// Everything anyone held on a tab that's gone: its consent, every
    /// session's attach/open/lease, and any page call it still owes — which
    /// settles with an error rather than hanging the request that made it.
    /// `seen` is left for the row-diff: the tab's `tab.closed` is still owed
    /// to whoever is listening.
    @MainActor
    private func drop(_ id: UUID) {
        grantedTabs.remove(String(id.uuidString.prefix(8)).lowercased())
        for origin in Array(sessions.keys) {
            sessions[origin]?.attached.remove(id)
            sessions[origin]?.mine.remove(id)
            sessions[origin]?.leases.remove(id)
        }
        if let owed = flying.removeValue(forKey: id) {
            for flight in owed.values { flight.settle(["error": "the tab is gone"]) }
        }
    }

    @MainActor
    private func closeTab(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        // Same rule as `bench close`, narrowed to what the session holds:
        // the agent's own tabs go; the user's and other sessions' never do.
        guard tab.bench else {
            done(["error": "not an agent tab — only tabs the agent opened can be closed from here"])
            return
        }
        guard granted(tab, origin) else {
            done(["error": "tab \(Bench.short(tab)) is not this session's — attach it first"])
            return
        }
        let id = Bench.short(tab)
        browser.close(tab)
        drop(tab.id)
        done(["id": id, "closed": true])
    }

    @MainActor
    private func selectTab(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        browser.select(tab)
        done(["id": Bench.short(tab), "active": true])
    }

    // MARK: - page

    @MainActor
    private func go(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        guard let url = (args["url"] as? String).flatMap(Address.url(from:)) else {
            done(["error": "page.go needs a url"])
            return
        }
        tab.go(to: url)
        Bench.shared.house(tab)
        done(["id": Bench.short(tab), "url": tab.address?.absoluteString ?? url.absoluteString])
    }

    @MainActor
    private func nav(_ op: String, _ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        switch op {
        case "page.back", "page.forward":
            // Going back in a tab that isn't holding a page would only stand
            // one up to nothing — a sleeping tab's history waits for a reload.
            guard tab.built != nil else {
                done(["error": "tab \(Bench.short(tab)) is asleep — page.reload or tabs.select it first"])
                return
            }
            Bench.shared.house(tab)
            if op == "page.back" { tab.back() } else { tab.forward() }
        case "page.reload":
            // Reload is the wake itself: it brings a rested tab back rather
            // than refusing it. A blank one has nothing to reload, though.
            guard tab.built != nil || tab.asleep else {
                done(["error": "tab \(Bench.short(tab)) has no page yet"])
                return
            }
            tab.reload()
            Bench.shared.house(tab)
        default:
            break
        }
        done(["id": Bench.short(tab)])
    }

    @MainActor
    private func wait(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        let limit = Date().addingTimeInterval((args["seconds"] as? NSNumber)?.doubleValue ?? 30)
        Bench.shared.wait(for: tab, in: browser, until: limit, done)
    }

    @MainActor
    private func text(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        view.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
            MainActor.assumeIsolated {
                if let error { done(["error": error.localizedDescription]); return }
                var text = (value as? String) ?? ""
                var cut = false
                if text.count > 120_000 { text = String(text.prefix(120_000)); cut = true }
                done(["text": text, "truncated": cut,
                      "url": tab.address?.absoluteString ?? "", "title": tab.title])
            }
        }
    }

    @MainActor
    private func eval(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let js = args["js"] as? String else { done(["error": "page.eval needs js"]); return }
        view.evaluateJavaScript(js) { value, error in
            MainActor.assumeIsolated {
                if let error { done(["error": error.localizedDescription]); return }
                done(["value": Bench.plain(value)])
            }
        }
    }

    // MARK: - drive.js

    /// Whether `JSONSerialization.data` can take the value at all. It does
    /// not throw a catchable error on a non-finite number or a non-JSON type
    /// (NSDate, NSData, …) — it raises NSInvalidArgumentException, which
    /// takes the app down with it, and `-1e999`/`NaN` arrive off the wire as
    /// exactly those numbers. So it's checked, not caught: every leaf a
    /// finite number, a string, a bool, or null; every key a string.
    nonisolated static func jsonSafe(_ value: Any, depth: Int = 0) -> Bool {
        guard depth < 400 else { return false }
        switch value {
        case is NSNull, is String:
            return true
        case let number as NSNumber:
            return number.doubleValue.isFinite
        case let array as [Any]:
            return array.allSatisfy { jsonSafe($0, depth: depth + 1) }
        case let dict as [String: Any]:
            return dict.values.allSatisfy { jsonSafe($0, depth: depth + 1) }
        default:
            return false
        }
    }

    /// A literal for embedding in a script — a JSON value, which JavaScript
    /// is happy to read as its own. Fragments allowed because scalars are
    /// embedded too — a bare string thrown at JSONSerialization is not an
    /// error you can catch, it's an exception that takes the app with it.
    /// Callers check `jsonSafe` on the whole request first, so what reaches
    /// here has already been proven writable.
    @MainActor
    private func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Call into the page's `window.__drive`, loading drive.js into it first.
    /// The load is idempotent (the script's own `if (window.__drive)` guard),
    /// and a page that still has no driver afterwards answers the "not
    /// loaded" error rather than a thrown blank. `call` is a function taking
    /// `d`; what it returns may be a promise — `callAsyncJavaScript` waits
    /// for those, which is the only way `act` and `run` can answer at all.
    /// A thrown drive.js error keeps its `code` (STALE_REF and friends are
    /// part of the protocol, not noise). `mutating` marks a call whose action
    /// may legitimately end in the page navigating away — the act.* tier —
    /// so a commit mid-call still answers `navChanged`; any other op dying
    /// the same death produced nothing and is the error `navigated mid-call`.
    @MainActor
    private func drive(_ view: PageView, _ call: String, mutating: Bool = false, _ done: @escaping ([String: Any]) -> Void) {
        let js = """
        \(AskJS.load("drive.js"))
        ;return (async function () {
          var d = window.__drive;
          if (!d) return { error: "drive.js not loaded" };
          // A tab painting in the dark (the offscreen room, anything
          // backgrounded) gets no animation frames, and drive.js's
          // actionability loop lives on them — lend it a 16ms tick for the
          // span of the call. The page's own rAF is restored after.
          var rafWas = window.requestAnimationFrame;
          var dark = document.visibilityState !== 'visible';
          if (dark) {
            try { window.requestAnimationFrame = function (f) { return setTimeout(function () { f(Date.now()); }, 16); }; }
            catch (e) { dark = false; }
          }
          try { return await (\(call))(d); }
          catch (e) {
            var o = { error: "" + (e && e.message || e) };
            if (e && e.code) o.code = "" + e.code;
            return o;
          }
          finally { if (dark) { try { window.requestAnimationFrame = rafWas; } catch (e) {} } }
        })()
        """
        // A navigation mid-call tears the context down before the completion
        // can run — park the answerer so `navigated` can settle it.
        let tab = browser.tabs.first { $0.built === view }
        let ticket = nextFlight; nextFlight += 1
        var settled = false
        let settle: ([String: Any]) -> Void = { out in
            if settled { return }
            settled = true
            if let tab { self.flying[tab.id]?[ticket] = nil }
            done(out)
        }
        if let tab { flying[tab.id, default: [:]][ticket] = (mutating, settle) }
        view.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value):
                    settle(value as? [String: Any] ?? ["value": Bench.plain(value)])
                case .failure(let error):
                    settle(["error": error.localizedDescription])
                }
            }
        }
    }

    /// A commit is the page's context going away. What it still owed us
    /// splits on what the call was doing: a mutation may well have caused
    /// the navigation it dies of, so it still answers "the action ran, the
    /// page moved" — but a read interrupted mid-call produced nothing, and
    /// saying so is the honest answer.
    @MainActor
    private func navigated(_ view: WKWebView) {
        guard let tab = browser.tabs.first(where: { $0.built === view }),
              let owed = flying.removeValue(forKey: tab.id) else { return }
        for flight in owed.values {
            flight.settle(flight.mutating
                          ? ["ok": true, "navChanged": true]
                          : ["error": "navigated mid-call", "code": "NAVIGATED"])
        }
    }

    /// Called from `webView(_:didCommit:)` — the moment a new document
    /// replaces the one in-flight calls were talking to.
    static func noteCommit(webView: WKWebView) {
        MainActor.assumeIsolated { (AskRuntime.drive as? Drive)?.navigated(webView) }
    }

    @MainActor
    private func snapshot(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        var opts: [String: Any] = [:]
        for key in ["scope", "boxes", "maxChars"] { if let v = args[key] { opts[key] = v } }
        drive(view, "function (d) { return d.snapshot(\(json(opts))); }", done)
    }

    @MainActor
    private func code(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let js = args["js"] as? String else { done(["error": "page.code needs js"]); return }
        // run() answers {value, consoleLines} — the value as safe() carried
        // it, and how much the console heard meanwhile. A commit mid-run is
        // an error, not navChanged: a program torn down before it returned
        // produced nothing, whatever it was about to do.
        drive(view, "function (d) { return d.run(\(json(js))); }", done)
    }

    @MainActor
    private func console(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        drive(view, """
        function (d) {
          var c = d.console, m = (typeof c === 'function') ? c.call(d) : c;
          if (m && m.messages) return m;
          if (m) return { messages: m };
          return { messages: [] };
        }
        """, done)
    }

    @MainActor
    private func frames(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        drive(view, """
        function (d) {
          var f = d.frames, m = (typeof f === 'function') ? f.call(d) : f;
          if (m && m.frames) return m;
          if (m) return { frames: m };
          return { frames: [] };
        }
        """, done)
    }

    // MARK: - screenshots

    /// Where shots go that no path was given for: the app's own folder, under
    /// ask/shots, named by tab and time.
    @MainActor
    private func shotsFolder() -> URL {
        let folder = Store.file("ask").appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    private func screenshot(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        let path = (args["path"] as? String).map { NSString(string: $0).expandingTildeInPath }
            ?? shotsFolder().appendingPathComponent("shot-\(Bench.short(tab))-\(Int(Date().timeIntervalSince1970 * 1000)).png").path
        let marks = args["marks"] as? Bool == true
        let width = (args["width"] as? NSNumber)?.doubleValue

        let mark = """
        \(AskJS.load("drive.js"))
        ;(window.__drive && typeof window.__drive.mark === 'function') ? window.__drive.mark() : null
        """
        let unmark = "(window.__drive && typeof window.__drive.unmark === 'function') ? window.__drive.unmark() : null"

        func finish(_ reply: [String: Any]) {
            if marks {
                DriveJS.run(view, unmark) { _, _ in MainActor.assumeIsolated { done(reply) } }
            } else {
                done(reply)
            }
        }
        func snap(_ width: Double?, _ jpeg: Bool) {
            let shot = WKSnapshotConfiguration()
            shot.afterScreenUpdates = true
            if let width { shot.snapshotWidth = NSNumber(value: width) }
            view.takeSnapshot(with: shot) { image, error in
                MainActor.assumeIsolated {
                    guard let image, let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff)
                    else {
                        finish(["error": error?.localizedDescription ?? "no picture"])
                        return
                    }
                    let data = jpeg
                        ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                        : rep.representation(using: .png, properties: [:])
                    guard let data else { finish(["error": "no picture"]); return }
                    // ~1.5 MB is all an answer should carry: a big PNG goes
                    // once more at half width, then as a JPEG. A JPEG over
                    // the cap is written anyway — it won't get smaller.
                    if data.count > 1_500_000, !jpeg {
                        if width == nil && rep.pixelsWide > 320 {
                            snap(Double(rep.pixelsWide) / 2, false)
                        } else {
                            snap(width, true)
                        }
                        return
                    }
                    do {
                        try data.write(to: URL(fileURLWithPath: path))
                        finish(["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh,
                                "data": data.base64EncodedString(),
                                "format": jpeg ? "jpeg" : "png"])
                    } catch {
                        finish(["error": error.localizedDescription])
                    }
                }
            }
        }
        if marks {
            DriveJS.run(view, mark) { _, _ in MainActor.assumeIsolated { snap(width, false) } }
        } else {
            snap(width, false)
        }
    }

    // MARK: - actions

    /// What an act's locator keys amount to, for `__drive.resolve`. `ref`,
    /// `loc` (`css:`/`role:`/`href:`/`xpath:`), `css`, and — for verbs that
    /// don't take `text` as a payload — `text=…` by the element's words.
    @MainActor
    private func query(_ verb: String, _ args: [String: Any]) -> [String: Any] {
        var q: [String: Any] = [:]
        for key in ["ref", "loc", "css"] { if let v = args[key] { q[key] = v } }
        if !["fill", "type", "press", "clickAt"].contains(verb), let t = args["text"] { q["text"] = t }
        return q
    }

    /// The arguments handed to `__drive.act` — everything but the tab, and
    /// never a gate-only key: the gate read `why` for the card's text, and
    /// the page is not the card's business.
    @MainActor
    private func actArgs(_ args: [String: Any]) -> [String: Any] {
        args.filter { $0.key != "tab" && !Policy.gateKeys.contains($0.key) }
    }

    /// A mutating action through drive.js, with a fresh snapshot folded in
    /// when the caller asked for one.
    @MainActor
    private func actJS(_ op: String, _ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        let verb = String(op.dropFirst(4))
        // Scroll's "page" is a word, not a locator — the driver reads
        // `query === 'page'` before it resolves anything.
        var q: Any = query(verb, args)
        if verb == "scroll" {
            if (args["ref"] as? String) == "page" { q = "page" }
            else if (q as? [String: Any])?.isEmpty == true { q = NSNull() }
        }
        drive(view, "function (d) { return d.act(\(json(verb)), \(json(q)), \(json(actArgs(args)))); }", mutating: true) { [weak self] out in
            MainActor.assumeIsolated {
                // drive.js folds a fresh snapshot in itself when asked; this
                // is the backstop for one that doesn't know withSnapshot.
                guard args["withSnapshot"] as? Bool == true, out["error"] == nil, out["snapshot"] == nil else {
                    done(out)
                    return
                }
                self?.drive(view, "function (d) { return d.snapshot({}); }") { snap in
                    var out = out
                    if snap["error"] == nil { out["snapshot"] = snap["snapshot"] ?? snap }
                    done(out)
                }
            }
        }
    }

    /// The middle of what a locator names, in the page's points, scrolled into
    /// view first — through `__drive` when there's a `ref`/`loc` to honour,
    /// through bench's finder for `css`/`text=`, which need nothing page-side.
    @MainActor
    private func point(_ view: PageView, _ q: [String: Any], _ done: @escaping ([Double]?, String?) -> Void) {
        if q["ref"] != nil || q["loc"] != nil {
            drive(view, """
            function (d) {
              var el = d.resolve(\(json(q)));
              if (!el) return { error: "nothing matches " + JSON.stringify(\(json(q))) };
              el.scrollIntoView({ block: 'center', inline: 'nearest' });
              var r = el.getBoundingClientRect();
              return { at: [r.left + r.width / 2, r.top + r.height / 2] };
            }
            """) { out in
                if let error = out["error"] as? String { done(nil, error); return }
                done((out["at"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }, nil)
            }
            return
        }
        let selector = (q["css"] as? String) ?? (q["text"] as? String).map { "text=\($0)" }
        guard let selector else {
            done(nil, "no locator — ref, loc, css or text")
            return
        }
        DriveJS.run(view, Bench.locate(selector)) { value, error in
            if let point = value as? [Double], point.count == 2 {
                done(point, nil)
            } else {
                done(nil, error ?? "nothing matches \(selector)")
            }
        }
    }

    /// Focus the element a locator names — the step before keys go to it the
    /// way a person's typing would.
    @MainActor
    private func focus(_ view: PageView, _ q: [String: Any], _ done: @escaping (String?) -> Void) {
        if q["ref"] != nil || q["loc"] != nil {
            drive(view, """
            function (d) {
              var el = d.resolve(\(json(q)));
              if (!el) return { error: "nothing matches " + JSON.stringify(\(json(q))) };
              el.scrollIntoView({ block: 'center', inline: 'nearest' });
              if (el.focus) el.focus();
              return { ok: true };
            }
            """) { done($0["error"] as? String) }
            return
        }
        let selector = (q["css"] as? String) ?? (q["text"] as? String).map { "text=\($0)" }
        guard let selector else { done(nil); return }
        DriveJS.run(view, """
        (function () {
          var s = \(json(selector)), el = null;
          if (s.indexOf('text=') === 0) {
            var want = s.slice(5).trim().toLowerCase();
            el = Array.prototype.find.call(document.querySelectorAll('button, a, [role=button], input[type=submit], input, textarea'), function (e) {
              return ((e.innerText || e.value || '').trim().toLowerCase()) === want;
            }) || null;
          } else {
            el = document.querySelector(s);
          }
          if (!el) return 'nothing matches ' + s;
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          if (el.focus) el.focus();
          return 'ok';
        })()
        """) { value, error in
            let said = value as? String
            done(said == "ok" ? nil : (error ?? said ?? "nothing matches \(selector)"))
        }
    }

    /// A real press at a page point — down and up on the view itself, the way
    /// `bench tap` clicks: trusted, in whichever window the view is housed.
    @MainActor
    private func mouse(_ view: PageView, at point: [Double], button: String, clicks: Int, flags: NSEvent.ModifierFlags) -> String? {
        guard let window = view.window else { return "the tab's view has no window" }
        let local = NSPoint(x: point[0], y: view.isFlipped ? point[1] : view.bounds.height - point[1])
        let spot = view.convert(local, to: nil)
        let downType: NSEvent.EventType
        let upType: NSEvent.EventType
        switch button {
        case "right": (downType, upType) = (.rightMouseDown, .rightMouseUp)
        case "middle": (downType, upType) = (.otherMouseDown, .otherMouseUp)
        default: (downType, upType) = (.leftMouseDown, .leftMouseUp)
        }
        Drive.injecting += 1
        defer { Drive.injecting -= 1 }
        for click in 1...max(1, clicks) {
            for type in [downType, upType] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: spot, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: click, pressure: type == downType ? 1 : 0
                ) else { continue }
                Drive.note(event)
                switch type {
                case .leftMouseDown: view.mouseDown(with: event)
                case .leftMouseUp: view.mouseUp(with: event)
                case .rightMouseDown: view.rightMouseDown(with: event)
                case .rightMouseUp: view.rightMouseUp(with: event)
                case .otherMouseDown: view.otherMouseDown(with: event)
                case .otherMouseUp: view.otherMouseUp(with: event)
                default: break
                }
            }
        }
        return nil
    }

    /// One key, down and up, as a real event on the view — `bench key`'s
    /// delivery for a single press.
    @MainActor
    private func key(_ view: PageView, code: UInt16, chars: String, flags: NSEvent.ModifierFlags) {
        Drive.injecting += 1
        defer { Drive.injecting -= 1 }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            ) else { continue }
            Drive.note(event)
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }

    @MainActor
    private func flags(_ names: [String]?) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names ?? [] {
            switch name {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            case "opt": flags.insert(.option)
            default: break
            }
        }
        return flags
    }

    /// A key by name — "Enter", "Tab", "Escape", "Backspace", "a" — as the
    /// key code and characters an event carries. The table is drive.js's own
    /// keymap's: same named keys, same digits, so a press lands the same with
    /// or without a driver in the page.
    @MainActor
    private func keyFor(_ name: String) -> (UInt16, String) {
        switch name.lowercased() {
        case "enter", "return": return (36, "\r")
        case "tab": return (48, "\t")
        case "escape", "esc": return (53, "\u{1B}")
        case "backspace": return (51, "\u{7F}")
        case "delete": return (117, "\u{F728}")
        case "space": return (49, " ")
        case "arrowup", "up": return (126, "\u{F700}")
        case "arrowdown", "down": return (125, "\u{F701}")
        case "arrowleft", "left": return (123, "\u{F702}")
        case "arrowright", "right": return (124, "\u{F703}")
        case "home": return (115, "\u{F729}")
        case "end": return (119, "\u{F72B}")
        case "pageup": return (116, "\u{F72C}")
        case "pagedown": return (121, "\u{F72D}")
        case "f1": return (122, "\u{F704}")
        case "f2": return (120, "\u{F705}")
        case "f3": return (99, "\u{F706}")
        case "f4": return (118, "\u{F707}")
        case "f5": return (96, "\u{F708}")
        case "f6": return (97, "\u{F709}")
        case "f7": return (98, "\u{F70A}")
        case "f8": return (100, "\u{F70B}")
        case "f9": return (101, "\u{F70C}")
        case "f10": return (109, "\u{F70D}")
        case "f11": return (103, "\u{F70E}")
        case "f12": return (111, "\u{F70F}")
        default:
            let character = name.first ?? " "
            // Digits have their own key codes; letters and the rest go
            // through bench's table (space where it has no answer).
            let digits: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29]
            return (digits[character] ?? Bench.keyCode(for: character), String(character))
        }
    }

    @MainActor
    private func click(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        let tier = args["tier"] as? String ?? "auto"
        if tier == "js" { actJS("act.click", args, done, from: origin); return }
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        let q = query("click", args)
        var callArgs = actArgs(args)
        callArgs["tier"] = tier == "event" ? "event" : "auto"
        // The driver does the actionability work — scrolls, waits the box
        // still, asks what sits at the centre — and for the event tier hands
        // the point back rather than clicking: the trusted part is ours.
        drive(view, "function (d) { return d.act('click', \(json(q)), \(json(callArgs))); }", mutating: true) { [weak self] out in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let at = (out["at"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }),
                   (out["handoff"] as? String) == "event" || out["escalate"] as? Bool == true || out["ignored"] as? Bool == true {
                    self.handClick(view, out: out, at: at, args: args, done)
                    return
                }
                let missing = (out["error"] as? String) == "drive.js not loaded"
                if missing, q["ref"] == nil, q["loc"] == nil {
                    // No driver in the page — but css/text are locators the
                    // bench's own finder can still take to a point.
                    self.clickResolved(view, q, args: args, done)
                } else {
                    done(out)
                }
            }
        }
    }

    /// A handoff or escalation answer became a real click: down and up at the
    /// point the driver proved out, with its button/double/modifiers.
    @MainActor
    private func handClick(_ view: PageView, out: [String: Any], at: [Double], args: [String: Any], _ done: ([String: Any]) -> Void) {
        let flags = flags((out["modifiers"] as? [String]) ?? args["modifiers"] as? [String])
        let clicks = (out["double"] as? Bool ?? args["double"] as? Bool) == true ? 2 : 1
        if let error = mouse(view, at: at, button: out["button"] as? String ?? args["button"] as? String ?? "left", clicks: clicks, flags: flags) {
            done(["error": error])
            return
        }
        var reply = out
        reply["ok"] = true
        reply["tier"] = "event"
        reply["handoff"] = nil
        reply["at"] = at.map { Int($0) }
        done(reply)
    }

    /// The event tier with no driver to ask: bench's finder takes a css/text
    /// locator to a point, and the click lands for real.
    @MainActor
    private func clickResolved(_ view: PageView, _ q: [String: Any], args: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        point(view, q) { at, error in
            MainActor.assumeIsolated {
                guard let at else { done(["error": error ?? "nothing to click"]); return }
                let flags = self.flags(args["modifiers"] as? [String])
                let clicks = (args["double"] as? Bool == true) ? 2 : 1
                if let error = self.mouse(view, at: at, button: args["button"] as? String ?? "left", clicks: clicks, flags: flags) {
                    done(["error": error])
                    return
                }
                done(["ok": true, "at": at.map { Int($0) }, "tier": "event"])
            }
        }
    }

    @MainActor
    private func type(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let text = args["text"] as? String else { done(["error": "act.type needs text"]); return }
        // Every character is paced, even at delay 0 — a burst sent
        // recursively inside one run-loop turn loses keys to WebKit's own
        // input handling. 16ms is a frame: fast enough to feel typed, slow
        // enough for each event to land before the next is handed over.
        let pace = max((args["delay"] as? NSNumber)?.doubleValue ?? 0, 16) / 1000
        focus(view, query("type", args)) { error in
            MainActor.assumeIsolated {
                if let error { done(["error": error]); return }
                view.window?.makeFirstResponder(view)
                let characters = Array(text)
                var sent = 0
                func next() {
                    MainActor.assumeIsolated {
                        if sent >= characters.count {
                            done(["ok": true, "typed": text])
                            return
                        }
                        let character = characters[sent]
                        sent += 1
                        self.key(view, code: Bench.keyCode(for: character), chars: String(character), flags: [])
                        DispatchQueue.main.asyncAfter(deadline: .now() + pace) { next() }
                    }
                }
                next()
            }
        }
    }

    @MainActor
    private func press(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let name = args["key"] as? String else { done(["error": "act.press needs key"]); return }
        let (code, chars) = keyFor(name)
        let mflags = flags(args["modifiers"] as? [String])
        // A locator, when one came, gets the focus first — Enter on a field
        // is a different press from Enter on the page.
        focus(view, query("press", args)) { error in
            MainActor.assumeIsolated {
                if let error { done(["error": error]); return }
                view.window?.makeFirstResponder(view)
                self.key(view, code: code, chars: chars, flags: mflags)
                done(["ok": true, "key": name])
            }
        }
    }

    @MainActor
    private func clickAt(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue else {
            done(["error": "act.clickAt needs x and y"])
            return
        }
        let flags = flags(args["modifiers"] as? [String])
        let clicks = (args["double"] as? Bool == true) ? 2 : 1
        // What's there is worth knowing even though the tier needs nothing
        // page-side — the driver describes whatever the point lands on.
        drive(view, """
        function (d) {
          var el = document.elementFromPoint ? document.elementFromPoint(\(x), \(y)) : null;
          return { element: el && d._describe ? d._describe(el) : null };
        }
        """) { out in
            MainActor.assumeIsolated {
                if let error = self.mouse(view, at: [x, y], button: args["button"] as? String ?? "left", clicks: clicks, flags: flags) {
                    done(["error": error])
                    return
                }
                var reply: [String: Any] = ["ok": true, "at": [Int(x), Int(y)], "tier": "event"]
                if let element = out["element"], !(element is NSNull) { reply["element"] = element }
                done(reply)
            }
        }
    }

    // MARK: - agent.meta

    @MainActor
    private func lease(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        let on = args["on"] as? Bool ?? true
        if on {
            sessions[origin, default: Share()].leases.insert(tab.id)
            armTouchMonitor()
        } else {
            sessions[origin]?.leases.remove(tab.id)
        }
        done(["id": Bench.short(tab), "lease": on])
    }

    /// The wire's hand on the Ask rail — and a line into the agent behind
    /// it. `open` shows or hides the panel as ever; `send` posts the text
    /// as the user's own message through Mind.send, so the turn that
    /// answers is the real in-app agent's — the composer's return key
    /// makes the same call. `steer` is the follow-up box's equivalent —
    /// Mind.steer, which sends when no chat is open — and `stop` the stop
    /// button's: Mind.stop ends the running turn. The calls ride one
    /// request fine (open the rail and send into it), and `send` alone
    /// runs behind a shut panel: the harness is seated here because the
    /// panel's first appearance is what otherwise seats it — a steer that
    /// falls back to send needs the seat just the same.
    @MainActor
    private func ask(_ args: [String: Any], _ done: ([String: Any]) -> Void) {
        if let on = args["open"] as? Bool { Mind.shared.open = on }
        var reply: [String: Any] = ["open": Mind.shared.open]
        if args["new"] as? Bool == true {
            // A fresh chat per scenario — Mind.newChat also clears the
            // chips' grants, which is exactly the isolation the runner is
            // after (design/benchmarks.md §"the one code addition").
            Mind.shared.newChat()
            appChat = Mind.shared.currentID    // nil until the next send
            reply["ok"] = true
            reply["newChat"] = true
        }
        if let text = args["send"] as? String {
            // Mind.send lets a blank fall on the floor — say so rather
            // than name a chat nothing was ever posted to.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply["error"] = "ui.ask send needs a non-empty text"
                done(reply)
                return
            }
            Harness.shared.attach()
            Mind.shared.send(text)
            appChat = Mind.shared.currentID
            reply["ok"] = true
            if let chat = Mind.shared.currentID {
                reply["chat"] = chat.uuidString
            }
        }
        if let text = args["steer"] as? String {
            // Same honesty as send: Mind.steer lets a blank fall on the
            // floor — say so rather than answer ok to nothing.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply["error"] = "ui.ask steer needs a non-empty text"
                done(reply)
                return
            }
            Harness.shared.attach()
            Mind.shared.steer(text)
            appChat = Mind.shared.currentID
            reply["ok"] = true
            // A steer with no chat open is a send — carry the chat it made.
            if let chat = Mind.shared.currentID {
                reply["chat"] = chat.uuidString
            }
        }
        if args["stop"] as? Bool == true {
            Mind.shared.stop()
            reply["ok"] = true
        }
        done(reply)
    }

    /// The user's own act on a page, as PageView sees it: a mouse down or a
    /// key press on the real window. Clicks that reach PageView this way are
    /// real by definition — the driver's own events are handed to the view
    /// directly (`injecting` still guards the path, in case one day they are
    /// posted through `sendEvent`). A view painting in the offscreen room
    /// answers to nobody's hand.
    static func noteTouch(webView: PageView) {
        guard injecting == 0, let window = webView.window, window === Links.window else { return }
        // A key WebKit sent back up the chain unused is still our key — same
        // timestamp, same code. (Only keys come back that way, and asking a
        // mouse event for its keyCode is an exception, so keys only.)
        if let event = NSApp.currentEvent, event.type == .keyDown || event.type == .keyUp,
           injected.contains(where: { $0.type == event.type && PageView.same($0, event) }) {
            return
        }
        MainActor.assumeIsolated { (AskRuntime.drive as? Drive)?.touched(webView) }
    }

    /// The event tap that watches the real stream. PageView never sees most
    /// clicks — WebKit's inner view takes them first — so the lease listens
    /// upstream, at `sendEvent`, where every event on the real window passes
    /// and none of the driver's do (they're handed to the view, not sent).
    @MainActor private var touchMonitor: Any?

    @MainActor
    private func armTouchMonitor() {
        guard touchMonitor == nil else { return }
        touchMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.realTouch(event) }
            return event
        }
    }

    /// A real event on the real window, before it lands. On the page itself,
    /// the touch belongs to that page's tab; anywhere else in the window —
    /// the strip, the field, a shortcut that swallows the key — it belongs
    /// to whichever tab is on stage, the one the lease is about.
    @MainActor
    private func realTouch(_ event: NSEvent) {
        guard let window = event.window, window === Links.window,
              sessions.values.contains(where: { !$0.leases.isEmpty }) else { return }
        var view: NSView?
        if event.type == .keyDown {
            view = window.firstResponder as? NSView
        } else {
            view = window.contentView?.hitTest(event.locationInWindow)
        }
        while let v = view {
            if let page = v as? PageView { touched(page); return }
            view = v.superview
        }
        if let active = browser.active { release(active.id) }
    }

    /// A lease on this tab, whoever holds it, ends — `lease.lost` goes only
    /// to the session that was holding it.
    @MainActor
    private func release(_ tab: UUID) {
        for held in Array(sessions.keys) where sessions[held]?.leases.contains(tab) == true {
            sessions[held]?.leases.remove(tab)
            emit("lease.lost", ["id": String(tab.uuidString.prefix(8)).lowercased()], to: held)
        }
    }

    @MainActor
    private func touched(_ view: PageView) {
        guard let tab = browser.tabs.first(where: { $0.built === view }) else { return }
        release(tab.id)
    }

    // MARK: - the row as events

    /// The 0.5s coalesced diff that turns `browser.tabs` into `tab.added`,
    /// `tab.navigated`, `tab.title` and `tab.closed` — on for as long as
    /// anyone is listening.
    @MainActor
    private func armDiff() {
        guard diffTimer == nil, onEvent != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.diff() }
        timer.resume()
        diffTimer = timer
    }

    /// The watched row — agent tabs and attached ones — against what it was
    /// last time this ran. The first pass only primes, so tabs that predate
    /// the listener aren't announced as new. `tab.*` is a broadcast: every
    /// subscribed session watches the same row, and a tab one session holds
    /// is news for all of them.
    @MainActor
    private func diff() {
        let held = Set(sessions.values.flatMap(\.attached))
        let watched = browser.tabs.filter { $0.bench || held.contains($0.id) }
        let now = Dictionary(uniqueKeysWithValues: watched.map {
            ($0.id, ($0.address?.absoluteString ?? "", $0.title))
        })
        defer { seen = now; primed = true }
        guard primed else { return }
        for tab in watched {
            let id = Bench.short(tab)
            let url = tab.address?.absoluteString ?? ""
            switch seen[tab.id] {
            case .none:
                emit("tab.added", ["id": id, "url": url, "title": tab.title])
            case .some(let old) where old.0 != url:
                emit("tab.navigated", ["id": id, "url": url, "title": tab.title])
            case .some(let old) where old.1 != tab.title:
                emit("tab.title", ["id": id, "title": tab.title])
            default:
                break
            }
        }
        for id in seen.keys where now[id] == nil {
            emit("tab.closed", ["id": String(id.uuidString.prefix(8)).lowercased()])
            drop(id)
        }
    }
}

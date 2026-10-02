import AppKit
import Foundation
import SwiftUI
import WebKit

// Ask — the assistant that lives beside the page: a chat panel on the window's
// right, an agent behind it that can read and drive the browser in tabs of its
// own or ones it has been handed.
//
// This file is the contract the parts are built against: the chat model and
// the panel's state live here; the page-side library (Runtime/ask/drive.js),
// the ops layer (Drive.swift, AgentSocket.swift), the model host
// (Harness.swift, Runtime/ask/harness.js) and the views (AskUI.swift) are their
// own files, and none of them reach into each other — everything meets here.

// MARK: - the model

/// A page handed to the agent — the composer's "@" chips. Attaching is the
/// consent: a chip's tab may be read and driven by the agent for the rest of
/// the chat — starting a new one or deleting one clears every grant — while
/// every other tab of yours stays metadata (id, title, address) only.
struct AskTab: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var address: String
}

/// One piece of what a turn did, in the order it happened — the reason the
/// stream can draw "wrote a paragraph, ran these calls, wrote again" instead
/// of one flattened blob. Display-only: `toHistory` keeps reading `text` and
/// `tools`, which still carry the same content unfolded.
struct AskBlock: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case text, tool, artifact }
    /// Minted when the block is pushed — stable across in-place updates
    /// (a text block growing by deltas, a tool's result landing).
    var id = UUID()
    var kind: Kind
    /// The paragraph text for `.text` blocks.
    var text = ""
    /// The call for `.tool` blocks — the same value the `tools` array holds.
    var tool: AskMessage.Tool?
    /// A picture's place on disk for `.artifact` blocks (a screenshot the
    /// turn took); `tab` names the agent tab it came from when it did.
    var path: String?
    var tab: String?

    /// The memberwise init, spelled out — the custom decoder below would
    /// otherwise be the only one and the factories couldn't mint.
    init(id: UUID = UUID(), kind: Kind, text: String = "", tool: AskMessage.Tool? = nil,
         path: String? = nil, tab: String? = nil) {
        self.id = id; self.kind = kind; self.text = text
        self.tool = tool; self.path = path; self.tab = tab
    }

    static func text(_ text: String) -> AskBlock { AskBlock(kind: .text, text: text) }
    static func tool(_ tool: AskMessage.Tool) -> AskBlock { AskBlock(kind: .tool, tool: tool) }
    static func artifact(_ path: String, tab: String? = nil) -> AskBlock {
        AskBlock(kind: .artifact, path: path, tab: tab)
    }

    /// The wire shape — `{kind:"text", text:…}`, `{kind:"tool", tool:{…}}`,
    /// `{kind:"artifact", path:…, tab:…}` — what harness.js emits. `id` is
    /// a view concern, minted on decode rather than carried.
    private enum Wire: String, CodingKey { case kind, text, tool, path, tab }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Wire.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        tool = try c.decodeIfPresent(AskMessage.Tool.self, forKey: .tool)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        tab = try c.decodeIfPresent(String.self, forKey: .tab)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Wire.self)
        try c.encode(kind, forKey: .kind)
        switch kind {
        case .text: try c.encode(text, forKey: .text)
        case .tool: try c.encodeIfPresent(tool, forKey: .tool)
        case .artifact:
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(tab, forKey: .tab)
        }
    }
}

/// One line in a chat, kept on disk between launches.
struct AskMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case you, agent, note }
    /// A tool call the agent made, or is mid-way through.
    struct Tool: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var args: String
        /// nil while it runs, then the answer — a string already trimmed for
        /// showing, not the tool's whole reply.
        var result: String?
        var failed = false
        /// The PNG the result wrote, when it wrote one (a page.screenshot
        /// lands here as a path the panel can thumb through).
        var shot: String?
        /// The model's own one-line reason for the call, when it gave one —
        /// the `</>` lines' caption.
        var why: String?
    }
    var id = UUID()
    var role: Role
    var text: String
    var tools: [Tool] = []
    /// What the turn did, in order — nil on chats written before blocks
    /// existed; `orderedBlocks` derives them when it is.
    var blocks: [AskBlock]? = nil
    /// How long the turn this message ends worked — stamped on `.done`,
    /// feeding the "Worked for 4m 39s" header; nil while it still runs.
    var workedFor: TimeInterval?
    /// A .note that is an error (a provider's refusal, a dead turn) —
    /// draws the tinted card with the retry pill instead of a quiet line.
    var isError = false
    /// The tabs the message rode in on — the consent chips, kept on the
    /// message because the composer lets its chips go. (Renamed from
    /// `attachments` when the typed pieces below arrived.)
    var tabs: [AskTab] = []
    /// The files, images and sites sent with it — AskAttach pieces,
    /// filled at send so history shows what the model was handed.
    var attachments: [AskAttach] = []
    var when = Date()
    /// The model that answered it — an id like "openrouter/…", stamped in
    /// `hear(.message)` so a chat that mixes brains can say who said what.
    var model: String?
    /// How many times the turn it began has been re-run — the bubble's
    /// quiet "· retried ×N"; never told to the model.
    var retries = 0
    var approval: AskApproval?

    /// The work in the order it happened. Messages written before blocks
    /// existed read text-then-tools — the same flat order they always drew.
    var orderedBlocks: [AskBlock] {
        if let blocks { return blocks }
        var derived: [AskBlock] = []
        if !text.isEmpty { derived.append(.text(text)) }
        derived.append(contentsOf: tools.map(AskBlock.tool))
        return derived
    }

    /// Drop what `committed` already carries. A closing `.message`
    /// re-states the whole run, but the stretch an earlier sealed message
    /// holds (a steered turn's work) is already on screen — matching is
    /// the run's own order: committed blocks are a prefix, committed text
    /// a prefix of the text, committed calls known by id. A paragraph that
    /// grew across the seam keeps only its tail here.
    mutating func trim(committedBy committed: [AskMessage]) {
        var words = ""
        var prefix: [AskBlock] = []
        var toolIDs: Set<String> = []
        for message in committed {
            words += message.text
            prefix += message.orderedBlocks
            toolIDs.formUnion(message.tools.map(\.id))
        }
        if text.hasPrefix(words) { text = String(text.dropFirst(words.count)) }
        tools.removeAll { toolIDs.contains($0.id) }
        guard var rest = blocks else { return }
        var i = 0
        outer: while i < prefix.count, i < rest.count {
            switch (prefix[i].kind, rest[i].kind) {
            case (.tool, .tool) where prefix[i].tool?.id == rest[i].tool?.id:
                i += 1
            case (.artifact, .artifact) where prefix[i].path == rest[i].path:
                i += 1
            case (.text, .text):
                if rest[i].text == prefix[i].text {
                    i += 1
                } else if rest[i].text.hasPrefix(prefix[i].text) {
                    rest[i].text = String(rest[i].text.dropFirst(prefix[i].text.count))
                    i += 1
                } else {
                    break outer
                }
            default:
                break outer
            }
        }
        blocks = Array(rest.dropFirst(i))
    }
}

extension AskMessage {
    /// The model/retries keys are newer than the files on disk —
    /// decode-missing reads nil/0, and everything else is as forgiving.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        tools = try c.decodeIfPresent([Tool].self, forKey: .tools) ?? []
        if let granted = try c.decodeIfPresent([AskTab].self, forKey: .tabs) {
            tabs = granted
            // The typed pieces are newer than every file on disk — and a
            // malformed one shouldn't eat the message, so it's read soft.
            attachments = (try? c.decodeIfPresent([AskAttach].self, forKey: .attachments)) ?? []
        } else {
            // Before the fields split, "attachments" carried the tabs.
            tabs = (try? c.decodeIfPresent([AskTab].self, forKey: .attachments)) ?? []
            attachments = []
        }
        when = try c.decodeIfPresent(Date.self, forKey: .when) ?? Date()
        model = try c.decodeIfPresent(String.self, forKey: .model)
        retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? 0
        approval = try c.decodeIfPresent(AskApproval.self, forKey: .approval)
        // Blocks, workedFor and isError are newer than every file on disk —
        // missing reads nil/0/false, and a malformed block array shouldn't
        // eat the message, so it reads soft.
        blocks = (try? c.decodeIfPresent([AskBlock].self, forKey: .blocks)) ?? nil
        workedFor = try c.decodeIfPresent(TimeInterval.self, forKey: .workedFor)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

/// A conversation: its messages, the tabs attached when each was sent, the
/// model it spoke to. Persisted to chats/<id>.json under the app's folder.
struct AskChat: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New chat"
    var model = ""
    var messages: [AskMessage] = []
    var when = Date()
    /// The session's leash — read asks nothing, guard asks on the heavy
    /// ops, full asks never (design/permissions.md §1). Chat-scoped like
    /// the consent it steers; the composer's mode chip moves it.
    var mode = AskMode.guard
    /// How hard the answering brain reasons. nil is "auto", the model's
    /// own default. A set value is a level the composer offered
    /// ("none", "minimal", "low", "medium", "high", "xhigh", "max") or
    /// the older word "off". Chat-scoped like the mode; the composer's
    /// reasoning chip moves it. The wire does not send it raw —
    /// AskChips.wireEffort maps it onto a level this model accepts.
    var effort: String? = nil
    /// The live turn's stamp (design/interaction.md §2): set on every
    /// send/retry, carried inside the job's chat, echoed on each event —
    /// a killed turn's trailing words can then be told from the live
    /// turn's and dropped.
    var turn: UUID?
    /// When the live turn began — set beside `turn`; it drives the
    /// "Working for M:SS" tick and the `workedFor` stamped on `.done`.
    var turnStartedAt: Date?
    /// The message the list had last drawn this chat through — a chat
    /// with content past it wears the unread dot.
    var lastSeen: UUID?
    /// The chat this one branched from (design/interaction.md §3) —
    /// nil for a chat that began life new.
    var parent: UUID?
}

extension AskChat {
    /// Old chats decode with mode .guard, no stamp, no parent — every key
    /// newer than the files on disk reads missing-as-default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        messages = try c.decodeIfPresent([AskMessage].self, forKey: .messages) ?? []
        when = try c.decodeIfPresent(Date.self, forKey: .when) ?? Date()
        mode = try c.decodeIfPresent(AskMode.self, forKey: .mode) ?? .guard
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        turn = try c.decodeIfPresent(UUID.self, forKey: .turn)
        turnStartedAt = try c.decodeIfPresent(Date.self, forKey: .turnStartedAt)
        lastSeen = try c.decodeIfPresent(UUID.self, forKey: .lastSeen)
        parent = try c.decodeIfPresent(UUID.self, forKey: .parent)
    }

    /// Whether the wire this chat speaks to takes a reasoning effort —
    /// AskModel.canReason's same rule, read off the stored
    /// "provider/model" id (the provider is the part before the slash).
    var canReason: Bool {
        ["openrouter/", "codex/"].contains { model.hasPrefix($0) }
    }
}

/// Which brain is asked. `provider` selects the wire (`"openrouter"`,
/// `"codex"`, `"devin"`, `"echo"`); `model` is the wire's own name for it.
struct AskModel: Codable, Equatable, Identifiable {
    var provider: String
    var model: String
    var label: String {
        let tail = model.split(separator: "/").last.map(String.init) ?? model
        return tail.split(separator: "-").map { word in
            let part = String(word)
            let upper = part.uppercased()
            if ["GPT", "GLM", "AI", "REST"].contains(upper) { return upper }
            return part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ").replacingOccurrences(of: "GPT ", with: "GPT-")
            .replacingOccurrences(of: "GLM ", with: "GLM-")
    }
    var id: String { "\(provider)/\(model)" }

    var readout: String { label }

    /// Whether the wire takes a reasoning effort — the reasoning chip's
    /// whole case for showing (openrouter and codex carry one; a REST
    /// turn and the echo brain don't).
    var canReason: Bool { ["openrouter", "codex"].contains(provider) }
}

// MARK: - the engine

/// What the model host is told and what it tells back. The harness in
/// Runtime/ask/harness.js is one engine; the echo engine is the other.
struct AskJob {
    /// The chat as it stands, messages and all.
    var chat: AskChat
    /// Tabs attached for this turn — the agent may read and drive these.
    var tabs: [AskTab]
    /// The typed attachments sent with it — images, files, sites — filled
    /// by Mind at send (text inside the cap, image bytes under it, paths
    /// and urls for the rest); the wire serializes what it can use.
    var attachments: [AskAttach] = []
    /// What to say to it.
    var text: String
}

enum AskEvent {
    /// Streamed text arriving for the message being composed.
    case delta(chat: UUID, text: String)
    /// A message finished — the whole thing, as it should be kept.
    case message(chat: UUID, AskMessage)
    /// A tool began, updated, or finished inside the running message.
    case tool(chat: UUID, AskMessage.Tool)
    /// The engine changed what it is doing — "thinking", a tool's name, "".
    case activity(chat: UUID, String)
    /// The turn ended, well or badly (nil text means stopped by the user).
    case done(chat: UUID, error: String?)
}

/// Something that can be asked. Harness.swift's webview host conforms and
/// sets `Mind.shared.engine` the first time the panel opens.
@MainActor
protocol AskEngine: AnyObject {
    /// Start a turn. Events come back on `Mind.shared.hear(_:)`.
    func run(_ job: AskJob)
    /// A new instruction while it runs — the engine may queue it.
    func steer(_ text: String)
    /// Stop the current turn.
    func stop()
    /// A person answered the question the turn was parked on — the result
    /// the parked ask.user call resolves with ({answer:…} / {declined:…}).
    func resolveAsk(_ result: [String: Any])
    /// A person answered a parked approval card — Drive settles the op it
    /// was holding with the verdict.
    func settleApproval(_ id: UUID, _ verdict: ApprovalVerdict)
    /// True while a turn is in flight.
    var running: Bool { get }
}

// MARK: - the fold

/// What an engine event does to a chat — the message/blocks/workedFor
/// half of `Mind.hear`, lifted out so a routine's run chat folds the same
/// stream without passing through Mind's seats (Routines.swift).
/// `folds` is the caller's per-chat set of message ids this run has
/// folded into — Mind keys it by chat, the run keys it by run.
///
///   delta    — begin or grow the live agent shell, mirror text blocks
///   tool     — upsert the call on the shell, mirror a .tool block
///   message  — the run's canonical record: committed work trimmed off,
///              live shells superseded in place
///   done     — the workedFor stamp on the turn's own last agent
///              message (never a tail note), the error's note line
///   activity — a seat concern; no chat mutation
enum AskFold {
    static func apply(_ event: AskEvent, to chat: inout AskChat, folds: inout Set<UUID>) {
        switch event {
        case .delta(_, let text):
            if chat.messages.last?.role != .agent {
                let shell = AskMessage(role: .agent, text: "", blocks: [])
                chat.messages.append(shell)
                folds.insert(shell.id)
            } else if let last = chat.messages.last {
                folds.insert(last.id)
            }
            let last = chat.messages.count - 1
            chat.messages[last].text += text
            // The same fold the harness's emit makes: words after a run of
            // tool work are a new paragraph, not a tail on the last one —
            // each section of the accordion begins at one of these.
            var blocks = chat.messages[last].blocks ?? []
            if blocks.last?.kind == .text {
                blocks[blocks.count - 1].text += text
            } else {
                blocks.append(.text(text))
            }
            chat.messages[last].blocks = blocks
        case .message(_, let arrived):
            var message = arrived
            // Who answered — the chat's model at the moment the message
            // landed — so a chat that mixes brains can say which said this.
            message.model = message.model ?? chat.model
            // A steered run's closing message re-states the *whole* run:
            // the stretch before the steer was already folded into the
            // earlier turn's sealed message, so it's trimmed off what lands
            // here — otherwise its paragraphs and calls draw twice.
            let boundary = chat.messages.lastIndex(where: { $0.role == .you }).map { $0 + 1 } ?? 0
            let committed = chat.messages[..<boundary].filter { $0.role == .agent && folds.contains($0.id) }
            if !committed.isEmpty { message.trim(committedBy: committed) }
            // The message is the run's canonical record — it supersedes
            // every shell the live fold left in this turn (a mid-turn
            // note can split the tail into a second one; keeping both
            // would draw the run's blocks twice inside one accordion).
            let tail = Array(chat.messages[boundary...])
            let where_ = tail.firstIndex { $0.role == .agent } ?? tail.count
            var kept = tail.filter { $0.role != .agent }
            kept.insert(message, at: min(where_, kept.count))
            chat.messages = Array(chat.messages.prefix(boundary)) + kept
        case .tool(_, let tool):
            if chat.messages.last?.role != .agent {
                let shell = AskMessage(role: .agent, text: "", blocks: [])
                chat.messages.append(shell)
                folds.insert(shell.id)
            } else if let last = chat.messages.last {
                folds.insert(last.id)
            }
            let last = chat.messages.count - 1
            if let held = chat.messages[last].tools.firstIndex(where: { $0.id == tool.id }) {
                chat.messages[last].tools[held] = tool
            } else {
                chat.messages[last].tools.append(tool)
            }
            // The block mirror: the same call lives at its position in the
            // turn's order — a result landing updates it in place.
            var blocks = chat.messages[last].blocks ?? []
            if let held = blocks.lastIndex(where: { $0.kind == .tool && $0.tool?.id == tool.id }) {
                blocks[held].tool = tool
            } else {
                blocks.append(.tool(tool))
            }
            chat.messages[last].blocks = blocks
        case .done(_, let error):
            // The duration lands on the message that closed the turn —
            // the accordion's "Worked for 4m 39s" reads it. A tail note
            // (an error line lands after the words) isn't the answer —
            // stamp the turn's own last agent message.
            let boundary = chat.messages.lastIndex(where: { $0.role == .you }).map { $0 + 1 } ?? 0
            if let started = chat.turnStartedAt,
               let last = chat.messages.lastIndex(where: { $0.role == .agent }),
               last >= boundary {
                chat.messages[last].workedFor = Date().timeIntervalSince(started)
            }
            chat.turnStartedAt = nil
            if let error, !error.isEmpty {
                // One honest line — the raw provider dump's first row
                // ("openrouter 400 — …"), the card carries the rest.
                let clean = error.components(separatedBy: "\n").first ?? error
                chat.messages.append(
                    AskMessage(role: .note, text: String(clean.prefix(280)), isError: true))
            }
        case .activity:
            break
        }
    }
}

// MARK: - the panel's state

@MainActor
final class Mind: ObservableObject {
    static let shared = Mind()

    /// The engine answering right now — the harness once it has been woken,
    /// the echo before that. The panel sets `engine = Harness.shared`.
    var engine: (any AskEngine)? {
        didSet { engine?.sync() }
    }

    @Published var open = Store.settings.bool(forKey: "ask.open") {
        didSet { Store.settings.set(open, forKey: "ask.open") }
    }

    /// Chats kept between launches, newest first.
    @Published private(set) var chats: [AskChat] = []
    /// The chat on screen.
    @Published private(set) var currentID: UUID?
    /// Tabs handed to the next turn.
    @Published var context: [AskTab] = []
    /// Files, images and sites handed to the next turn — the typed
    /// companions of the tab chips, cleared with them on send, new chat
    /// and fork. Not consent: a file's bytes go, not access to the folder.
    @Published var attachments: [AskAttach] = []
    /// The model the next chat speaks to, kept between launches.
    @Published var model: AskModel = Mind.savedModel() {
        didSet { Store.settings.set(try? JSONEncoder().encode(model), forKey: "ask.model") }
    }
    /// What the engine is doing right now, for the status line.
    @Published private(set) var activity = ""
    /// The chat the live turn belongs to — `running` alone can't say it,
    /// and a chat that isn't the running one must not wear its spinner or
    /// feed it steers. Set on send/retry, cleared on that chat's `.done`.
    @Published private(set) var runningChatID: UUID?

    /// Half-typed composer text, keyed by chat — session-only, never
    /// persisted. Shared by every surface so the rail and the Ask window
    /// hold the same draft for the same chat (fullscreen-features §6.4);
    /// `draftKey` is the nowhere-chat a first send is typed into.
    @Published var drafts: [UUID: String] = [:]
    static let draftKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The composer's text binding for whichever chat is on screen.
    var draft: Binding<String> {
        Binding(
            get: { self.drafts[self.currentID ?? Mind.draftKey] ?? "" },
            set: { self.drafts[self.currentID ?? Mind.draftKey] = $0 }
        )
    }

    /// Ops the gate parked for the user's verdict (design/permissions.md
    /// §5) — a card each in the chat stream. Only the .app session can
    /// raise one; a socket's asks are refused over the wire.
    @Published private(set) var pendingApprovals: [AskApproval] = []
    /// The question a parked ask.user is waiting on
    /// (design/interaction.md §1) — while it's up the composer is its
    /// answer box.
    @Published private(set) var question: AskQuestion?
    /// The 300-second patience a question carries — nobody answering is
    /// itself an answer ({declined:"timeout"}).
    private var questionClock: Task<Void, Never>?

    /// Agent messages this run has folded into, per chat. A closing
    /// `.message` re-states the whole run — anything before the current
    /// turn's `.you` boundary that the run already streamed is trimmed off
    /// it, so a steered turn's sealed work isn't drawn twice.
    private var runFolds: [UUID: Set<UUID>] = [:]

    var current: AskChat? { chats.first { $0.id == currentID } }
    var running: Bool {
        #if DEBUG
        if demoRunning { return true }
        #endif
        return engine?.running ?? false
    }

    #if DEBUG
    /// Probe-world lever: `ask.demo` on the probe suite makes the panel's
    /// next opening raise a real parked-op approval through the gate and
    /// pose a question against a planted ask.user card — this stands the
    /// turn "running" the question's pending state hangs on. Test runs
    /// only (Store.testing gates it); see demoCards().
    private var demoRunning = false
    #endif

    init() {
        if Store.settings.string(forKey: "ask.mode") == "read" {
            Store.settings.set(AskMode.guard.rawValue, forKey: "ask.mode")
        }
        chats = AskStore.list()
        currentID = chats.first?.id
    }

    /// The panel opened or closed. Opening wakes the engine; closing leaves
    /// it running — a job keeps working behind the shut panel.
    func toggle() { open.toggle() }

    func send(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        var chat = current ?? AskChat()
        if current == nil {
            // A chat is born on its first send — its leash and its effort
            // are the Settings picks until the composer's chips say
            // otherwise.
            chat.mode = AskMode(rawValue: Store.settings.string(forKey: "ask.mode") ?? "") ?? .guard
            chat.effort = Store.settings.string(forKey: "ask.effort")
            chats.insert(chat, at: 0)
            currentID = chat.id
        }
        // Every turn: the answering brain rides the chat (harness.js reads
        // job.chat.model — a mid-chat switch would otherwise never land),
        // and the turn's stamp tells its events from a killed turn's tail.
        chat.model = model.id
        chat.turn = UUID()
        chat.turnStartedAt = Date()
        // One run at a time on the engine — starting here kills whatever
        // was in flight, and that chat's done may never arrive (its events
        // are another turn's tail, filtered stale). Its books close now:
        // the accordion's clock freezes, its parked asks settle refused,
        // and nothing keeps wearing the ring.
        if let old = runningChatID, old != chat.id,
           let at = chats.firstIndex(where: { $0.id == old }) {
            let boundary = chats[at].messages.lastIndex(where: { $0.role == .you }).map { $0 + 1 } ?? 0
            if let started = chats[at].turnStartedAt,
               let last = chats[at].messages.lastIndex(where: { $0.role == .agent }),
               last >= boundary, chats[at].messages[last].workedFor == nil {
                chats[at].messages[last].workedFor = Date().timeIntervalSince(started)
            }
            chats[at].turnStartedAt = nil
            if question?.chat == old {
                questionClock?.cancel()
                question = nil
            }
            pendingApprovals.removeAll { $0.chat == old }
            AskStore.save(chats[at])
            runFolds[old] = nil
        }
        runningChatID = chat.id
        // The typed attachments' send-time fill — a file's text inside its
        // cap, an image's bytes inside its own — so what persists on the
        // message is what the model could actually be shown.
        let pieces = attachments.map { $0.filled }
        let message = AskMessage(role: .you, text: words, tabs: context, attachments: pieces)
        chat.messages.append(message)
        store(chat)
        if chat.title == "New chat" {
            rename(chat, to: String(words.prefix(48)))
        }
        // A run replaces whatever the turn before it was holding: Drive
        // settles its parked asks refused (denyPending), the cards come
        // down here to match, and the gate hears which leash is on.
        pendingApprovals.removeAll()
        pushMode()
        if let engine {
            engine.run(AskJob(chat: chat, tabs: context, attachments: pieces, text: words))
        } else {
            hear(.delta(chat: chat.id, text: "(no engine yet — the panel's model host isn't up)"))
            hear(.done(chat: chat.id, error: nil))
        }
        context = []
        attachments = []
    }

    /// The page on stage, handed over as a chip — the open transition's
    /// consent (the Ask button calls this the moment the rail opens, so
    /// the panel arrives with the page already worn, removable as ever).
    /// Blank tabs have nothing to read, the agent's own bench tabs need
    /// no grant, and a tab already chipped can't be given twice.
    func hand(_ tab: Tab?) {
        guard let tab, let address = tab.address, !tab.bench,
              !context.contains(where: { $0.id == tab.id }) else { return }
        context.append(AskTab(id: tab.id, title: tab.label, address: address.absoluteString))
    }

    /// A follow-up while the agent is mid-turn: queued or steered, the
    /// engine's choice — unless the agent is the one waiting: while a
    /// question for this chat is open the composer *is* its answer box,
    /// and steering would just queue unread behind the parked call
    /// (design/interaction.md §1). Stays on screen as your message either
    /// way.
    func steer(_ text: String) {
        let correction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !correction.isEmpty, pendingApprovals.contains(where: { $0.chat == currentID }) {
            for approval in pendingApprovals.filter({ $0.chat == currentID }) { resolve(approval, .deny) }
            stop()
            send(correction)
            return
        }
        guard running else { return send(text) }
        guard let chat = current else { return send(text) }
        // A word typed in a chat that isn't the one mid-turn can't ride
        // the engine's steer — the live turn is another chat's, and
        // engine.steer would feed it. It starts this chat's own turn
        // instead (the harness's one-turn rule ends the other).
        guard runningChatID == chat.id else { return send(text) }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        var copy = chat
        // A steer cuts the turn open mid-flight: the message above it
        // belongs to the pre-steer stretch — seal it with the span it
        // actually ran so its accordion can say how long it worked. A note
        // may sit on the tail (a verdict line landed after the words) —
        // seal the turn's last agent message, not whatever is last.
        let boundary = copy.messages.lastIndex(where: { $0.role == .you }).map { $0 + 1 } ?? 0
        if let last = copy.messages.lastIndex(where: { $0.role == .agent }),
           last >= boundary, copy.messages[last].workedFor == nil {
            copy.messages[last].workedFor =
                Date().timeIntervalSince(copy.turnStartedAt ?? copy.messages[last].when)
        }
        copy.messages.append(AskMessage(role: .you, text: words))
        store(copy)
        if let q = question, q.chat == chat.id {
            answer(words)
        } else {
            engine?.steer(words)
        }
    }

    func stop() {
        engine?.stop()
        // The engine's done may never arrive (a dead page answers
        // nothing) — the live flag comes down either way, and the killed
        // turn's books close here the way .done would close them: its
        // accordion's clock freezes at the span it actually ran.
        if let chat = runningChatID, let at = chats.firstIndex(where: { $0.id == chat }) {
            let boundary = chats[at].messages.lastIndex(where: { $0.role == .you }).map { $0 + 1 } ?? 0
            if let started = chats[at].turnStartedAt,
               let last = chats[at].messages.lastIndex(where: { $0.role == .agent }),
               last >= boundary, chats[at].messages[last].workedFor == nil {
                chats[at].messages[last].workedFor = Date().timeIntervalSince(started)
            }
            chats[at].turnStartedAt = nil
            AskStore.save(chats[at])
        }
        runFolds = [:]
        runningChatID = nil
        #if DEBUG
        demoRunning = false
        #endif
        // The kill settles every ask the turn was holding (Harness →
        // denyPending; the JS promise is flushed {error:stopped}) — its
        // cards and its question come down with it.
        pendingApprovals.removeAll()
        questionClock?.cancel()
        question = nil
    }

    /// Move a chat's read marker to its latest word — saved without
    /// store()'s activity bump: looking is not doing. Called for the chat
    /// being left (what landed while it was open was seen) and the one
    /// arrived at (it starts read).
    private func markSeen(_ chat: UUID) {
        guard let at = chats.firstIndex(where: { $0.id == chat }),
              chats[at].lastSeen != chats[at].messages.last?.id else { return }
        chats[at].lastSeen = chats[at].messages.last?.id
        AskStore.save(chats[at])
    }

    func newChat() {
        if let old = currentID { markSeen(old) }
        currentID = nil
        context = []
        attachments = []
        // Consent was the chat's: the chips' grants end with it — a tab
        // attachable in the last chat isn't this one's to drive, and the
        // asks parked on it settle refused inside the same call.
        pendingApprovals.removeAll()
        AskRuntime.drive?.perform("tabs.ungrantAll", [:], from: .app) { _ in }
        pushMode()
    }

    /// Start an empty, addressable chat for a local agent client. The UI's
    /// normal `newChat()` stays lazy and creates a chat on first send.
    func newChatForAgent() -> UUID {
        newChat()
        var chat = AskChat()
        chat.model = model.id
        chat.mode = AskMode(rawValue: Store.settings.string(forKey: "ask.mode") ?? "") ?? .guard
        chat.effort = Store.settings.string(forKey: "ask.effort")
        chats.insert(chat, at: 0)
        currentID = chat.id
        AskStore.save(chat)
        pushMode()
        return chat.id
    }

    func select(_ chat: AskChat) {
        // The chat being left was watched — words that landed while it was
        // open are read, so its marker moves to its latest before leaving.
        if let old = currentID, old != chat.id { markSeen(old) }
        currentID = chat.id
        markSeen(chat.id)
        pushMode()
    }

    func remove(_ chat: AskChat) {
        // Deleting the chat a turn is still writing to would leave the turn
        // live, its events landing on a chat that isn't there — stop first,
        // whether it's the open one or a job running in the background.
        if chat.id == runningChatID { stop() }
        chats.removeAll { $0.id == chat.id }
        AskStore.drop(chat.id)
        if currentID == chat.id {
            currentID = chats.first?.id
            if let now = currentID { markSeen(now) }
        }
        pushMode()
        // Its grants die with it — consent was the chat's, not the app's —
        // and its parked asks with them (ungrantAll settles them refused).
        pendingApprovals.removeAll { $0.chat == chat.id }
        if question?.chat == chat.id {
            questionClock?.cancel()
            question = nil
        }
        AskRuntime.drive?.perform("tabs.ungrantAll", [:], from: .app) { _ in }
    }

    func rename(_ chat: AskChat, to title: String) {
        guard let at = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        chats[at].title = title
        AskStore.save(chats[at])
    }

    /// An event from the engine, folded into the chat it names. The
    /// message-level work is AskFold's — shared with run chats — while the
    /// seats (activity, question, approvals, the running ring) are this
    /// class's own.
    func hear(_ event: AskEvent) {
        switch event {
        case .activity(_, let doing):
            activity = doing
        case .done(let chat, _):
            activity = ""
            if runningChatID == chat { runningChatID = nil; pushMode() }
            // A turn that ended isn't waiting on anyone — its question
            // and its parked asks are over whether they answered or not.
            if question?.chat == chat {
                questionClock?.cancel()
                question = nil
            }
            pendingApprovals.removeAll { $0.chat == chat }
            defer { runFolds[chat] = nil }
            guard let at = chats.firstIndex(where: { $0.id == chat }) else { return }
            AskFold.apply(event, to: &chats[at], folds: &runFolds[chat, default: []])
            store(chats[at])
        case .delta(let chat, _), .tool(let chat, _):
            guard let at = chats.firstIndex(where: { $0.id == chat }) else { return }
            AskFold.apply(event, to: &chats[at], folds: &runFolds[chat, default: []])
        case .message(let chat, _):
            guard let at = chats.firstIndex(where: { $0.id == chat }) else { return }
            AskFold.apply(event, to: &chats[at], folds: &runFolds[chat, default: []])
            store(chats[at])
        }
    }

    // MARK: - the asks: approvals and questions

    /// The rail's attention grab — a parked ask pops the panel open.
    /// Suppressed while the Ask window is the one in front: its parked
    /// zone already shows the card there, and popping the rail beside it
    /// is asking for the same attention twice (fullscreen-features §6.3).
    private func knock() {
        if AskWindow.window?.isKeyWindow != true { open = true }
    }

    /// A parked op wants the user's say (design/permissions.md §5) —
    /// Drive raises it the same way `ui.ask` opens the panel: the card
    /// lands in the chat's stream, and asking is deliberate
    /// attention-seeking.
    func removeApproval(_ id: UUID) { pendingApprovals.removeAll { $0.id == id } }

    func raise(_ approval: AskApproval) {
        pendingApprovals.removeAll { $0.id == approval.id }
        pendingApprovals.append(approval)
    }

    /// A card's verdict — the parked op settles in Drive, and the chat
    /// keeps the audit line: persisted in the JSON, replayed into history
    /// as `[note: …]` so the model sees its own record.
    func resolve(_ approval: AskApproval, _ verdict: ApprovalVerdict) {
        pendingApprovals.removeAll { $0.id == approval.id }
        if let engine { engine.settleApproval(approval.id, verdict) }
        else { (AskRuntime.drive as? Drive)?.settleApproval(approval.id, verdict) }
        guard let at = chats.firstIndex(where: { $0.id == approval.chat }) else { return }
        let what = approval.host.map { "\(approval.op) on \($0)" } ?? approval.op
        let text: String
        switch verdict {
        case .allow: text = "✓ allowed \(what)"
        case .deny: text = "✗ denied \(what)"
        case .always: text = "✓ allowed \(what)"
        }
        chats[at].messages.append(AskMessage(role: .note, text: text, approval: approval))
        store(chats[at])
    }

    /// The agent asking the person mid-turn (design/interaction.md §1):
    /// its tool call stays parked on the JS side while the question card
    /// waits here — 300 seconds, and nobody answering is itself an
    /// answer. Asking is deliberate attention-seeking: the panel opens.
    func pose(_ text: String, options: [String], in chat: UUID) {
        questionClock?.cancel()
        let asked = AskQuestion(chat: chat, text: text, options: options)
        question = asked
        knock()
        questionClock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, !Task.isCancelled, question?.id == asked.id else { return }
            engine?.resolveAsk(["declined": "timeout"])
            question = nil
        }
    }

    /// The question answered — by text, by a picked option, or by the
    /// composer-as-answer-box; the parked call gets {answer:…}.
    func answer(_ text: String) {
        questionClock?.cancel()
        questionClock = nil
        engine?.resolveAsk(["answer": text])
        question = nil
    }

    /// The question let go — {declined:"dismissed"}: a declined question
    /// means the agent makes its own call and says what it assumed.
    func pass() {
        questionClock?.cancel()
        questionClock = nil
        engine?.resolveAsk(["declined": "dismissed"])
        question = nil
    }

    /// Re-run from a user message: drops everything after it and sends it
    /// again (design/interaction.md §2). `brain` becomes the chat's
    /// model — sticky for the rest of the chat; `mind.model` (the
    /// new-chat default) untouched.
    func retry(from message: AskMessage, with brain: AskModel? = nil) {
        guard let chat = current, !running,
              let at = chat.messages.firstIndex(where: { $0.id == message.id }),
              chat.messages[at].role == .you else { return }
        var copy = chat
        copy.messages = Array(copy.messages.prefix(through: at))  // the .you stays
        copy.messages[at].retries += 1
        if let brain { copy.model = brain.id }
        copy.turn = UUID()
        copy.turnStartedAt = Date()
        runningChatID = chat.id
        store(copy)
        engine?.run(AskJob(chat: copy, tabs: message.tabs,
                           attachments: message.attachments, text: message.text))
    }

    /// Branch at a message — nil means the whole chat (design/
    /// interaction.md §3). A pure clone, persisted at once, becoming
    /// current; nothing re-runs. Grants do NOT carry: consent was the
    /// parent's chat's, so the fork clears context and ends every grant
    /// the way a new chat does.
    func fork(from message: AskMessage? = nil) {
        guard let chat = current else { return }
        var copy = AskChat()
        copy.parent = chat.id
        copy.model = chat.model
        copy.mode = chat.mode
        copy.title = chat.title + " (fork)"
        copy.messages = message
            .flatMap { m in chat.messages.firstIndex { $0.id == m.id } }
            .map { Array(chat.messages.prefix(through: $0)) } ?? chat.messages
        copy.when = Date()
        chats.insert(copy, at: 0)
        AskStore.save(copy)
        if let old = currentID { markSeen(old) }
        currentID = copy.id
        markSeen(copy.id)
        context = []
        attachments = []
        pendingApprovals.removeAll()
        AskRuntime.drive?.perform("tabs.ungrantAll", [:], from: .app) { _ in }
        pushMode()
    }

    /// The composer's leash switch: writes the current chat's mode — or,
    /// with no chat open, the Settings default the next chat is born
    /// with — then tells the gate so the new leash binds at once.
    func setMode(_ mode: AskMode) {
        if let at = chats.firstIndex(where: { $0.id == currentID }) {
            chats[at].mode = mode
            AskStore.save(chats[at])
        } else {
            Store.settings.set(mode.rawValue, forKey: "ask.mode")
        }
        pushMode()
    }

    /// The composer's reasoning pick: writes the current chat's effort —
    /// or, with no chat open, the Settings default the next chat is born
    /// with — the same edit-the-chat-or-the-default pattern setMode has.
    /// nil is "auto": the wire's own call.
    func setEffort(_ effort: String?) {
        if let at = chats.firstIndex(where: { $0.id == currentID }) {
            chats[at].effort = effort
            AskStore.save(chats[at])
        } else {
            Store.settings.set(effort, forKey: "ask.effort")
        }
    }

    /// The .app session's leash *is* the current chat's mode — pushed on
    /// send, select, new chat, fork and a mode change, the same push
    /// pattern `hear` uses. With no chat open the Settings default speaks.
    private func pushMode() {
        let mode = runningChatID.flatMap { id in chats.first(where: { $0.id == id })?.mode } ?? current?.mode
            ?? AskMode(rawValue: Store.settings.string(forKey: "ask.mode") ?? "") ?? .guard
        (AskRuntime.drive as? Drive)?.setMode(mode, for: .app)
    }

    #if DEBUG
    /// A probe-world lever for drawing the cards (`defaults write
    /// com.officecommun.search.test.<world> ask.demo -bool true`, then the
    /// panel's next opening fires this once). Not a mock of the gate — it
    /// performs a real `tabs.open` then a real `act.submit` through the
    /// .app door, so the verdict, the parked finish, `Mind.raise` and the
    /// card's tab screenshot are all the shipping path; only the model is
    /// absent. The question card is planted the way a parked ask.user
    /// leaves it, with `demoRunning` standing the turn up for its
    /// pending state. Test worlds only — Store.testing gates the flag.
    func demoCards() {
        guard Store.testing, Store.settings.bool(forKey: "ask.demo") else { return }
        Store.settings.set(false, forKey: "ask.demo")
        model = AskModel(provider: "echo", model: "echo")
        send("demo")
        (AskRuntime.drive as? Drive)?.setMode(.guard, for: .app)
        AskRuntime.drive?.perform("tabs.open", ["url": "https://example.com"], from: .app) { result in
            guard let tab = result["id"] as? String else { return }
            Task { @MainActor in
                // Let the page stand up first so the card's evidence shot
                // has something to show — and the echo turn's done has
                // landed, so the card isn't swept with it.
                try? await Task.sleep(for: .seconds(1.2))
                AskRuntime.drive?.perform(
                    "act.submit", ["tab": tab, "why": "place the office-supplies reorder"],
                    from: .app
                ) { _ in }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard let chat = current else { return }
            var copy = chat
            var ask = AskMessage(
                role: .agent, text: "",
                tools: [AskMessage.Tool(
                    id: "demo-ask", name: "ask_user",
                    args: #"{"question":"Which should I reorder?","options":["the cheap one","the sturdy one"]}"#
                )]
            )
            ask.blocks = [.tool(ask.tools[0])]
            copy.messages.append(ask)
            store(copy)
            demoRunning = true
            runningChatID = chat.id
            pose("Which should I reorder?", options: ["the cheap one", "the sturdy one"], in: chat.id)
        }
    }

    /// A probe-world lever for the turn stream (`defaults write
    /// com.officecommun.search.test.<world> ask.demostream -bool true`,
    /// then the panel's next opening fires this once): plants a finished
    /// two-turn chat — user pill, a worked-for accordion holding paragraphs
    /// between tool clusters and a real screenshot card, then the answer —
    /// so the rail's stream can be audited without a live model.
    func demoStream() {
        guard Store.testing, Store.settings.bool(forKey: "ask.demostream") else { return }
        Store.settings.set(false, forKey: "ask.demostream")

        // A real PNG for the shot card, drawn into the world's own folder.
        let shotPath = Store.file("demo-stream-shot.png").path
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 150,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let rep {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 240, height: 150).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 208, height: 118),
                         xRadius: 10, yRadius: 10).fill()
            NSColor.systemTeal.setFill()
            NSRect(x: 30, y: 96, width: 120, height: 12).fill()
            NSRect(x: 30, y: 74, width: 180, height: 8).fill()
            NSRect(x: 30, y: 56, width: 150, height: 8).fill()
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: shotPath))
        }

        func tool(_ id: String, _ name: String, _ args: String, _ result: String,
                  why: String? = nil, shot: String? = nil) -> AskMessage.Tool {
            AskMessage.Tool(id: id, name: name, args: args, result: result,
                            failed: false, shot: shot, why: why)
        }

        var first = AskChat(title: "Desk lamp research")
        first.model = "codex/gpt-6-luna"
        first.messages = [
            AskMessage(role: .you, text: "Find a good desk lamp under $80"),
            AskMessage(
                role: .agent, text: "",
                blocks: [
                    .text("One of the more promising listings is on vivo.com — checking the price and stock now."),
                    .tool(tool("d1", "snapshot", #"{"tab":"abc123"}"#, #"{"lines":42}"#)),
                    .tool(tool("d2", "navigate", #"{"tab":"abc123","url":"https://vivo.com/lamp"}"#, #"{"ok":true}"#)),
                    .tool(tool("d3", "screenshot", #"{"tab":"abc123"}"#, #"{"path":"…"}"#,
                               shot: shotPath)),
                    .text("I found an important detail: the listing price excludes shipping, so I checked the checkout page instead."),
                    .tool(tool("d4", "navigate", #"{"tab":"abc123","url":"https://vivo.com/checkout"}"#, #"{"ok":true}"#)),
                    .tool(tool("d5", "act.fill", #"{"tab":"abc123","ref":"e9","value":"1"}"#, #"{"ok":true}"#,
                               why: "Ruling out cheaper imports")),
                    .text("The **lamp is $64.99 with free shipping** — under your $80 budget. [vivo.com](https://vivo.com/lamp) has it in stock, and the checkout page confirms the total."),
                ],
                workedFor: 243,
                model: "codex/gpt-6-luna"),
            AskMessage(role: .you, text: "How does it compare to the IKEA one?"),
            AskMessage(
                role: .agent, text: "",
                blocks: [
                    .tool(tool("d6", "navigate", #"{"tab":"abc124","url":"https://ikea.com/forsa"}"#, #"{"ok":true}"#)),
                    .tool(tool("d7", "read_text", #"{"tab":"abc124"}"#, #"{"chars":8211}"#)),
                    .text("The FORSÅ is $59.99 but shipping adds $19, so the vivo lamp ends up cheaper overall."),
                ],
                workedFor: 38,
                model: "codex/gpt-6-luna"),
            AskMessage(role: .you, text: "One with a warm bulb?"),
            // The live turn, mid-flight: a paragraph, a settled call, a
            // paragraph, then a call still out — the open accordion's
            // "Working for Ns" ticks while its last row spins.
            AskMessage(
                role: .agent, text: "",
                blocks: [
                    .text("Checking the vivo listing's bulb options."),
                    .tool(tool("d8", "navigate", #"{"tab":"abc123","url":"https://vivo.com/lamp"}"#, #"{"ok":true}"#)),
                    .text("One of the two finishes ships with a 2700K bulb — confirming it's the dimmable one."),
                    .tool(AskMessage.Tool(id: "d9", name: "snapshot", args: #"{"tab":"abc123"}"#)),
                ],
                model: "codex/gpt-6-luna"),
        ]
        first.turnStartedAt = Date().addingTimeInterval(-47)
        chats.insert(first, at: 0)
        AskStore.save(first)
        currentID = first.id
        demoRunning = true
        runningChatID = first.id
        activity = "reading the page"
    }

    /// A probe-world lever for the composer's chips (`defaults write
    /// com.officecommun.search.test.<world> ask.attach -bool true`, then the
    /// panel's next opening fires this once): hands the page on stage over
    /// through `hand`, the same act the Ask button takes on an open, and
    /// adds one attachment of each kind — a picture drawn into the world's
    /// own folder, a text file written beside it, a site. Test runs only.
    func demoAttach(_ browser: Browser) {
        guard Store.testing, Store.settings.bool(forKey: "ask.attach") else { return }
        Store.settings.set(false, forKey: "ask.attach")
        hand(browser.active)
        // A real PNG, drawn small and unmistakable, so the image chip has
        // an actual thumbnail to load.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let rep, let png = { () -> Data? in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 56, height: 56), xRadius: 16, yRadius: 16).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: 22, width: 20, height: 20)).fill()
            return rep.representation(using: .png, properties: [:])
        }() {
            let url = Store.file("demo-image.png")
            try? png.write(to: url)
            attachments.append(AskAttach.picked(url, image: true))
        }
        let file = Store.file("demo-reorder.txt")
        try? "reorder pens — the sturdy ones\nask which before buying\n".write(to: file, atomically: true, encoding: .utf8)
        attachments.append(AskAttach.picked(file, image: false))
        attachments.append(.site(URL(string: "https://example.com")!))
    }

    /// Every probe-world lever fired once, for whichever Ask surface is
    /// appearing — the rail and the Ask window share this so test hooks
    /// run identically from either (fullscreen-features §2).
    func demoHooks(_ browser: Browser) {
        demoCards()
        demoAttach(browser)
        demoStream()
    }
    #endif

    private func store(_ chat: AskChat) {
        guard let at = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        var copy = chat
        // The list orders by last activity — a chat that just heard
        // something bubbles up instead of sitting at its birthday.
        copy.when = Date()
        chats[at] = copy
        chats.sort { $0.when > $1.when }
        AskStore.save(copy)
    }

    static func savedModel() -> AskModel {
        (Store.settings.data(forKey: "ask.model"))
            .flatMap { try? JSONDecoder().decode(AskModel.self, from: $0) }
            ?? AskModel(provider: "openrouter", model: "z-ai/glm-5.3-flash")
    }
}

// MARK: - the engine's eyes and hands

/// The ops layer: `Drive` implements it for the in-app harness and the
/// agent.sock sessions alike. An op that can't be done comes back with an
/// "error" key rather than throwing — the wire is JSON either way.
protocol Driving {
    /// `op` is "tabs.list", "page.snapshot", "act.click", … — see
    /// Runtime/ask/PROTOCOL.md. `args` is the request's own object; `origin`
    /// is the session asking — the in-app harness (`.app`, the default) or
    /// one agent.sock connection — and session state keys off it.
    func perform(_ op: String, _ args: [String: Any], from origin: DriveOrigin, done: @escaping ([String: Any]) -> Void)
    /// Events the driver raises between answers — navigation, a tab's title
    /// changing, a tab it opened closing. nil until a session subscribes.
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
}

enum AskRuntime {
    /// The one ops layer, installed in Browser.init — before and regardless
    /// of the bench preference, since the harness drives through it too.
    static var drive: (any Driving)?
}

// MARK: - keys

/// API keys, kept in a 0600 file inside the app's own folder rather than the
/// keychain: ad-hoc builds sign differently every time and the keychain would
/// ask again with each one. The folder already trusts this model — the bench
/// socket's whole safety is the same mode.
enum Keys {
    static func get(_ name: String) -> String? {
        all()[name]
    }

    static func set(_ name: String, _ value: String?) {
        var keys = all()
        if let value, !value.isEmpty { keys[name] = value } else { keys[name] = nil }
        let url = file()
        do {
            let data = try JSONSerialization.data(withJSONObject: keys, options: [.prettyPrinted, .sortedKeys])
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Written beside the file then renamed over it: the old keys
            // can never be truncated mid-write, and the file is born 0600
            // — never world-readable even for the moment before a chmod.
            let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
            defer { try? FileManager.default.removeItem(at: temp) }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            // replaceItemAt can keep the old file's attributes — put the
            // mode back, then check the file really is 0600.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
               mode.uint16Value & 0o777 != 0o600 {
                NSLog("[keys] %@ has mode %o after a write", url.lastPathComponent, mode.uintValue)
            }
        } catch {
            NSLog("[keys] could not write %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    /// Every key set, for the settings panel's "•••" display.
    static func names() -> [String] { all().keys.sorted() }

    private static func file() -> URL { Store.file("ask.keys.json") }
    private static func all() -> [String: String] {
        guard let data = try? Data(contentsOf: file()),
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return keys
    }
}

// MARK: - the javascript the app carries

enum AskJS {
    /// A file from Runtime/ask/, as a string. Installed apps read it from the
    /// bundle's Resources; a build run out of .build reads the source tree,
    /// found from this file's own path.
    static func load(_ name: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "ask"),
           let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("Runtime/ask/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

enum DriveJS {
    /// JavaScript in a tab's page, answered as an Any the way JSON can carry.
    /// The workhorse the ops layer reaches for.
    static func run(_ web: WKWebView, _ js: String, done: @escaping (Any?, String?) -> Void) {
        web.evaluateJavaScript(js) { value, error in
            MainActor.assumeIsolated { done(value, error?.localizedDescription) }
        }
    }
}

extension AskEngine {
    /// Engines that have nothing to sync override nothing.
    func sync() {}
    /// An engine that never parks a question never has one answered — the
    /// card's own timeout or dismissal settles it on the Mind side.
    func resolveAsk(_ result: [String: Any]) {}
    /// An engine that never parks an approval never has one settled.
    func settleApproval(_ id: UUID, _ verdict: ApprovalVerdict) {}
}

// MARK: - where chats live

enum AskStore {
    private static var folder: URL { Store.file("chats") }

    static func list() -> [AskChat] {
        let url = folder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.compactMap { name -> AskChat? in
            guard name.hasSuffix(".json") else { return nil }
            let file = url.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let chat = try? JSONDecoder().decode(AskChat.self, from: data)
            else {
                // A chat that won't decode is set aside, not silently
                // lost — the file stays recoverable beside its siblings.
                Store.quarantine(file)
                return nil
            }
            return chat
        }.sorted { $0.when > $1.when }
    }

    static func save(_ chat: AskChat) {
        let url = folder
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONEncoder().encode(chat).write(to: url.appendingPathComponent("\(chat.id.uuidString).json"), options: .atomic)
        } catch {}
    }

    static func drop(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
    }
}

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
    }
    var id = UUID()
    var role: Role
    var text: String
    var tools: [Tool] = []
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
    /// How hard the answering brain reasons — "off", "low", "medium",
    /// "high" or the wires' "xhigh"/"max"; nil is "auto", the wire's own
    /// call. Chat-scoped like the
    /// mode; the composer's reasoning chip moves it, and the wire reads
    /// it out of the job's chat.
    var effort: String? = nil
    /// The live turn's stamp (design/interaction.md §2): set on every
    /// send/retry, carried inside the job's chat, echoed on each event —
    /// a killed turn's trailing words can then be told from the live
    /// turn's and dropped.
    var turn: UUID?
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
    var label: String { provider == "echo" ? "Echo" : model }
    var id: String { "\(provider)/\(model)" }

    /// What the composer's chip reads: the wire and the model's tail —
    /// "openrouter/glm-5.3-flash". A provider that *is* the model
    /// ("devin"/"devin", echo) needs no tail on it.
    var readout: String {
        provider == "echo" || provider == model
            ? label
            : "\(provider)/\(model.components(separatedBy: "/").last ?? model)"
    }

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
        guard let chat = current else { return send(text) }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        var copy = chat
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

    func newChat() {
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

    func select(_ chat: AskChat) {
        currentID = chat.id
        pushMode()
    }

    func remove(_ chat: AskChat) {
        // Deleting the chat a turn is still writing to would leave the turn
        // live, its events landing on a chat that isn't there — stop first.
        if chat.id == currentID, running { stop() }
        chats.removeAll { $0.id == chat.id }
        AskStore.drop(chat.id)
        if currentID == chat.id { currentID = chats.first?.id }
        pushMode()
        // Its grants die with it — consent was the chat's, not the app's —
        // and its parked asks with them (ungrantAll settles them refused).
        pendingApprovals.removeAll()
        AskRuntime.drive?.perform("tabs.ungrantAll", [:], from: .app) { _ in }
    }

    func rename(_ chat: AskChat, to title: String) {
        guard let at = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        chats[at].title = title
        AskStore.save(chats[at])
    }

    /// An event from the engine, folded into the chat it names.
    func hear(_ event: AskEvent) {
        switch event {
        case .delta(let chat, let text):
            guard let at = chats.firstIndex(where: { $0.id == chat }) else { return }
            if chats[at].messages.last?.role != .agent {
                chats[at].messages.append(AskMessage(role: .agent, text: ""))
            }
            chats[at].messages[chats[at].messages.count - 1].text += text
        case .message(let chat, let message):
            guard let at = chats.firstIndex(where: { $0.id == chat }) else { return }
            var message = message
            // Who answered — the chat's model at the moment the message
            // landed — so a chat that mixes brains can say which said this.
            message.model = message.model ?? chats[at].model
            if chats[at].messages.last?.role == .agent {
                chats[at].messages[chats[at].messages.count - 1] = message
            } else {
                chats[at].messages.append(message)
            }
            store(chats[at])
        case .tool(let chat, let tool):
            guard let at = chats.firstIndex(where: { $0.id == chat }) else { return }
            if chats[at].messages.last?.role != .agent {
                chats[at].messages.append(AskMessage(role: .agent, text: ""))
            }
            let last = chats[at].messages.count - 1
            if let held = chats[at].messages[last].tools.firstIndex(where: { $0.id == tool.id }) {
                chats[at].messages[last].tools[held] = tool
            } else {
                chats[at].messages[last].tools.append(tool)
            }
        case .activity(_, let doing):
            activity = doing
        case .done(let chat, let error):
            activity = ""
            // A turn that ended isn't waiting on anyone — its question
            // and its parked asks are over whether they answered or not.
            if question?.chat == chat {
                questionClock?.cancel()
                question = nil
            }
            pendingApprovals.removeAll { $0.chat == chat }
            if let at = chats.firstIndex(where: { $0.id == chat }) {
                if let error, !error.isEmpty {
                    chats[at].messages.append(AskMessage(role: .note, text: error))
                }
                store(chats[at])
            }
        }
    }

    // MARK: - the asks: approvals and questions

    /// A parked op wants the user's say (design/permissions.md §5) —
    /// Drive raises it the same way `ui.ask` opens the panel: the card
    /// lands in the chat's stream, and asking is deliberate
    /// attention-seeking.
    func raise(_ approval: AskApproval) {
        pendingApprovals.append(approval)
        open = true
    }

    /// A card's verdict — the parked op settles in Drive, and the chat
    /// keeps the audit line: persisted in the JSON, replayed into history
    /// as `[note: …]` so the model sees its own record.
    func resolve(_ approval: AskApproval, _ verdict: ApprovalVerdict) {
        pendingApprovals.removeAll { $0.id == approval.id }
        engine?.settleApproval(approval.id, verdict)
        guard let at = chats.firstIndex(where: { $0.id == approval.chat }) else { return }
        let what = approval.host.map { "\(approval.op) on \($0)" } ?? approval.op
        let text: String
        switch verdict {
        case .allow: text = "✓ allowed \(what)"
        case .deny: text = "✗ denied \(what)"
        case .always: text = "✓ always allowed \(what)"
        }
        chats[at].messages.append(AskMessage(role: .note, text: text))
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
        open = true
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
        currentID = copy.id
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
        let mode = current?.mode
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
            copy.messages.append(AskMessage(
                role: .agent, text: "",
                tools: [AskMessage.Tool(
                    id: "demo-ask", name: "ask_user",
                    args: #"{"question":"Which should I reorder?","options":["the cheap one","the sturdy one"]}"#
                )]
            ))
            store(copy)
            demoRunning = true
            pose("Which should I reorder?", options: ["the cheap one", "the sturdy one"], in: chat.id)
        }
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
    #endif

    private func store(_ chat: AskChat) {
        guard let at = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        chats[at] = chat
        AskStore.save(chat)
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
            guard name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: url.appendingPathComponent(name)),
                  let chat = try? JSONDecoder().decode(AskChat.self, from: data)
            else { return nil }
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

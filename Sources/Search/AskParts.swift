import SwiftUI
import AppKit

// The pieces the rail's AskPanel and the fullscreen AskPage are both
// built from — one implementation, two surfaces (fullscreen-features §2):
// the stream with its bottom pin, the composer with its send path, the
// parked zone, and the empty state. AskDensity carries which rung of the
// ladder a surface is on so the shared views size themselves for it
// (fullscreen-ux §4).

/// How much room the stream gets — `rail` is the sidebar's compact cut,
/// `page` the Ask window's reading measure. Every literal the two surfaces
/// differ on lives here so neither side forks the views.
enum AskDensity {
    case rail, page

    /// Agent prose and accordion paragraphs.
    var text: CGFloat { self == .page ? 14 : 12.5 }
    /// The accordion's own paragraph voice, a half-step under the answer.
    var paragraph: CGFloat { self == .page ? 13 : 12.5 }
    /// "Worked for…" header.
    var workedHead: CGFloat { self == .page ? 13 : 12 }
    /// Tool-cluster header.
    var clusterHead: CGFloat { self == .page ? 12 : 11 }
    /// ToolRow's mono name and its args tail.
    var toolName: CGFloat { self == .page ? 11 : 10.5 }
    var toolDetail: CGFloat { self == .page ? 10 : 9.5 }
    /// The hover meta chip's text.
    var meta: CGFloat { self == .page ? 10.5 : 9.5 }
    var metaHeight: CGFloat { self == .page ? 20 : 14 }
    /// Note lines inside the accordion and between turns.
    var note: CGFloat { self == .page ? 11 : 10.5 }
    /// The error card's text.
    var errorNote: CGFloat { self == .page ? 12 : 11.5 }
    /// The user pill's padding and radius.
    var youPadH: CGFloat { self == .page ? 14 : 10 }
    var youPadV: CGFloat { self == .page ? 9 : 7 }
    var youRadius: CGFloat { self == .page ? 16 : 14 }
    /// The pill's cap — on the page it stops at the measure, on the rail
    /// it rides the column's lead padding instead.
    var youMaxWidth: CGFloat? { self == .page ? 560 : nil }
    var shotMaxWidth: CGFloat { self == .page ? 240 : 132 }
    var shotRadius: CGFloat { self == .page ? 12 : 8 }
    /// Stream rhythm — the page doubles the rail's gap.
    var turnGap: CGFloat { self == .page ? 28 : 14 }
    var streamPadH: CGFloat { self == .page ? 24 : 14 }
    var streamPadV: CGFloat { self == .page ? 32 : 16 }
    /// The top-edge fade once scrolled.
    var fade: CGFloat { self == .page ? 40 : 32 }
    /// The composer's size rung.
    var composerSize: FluidSize { self == .page ? .default : .compact }
}

private struct AskDensityKey: EnvironmentKey {
    static let defaultValue: AskDensity = .rail
}

extension EnvironmentValues {
    var askDensity: AskDensity {
        get { self[AskDensityKey.self] }
        set { self[AskDensityKey.self] = newValue }
    }
}

/// Who a parked card or a transcript's menu answers to — Mind by default;
/// a run's Routines when the view sits on a routine transcript. A nil
/// action means the affordance doesn't draw at all: a run's messages have
/// no "from here" variants or fork, and its parked cards settle on the
/// run, never the interactive rail (design/automation-frontend §4).
struct AskVerdicts {
    var resolve: ((AskApproval, ApprovalVerdict) -> Void)?
    var refresh: ((AskApproval) -> Void)?
    var answer: ((String) -> Void)?
    var pass: (() -> Void)?
    /// Re-ask the message's word — Mind's "from here", a run's re-enqueue.
    var retry: ((AskMessage) -> Void)?
    /// The "Retry with…" model pick — no model-swap retry exists on a run.
    var retryWith: ((AskMessage, AskModel) -> Void)?
    var fork: ((AskMessage) -> Void)?
    /// Whether retry affordances read disabled right now.
    var retryBlocked: () -> Bool = { false }

    /// The interactive conversation's verdicts — straight to Mind. The
    /// closures run from button taps (always the main actor); the type
    /// itself stays non-isolated so it can sit in an EnvironmentKey.
    static let mind = AskVerdicts(
        resolve: { a, v in MainActor.assumeIsolated { Mind.shared.resolve(a, v) } },
        refresh: { card in MainActor.assumeIsolated { (AskRuntime.drive as? Drive)?.refreshApproval(card.id) } },
        answer: { w in MainActor.assumeIsolated { Mind.shared.answer(w) } },
        pass: { MainActor.assumeIsolated { Mind.shared.pass() } },
        retry: { m in MainActor.assumeIsolated { Mind.shared.retry(from: m) } },
        retryWith: { m, b in MainActor.assumeIsolated { Mind.shared.retry(from: m, with: b) } },
        fork: { m in MainActor.assumeIsolated { Mind.shared.fork(from: m) } },
        retryBlocked: { MainActor.assumeIsolated { Mind.shared.running } }
    )

    /// A run's verdicts — parked asks settle through Routines, and its
    /// one-word transcript's retry is the routine run again.
    static func run(_ run: RoutineRun) -> AskVerdicts {
        AskVerdicts(
            resolve: { a, v in MainActor.assumeIsolated { Routines.shared.resolve(run, a, v) } },
            refresh: { card in MainActor.assumeIsolated { (AskRuntime.drive as? Drive)?.refreshApproval(card.id) } },
            answer: { w in MainActor.assumeIsolated { Routines.shared.answer(run, w) } },
            pass: { MainActor.assumeIsolated { Routines.shared.pass(run) } },
            retry: { _ in MainActor.assumeIsolated { Routines.shared.retry(run) } },
            retryWith: nil,
            fork: nil,
            // A live run can't "run again" — the menu item would just
            // stack a duplicate behind the seat.
            retryBlocked: { run.state == .running || run.state == .waiting || run.state == .queued }
        )
    }
}

private struct AskVerdictsKey: EnvironmentKey {
    static let defaultValue: AskVerdicts = .mind
}

extension EnvironmentValues {
    var askVerdicts: AskVerdicts {
        get { self[AskVerdictsKey.self] }
        set { self[AskVerdictsKey.self] = newValue }
    }
}

// MARK: - the pin

/// The stream's bottom-pin, owned by the surface so the composer can ask
/// for a re-pin without reaching into the stream's view state. Intent
/// (`pinned`) is kept apart from the measured `atBottom`: a scrollTo that
/// lands short of still-animating content is drift to re-assert, not the
/// reader leaving (the sidebar's P1 fix — a silent unpin once read as a
/// scroll-away).
@MainActor
final class AskPin: ObservableObject {
    /// What the geometry reads: true while the stream's end is the
    /// viewport's end.
    @Published var atBottom = true
    /// True while the stream's head is at the viewport's top — the page's
    /// header hairline only earns its line once the reader has scrolled.
    @Published var atTop = true
    /// Something arrived while the reader was away — the "New activity"
    /// pill's cue.
    @Published var newSinceScroll = false
    /// Whether the stream *should* hold its end — the reader scrolling
    /// away is the only thing that lifts it.
    var pinned = true
    /// The stream's reader — captured so send() can re-pin to the end.
    var proxy: ScrollViewProxy?
    /// Retries of the pin — a scrollTo during an animated insert lands
    /// early; the ticket keeps one ladder alive at a time.
    private var ticket = 0

    /// What the stream's geometry reports — the end gap, the head's
    /// offset, plus the two sizes that move it — so a growing stream or a
    /// resizing window (layout churn) isn't mistaken for the reader
    /// scrolling away (offset alone moves).
    struct Geo: Equatable {
        var gap: CGFloat
        var top: CGFloat
        var content: CGFloat
        var view: CGFloat
    }

    /// The pin's judgement. Landing at the bottom re-engages intent; a gap
    /// appearing while content *and* viewport sat still is the reader
    /// scrolling away — the only lift that counts. A gap with the sizes
    /// moving is layout churn: while the pin's intent holds, the end is
    /// re-asserted once the inserts settle rather than treated as unread.
    func read(_ old: Geo, _ new: Geo) {
        // A no-change report reads identical to a scroll-away — sizes still,
        // gap present — so it must never reach the intent check.
        guard old != new else { return }
        atBottom = new.gap < 24
        atTop = new.top < 8
        if atBottom {
            newSinceScroll = false
            pinned = true
            return
        }
        if new.content == old.content, new.view == old.view {
            pinned = false
            return
        }
        if pinned { toEndSoon() }
    }

    /// Back to the writing: scroll to the end, clear the pill, re-pin.
    /// A chat switch lands unanimated — arriving somewhere new shouldn't
    /// drift through what isn't being read.
    func toEnd(animated: Bool = true, with animation: Animation = Motion.glide) {
        guard let proxy else { return }
        pinned = true
        if animated {
            withAnimation(animation) { proxy.scrollTo("end") }
        } else {
            proxy.scrollTo("end")
        }
        atBottom = true
        newSinceScroll = false
        toEndSoon()
    }

    /// Re-assert the end through an insert's animation — one scrollTo during
    /// a spring lands short of where the content finishes, so a short ladder
    /// fires until the geometry reads "at the bottom" or intent lifts.
    func toEndSoon() {
        ticket += 1
        let mine = ticket
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, mine == self.ticket, self.pinned, !self.atBottom else { return }
                self.proxy?.scrollTo("end")
            }
        }
    }
}

// MARK: - the composer box

/// The composer's state and its send path, shared by the surface so the
/// empty state's suggestion pills send through exactly what Return does —
/// including the cross-chat takeover warning (design/sidebar-features §2.4).
@MainActor
final class AskComposerBox: ObservableObject {
    /// The URL the "Website…" pick is collecting, while its row is up.
    @Published var siteDraft: String? = nil
    /// Kept in the field while a surface is up — FluidInputMessage takes
    /// a plain binding, not a FocusState.
    @Published var typing = false
    /// Another chat's turn is in flight — sending here would stop it.
    /// The composer warns once (armed), and the next send takes the turn.
    @Published var takeoverArmed = false
    private var takeoverClock: Task<Void, Never>?

    private var mind: Mind { Mind.shared }

    /// What a Return sends — an "@" list that's up takes it first (it
    /// picks the top row, not sends the mark); while *this* chat's turn is
    /// in flight the words steer it; while *another* chat's is, the first
    /// send arms the takeover and the second takes it — the other turn
    /// ends either way, so it never ends by accident.
    func send(_ words: String, browser: Browser, pin: AskPin) {
        if let first = attachable(browser).first {
            attach(first)
            return
        }
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if otherRunning != nil, !takeoverArmed {
            takeoverArmed = true
            takeoverClock?.cancel()
            takeoverClock = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self else { return }
                self.takeoverArmed = false
            }
            return
        }
        takeoverClock?.cancel()
        takeoverArmed = false
        // The composer's send() leaves clearing to the caller.
        mind.draft.wrappedValue = ""
        if runningHere { mind.steer(words) } else { mind.send(words) }
        pin.toEnd()
        typing = true
    }

    /// One Esc rung inside the composer — shed an open "@…" tail first,
    /// then the site row. Shared by the surface-level Esc handler and the
    /// composer's own keyPress (focused-field path).
    func escapeLayer() -> Bool {
        if let query = at {
            mind.draft.wrappedValue = String(mind.draft.wrappedValue.dropLast(query.count + 1))
            return true
        }
        if siteDraft != nil {
            siteDraft = nil
            return true
        }
        return false
    }

    /// This chat's turn is the one in flight — what Return decides
    /// (steer vs. send).
    var runningHere: Bool {
        mind.runningChatID != nil && mind.runningChatID == mind.currentID
    }

    /// The chat whose turn is in flight when it isn't this one — sending
    /// in this chat takes the engine from it, so the composer says so
    /// first (design/sidebar-features.md §2.4).
    var otherRunning: AskChat? {
        guard let running = mind.runningChatID, running != mind.currentID else { return nil }
        return mind.chats.first { $0.id == running }
    }

    // MARK: "@"

    /// What follows the last "@" in the draft, when one ends it — nothing, a
    /// start of a title. An "@" with a space before it is the trigger; one
    /// grown inside a word is an email address and is left alone.
    var at: String? {
        let text = mind.draft.wrappedValue
        guard let mark = text.lastIndex(of: "@") else { return nil }
        let tail = text[text.index(after: mark)...]
        guard !tail.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        if mark != text.startIndex {
            let before = text[text.index(before: mark)]
            guard before == " " || before == "\n" else { return nil }
        }
        return String(tail)
    }

    /// The tabs the "@…" could mean: all of them while it is bare, then the
    /// ones whose name or address has what was typed. A chip already worn is
    /// not offered twice; a bench tab needs no chip at all — it's the
    /// agent's already (the same skip `suggested` makes).
    func attachable(_ browser: Browser) -> [Tab] {
        guard let query = at else { return [] }
        // The app's own pages are left out — there is no page behind a
        // Settings tab for the agent to read or drive.
        let open = browser.tabs.filter { tab in
            !tab.bench && tab.native == nil && !mind.context.contains { $0.id == tab.id }
        }
        guard !query.isEmpty else { return Array(open.prefix(6)) }
        return Array(open.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || ($0.address?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }.prefix(6))
    }

    /// The active tab, when the agent could use it and doesn't have it
    /// yet — a bench tab needs no chip (it's the agent's already), an
    /// attached one can't be given twice.
    func suggested(_ browser: Browser) -> Tab? {
        guard let tab = browser.active, tab.address != nil, tab.native == nil,
              !tab.bench,
              !mind.context.contains(where: { $0.id == tab.id }) else { return nil }
        return tab
    }

    /// Take the tab: the chip goes on, the "@…" leaves the draft.
    func attach(_ tab: Tab) {
        mind.hand(tab)
        let text = mind.draft.wrappedValue
        if let mark = text.lastIndex(of: "@") {
            mind.draft.wrappedValue = String(text[..<mark])
        }
    }
}

// MARK: - the stream

/// The turns, newest arriving at the bottom and the view following — a
/// stream stays pinned to its end while the reader is there, and stops
/// following the moment they scroll up to read. What arrives meanwhile is
/// announced by the "New activity" pill, not by yanking the page
/// (design/sidebar-ux.md §6). Drawn identically on both surfaces; the
/// density env carries the rhythm.
struct AskStream: View {
    @ObservedObject var browser: Browser
    @ObservedObject var pin: AskPin
    @ObservedObject private var mind = Mind.shared
    @Environment(\.askDensity) private var density

    /// Accordions the user has touched — a turn's work opens by default
    /// while it's the live one and folds once it settles; the user's own
    /// toggle always wins these.
    @State private var openTurns: Set<UUID> = []
    @State private var foldedTurns: Set<UUID> = []
    /// The stream's top-edge fade — crisp at rest, a fade once the reader
    /// has scrolled away from the top (design/sidebar-ux.md §6).
    @State private var fadeState = FluidScrollFadeState()

    private var messages: [AskMessage] { mind.current?.messages ?? [] }
    /// The messages as turns: each of yours and the work that answered it.
    private var split: (orphans: [AskMessage], turns: [AskTurn]) {
        AskTurns.split(messages)
    }
    /// This chat's turn is the one in flight — the ring after the title,
    /// the ticking header, and what Return decides (steer vs. send).
    private var runningHere: Bool {
        mind.runningChatID != nil && mind.runningChatID == mind.currentID
    }

    /// True when this chat has heard more than one brain — the hover
    /// chip's model tail earns its place only then (design/chatux.md).
    private var mixed: Bool {
        Set(messages.compactMap(\.model)).count > 1
    }

    /// The question this chat is being asked, when it is — passed down so
    /// the ask_user row can go live for it. A question raised for another
    /// chat is none of this conversation's.
    private var asked: AskQuestion? {
        guard let question = mind.question, question.chat == mind.currentID else { return nil }
        return question
    }

    /// The `.you` a ↻ would re-run from — while the tail of the
    /// conversation is the agent's answer. An error tail's retry lives
    /// on its own card instead, so this never doubles it.
    private var retryable: AskMessage? {
        guard !runningHere, let tail = messages.last,
              tail.role == .agent else { return nil }
        return messages.last { $0.role == .you }
    }

    /// A turn's accordion state: open while it's the live one, folded once
    /// it settles — and whatever the user last set it to wins both.
    private func turnOpen(_ turn: AskTurn, live: Bool) -> Binding<Bool> {
        Binding(
            get: { openTurns.contains(turn.id) || (live && !foldedTurns.contains(turn.id)) },
            set: { open in
                if open {
                    openTurns.insert(turn.id)
                    foldedTurns.remove(turn.id)
                } else {
                    openTurns.remove(turn.id)
                    foldedTurns.insert(turn.id)
                }
            }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            stream
            .overlay(alignment: .bottom) {
                if pin.newSinceScroll, !pin.atBottom {
                    Button {
                        pin.toEnd(with: Motion.settle)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text("New activity")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(FluidTone.foreground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(FluidTone.surface(3), in: Capsule())
                        .overlay(Capsule().strokeBorder(FluidTone.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 16)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(FluidSpring.fast, value: pin.newSinceScroll)
            .onAppear {
                pin.proxy = proxy
                pin.toEnd()
            }
            .onChange(of: mind.currentID) { _, _ in
                // Another chat — its own accordion choices and its own pin.
                openTurns.removeAll()
                foldedTurns.removeAll()
                pin.toEnd(animated: false)
            }
            .onChange(of: mind.runningChatID) { old, new in
                // A turn that ended while its accordion was open stays
                // open (design/sidebar-ux.md §2.5) — only a user-set fold
                // or a new word of yours closes it. Only this chat's own
                // settle counts — a background run ending touches nothing.
                if let settled = old, new == nil, settled == mind.currentID {
                    DispatchQueue.main.async {
                        if let last = split.turns.last, !foldedTurns.contains(last.id) {
                            openTurns.insert(last.id)
                        }
                    }
                }
            }
            .onChange(of: messages) { old, new in
                // A new word of yours ends the live turn — the ones before
                // it fold to history (design/sidebar-ux.md §3.6).
                if new.last?.role == .you, new.last?.id != old.last?.id {
                    openTurns.removeAll()
                    foldedTurns.removeAll()
                }
                if pin.pinned {
                    // Held intent: re-assert the end through the insert's
                    // animation rather than trusting one raced scrollTo.
                    pin.toEndSoon()
                } else if old != new {
                    pin.newSinceScroll = true
                }
            }
        }
    }

    /// The scroll view wearing the pin where the OS offers one — macOS 15's
    /// `defaultScrollAnchor`/`onScrollGeometryChange` do the bottom-following
    /// and the away-detection; older macOS keeps the stream end-pinned the
    /// way it always was (the pill's cue simply never arms).
    @ViewBuilder
    private var stream: some View {
        if #available(macOS 15.0, *) {
            scrollBody
                // The pin: at the bottom it holds against growing content —
                // streaming words keep the last line in view. Scrolled
                // away, it holds the reader's place instead of dragging
                // them back.
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: AskPin.Geo.self) { geo in
                    AskPin.Geo(
                        gap: geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height,
                        top: geo.contentOffset.y,
                        content: geo.contentSize.height,
                        view: geo.containerSize.height)
                } action: { old, new in
                    pin.read(old, new)
                }
        } else {
            scrollBody
        }
    }

    /// The turns themselves — what both OS branches of `stream` draw.
    private var scrollBody: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: density.turnGap) {
                    // Short chats rest at the bottom — the composer they
                    // answer is down there, so the words are too.
                    Spacer(minLength: 0)
                    ForEach(split.orphans) { message in
                        AskLine(message: message, mixed: mixed, browser: browser)
                    }
                    ForEach(Array(split.turns.enumerated()), id: \.element.id) { index, turn in
                        TurnView(
                            turn: turn,
                            live: runningHere && index == split.turns.count - 1,
                            waiting: asked != nil
                                || mind.pendingApprovals.contains { $0.chat == mind.currentID },
                            startedAt: mind.current?.turnStartedAt,
                            activity: mind.activity,
                            mixed: mixed,
                            open: turnOpen(turn, live: runningHere && index == split.turns.count - 1),
                            browser: browser
                        )
                        // The find capsule's chevrons land here.
                        .id(turn.id)
                    }
                    if let retryable {
                        // A quiet way back (design/interaction.md §2) —
                        // hidden while a turn is in flight.
                        Button { mind.retry(from: retryable) } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Palette.faint)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Palette.ground, in: Capsule())
                                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Retry from your last message")
                        .transition(.opacity)
                    }
                    Color.clear.frame(height: 0).id("end")
                }
                .padding(.horizontal, density.streamPadH)
                .padding(.vertical, density.streamPadV)
                .fluidFadeContent(fadeState)
            }
            // The top edge only: a fade once the reader has scrolled
            // away — at rest the stream's head is crisp, and the bottom
            // stays crisp always (the composer is the boundary).
            .coordinateSpace(name: fadeState.space)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                fadeState.setViewHeight($0)
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .black.opacity(fadeState.topAlpha), location: 0),
                    .init(color: .black, location: min(density.fade / max(fadeState.viewHeight, 1), 0.5)),
                    .init(color: .black, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
    }
}

// MARK: - the parked zone

/// Parked work that needs a person, pinned where it can be answered —
/// between the stream and the composer, above a hairline, never a
/// sheet. The question card and the gate's approvals live here while
/// they're open (design/permissions.md §5).
struct AskParked: View {
    @ObservedObject private var mind = Mind.shared

    /// The question this chat is being asked, when it is.
    private var asked: AskQuestion? {
        guard let question = mind.question, question.chat == mind.currentID else { return nil }
        return question
    }

    var body: some View {
        let approvals = mind.pendingApprovals.filter { $0.chat == mind.currentID }
        if !approvals.isEmpty || asked != nil {
            VStack(spacing: 0) {
                Rule(inset: 0)
                VStack(spacing: 6) {
                    ForEach(approvals) { approval in
                        ApprovalCard(approval: approval)
                    }
                    if let asked {
                        QuestionCard(question: asked)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - the composer

/// The card at the bottom, Fluid's input-message: chips and picks in
/// the header slot, the field that sends on Return, attach + leash on
/// the status row's left, the brain·effort chip and the morphing
/// send/stop on its right. Same view on both surfaces — the density env
/// picks the size rung, the box carries the send.
struct AskComposer: View {
    @ObservedObject var browser: Browser
    @ObservedObject var box: AskComposerBox
    @ObservedObject var pin: AskPin
    @ObservedObject private var mind = Mind.shared
    @Environment(\.askDensity) private var density

    private var messages: [AskMessage] { mind.current?.messages ?? [] }
    private var runningHere: Bool { box.runningHere }

    /// The question this chat is being asked, when it is.
    private var asked: AskQuestion? {
        guard let question = mind.question, question.chat == mind.currentID else { return nil }
        return question
    }

    var body: some View {
        FluidInputMessage(
            text: mind.draft,
            placeholder: asked != nil ? "Answer the agent…" : "Reply, @ for context",
            history: messages.filter { $0.role == .you }.map(\.text),
            status: runningHere ? .streaming : .idle,
            size: density.composerSize,
            focus: Binding(get: { box.typing }, set: { box.typing = $0 }),
            onSend: { words, _ in box.send(words, browser: browser, pin: pin) },
            onStop: { mind.stop() },
            header: { composerHead },
            trailing: {
                ModelChip(browser: browser)
            },
            leading: {
                HStack(spacing: 4) {
                    AttachMenu(browser: browser, siteDraft: $box.siteDraft)
                    ModeMenu()
                }
            }
        )
        .padding(.horizontal, density == .page ? 0 : 10)
        .padding(.top, density == .page ? 12 : 8)
        .padding(.bottom, density == .page ? 16 : 10)
        .onKeyPress(.escape) {
            // Layers the surface's own Esc doesn't know about: an open
            // "@…" tail first, then the site row — the same rungs the
            // window's Esc gate consults through `escapeLayer`.
            box.escapeLayer() ? .handled : .ignored
        }
    }

    /// The composer's header slot: the working-elsewhere warning while
    /// another chat's turn is in flight, consent chips, the site row while
    /// it's collecting, the "@…" quick-pick while one is open — whatever
    /// sits between the field and the stream.
    @ViewBuilder
    private var composerHead: some View {
        if let other = box.otherRunning {
            // A quiet line, not a wall: the first send says it again more
            // plainly, and the second takes the turn.
            HStack(spacing: 6) {
                Ring(size: 9)
                Text(box.takeoverArmed
                     ? "Send again — “\(other.title)” stops"
                     : "Working in “\(other.title)” — sending here stops it")
                    .font(.system(size: 10.5))
                    .foregroundStyle(box.takeoverArmed ? FluidTone.foreground : FluidTone.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        if !mind.context.isEmpty || !mind.attachments.isEmpty || box.suggested(browser) != nil {
            chips
        }
        if box.siteDraft != nil {
            SiteRow(text: $box.siteDraft) { url in
                mind.attachments.append(.site(url))
            }
        }
        if box.at != nil {
            attach
        }
    }

    /// The chips over the field — each tab the next turn may read and
    /// drive, and each piece it may have — ending in the one it could
    /// have: the tab on screen, dimmed and dashed until it's asked for.
    /// (design/chatux.md — the chip *is* the consent.)
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(mind.context) { tab in
                    Chip(tab: tab, icon: browser.tabs.first { $0.id == tab.id }?.icon) {
                        mind.context.removeAll { $0.id == tab.id }
                    }
                }
                ForEach(mind.attachments) { piece in
                    AttachChip(piece: piece) {
                        mind.attachments.removeAll { $0.id == piece.id }
                    }
                }
                if let tab = box.suggested(browser) {
                    suggestion(tab)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// The dimmed dashed "+ tab" at the row's end — one click of consent.
    private func suggestion(_ tab: Tab) -> some View {
        Button { mind.hand(tab) } label: {
            HStack(spacing: 5) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 12, dim: true)
                Text("+ \(tab.label.count > 18 ? String(tab.label.prefix(18)) + "…" : tab.label)")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(Palette.faint)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(Palette.ground, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, style: StrokeStyle(dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Hand this page to the agent")
    }

    /// The little list above the field while an "@" is open — the same row
    /// the summon wears, narrowed to picking rather than going.
    private var attach: some View {
        VStack(spacing: 0) {
            if box.attachable(browser).isEmpty {
                Text("No tab matches")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(box.attachable(browser)) { tab in
                    AttachRow(tab: tab) { box.attach(tab) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - the empty state

/// Nothing asked yet — the mark, what it is for, and three places to start.
/// The page's hero rung is the same content at the bigger type
/// (fullscreen-ux §7); `hero` picks it.
struct AskEmpty: View {
    @ObservedObject var browser: Browser
    @ObservedObject var box: AskComposerBox
    @ObservedObject var pin: AskPin
    var hero = false
    @ObservedObject private var mind = Mind.shared

    var body: some View {
        VStack(spacing: hero ? 14 : 12) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: hero ? 24 : 20, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: hero ? 64 : 54, height: hero ? 64 : 54)
                .background(hero ? FluidTone.surface(2) : Palette.ground, in: Circle())
                .overlay(Circle().strokeBorder(hero ? FluidTone.border : Palette.hairline, lineWidth: 1))
            Text("Ask Search")
                .font(.system(size: hero ? 20 : 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(hero
                 ? "Ask about anything, or hand the agent a task.\n@ attaches a tab — it can read and drive what you give it."
                 : "Ask about this page, or give it a task.\n@ attaches a tab.")
                .font(.system(size: hero ? 13 : 11.5))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            ViewThatFits {
                HStack(spacing: 6) { ways }
                VStack(spacing: 6) { ways }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, hero ? 40 : 18)
    }

    /// The three things an empty chat offers, once horizontally if they fit.
    /// They send through the composer's `send` like typed words — the
    /// cross-chat takeover warning applies to them the same.
    @ViewBuilder
    private var ways: some View {
        Pill("Summarize this page") {
            // Handing the tab over is the consent — the chip goes on before
            // the words are sent so the turn starts with it attached.
            mind.hand(browser.active)
            box.send("Summarize this page", browser: browser, pin: pin)
        }
        Pill("What's open?") { box.send("List my open tabs", browser: browser, pin: pin) }
        Pill("Open example.com") { box.send("Open example.com", browser: browser, pin: pin) }
    }
}

/// A tab handed to the agent, as a capsule — its mark, its name cut short,
/// and a cross while it is still in the composer's power to take back.
struct Chip: View {
    let tab: AskTab
    var icon: NSImage?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Mark(icon: icon, letter: String(tab.title.prefix(1)).uppercased(), size: 12)
            Text(tab.title.count > 18 ? String(tab.title.prefix(18)) + "…" : tab.title)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ink)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, remove == nil ? 8 : 5)
        .padding(.vertical, 4)
        .background(Palette.wash, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// One row of the "@…" list — the tab's mark and name, where it is.
struct AttachRow: View {
    @ObservedObject var tab: Tab
    let pick: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 14)
                Text(tab.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Palette.ink)
                if let address = tab.address {
                    Text(address.host() ?? address.absoluteString)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

import AppKit
import SwiftUI

// The turn, as the stream draws it: your message, then the agent's work —
// folded under a "Worked for 4m 39s" disclosure — and its answer kept
// outside, plain and last. `AskBlock`s on the agent message carry the
// order the work happened in; this file groups them into sections (a
// paragraph and the calls that follow it, up to the next paragraph) and
// draws the accordion the design's stream is built around
// (design/sidebar-ux.md §2, design/sidebar-features.md §2.1).
//
// State is Mind's as ever; these views only read it.

/// One exchange: your message and everything the agent did for it —
/// the agent messages that followed, and the notes that landed inside.
struct AskTurn: Identifiable {
    let you: AskMessage
    /// The agent's answer messages, in order — almost always one; a note
    /// mid-turn can split it in two, and the order is what matters.
    var agent: [AskMessage] = []
    /// Notes that landed while the turn ran — verdict lines, quiet audit
    /// trail. Error notes land here too but draw outside the accordion.
    var notes: [AskMessage] = []

    var id: UUID { you.id }

    /// The turn's work in the order it happened — every agent message's
    /// blocks concatenated (one message is the common case; a note can
    /// split a turn's tail into a second agent message).
    var blocks: [AskBlock] { agent.flatMap(\.orderedBlocks) }

    /// How long it worked — stamped on the closing message at `.done`.
    /// Mid-turn steered splits carry an approximate stamp set at the cut.
    var workedFor: TimeInterval? { agent.last?.workedFor }

    /// The text run that *is* the answer — the last paragraph block,
    /// rendered outside the accordion, last in the stream. While the turn
    /// is live every paragraph is still work — the last one graduates to
    /// answer only when the turn lands.
    func answerIndex(live: Bool) -> Int? {
        live ? nil : blocks.lastIndex { $0.kind == .text && !$0.text.isEmpty }
    }

    /// The blocks the accordion owns: all of them minus the answer's
    /// paragraph — the final iteration's tools stay inside as its last
    /// section even though its text steps out.
    func work(live: Bool) -> [AskBlock] {
        var all = blocks
        if let i = answerIndex(live: live) { all.remove(at: i) }
        return all
    }

    func answer(live: Bool) -> String {
        guard let i = answerIndex(live: live) else { return "" }
        return blocks[i].text
    }

    /// Whether there's folded work to show — a turn that only spoke (no
    /// calls, one paragraph) draws no accordion at all once settled.
    func hasWork(live: Bool) -> Bool {
        !work(live: live).isEmpty || !notes.filter({ !$0.isError }).isEmpty
    }

    /// The agent message that would carry meta for the answer — for
    /// "which brain said this" on the hover chip.
    var answerMessage: AskMessage? { agent.last }
}

/// Split a chat's messages at `.you` boundaries — each turn is one of your
/// messages plus the agent work and notes that follow it, up to the next
/// word of yours. Messages before the first `.you` are orphans (notes a
/// dead run left behind).
enum AskTurns {
    static func split(_ messages: [AskMessage]) -> (orphans: [AskMessage], turns: [AskTurn]) {
        var orphans: [AskMessage] = []
        var turns: [AskTurn] = []
        for message in messages {
            switch message.role {
            case .you:
                turns.append(AskTurn(you: message))
            case .agent:
                if turns.isEmpty { orphans.append(message); continue }
                turns[turns.count - 1].agent.append(message)
            case .note:
                if turns.isEmpty { orphans.append(message); continue }
                turns[turns.count - 1].notes.append(message)
            }
        }
        return (orphans, turns)
    }

    /// The header's readout — "<1s", "12s", "4m 39s", "1h 4m". Whole
    /// seconds, digits that don't jitter (`monospacedDigit` on the text).
    static func worked(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 1 { return "<1s" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// A tool's one-line verb phrase — the cluster summary's words.
    /// Past-tense once settled, present while the turn's live.
    static func verb(_ tool: AskMessage.Tool, live: Bool) -> String {
        // "browsed acme.com" earns the host; the rest read bare.
        let host = field("url", in: tool.args)
            .flatMap { Address.url(from: $0)?.host() } ?? ""
        let at = host.isEmpty ? "" : " \(host)"
        switch tool.name {
        case "tabs_list": return live ? "listing tabs" : "listed tabs"
        case "tab_open": return live ? "opening a tab" : "opened a tab"
        case "surface_tab": return live ? "surfacing a tab" : "surfaced a tab"
        case "tab_attach": return live ? "attaching a tab" : "attached a tab"
        case "navigate": return (live ? "browsing" : "browsed") + at
        case "back": return live ? "going back" : "went back"
        case "forward": return live ? "going forward" : "went forward"
        case "reload": return live ? "reloading" : "reloaded"
        case "wait": return live ? "waiting for the page" : "waited for the page"
        case "snapshot": return live ? "reading the page" : "read the page"
        case "screenshot": return live ? "taking a screenshot" : "took a screenshot"
        case "read_text": return live ? "reading the page text" : "read the page text"
        case "run_code", "eval": return live ? "running code" : "ran code"
        case "click", "click_at": return live ? "clicking" : "clicked"
        case "fill": return live ? "filling a field" : "filled a field"
        case "type": return live ? "typing" : "typed"
        case "press":
            let key = field("key", in: tool.args) ?? ""
            return (live ? "pressing" : "pressed") + (key.isEmpty ? "" : " \(key)")
        case "hover": return live ? "hovering" : "hovered"
        case "scroll": return live ? "scrolling" : "scrolled"
        case "select": return live ? "selecting" : "selected"
        case "check": return live ? "checking a box" : "checked a box"
        case "submit": return live ? "submitting the form" : "submitted the form"
        case "console": return live ? "reading the console" : "read the console"
        case "frames": return live ? "listing frames" : "listed frames"
        case "dialogs", "answer_dialog", "choose_files":
            return live ? "handling a dialog" : "handled a dialog"
        case "close_tab": return live ? "closing a tab" : "closed a tab"
        case "ask_user": return live ? "asking you" : "asked you"
        case "done": return "" // the turn's boundary, not work — never listed
        case _ where tool.name.hasPrefix("inspector_"):
            return live ? "inspecting the page" : "inspected the page"
        default: return live ? "acting" : "acted"
        }
    }

    /// A tool's class — picks the cluster's icon: reads get the glass,
    /// acts and code the chevrons, a question its bubble, a shot the photo.
    static func icon(_ tool: AskMessage.Tool) -> String {
        switch tool.name {
        case "snapshot", "read_text", "console", "frames", "tabs_list":
            return "magnifyingglass"
        case "ask_user": return "questionmark.bubble"
        case "screenshot": return "photo"
        case "navigate", "back", "forward", "reload", "wait",
             "tab_open", "surface_tab", "tab_attach", "close_tab":
            return "globe"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The heaviest class in a cluster decides its icon — an act beats a
    /// read; a question beats both.
    static func icon(for tools: [AskMessage.Tool]) -> String {
        if tools.contains(where: { $0.name == "ask_user" }) { return "questionmark.bubble" }
        if tools.contains(where: { $0.why != nil }) { return "chevron.left.forwardslash.chevron.right" }
        if tools.contains(where: { tool in
            !["snapshot", "read_text", "console", "frames", "tabs_list",
              "navigate", "back", "forward", "reload", "wait", "screenshot",
              "tab_open", "surface_tab", "tab_attach", "close_tab"].contains(tool.name)
        }) { return "chevron.left.forwardslash.chevron.right" }
        if tools.contains(where: { $0.name == "screenshot" }) { return "photo" }
        return "magnifyingglass"
    }

    /// One key out of a small JSON object, or nil when it isn't one —
    /// the same soft read the question row uses on its args.
    private static func field(_ name: String, in json: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?[name] as? String
    }
}

// MARK: - the turn

/// A whole exchange as the stream draws it: your bubble, the "Worked for"
/// accordion over what the agent did, any error it ended in, and the
/// answer kept outside and last (design/sidebar-ux.md §2).
struct TurnView: View {
    let turn: AskTurn
    /// This chat's turn is the one in flight — accordion open and ticking.
    var live = false
    /// Parked on the question or an approval — "Waiting on you — Ns".
    var waiting = false
    var startedAt: Date?
    var activity = ""
    /// More than one brain has answered in this chat — the meta chip's
    /// model tail earns its place only then.
    var mixed = false
    var open: Binding<Bool>
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AskLine(message: turn.you, live: live, mixed: mixed, question: nil, browser: browser)
            if live || turn.hasWork(live: live) {
                WorkedFor(
                    turn: turn,
                    live: live,
                    waiting: waiting,
                    startedAt: startedAt,
                    activity: activity,
                    openBinding: open,
                    browser: browser
                )
                .askArrive("work-\(turn.id)", anchor: .topLeading, delay: 0.05, rise: 8)
            }
            ForEach(turn.notes.filter(\.isError)) { note in
                ErrorNote(note: note, you: turn.you)
                    .askArrive("error-\(note.id)", anchor: .topLeading)
            }
            let answer = turn.answer(live: live)
            if !answer.isEmpty {
                AnswerLine(text: answer, meta: turn.answerMessage, mixed: mixed, browser: browser)
                    .askArrive("answer-\(turn.id)", anchor: .topLeading, rise: 10)
            }
        }
    }
}

/// The answer, plain and last — the turn's tail drawn like the agent's own
/// line: hover floats the small meta chip (copy, when, which brain), the
/// menu offers copy and fork.
private struct AnswerLine: View {
    let text: String
    /// The message the answer came from — the meta chip reads its clock
    /// and model. Nil shouldn't happen (answers come from agent messages).
    let meta: AskMessage?
    var mixed = false
    @ObservedObject var browser: Browser
    @Environment(\.askDensity) private var density
    @Environment(\.askVerdicts) private var verdicts
    @State private var hovering = false

    var body: some View {
        AskMarkdown(text)
            .font(.system(size: density.text))
            .lineSpacing(density == .page ? 4 : 0)
            .foregroundStyle(FluidTone.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                if hovering {
                    metaChip
                        .offset(y: 16)
                        // The chip's own hover feeds the same flag — no
                        // dead pixel between the line and it.
                        .onHover { hovering = $0 }
                        .transition(.offset(y: -4).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .topLeading)))
                }
            }
            .onHover { hovering = $0 }
            .animation(AskMotion.pop, value: hovering)
            .contextMenu {
                Button("Copy") { AskUI.copy(text) }
                if let meta, let fork = verdicts.fork {
                    Button("Fork from here") { fork(meta) }
                }
            }
    }

    /// Copy, when, and — when the chat mixes brains — which one spoke.
    private var metaChip: some View {
        HStack(spacing: 6) {
            CopyChip(text)
            if let meta {
                Text(AskUI.ago(meta.when))
                if mixed, let tail = meta.model?.components(separatedBy: "/").dropFirst().joined(separator: "/"), !tail.isEmpty {
                    Text(tail)
                }
            }
        }
        .font(.system(size: density.meta))
        .foregroundStyle(Palette.faint)
        .padding(.horizontal, 7)
        .frame(height: density.metaHeight)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// A turn that ended badly, in the answer's place: the error is part of
/// the exchange, not the folded work — and the way back is right on it,
/// a quiet retry pill re-asking the question (design/sidebar-ux.md §3.8).
private struct ErrorNote: View {
    let note: AskMessage
    /// The word of yours the turn ran on — what the retry re-asks.
    let you: AskMessage
    @Environment(\.askDensity) private var density
    @Environment(\.askVerdicts) private var verdicts

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(FluidTone.destructive)
                .frame(width: 12, alignment: .center)
                .padding(.top, 1)
            Text(note.text)
                .font(.system(size: density.errorNote))
                .foregroundStyle(FluidTone.destructive)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let retry = verdicts.retry {
                Button { retry(you) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(FluidTone.destructive)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(FluidTone.destructiveLight.opacity(0.5), in: Capsule())
                        .overlay(Capsule().strokeBorder(FluidTone.destructive.opacity(0.3), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Retry")
                .disabled(verdicts.retryBlocked())
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FluidTone.destructiveLight.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(FluidTone.destructive.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - the accordion

/// One turn's folded work: a bare collapsible row — "Worked for 4m 39s"
/// — over the sections it took, open while the work is the thing
/// happening. Never a card around the working: it's a section in the
/// flow, not a wall between reasoning and answer.
struct WorkedFor: View {
    let turn: AskTurn
    /// This turn is the live one — its header ticks and it starts open.
    var live = false
    /// Parked on a question or an approval — "Waiting on you — Ns".
    var waiting = false
    /// The chat's live-turn start — the ticking clock's zero.
    var startedAt: Date?
    /// The engine's doing-word while the turn runs ("thinking…", a tool
    /// name) — drawn under the header when the accordion's been folded.
    var activity = ""
    /// The user's own toggle wins — the panel holds the sets this writes.
    var openBinding: Binding<Bool>
    @ObservedObject var browser: Browser
    @Environment(\.askDensity) private var density

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            panel
            // Folded by the user while the turn's alive: one line of the
            // doing still reads, so a folded live turn never looks dead.
            if live, !openBinding.wrappedValue, !activity.isEmpty {
                HStack(spacing: 7) {
                    AskSpinner(size: 9)
                    Text(activity)
                        .font(.system(size: density.note))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 2)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
    }

    // MARK: header

    /// The row: ring while it works, the word and the time, the chevron.
    private var header: some View {
        Button {
            withAnimation(FluidSpring.fast) { openBinding.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                if live {
                    AskSpinner(size: 9)
                }
                label
                Image(systemName: "chevron.right")
                    .font(.system(size: density == .page ? 8 : 7, weight: .bold))
                    .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                    .rotationEffect(.degrees(openBinding.wrappedValue ? 90 : 0))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FluidTone.hover)
                .opacity(hovering ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.08), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(live ? "Working" : "Worked")
        .accessibilityValue(label_)
    }

    private var lit: Bool { openBinding.wrappedValue || hovering }

    /// "Working for 4m 39s" / "Waiting on you — 12s" / "Worked for 4m 39s".
    private var label_: String {
        if live {
            let span = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            if waiting { return "Waiting on you — \(AskTurns.worked(span))" }
            return "Working for \(AskTurns.worked(span))"
        }
        if let worked = turn.workedFor { return "Worked for \(AskTurns.worked(worked))" }
        return "Worked"
    }

    /// The dual-layer label — an invisible semibold twin reserves the
    /// width so emboldening on open never reflows (FluidStepsTrigger's
    /// trick). Live, it ticks once a second off the timeline.
    @ViewBuilder
    private var label: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                dual(label_)
                    // The sweep says the word is alive — settled turns
                    // keep their label still.
                    .fluidShimmerSweep(FluidTone.mutedForeground, active: true)
            }
        } else {
            dual(label_)
        }
    }

    private func dual(_ text: String) -> some View {
        ZStack(alignment: .leading) {
            Text(text).font(.system(size: density.workedHead, weight: .semibold)).hidden()
            Text(text)
                .font(.system(size: density.workedHead, weight: openBinding.wrappedValue ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
        }
    }

    // MARK: panel

    /// The measured-height body — sections of paragraph + calls. Closed,
    /// settled history doesn't pay to draw them; live and open, it does.
    private var panel: some View {
        WorkedPanel(open: openBinding.wrappedValue) {
            VStack(alignment: .leading, spacing: 12) {
                if turn.work(live: live).isEmpty && turn.notes.filter({ !$0.isError }).isEmpty {
                    // A live turn before its first block: the doing-line.
                    HStack(spacing: 7) {
                        AskSpinner(size: 9)
                        Text(activity.isEmpty ? "working…" : activity)
                            .font(.system(size: density.note))
                            .foregroundStyle(FluidTone.mutedForeground)
                    }
                    .padding(.leading, 2)
                } else {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        WorkSection(section: section, live: live, browser: browser)
                            .askArrive("section-\(turn.id)-\(index)", anchor: .topLeading, rise: 6)
                    }
                    ForEach(turn.notes.filter { !$0.isError }) { note in
                        if let approval = note.approval {
                            DisclosureGroup(note.text) {
                                ApprovalCard(approval: approval, resolved: true)
                                    .padding(.top, 5)
                            }
                            .font(.system(size: density.note))
                            .foregroundStyle(FluidTone.mutedForeground)
                            .padding(.horizontal, 12)
                        } else {
                            Text(note.text)
                                .font(.system(size: density.note))
                                .foregroundStyle(FluidTone.mutedForeground)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.top, 4)
        }
    }

    /// The turn's work grouped at each paragraph — a section is the words
    /// and the calls that follow them, until the next words. A leading
    /// run of calls is its own paragraph-less section.
    private var sections: [WorkGroup] {
        var groups: [WorkGroup] = []
        for block in turn.work(live: live) {
            if block.kind == .text {
                groups.append(WorkGroup(text: block.text))
            } else {
                if groups.isEmpty { groups.append(WorkGroup(text: nil)) }
                groups[groups.count - 1].append(block)
            }
        }
        return groups
    }
}

/// The measure-and-clamp collapse FluidStepsPanel does, without its fixed
/// padding — the rail's panel hangs tight to the stream's rhythm.
private struct WorkedPanel<Content: View>: View {
    var open: Bool
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { height = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in height = h }
                }
            )
            .frame(height: open ? height : 0, alignment: .top)
            .clipped()
            .animation(FluidSpring.moderate, value: open)
    }
}

/// One section inside the work: a paragraph if it wrote one, then its
/// calls as a nested cluster, then the pictures it produced.
struct WorkGroup {
    var text: String?
    var tools: [AskMessage.Tool] = []
    var shots: [AskBlock] = []

    mutating func append(_ block: AskBlock) {
        switch block.kind {
        case .tool:
            if let tool = block.tool {
                tools.append(tool)
                // A screenshot's path doubles as its artifact card.
                if let shot = tool.shot { shots.append(.artifact(shot, tab: nil)) }
            }
        case .artifact:
            shots.append(block)
        case .text:
            break
        }
    }
}

private struct WorkSection: View {
    let section: WorkGroup
    var live: Bool
    @ObservedObject var browser: Browser
    @Environment(\.askDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = section.text, !text.isEmpty {
                AskMarkdown(text)
                    .font(.system(size: density.paragraph))
                    .foregroundStyle(FluidTone.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !section.tools.isEmpty {
                ToolCluster(tools: section.tools, live: live)
            }
            ForEach(section.shots) { block in
                ShotCard(path: block.path ?? "", browser: browser)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - the cluster

/// A run of calls as one honest line — "Searched the web, read a page,
/// browsed acme.com" — that opens into the row-per-call detail. The
/// model's own `why` outranks the verb list when it gave one: those are
/// the "</>" lines.
private struct ToolCluster: View {
    let tools: [AskMessage.Tool]
    var live: Bool
    @Environment(\.askDensity) private var density
    @State private var open = false
    @State private var hovering = false

    /// The `why` the model gave its heaviest call, if any — the row reads
    /// it under "</>" instead of the verb summary.
    private var why: String? {
        tools.last { $0.why != nil && !$0.why!.isEmpty }?.why
    }

    /// The verb list: deduped in order, three shown then "+N more".
    private var summary: String {
        var seen: [String] = []
        for tool in tools where tool.name != "done" {
            let v = AskTurns.verb(tool, live: live)
            if !v.isEmpty, !seen.contains(v) { seen.append(v) }
        }
        let head = seen.prefix(3).joined(separator: ", ")
        return seen.count > 3 ? head + " +\(seen.count - 3) more" : head
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(FluidSpring.fast) { open.toggle() }
            } label: {
                HStack(spacing: 7) {
                    icon
                        .frame(width: 12, alignment: .center)
                    Text(title)
                        .font(.system(size: density.clusterHead, weight: .medium))
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FluidTone.hover)
                    .opacity(hovering ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.08), value: hovering)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(.isHeader)

            WorkedPanel(open: open) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { tool in
                        if tool.name == "ask_user" {
                            // The pinned zone owns the live card; in the
                            // cluster the call stays a one-line row.
                            QuestionRow(tool: tool, live: live)
                        } else {
                            ToolRow(tool: tool, live: live)
                        }
                    }
                }
                .padding(.leading, 19)
                .padding(.top, 4)
            }
        }
    }

    private var lit: Bool { open || hovering }

    @ViewBuilder
    private var icon: some View {
        if let why {
            // The code-tag lines — "</>" in mono, the phrase after it.
            Text("</>")
                .font(.system(size: density == .page ? 9.5 : 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(FluidTone.mutedForeground)
        } else {
            Image(systemName: AskTurns.icon(for: tools))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(FluidTone.mutedForeground)
        }
    }

    private var title: String { why ?? summary }
}

// MARK: - the shot card

/// A screenshot the turn took — the result's PNG at thumb size, lazy on
/// appear. Click opens the picture in a tab; the menu offers the copies.
private struct ShotCard: View {
    let path: String
    @ObservedObject var browser: Browser
    @Environment(\.askDensity) private var density
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: density.shotRadius, style: .continuous)
                    .fill(FluidTone.muted)
                    .frame(width: density.shotMaxWidth, height: density.shotMaxWidth * 82 / 132)
                    .overlay(FluidRingSpinner(diameter: 18))
            }
        }
        .frame(maxWidth: density.shotMaxWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: density.shotRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: density.shotRadius, style: .continuous)
                .strokeBorder(FluidTone.border, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.shotRadius, style: .continuous)
                .fill(FluidTone.hover)
                .opacity(hovering ? 1 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: density.shotRadius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.08), value: hovering)
        .onTapGesture {
            browser.open(URL(fileURLWithPath: path), foreground: true)
        }
        .contextMenu {
            Button("Open in Tab") { browser.open(URL(fileURLWithPath: path), foreground: true) }
            Button("Copy Image") {
                if let image { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .task(id: path) {
            guard !path.isEmpty else { return }
            image = NSImage(contentsOfFile: path)
        }
    }
}

// MARK: - markdown text

/// Agent prose: markdown inline (links, bold, code — the design's blue
/// linked words), plain everywhere else. Links open in a real tab, never
/// the panel — the openURL environment is bound by the turn view.
struct AskMarkdown: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        if let markdown = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(markdown)
        } else {
            Text(text)
        }
    }
}

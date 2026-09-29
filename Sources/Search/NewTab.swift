import SwiftUI

/// The blank tab's shelf — recent chats and automations as card
/// sections under the field, each card a door into the Ask window
/// (design/newtab.md). It mounts beside the suggestions list: offers
/// empty means the field is at rest and the shelf is welcome; typing or
/// a ⌘K summon swaps it for the list on one quick crossfade.
///
/// Observation lives on the leaf views only — Mind and Routines publish
/// per streamed token, so subscribing up here (or anywhere above) would
/// redraw the field overlay with every delta.
struct NewTabShelf: View {
    @ObservedObject var browser: Browser
    /// The window's height — the overlay only spans the field, so the
    /// room under it is learned from the window itself.
    @State private var stage: CGFloat = 780
    @State private var resizeWatch: NSObjectProtocol?

    /// What's under the shelf's anchor: the field sits 30pt above centre,
    /// the shelf hangs 28 under it, and a little air is kept at the
    /// window's foot.
    private var avail: CGFloat { stage / 2 - 39 }

    /// The tier the room affords — tuned heights from the spec: a
    /// section is header 16 + gap 6 + rows of 62 at gaps of 8, sections
    /// 18 apart.
    private var chatCap: Int {
        avail >= 360 ? 4 : avail >= 100 ? 2 : 0
    }
    private var routineCap: Int {
        avail >= 360 ? 4 : avail >= 200 ? 2 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if chatCap > 0 {
                NewTabChats(cap: chatCap)
            }
            if routineCap > 0 {
                NewTabRoutines(cap: routineCap)
            }
        }
        .background(WindowSetup { window in
            stage = window.frame.height
            resizeWatch = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { note in
                Task { @MainActor in
                    if let w = note.object as? NSWindow { stage = w.frame.height }
                }
            }
        })
        .onDisappear {
            if let resizeWatch { NotificationCenter.default.removeObserver(resizeWatch) }
        }
    }
}

/// The deep-link both card kinds take: warm windows hear `show`, closed
/// ones get `pending` — consumed once when the fresh page dresses.
private func openAsk(tab: Int, routine: UUID? = nil, newRoutine: Bool = false,
                     openWindow: OpenWindowAction) {
    if AskWindow.window != nil {
        AskWindow.show(tab, routine, newRoutine)
    } else {
        // The cold dress reads the persisted tab before pending lands.
        Store.settings.set(tab, forKey: "ask.page.tab")
        AskWindow.pending = .init(tab: tab, routine: routine, newRoutine: newRoutine)
    }
    openWindow(id: "ask")
    AskWindow.window?.makeKeyAndOrderFront(nil)
}

// MARK: - a section's chrome

/// The section label and its "All ⌄" door — the PROMPT/RUNS header idiom
/// at 10pt, the door a plain muted ghost rather than a button-shaped one.
private struct NewTabSection<Content: View>: View {
    let title: String
    let count: Int
    var seeAll: () -> Void = {}
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FluidTone.mutedForeground)
                Spacer(minLength: 0)
                Button(action: seeAll) {
                    Text("All ⌄")
                        .font(.system(size: 11))
                        .foregroundStyle(hovering
                            ? FluidTone.foreground : FluidTone.mutedForeground)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.08), value: hovering)
                .accessibilityLabel("Show all \(title.lowercased())")
            }
            FluidCardGroup(columns: 2, outlined: true, separated: true,
                           count: count) { content() }
        }
    }
}

// MARK: - chats

/// The CHATS section — most recent first, the same order the nav keeps.
private struct NewTabChats: View {
    let cap: Int
    @ObservedObject private var mind = Mind.shared
    @Environment(\.openWindow) private var openWindow

    private var chats: [AskChat] { Array(mind.chats.prefix(cap)) }

    var body: some View {
        if !chats.isEmpty {
            NewTabSection(title: "CHATS", count: chats.count,
                          seeAll: { openAsk(tab: 0, openWindow: openWindow) }) {
                ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                    NewTabChatCard(chat: chat, index: index)
                }
            }
        }
    }
}

/// One chat: title over the last line, with the nav row's marks —
/// unread dot, running ring, the parked question and approvals, the ⑂
/// of a fork. Clicking is a look: select rides mind's single cursor.
private struct NewTabChatCard: View {
    let chat: AskChat
    let index: Int
    @ObservedObject private var mind = Mind.shared
    @Environment(\.openWindow) private var openWindow

    private var unread: Bool {
        chat.id != mind.currentID && !chat.messages.isEmpty
            && chat.lastSeen != chat.messages.last?.id
    }

    /// The last thing worth a preview — notes are verdict chrome, not
    /// something anyone said.
    private var preview: String {
        let last = chat.messages.last { $0.role != .note }
        return last.map { AskUI.oneline($0.text) } ?? ""
    }

    private var approvals: Int {
        mind.pendingApprovals.filter { $0.chat == chat.id }.count
    }

    var body: some View {
        FluidCard(index: index, onClick: {
            mind.select(chat)
            openAsk(tab: 0, openWindow: openWindow)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if unread {
                        Circle()
                            .fill(FluidTone.destructive)
                            .frame(width: 6, height: 6)
                    }
                    Text(chat.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FluidTone.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(AskUI.ago(chat.when))
                        .font(.system(size: 10))
                        .foregroundStyle(FluidTone.mutedForeground)
                }
                HStack(spacing: 6) {
                    Text(preview.isEmpty ? "New chat" : preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if chat.id == mind.runningChatID {
                        Ring(size: 9)
                    } else if mind.question?.chat == chat.id {
                        Image(systemName: "questionmark.bubble")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(RoutineUI.amber)
                    }
                    if approvals > 0 {
                        Text("\(approvals)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(FluidTone.destructive)
                            .frame(minWidth: 13)
                            .frame(height: 13)
                            .padding(.horizontal, 2)
                            .background(FluidTone.destructiveLight, in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                FluidTone.destructive.opacity(0.3), lineWidth: 1))
                    }
                    if chat.parent != nil {
                        Text("⑂")
                            .font(.system(size: 10))
                            .foregroundStyle(FluidTone.mutedForeground)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chat.title), \(AskUI.ago(chat.when))")
        .accessibilityHint("Open chat")
    }
}

// MARK: - automations

/// The AUTOMATIONS section — attention first, not creation order: runs
/// needing a person, then unseen outcomes, then the coming-up-next
/// clock, paused last (the new tab is a glance surface).
private struct NewTabRoutines: View {
    let cap: Int
    @ObservedObject private var routines = Routines.shared
    @Environment(\.openWindow) private var openWindow

    private func rank(_ routine: Routine, _ status: RoutineUI.Status) -> Int {
        if status.live != nil { return 0 }
        if status.unacknowledged > 0 { return 1 }
        return routine.enabled ? 2 : 3
    }

    private var ordered: [(Routine, RoutineUI.Status)] {
        routines.routines
            .map { ($0, RoutineUI.status(of: $0, in: routines)) }
            .sorted { a, b in
                let ra = rank(a.0, a.1), rb = rank(b.0, b.1)
                if ra != rb { return ra < rb }
                switch ra {
                case 0:
                    return (a.1.live?.queuedAt ?? .distantPast)
                        > (b.1.live?.queuedAt ?? .distantPast)
                case 2:
                    return (a.0.nextRunAt ?? .distantFuture)
                        < (b.0.nextRunAt ?? .distantFuture)
                default:
                    return a.0.updatedAt > b.0.updatedAt
                }
            }
    }

    var body: some View {
        let shown = Array(ordered.prefix(cap))
        if !shown.isEmpty {
            NewTabSection(title: "AUTOMATIONS", count: shown.count,
                          seeAll: { openAsk(tab: 1, openWindow: openWindow) }) {
                ForEach(Array(shown.enumerated()), id: \.element.0.id) { index, pair in
                    NewTabRoutineCard(routine: pair.0, status: pair.1, index: index)
                }
            }
        }
    }
}

/// One routine: name, its schedule's words, and the shared status line —
/// the live run's glyph where a row would spin, the failed chip where a
/// run went wrong, the unseen count trailing.
private struct NewTabRoutineCard: View {
    let routine: Routine
    let status: RoutineUI.Status
    let index: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        FluidCard(index: index, onClick: {
            openAsk(tab: 1, routine: routine.id, openWindow: openWindow)
        }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(routine.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FluidTone.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let run = status.live {
                        if run.state == .waiting {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(RoutineUI.amber)
                        } else {
                            Ring(size: 9)
                        }
                    }
                    if status.unacknowledged > 0 {
                        Text("\(status.unacknowledged)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(FluidTone.destructive)
                            .frame(minWidth: 13)
                            .frame(height: 13)
                            .padding(.horizontal, 2)
                            .background(FluidTone.destructiveLight, in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                FluidTone.destructive.opacity(0.3), lineWidth: 1))
                    }
                }
                Text(routine.schedule.sentence)
                    .font(.system(size: 11))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .lineLimit(1)
                Text(status.line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(routine.name), \(routine.schedule.sentence), \(status.line)")
        .accessibilityHint("Open routine")
    }
}

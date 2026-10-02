import SwiftUI
import AppKit

// The Ask window — the rail's conversation as a page of its own: a Fluid
// navigation sidebar on the left, the shared stream and composer in a
// 760pt reading column on the right (design/fullscreen-ux.md). It is a
// second view on the same Mind — one cursor, one draft, one pin per
// surface; selecting a chat here selects it there.

/// The Ask window's keys, before the browser's — `ContentView.take()` is
/// app-global, so the window registers itself the way a Little window
/// does (fullscreen-features §6.1): ⌘F is the transcript's, ⌘K the
/// switcher's, ⌘N a new chat, ⌘. the stop, ⌘W the window's own close,
/// Esc the page's cascade. Anything else falls through to the menus.
enum AskWindow {
    static weak var window: NSWindow?
    static var find: () -> Void = {}
    static var switcher: () -> Void = {}
    static var newChat: () -> Void = {}
    static var stop: () -> Void = {}
    /// One Esc rung — true when it shed something. Called until a layer
    /// takes it; false hands the key to SwiftUI (the composer's own
    /// @-tail and site-row layers live there).
    static var escape: () -> Bool = { false }
    /// The title field's own rung while it is being edited — Esc there
    /// reverts rather than committing (AskTitleField registers it; nil
    /// the rest of the time).
    static var titleEscape: (() -> Bool)?

    /// Cold-open intent — set before `openWindow`, consumed once at
    /// dress. Reopen builds a fresh AskPage, so the same consume path
    /// serves a closed window every time.
    static var pending: Pending?
    struct Pending {
        var tab = 0                 // 0 Chats, 1 Automations
        var routine: UUID? = nil    // an Automations selection
        var newRoutine = false      // land on the create form
    }
    /// Warm path — the page registers it at dress like the key closures.
    /// Flips the tab (self-persisting) and routes the selection through
    /// the dirty-form guard.
    static var show: (_ tab: Int, _ routine: UUID?, _ newRoutine: Bool) -> Void = { _, _, _ in }

    static func owns(_ candidate: NSWindow?) -> Bool {
        window != nil && candidate === window
    }

    static func take(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "f", flags == .command { find(); return true }
        if key == "k", flags == .command { switcher(); return true }
        if key == "n", flags == .command || flags == [.command, .shift] { newChat(); return true }
        if key == ".", flags == .command { stop(); return true }
        if key == "w", flags == .command { window?.performClose(nil); return true }
        if event.keyCode == 53, flags.isEmpty { return escape() }
        return false
    }
}

/// The page itself: nav + column in a persisted sidebar shell, with the
/// density env turned to `.page` so every shared view takes the roomier
/// rung without a forked file.
struct AskPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var mind = Mind.shared
    @ObservedObject private var routines = Routines.shared
    @StateObject private var pin = AskPin()
    @StateObject private var composer = AskComposerBox()

    /// The sidebar's tab — Chats or Automations.
    @State private var tab: Int = Store.settings.integer(forKey: "ask.page.tab")
    /// The list filter — chats on tab 0, routines on tab 1.
    @State private var query = ""
    /// The transcript find capsule (⌘F).
    @State private var finding = false {
        // The capsule's query dies with it — reopening starts clean
        // rather than mid-list on words typed three finds ago.
        didSet { if !finding { findText = ""; findAt = 0 } }
    }
    @State private var findText = ""
    @State private var findAt = 0
    /// The chat/routine switcher (⌘K).
    @State private var switching = false
    @State private var switchQuery = ""
    /// The share menu's popup.
    @State private var sharing = false
    /// A row's ⋯ menu — keyed by chat so each row carries its own.
    @State private var rowMenu: UUID?
    /// The routine rows' ⋯ menu, keyed the same way.
    @State private var routineMenu: UUID?
    /// A "Rename…" picked off a row — hands the chat to the header's
    /// inline title field rather than growing a second rename surface.
    @State private var renameRequest: UUID?

    // Automations — the board's selection, its form (nil = closed), the
    // discard-confirm for a dirty form, the delete-confirm, and the move
    // waiting on the discard's answer.
    @State private var routineID: UUID?
    @State private var routineDraft: RoutineDraft?
    @State private var routineDiscarding = false
    @State private var routineDeleting: Routine?
    @State private var routinePending: (() -> Void)?

    private var runningHere: Bool {
        mind.runningChatID != nil && mind.runningChatID == mind.currentID
    }

    var body: some View {
        FluidSidebarProvider(persist: true, persistKey: "asknav", peek: .hover, width: 232) {
            HStack(spacing: 0) {
                FluidSidebar(minWidth: 200, maxWidth: 320, collapseSlop: 56,
                             collapsible: .offcanvas, bordered: true, rail: true) {
                    nav
                }
                column
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FluidTone.surface(1))
        .environment(\.askDensity, .page)
        // A link in anything the agent wrote opens as a real browser tab.
        .environment(\.openURL, OpenURLAction { url in
            browser.open(url, foreground: true)
            return .handled
        })
        .background(WindowSetup { window in
            AskWindow.dress(window)
            bindKeys()
        })
        .fluidDialog(isPresented: $switching, size: .lg, position: .top,
                     topStyle: .palette,
                     showCloseButton: false, panelPadding: 0, maxHeight: 440) {
            FluidCommandMenu(
                items: switcherItems,
                query: $switchQuery,
                placeholder: tab == 0 ? "Jump to a chat…" : "Jump to a routine…",
                onSelect: { _ in switching = false },
                onEscape: { switching = false }
            )
            // The shell's close — rows close on select and the footer
            // hints at Esc, as in a CommandMenuDialog.
            .environment(\.fluidCommandDialogClose, { switching = false })
        }
        // Delete asks — it takes the run history with it.
        .fluidDialog(isPresented: Binding(
            get: { routineDeleting != nil },
            set: { if !$0 { routineDeleting = nil } }), size: .sm) {
            VStack(alignment: .leading, spacing: 0) {
                FluidDialogHeader {
                    FluidDialogTitle("Delete routine?")
                    FluidDialogDescription(
                        "“\(routineDeleting?.name ?? "")” and its run history are removed. There is no undo.")
                }
                FluidDialogFooter {
                    FluidButton("Cancel", variant: .tertiary) { routineDeleting = nil }
                    FluidButton("Delete") {
                        if let routine = routineDeleting {
                            Routines.shared.remove(routine)
                            if routineID == routine.id { routineID = nil }
                        }
                        routineDeleting = nil
                    }
                }
            }
        }
        // A dirty form asks before its typing is shed. Backdrop, Esc and
        // the ✕ all close it without a button — the parked act dies with
        // the dialog either way, so a later Discard can't replay a stale
        // intent.
        .onChange(of: routineDiscarding) { _, open in
            if !open { routinePending = nil }
        }
        .fluidDialog(isPresented: $routineDiscarding, size: .sm) {
            VStack(alignment: .leading, spacing: 0) {
                FluidDialogHeader {
                    FluidDialogTitle("Discard changes?")
                    FluidDialogDescription("The routine edits aren't saved.")
                }
                FluidDialogFooter {
                    FluidButton("Keep editing", variant: .tertiary) {
                        routineDiscarding = false
                        routinePending = nil
                    }
                    FluidButton("Discard") {
                        routineDraft = nil
                        routineDiscarding = false
                        let act = routinePending
                        routinePending = nil
                        act?()
                    }
                }
            }
        }
        .onAppear {
            Harness.shared.attach()
            #if DEBUG
            Mind.shared.demoHooks(browser)
            #endif
            DispatchQueue.main.async { composer.typing = true }
            // Landing straight on Automations (a persisted tab) picks
            // the first routine rather than showing the empty pane.
            if tab == 1, routineID == nil, routineDraft == nil {
                routineID = routines.routines.first?.id
            }
        }
        .onChange(of: tab) { _, new in
            Store.settings.set(new, forKey: "ask.page.tab")
            // The chat-only overlays don't travel — a capsule left armed
            // would resurface on the way back and eat an Esc meant for
            // the routine form.
            finding = false
            rowMenu = nil
            sharing = false
            if new == 1, routineID == nil, routineDraft == nil {
                routineID = routines.routines.first?.id
            }
        }
        // Picking a chat puts the cursor in the composer — the page's
        // keyboard lives there, so it should start held (spec §3).
        .onChange(of: mind.currentID) { _, _ in composer.typing = true }
    }

    /// What ⌘F, ⌘K, ⌘N, ⌘. and Esc mean while this window is key —
    /// wired once the window exists (fullscreen-features §6). Bindings and
    /// the shared objects are captured so the keys always read live state —
    /// a `self` snapshot would freeze the day the window dressed.
    private func bindKeys() {
        let finding = $finding, query = $query
        let switchQuery = $switchQuery, switching = $switching
        let sharing = $sharing, rowMenu = $rowMenu, routineMenu = $routineMenu
        let tab = $tab, routineID = $routineID, routineDraft = $routineDraft
        let routineDiscarding = $routineDiscarding, routineDeleting = $routineDeleting
        let routinePending = $routinePending
        let composer = composer, mind = Mind.shared, pin = pin
        AskWindow.find = {
            // Find is transcript-scoped — the Automations tab has none yet.
            guard tab.wrappedValue == 0 else { return }
            withAnimation(FluidSpring.fast) { finding.wrappedValue = true }
        }
        AskWindow.switcher = { switchQuery.wrappedValue = ""; switching.wrappedValue = true }
        AskWindow.newChat = {
            if tab.wrappedValue == 1 {
                self.requestRoutine { routineDraft.wrappedValue = RoutineDraft() }
            } else {
                mind.newChat()
            }
        }
        AskWindow.stop = {
            if tab.wrappedValue == 1 {
                if let id = routineID.wrappedValue,
                   let run = RoutineUI.liveRun(in: Routines.shared.runs[id] ?? []) {
                    Routines.shared.stop(run)
                }
            } else if mind.runningChatID != nil, mind.runningChatID == mind.currentID {
                mind.stop()
            }
        }
        AskWindow.escape = {
            // Layers, topmost first: the ⌘K switcher, an open share or row
            // menu, the find capsule, the title's own edit (it reverts),
            // the nav filter, then the composer's own (@-tail, site row),
            // a scrolled-away stream back to the present, and only a
            // blurred field after that. Never the window itself. On the
            // Automations tab the chat rungs give way to the board's:
            // dialog, the form (dirty asks first), the filter, the pick.
            if switching.wrappedValue { switching.wrappedValue = false; return true }
            if sharing.wrappedValue { sharing.wrappedValue = false; return true }
            if rowMenu.wrappedValue != nil { rowMenu.wrappedValue = nil; return true }
            if routineMenu.wrappedValue != nil { routineMenu.wrappedValue = nil; return true }
            if routineDeleting.wrappedValue != nil { routineDeleting.wrappedValue = nil; return true }
            if routineDiscarding.wrappedValue {
                routineDiscarding.wrappedValue = false
                routinePending.wrappedValue = nil
                return true
            }
            if finding.wrappedValue {
                withAnimation(FluidSpring.fast) { finding.wrappedValue = false }
                return true
            }
            if tab.wrappedValue == 1 {
                if AskWindow.titleEscape?() == true { return true }
                if routineDraft.wrappedValue != nil {
                    if routineDraft.wrappedValue?.dirty == true {
                        routineDiscarding.wrappedValue = true
                    } else {
                        routineDraft.wrappedValue = nil
                    }
                    return true
                }
                if !query.wrappedValue.isEmpty { query.wrappedValue = ""; return true }
                if routineID.wrappedValue != nil { routineID.wrappedValue = nil; return true }
                return false
            }
            if AskWindow.titleEscape?() == true { return true }
            if !query.wrappedValue.isEmpty { query.wrappedValue = ""; return true }
            if composer.escapeLayer() { return true }
            if !pin.atBottom {
                withAnimation(FluidSpring.fast) { pin.toEnd() }
                return true
            }
            if let window = AskWindow.window,
               let first = window.firstResponder,
               !(first is NSWindow) && first !== window.contentView {
                window.makeFirstResponder(window.contentView)
                return true
            }
            return false
        }
        // The nav row's selection goes through the dirty guard too — a
        // click on another routine with edits on the table asks first.
        RoutinesUI.select = { [self] id in
            self.requestRoutine {
                routineDraft.wrappedValue = nil
                routineID.wrappedValue = id
            }
        }
        // Deep links in — a new-tab card asks for a tab and (maybe) a
        // routine the same way the window's own rows do.
        AskWindow.show = { [self] tabID, routine, makeNew in
            tab.wrappedValue = tabID
            if makeNew {
                self.requestRoutine { routineDraft.wrappedValue = RoutineDraft() }
            } else if let routine {
                RoutinesUI.select(routine)
            }
        }
        // A cold open arrives before the page exists — the pending intent
        // lands here, after onAppear's first-routine pick, so it wins.
        if let pending = AskWindow.pending {
            AskWindow.pending = nil
            AskWindow.show(pending.tab, pending.routine, pending.newRoutine)
        }
    }

    /// Anything that would shed the routine form — picking another row,
    /// New routine, Edit… — goes through here so a dirty draft gets its
    /// "Discard changes?" first instead of losing the typing silently.
    private func requestRoutine(_ act: @escaping () -> Void) {
        if routineDraft?.dirty == true {
            routinePending = act
            routineDiscarding = true
        } else {
            routineDraft = nil
            act()
        }
    }

    // MARK: - the nav sidebar

    private var nav: some View {
        VStack(spacing: 0) {
            // The window's traffic lights sit on this corner's top strip —
            // the header starts under them rather than through them.
            Color.clear.frame(height: 28)
            FluidSidebarHeader {
                VStack(spacing: 8) {
                    FluidTabs(items: ["Chats", "Automations"], selection: $tab,
                              size: .compact, substrate: 0)
                        .overlay(alignment: .topTrailing) {
                            // Waiting or unseen runs — the tab's share of
                            // the routines badge rides its trailing corner.
                            if routines.badge > 0 {
                                Text("\(routines.badge)")
                                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                                    .foregroundStyle(FluidTone.destructive)
                                    .frame(minWidth: 13)
                                    .frame(height: 13)
                                    .padding(.horizontal, 2)
                                    .background(FluidTone.destructiveLight, in: Capsule())
                                    .overlay(Capsule().strokeBorder(FluidTone.destructive.opacity(0.3), lineWidth: 1))
                                    .offset(x: -4, y: -5)
                                    .allowsHitTesting(false)
                            }
                        }
                    FluidSidebarInput(tab == 0 ? "Search chats…" : "Search routines…",
                                      text: $query, icon: "magnifyingglass")
                }
            }
            FluidSidebarContent {
                if tab == 0 { chatsMenu } else { routinesNav }
            }
            FluidSidebarFooter {
                FluidSidebarMenuButton(index: -1, icon: "gearshape",
                                       size: .regular, isActive: false) {
                    browser.openInternal(.settings, section: "ask")
                } label: {
                    FluidSidebarMenuRowLabel(label: "Ask Settings")
                } trailing: {
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FluidTone.surface(0))
    }

    /// The chats, most recently alive first — the new-chat row, then a
    /// FluidChatRow each, filtered by the search field's text.
    private var chatsMenu: some View {
        // The lit row is the chat on screen — row 0 is New chat, the
        // chats index off the filtered list (menuActive == index).
        FluidSidebarMenu(activeIndex: Binding(
            get: { filtered.firstIndex(where: { $0.id == mind.currentID }).map { $0 + 1 } },
            set: { _ in })) {
            FluidSidebarMenuButton(index: 0, icon: "square.and.pencil",
                                   variant: .outline, size: .regular,
                                   isActive: false) {
                mind.newChat()
            } label: {
                FluidSidebarMenuRowLabel(label: "New chat")
            } trailing: {
                EmptyView()
            }
            FluidSidebarGroup("Recent") {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "No chats yet" : "No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                ForEach(Array(filtered.enumerated()), id: \.element.id) { i, chat in
                    FluidChatRow(chat: chat, index: i + 1,
                                 menuOpen: rowMenu == chat.id,
                                 onMenu: { rowMenu = $0 ? chat.id : nil },
                                 onRename: {
                                    // The title field renames the chat on
                                    // screen — a row's rename selects it
                                    // first, then hands over the pencil.
                                    mind.select(chat)
                                    renameRequest = chat.id
                                 })
                }
            }
        }
    }

    /// The list the search field is filtering — title or the last line.
    private var filtered: [AskChat] {
        guard !query.isEmpty else { return mind.chats }
        return mind.chats.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.messages.last?.text.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// The routines — the new-routine door, then a RoutineRow each, the
    /// same list anatomy the chats menu keeps (automation-frontend §2).
    private var routinesNav: some View {
        // Row 0 is New routine; the rows index off the filtered list.
        FluidSidebarMenu(activeIndex: Binding(
            get: { filteredRoutines.firstIndex(where: { $0.id == routineID }).map { $0 + 1 } },
            set: { _ in })) {
            FluidSidebarMenuButton(index: 0, icon: "plus",
                                   variant: .outline, size: .regular,
                                   isActive: false) {
                requestRoutine { routineDraft = RoutineDraft() }
            } label: {
                FluidSidebarMenuRowLabel(label: "New routine")
            } trailing: {
                EmptyView()
            }
            FluidSidebarGroup("Routines") {
                if filteredRoutines.isEmpty {
                    Text(query.isEmpty ? "No routines yet" : "No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                ForEach(Array(filteredRoutines.enumerated()), id: \.element.id) { i, routine in
                    RoutineRow(routine: routine, index: i + 1,
                               menuOpen: routineMenu == routine.id,
                               onMenu: { routineMenu = $0 ? routine.id : nil },
                               onEdit: {
                                   requestRoutine {
                                       routineID = routine.id
                                       routineDraft = RoutineDraft(routine)
                                   }
                               },
                               onDelete: { routineDeleting = routine })
                }
            }
        }
    }

    /// The routines the nav filter passes — name or prompt.
    private var filteredRoutines: [Routine] {
        guard !query.isEmpty else { return routines.routines }
        return routines.routines.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.prompt.localizedCaseInsensitiveContains(query)
        }
    }

    /// The ⌘K list — a New action, then every chat by title or every
    /// routine by name, depending on which list is on the left.
    private var switcherItems: [FluidCommandItem] {
        if tab == 1 {
            return [FluidCommandItem("__new", label: "New Routine", icon: "plus",
                                     shortcut: "cmd+n") {
                requestRoutine { routineDraft = RoutineDraft() }
            }] + routines.routines.map { routine in
                FluidCommandItem(
                    routine.id.uuidString,
                    label: routine.name,
                    description: routine.schedule.sentence,
                    icon: "clock.badge",
                    keywords: [routine.prompt]
                ) {
                    RoutinesUI.select(routine.id)
                }
            }
        }
        return [FluidCommandItem("__new", label: "New Chat", icon: "square.and.pencil",
                          shortcut: "cmd+n") {
            mind.newChat()
        }] + mind.chats.map { chat in
            FluidCommandItem(
                chat.id.uuidString,
                label: chat.title,
                description: AskUI.ago(chat.when),
                icon: chat.id == mind.runningChatID ? "circle.dotted" : "bubble.left",
                keywords: [chat.messages.last?.text ?? ""]
            ) {
                mind.select(chat)
            }
        }
    }

    // MARK: - the column

    /// Chats or the routines board — the header's own swap is the whole
    /// column's, so the band, stream and form never share a stale frame.
    @ViewBuilder
    private var column: some View {
        if tab == 0 {
            chatColumn
        } else {
            RoutineBoard(browser: browser, routineID: $routineID,
                         draft: $routineDraft, discarding: $routineDiscarding,
                         deleting: $routineDeleting)
        }
    }

    /// Header band, transcript, parked zone, composer — the reading
    /// column centered at the measure.
    private var chatColumn: some View {
        VStack(spacing: 0) {
            pageHead
            ZStack(alignment: .top) {
                middle
                // The stream's hairline — only once scrolled, under the
                // band's edge (fullscreen-ux §2).
                Rule(inset: 0)
                    .opacity(pin.atTop ? 0 : 1)
                    .animation(FluidSpring.fast, value: pin.atTop)
                    .allowsHitTesting(false)
            }
            AskParked()
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
            AskComposer(browser: browser, box: composer, pin: pin)
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FluidTone.surface(1))
    }

    @ViewBuilder
    private var middle: some View {
        if mind.current?.messages.isEmpty ?? true {
            AskEmpty(browser: browser, box: composer, pin: pin, hero: true)
        } else {
            AskStream(browser: browser, pin: pin)
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
        }
    }

    /// The 52pt band: sidebar trigger, the chat's editable name, the ring
    /// while this chat runs, then share / find / new-chat doors.
    private var pageHead: some View {
        HStack(spacing: 8) {
            // The window's lights own the top-left corner — while the nav
            // is collapsed the header draws under them, so step aside.
            SidebarLeadRoom()
            FluidSidebarTrigger()
            AskTitleField(renameRequest: $renameRequest)
            if runningHere {
                AskSpinner(size: 9)
            }
            Spacer(minLength: 0)
            if finding {
                AskTranscriptFind(text: $findText, at: $findAt,
                                  matches: findMatches, pin: pin) {
                    withAnimation(FluidSpring.fast) { finding = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            shareMenu
            FluidButton(variant: .ghost, size: .iconCompact) {
                withAnimation(FluidSpring.fast) { finding.toggle() }
            } label: {
                FluidIcon("magnifyingglass", size: 14)
            }
            .help("Find in transcript   ⌘F")
            .accessibilityLabel("Find in transcript")
            FluidButton(variant: .ghost, size: .iconCompact) {
                mind.newChat()
            } label: {
                FluidIcon("square.and.pencil", size: 14)
            }
            .help("New chat   ⌘N")
            .accessibilityLabel("New chat")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(FluidTone.surface(1))
    }

    /// Transcript find: the turn ids whose text, blocks or notes carry
    /// the query, in stream order.
    private var findMatches: [UUID] {
        guard !findText.isEmpty, let chat = mind.current else { return [] }
        return AskTurns.split(chat.messages).turns.filter { turn in
            turn.you.text.localizedCaseInsensitiveContains(findText)
                || turn.blocks.contains {
                    $0.text.localizedCaseInsensitiveContains(findText)
                        || ($0.tool?.name.localizedCaseInsensitiveContains(findText) ?? false)
                        || ($0.tool?.args.localizedCaseInsensitiveContains(findText) ?? false)
                }
                || turn.notes.contains { $0.text.localizedCaseInsensitiveContains(findText) }
        }.map(\.id)
    }

    /// Copy Transcript / Copy as Markdown / Share… — the menu on the
    /// header's share door (fullscreen-features §3).
    private var shareMenu: some View {
        FluidButton(variant: .ghost, size: .iconCompact, active: sharing) {
            sharing = true
        } label: {
            FluidIcon("square.and.arrow.up", size: 14)
        }
        .help("Share")
        .accessibilityLabel("Share transcript")
        .fluidMenuPopup(isPresented: $sharing, width: 200, maxHeight: nil) {
            FluidMenuItem(index: 0, icon: "doc.on.doc", label: "Copy Transcript") {
                if let chat = mind.current { AskUI.copy(AskUI.transcript(chat)) }
            }
            FluidMenuItem(index: 1, icon: "doc.plaintext", label: "Copy as Markdown") {
                if let chat = mind.current { AskUI.copy(AskUI.markdown(chat)) }
            }
            FluidMenuItem(index: 2, icon: "square.and.arrow.up", label: "Share…") {
                shareTranscript()
            }
        }
        .disabled(mind.current == nil)
    }

    /// The system share picker on the transcript text, anchored at the
    /// window's top-right corner the way the browser's File › Share is.
    private func shareTranscript() {
        guard let chat = mind.current, let window = AskWindow.window,
              let view = window.contentView else { return }
        let inset: CGFloat = 48
        let y = view.isFlipped ? inset : view.bounds.maxY - inset
        let anchor = NSRect(x: view.bounds.maxX - inset, y: y, width: 1, height: 1)
        NSSharingServicePicker(items: [AskUI.markdown(chat)])
            .show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}

// MARK: - window dressing

extension AskWindow {
    /// The parts of the browser window's dressing a second window keeps —
    /// the hidden title, the background, the world-namespaced autosave —
    /// without the tab-strip machinery the column owns.
    static func dress(_ window: NSWindow) {
        AskWindow.window = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(FluidTone.background)
        window.isMovableByWindowBackground = true
        // A test run keeps its own frame, the same rule the browser's
        // autosave follows (fullscreen-features §1).
        window.setFrameAutosaveName(Store.world.map { "search-ask (\($0))" } ?? "search-ask")
        window.minSize = NSSize(width: 720, height: 480)
        // The content view covers the title bar's ground — the lights
        // ride above it (the same lift `dress` does for the browser).
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }
}

// MARK: - the chat row

/// One chat in the nav — the FluidTone rebuild of the rail's ChatRow
/// (fullscreen-ux §3): two lines on a 48pt menu row, badges trailing,
/// hover actions for the menu and the delete.
private struct FluidChatRow: View {
    var chat: AskChat
    let index: Int
    var menuOpen = false
    var onMenu: (Bool) -> Void = { _ in }
    var onRename: () -> Void = {}
    @ObservedObject private var mind = Mind.shared

    var body: some View {
        FluidSidebarMenuButton(
            index: index,
            dot: unread ? .filled : nil,
            size: .large
        ) {
            mind.select(chat)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                FluidSidebarMenuRowLabel(label: chat.title)
                Text(AskUI.ago(chat.when))
                    .font(.system(size: 11))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .lineLimit(1)
            }
        } trailing: {
            FluidSidebarMenuActions(showOnHover: true) {
                FluidSidebarMenuAction("ellipsis", popupOpen: menuOpen) {
                    onMenu(true)
                }
                .fluidMenuPopup(isPresented: Binding(
                    get: { menuOpen }, set: { onMenu($0) }),
                    width: 180, maxHeight: nil) {
                    FluidMenuItem(index: 0, icon: "pencil", label: "Rename…") {
                        onRename()
                    }
                    FluidMenuItem(index: 1, icon: "doc.on.doc", label: "Copy Transcript") {
                        AskUI.copy(AskUI.transcript(chat))
                    }
                    FluidMenuItem(index: 2, icon: "arrow.branch", label: "Fork") {
                        mind.select(chat)
                        mind.fork()
                    }
                    FluidMenuItem(index: 3, icon: "trash", label: "Delete") {
                        mind.remove(chat)
                    }
                }
                FluidSidebarMenuAction("xmark") {
                    mind.remove(chat)
                }
            }
            if chat.parent != nil {
                Text("⑂")
                    .font(.system(size: 9))
                    .foregroundStyle(FluidTone.mutedForeground)
            }
            if chat.id == mind.runningChatID {
                AskSpinner(size: 9)
            } else if mind.question?.chat == chat.id {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(FluidTone.mutedForeground)
            } else {
                let parked = mind.pendingApprovals.filter { $0.chat == chat.id }.count
                if parked > 0 {
                    FluidSidebarMenuBadge("\(parked)")
                }
            }
        }
        .contextMenu {
            Button("Rename…") { onRename() }
            Button("Copy Transcript") { AskUI.copy(AskUI.transcript(chat)) }
            Button("Fork") {
                mind.select(chat)
                mind.fork()
            }
            Divider()
            Button("Delete", role: .destructive) { mind.remove(chat) }
        }
    }

    /// Unheard news — never on the chat on screen.
    private var unread: Bool {
        chat.id != mind.currentID && !chat.messages.isEmpty
            && chat.lastSeen != chat.messages.last?.id
    }
}

// MARK: - the title

/// The chat's name as the header's title — click to rename in place:
/// Return commits, Esc reverts, an empty field becomes "New chat"
/// (fullscreen-ux §2). The model's auto-title on first send keeps working
/// — a name you gave is only rewritten while it's still "New chat".
private struct AskTitleField: View {
    @ObservedObject private var mind = Mind.shared
    /// A row menu's "Rename…" — the chat it named is selected by the row
    /// already; the field just takes over with the pencil out.
    @Binding var renameRequest: UUID?
    /// The chat being renamed — not just *that* one is, so a switch of
    /// current mid-edit can't write its name onto a different chat.
    @State private var editing: UUID?
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let editing, let chat = mind.current, chat.id == editing {
                TextField("New chat", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FluidTone.foreground)
                    .focused($focused)
                    .frame(maxWidth: 380)
                    .onSubmit { commit() }
                    .onKeyPress(.escape) {
                        // Revert — the blur commit sees editing already
                        // nil and stands down.
                        self.editing = nil
                        return .handled
                    }
                    .onChange(of: focused) { _, on in
                        if !on { commit() }
                    }
            } else {
                Button {
                    guard let chat = mind.current else { return }
                    text = chat.title
                    editing = chat.id
                    focused = true
                } label: {
                    HStack(spacing: 6) {
                        Text(mind.current?.title ?? "Ask")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(FluidTone.foreground)
                        if hovering, mind.current != nil {
                            Image(systemName: "pencil")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(FluidTone.mutedForeground)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hovering && mind.current != nil ? FluidTone.hover : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.08), value: hovering)
            }
        }
        .onChange(of: editing != nil) { _, on in armTitleEscape(on) }
        .onChange(of: renameRequest) { _, id in
            // A row's "Rename…" — enter editing the same way the header
            // click does, on whatever chat the row asked for.
            guard let id, let chat = mind.current, chat.id == id else {
                renameRequest = nil
                return
            }
            text = chat.title
            editing = id
            focused = true
            renameRequest = nil
        }
        // The window may be dressed while the field is still up — the rung
        // belongs to the window, so it is set once more when it joins one.
        .onAppear { armTitleEscape(editing != nil) }
        .onDisappear { armTitleEscape(false) }
    }

    private func commit() {
        // The chat that was being renamed — which may no longer be the
        // one on screen if the reader switched mid-edit.
        guard let id = editing, let chat = mind.chats.first(where: { $0.id == id })
        else { return }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        mind.rename(chat, to: title.isEmpty ? "New chat" : title)
        editing = nil
    }

    /// Esc seen before the field's own keyPress gets it — the window's
    /// Esc gate intercepts first, so the revert rung is registered where
    /// it can reach: set while editing, cleared when the edit ends.
    private func armTitleEscape(_ on: Bool) {
        if on {
            let editing = $editing
            AskWindow.titleEscape = {
                editing.wrappedValue = nil
                return true
            }
        } else if AskWindow.titleEscape != nil {
            AskWindow.titleEscape = nil
        }
    }
}

// MARK: - transcript find

/// The find capsule pinned to the header (⌘F): the query field, "n of m",
/// chevrons walking the turns that match, and the × that sheds it.
/// v1 jumps turn to turn — the same scrollTo the pin rides.
private struct AskTranscriptFind: View {
    @Binding var text: String
    @Binding var at: Int
    let matches: [UUID]
    @ObservedObject var pin: AskPin
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(FluidTone.mutedForeground)
            TextField("Find in transcript", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(FluidTone.foreground)
                .focused($focused)
                .frame(width: 130)
                .onKeyPress(.escape) { close(); return .handled }
            if !text.isEmpty {
                Text(matches.isEmpty ? "0 of 0" : "\(min(at + 1, matches.count)) of \(matches.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(FluidTone.mutedForeground)
                    .fixedSize()
                Button { step(-1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
                Button { step(1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(FluidTone.mutedForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(FluidTone.surface(2), in: Capsule())
        .overlay(Capsule().strokeBorder(FluidTone.border, lineWidth: 1))
        .onAppear { focused = true }
        .onChange(of: matches) { _, new in
            at = min(at, max(new.count - 1, 0))
            jump()
        }
    }

    /// To the match at `at`, wrapping — the stream's own scrollTo.
    private func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        at = (at + direction + matches.count) % matches.count
        jump()
    }

    private func jump() {
        guard matches.indices.contains(at) else { return }
        pin.pinned = false
        pin.proxy?.scrollTo(matches[at], anchor: .center)
    }
}

/// The window's lights own the top-left corner; when the nav sidebar is
/// collapsed the header band draws under them — this yields their strip
/// so the trigger never sits on a button. Shared with the routines board.
struct SidebarLeadRoom: View {
    @Environment(\.fluidSidebar) private var sidebar

    var body: some View {
        if sidebar?.open == false {
            Color.clear.frame(width: 68)
        }
    }
}

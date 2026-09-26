import SwiftUI
import AppKit

// Ask, beside the page: a floating card off the window's right edge with the
// conversation in it — the header with its doors, the messages, and the
// composer where you speak. The state of it is Mind's; this file only draws.
//
// The button that opens it is here too — it is worn by the top strip and by
// the sidebar alike, so it is drawn once.

/// The small pill in the chrome: the sparkle and the word, where every other
/// door is a bare symbol — it is a feature being announced, not a tool. Lit
/// while the panel is open, the same bargain Door keeps.
struct AskButton: View {
    /// How much of the strip's trailing edge the button needs refused to
    /// window drags — a little past what the word and sparkle take.
    static let width: CGFloat = 60

    /// The window's tabs — read only on the click, to hand the page on
    /// stage over with the open.
    var browser: Browser
    @ObservedObject private var mind = Mind.shared
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Motion.glide) { mind.toggle() }
            // Opening is the consent: the page on stage goes on the
            // composer's row as the first chip — seen, and as removable
            // as any other. Only on the closed→open edge, and nothing on
            // a close.
            if mind.open { mind.hand(browser.active) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9.5, weight: .medium))
                Text("Ask")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(mind.open ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(mind.open ? Palette.wash : (hovering ? Palette.hover : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mind.open ? "Close Ask" : "Ask Search")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: mind.open)
    }
}

/// The rail: one card the window's height, in from every edge the way the
/// panels float over the page — and the page gives ground to it rather than
/// being covered, the way it does for the column on the other side.
struct AskPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var mind = Mind.shared

    /// The chat list, over the messages when it is asked for.
    @State private var listing = false
    /// What is being typed into the composer.
    @State private var draft = ""
    /// The URL the "Website…" pick is collecting, while its row is up.
    @State private var siteDraft: String? = nil
    /// Kept in the field while the panel is up.
    @FocusState private var typing: Bool

    private var messages: [AskMessage] { mind.current?.messages ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            head
            Rule(inset: 0)
            middle
            composer
        }
        .background(Palette.wash.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, y: 4)
        // The rail is the window's whole right column now — the strip
        // ends at its edge — so the card keeps the same air on every side.
        .padding(.top, 8)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .onAppear {
            Harness.shared.attach()
            #if DEBUG
            Mind.shared.demoCards()
            Mind.shared.demoAttach(browser)
            #endif
            DispatchQueue.main.async { typing = true }
        }
        .animation(Motion.quick, value: listing)
    }

    // MARK: - the header

    /// The chat's name — "Ask" before there is one — opening the list of
    /// them, then the model on duty, a way to start afresh, and the cross.
    private var head: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(Motion.quick) { listing.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(mind.current?.title ?? "Ask")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: listing ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.faint)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(listing ? Palette.ground : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)

            ModelSelector(browser: browser, short: true)

            Spacer(minLength: 0)

            Door(icon: "square.and.pencil", help: "New chat") {
                mind.newChat()
                listing = false
            }
            Door(icon: "xmark", help: "Close Ask") {
                withAnimation(Motion.glide) { mind.toggle() }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
    }

    // MARK: - the middle

    @ViewBuilder
    private var middle: some View {
        if listing {
            chatList
                .transition(.opacity)
        } else if messages.isEmpty {
            empty
        } else {
            conversation
        }
    }

    /// Every chat it has kept, newest first, with a way to start a new one
    /// and to drop one. A turn in flight wears the ring.
    private var chatList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                Quiet(icon: "square.and.pencil", title: "New chat") {
                    mind.newChat()
                    listing = false
                }
                ForEach(mind.chats) { chat in
                    ChatRow(
                        chat: chat,
                        live: chat.id == mind.currentID,
                        running: mind.running && chat.id == mind.currentID
                    ) {
                        mind.select(chat)
                        withAnimation(Motion.quick) { listing = false }
                    } remove: {
                        mind.remove(chat)
                    } fork: {
                        // Fork clones the *current* chat — select first,
                        // then the branch is taken and becomes current.
                        mind.select(chat)
                        mind.fork()
                    }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: .infinity)
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

    /// The `.you` a ↻ would re-run from — only while the tail of the
    /// conversation is the agent's (a retry re-asks the last thing asked).
    private var retryable: AskMessage? {
        guard messages.last?.role == .agent, !mind.running else { return nil }
        return messages.last { $0.role == .you }
    }

    /// The messages, newest arriving at the bottom and the view following —
    /// a stream stays pinned to its end, which is where the writing is.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        // The conversation only ever shows the current chat,
                        // so "still mid-turn" here means the one on screen.
                        AskLine(message: message, live: mind.running, mixed: mixed,
                                question: asked, browser: browser)
                    }
                    // The gate's parked ops, carded where the stream can
                    // answer them (design/permissions.md §5).
                    ForEach(mind.pendingApprovals.filter { $0.chat == mind.currentID }) { approval in
                        ApprovalCard(approval: approval)
                    }
                    if mind.running {
                        HStack(spacing: 7) {
                            Ring(size: 9)
                            Text(mind.activity.isEmpty ? "working…" : mind.activity)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .transition(.opacity)
                    } else if let retryable {
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
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .onAppear { proxy.scrollTo("end") }
            .onChange(of: mind.currentID) { _, _ in proxy.scrollTo("end") }
            .onChange(of: messages) { _, _ in proxy.scrollTo("end") }
        }
    }

    /// Nothing asked yet — the mark, what it is for, and three places to start.
    private var empty: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 54, height: 54)
                .background(Palette.ground, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            Text("Ask Search")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Ask about this page, or give it a task.\n@ attaches a tab.")
                .font(.system(size: 11.5))
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
        .padding(.horizontal, 18)
    }

    /// The three things an empty chat offers, once horizontally if they fit.
    @ViewBuilder
    private var ways: some View {
        Pill("Summarize this page") {
            // Handing the tab over is the consent — the chip goes on before
            // the words are sent so the turn starts with it attached.
            mind.hand(browser.active)
            mind.send("Summarize this page")
        }
        Pill("What's open?") { mind.send("List my open tabs") }
        Pill("Open example.com") { mind.send("Open example.com") }
    }

    // MARK: - the composer

    /// The card at the bottom: the tabs and the pieces handed over as
    /// chips, the field that sends on Return, the word going out or the
    /// stop while it works, and the brain it goes to under what effort.
    private var composer: some View {
        Card {
            if !mind.context.isEmpty || !mind.attachments.isEmpty || suggested != nil {
                chips
                Rule(inset: 0)
            }
            if siteDraft != nil {
                SiteRow(text: $siteDraft) { url in
                    mind.attachments.append(.site(url))
                }
                Rule(inset: 0)
            }
            if at != nil {
                attach
                Rule(inset: 0)
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachMenu(browser: browser, siteDraft: $siteDraft)
                    .padding(.bottom, 1)
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text("Ask AI a task, @ for context")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted.opacity(0.7))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1...6)
                        .focused($typing)
                        // Return sends; ⇧Return stays a newline.
                        .onKeyPress(.return, phases: .down) { press in
                            guard !press.modifiers.contains(.shift) else { return .ignored }
                            submit()
                            return .handled
                        }
                        .onSubmit(submit)
                }
                Button {
                    if mind.running { mind.stop() } else { submit() }
                } label: {
                    Image(systemName: mind.running ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(mind.running || said ? Palette.ink : Palette.faint)
                }
                .buttonStyle(.plain)
                .disabled(!mind.running && !said)
                .padding(.bottom, 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rule(inset: 0)
            // The status row: who answers the next turn, how hard it
            // thinks and under what leash — never what the live one is
            // doing (the stream says that already).
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ModelSelector(browser: browser)
                // The chip stays while either brain in play can think —
                // the next turn's pick or the wire the open chat is on:
                // a mid-chat switch to echo/devin shouldn't hide the
                // effort the chat's own model still reads.
                if mind.model.canReason || (mind.current?.canReason ?? false) {
                    ReasonSelector()
                }
                ModeMenu()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
                if let tab = suggested {
                    suggestion(tab)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// The active tab, when the agent could use it and doesn't have it
    /// yet — a bench tab needs no chip (it's the agent's already), an
    /// attached one can't be given twice.
    private var suggested: Tab? {
        guard let tab = browser.active, tab.address != nil, !tab.bench,
              !mind.context.contains(where: { $0.id == tab.id }) else { return nil }
        return tab
    }

    /// The dimmed dashed "+ tab" at the row's end — one click of consent.
    private func suggestion(_ tab: Tab) -> some View {
        Button { chip(tab) } label: {
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

    /// The word a Return sends — empty fields go nowhere.
    private var said: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        // An "@" list that's up takes Return first — it picks the top row,
        // not sends the mark on as a message.
        if let first = attachable.first {
            attach(first)
            return
        }
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        draft = ""
        // While a turn is in flight the words steer it; otherwise they start one.
        if mind.running { mind.steer(words) } else { mind.send(words) }
    }

    // MARK: - "@"

    /// What follows the last "@" in the draft, when one ends it — nothing, a
    /// start of a title. An "@" with a space before it is the trigger; one
    /// grown inside a word is an email address and is left alone.
    private var at: String? {
        guard let mark = draft.lastIndex(of: "@") else { return nil }
        let tail = draft[draft.index(after: mark)...]
        guard !tail.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        if mark != draft.startIndex {
            let before = draft[draft.index(before: mark)]
            guard before == " " || before == "\n" else { return nil }
        }
        return String(tail)
    }

    /// The tabs the "@…" could mean: all of them while it is bare, then the
    /// ones whose name or address has what was typed. A chip already worn is
    /// not offered twice; a bench tab needs no chip at all — it's the
    /// agent's already (the same skip `suggested` makes).
    private var attachable: [Tab] {
        guard let query = at else { return [] }
        let open = browser.tabs.filter { tab in
            !tab.bench && !mind.context.contains { $0.id == tab.id }
        }
        guard !query.isEmpty else { return Array(open.prefix(6)) }
        return Array(open.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || ($0.address?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }.prefix(6))
    }

    /// The little list above the field while an "@" is open — the same row
    /// the summon wears, narrowed to picking rather than going.
    private var attach: some View {
        VStack(spacing: 0) {
            if attachable.isEmpty {
                Text("No tab matches")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(attachable) { tab in
                    AttachRow(tab: tab) { attach(tab) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The consent itself: the tab's chip goes on the composer's row.
    /// Factored out of `attach` so the dashed suggestion can wear the
    /// same act without a "@…" to strip — `hand` keeps the checks
    /// (address, no bench, not already chipped) in one place.
    private func chip(_ tab: Tab) {
        mind.hand(tab)
    }

    /// Take the tab: the chip goes on, the "@…" leaves the draft.
    private func attach(_ tab: Tab) {
        chip(tab)
        if let mark = draft.lastIndex(of: "@") {
            draft = String(draft[..<mark])
        }
    }

    // MARK: - the models

    /// The brains on offer, grouped by the wire they ride — the selector's
    /// sections: a name the section reads, the provider's wire name, and
    /// each model as (title it is called by here, the wire's own name for
    /// it). Settings' free-text model still works — a pick from a section
    /// overwrites it, a custom one shows in its provider's section.
    static let providers: [(name: String, provider: String, models: [(title: String, model: String)])] = [
        ("OpenRouter", "openrouter", [
            ("z-ai/glm-5.3-flash", "z-ai/glm-5.3-flash"),
        ]),
        ("Codex", "codex", [
            ("gpt-6-luna", "gpt-6-luna"),
        ]),
        ("Devin", "devin", [
            ("Devin (REST)", "devin"),
        ]),
        ("Echo", "echo", [
            ("Echo", "echo"),
        ]),
    ]

    /// The flat list the retry menu wants — every provider's models in
    /// order, named the way the chip reads them.
    static let models: [(title: String, provider: String, model: String)] =
        providers.flatMap { group in
            group.models.map { item in
                (AskModel(provider: group.provider, model: item.model).readout, group.provider, item.model)
            }
        }

    /// The reasoning efforts a thinking wire takes — nil is "auto", the
    /// provider's own call; each with the word its menu reads and the
    /// short form the chip wears.
    static let efforts: [(value: String?, title: String, chip: String)] = [
        (nil, "Auto", "auto"),
        ("off", "Off", "off"),
        ("low", "Low", "low"),
        ("medium", "Medium", "med"),
        ("high", "High", "high"),
    ]

    /// The model as a capsule — a menu of the providers' sections behind a
    /// press, a check on the pair on duty. `short` is the header's, just
    /// the model's name; the composer's wears the provider with it.
    private struct ModelSelector: View {
        var browser: Browser
        var short = false
        @ObservedObject private var mind = Mind.shared

        /// A provider's models — plus the current one when it isn't a
        /// listed name (a custom model typed in Settings), so the check
        /// still lands somewhere.
        private func items(in group: (name: String, provider: String, models: [(title: String, model: String)])) -> [(title: String, model: String)] {
            var items = group.models
            if mind.model.provider == group.provider,
               !items.contains(where: { $0.model == mind.model.model }) {
                items.append((title: mind.model.model, model: mind.model.model))
            }
            return items
        }

        var body: some View {
            Menu {
                ForEach(AskPanel.providers, id: \.provider) { group in
                    Section(group.name) {
                        ForEach(items(in: group), id: \.model) { item in
                            Button {
                                mind.model = AskModel(provider: group.provider, model: item.model)
                            } label: {
                                if mind.model == AskModel(provider: group.provider, model: item.model) {
                                    Label(item.title, systemImage: "checkmark")
                                } else {
                                    Text(item.title)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Settings…") {
                    // The ask page — the settings panel reads it back on open.
                    Store.settings.set("ask", forKey: "settings.page")
                    browser.tuning = true
                }
            } label: {
                StatusChip(text: short ? mind.model.label : mind.model.readout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// The reasoning effort as the same kind of capsule — how hard the
    /// next turn thinks before it answers: auto leaves it to the wire,
    /// off skips it, the rest name it. Chat-scoped like the mode: with a
    /// chat open it edits that chat's effort; with none, the default a
    /// chat is born with. Only drawn where the wire takes one at all —
    /// the composer's `canReason` gate.
    private struct ReasonSelector: View {
        @ObservedObject private var mind = Mind.shared

        /// The current chat's effort; with no chat open, the Settings
        /// default the next chat is born with. nil reads "auto".
        private var effort: String? {
            mind.current?.effort ?? Store.settings.string(forKey: "ask.effort")
        }

        var body: some View {
            Menu {
                ForEach(AskPanel.efforts, id: \.title) { item in
                    Button {
                        mind.setEffort(item.value)
                    } label: {
                        if (effort ?? "auto") == (item.value ?? "auto") {
                            Label(item.title, systemImage: "checkmark")
                        } else {
                            Text(item.title)
                        }
                    }
                }
            } label: {
                StatusChip(
                    icon: "brain",
                    text: AskPanel.efforts.first { ($0.value ?? "auto") == (effort ?? "auto") }?.chip ?? "auto"
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How hard the model reasons — auto leaves it to the provider")
        }
    }

    /// The mode as the same kind of capsule — the leash the next turn runs
    /// under (design/permissions.md §1), drawn whether or not a chat is
    /// open: with none, it edits the default a chat is born with.
    private struct ModeMenu: View {
        @ObservedObject private var mind = Mind.shared

        /// The current chat's leash; with no chat open, the Settings
        /// default the next chat is born with (the chip edits that).
        private var mode: AskMode {
            mind.current?.mode
                ?? AskMode(rawValue: Store.settings.string(forKey: "ask.mode") ?? "") ?? .guard
        }

        var body: some View {
            Menu {
                ForEach([AskMode.read, .guard, .full], id: \.self) { item in
                    Button {
                        mind.setMode(item)
                    } label: {
                        if mode == item {
                            Label(item.label, systemImage: "checkmark")
                        } else {
                            Label(item.label, systemImage: item.icon)
                        }
                    }
                }
            } label: {
                StatusChip(icon: mode.icon, text: mode.label)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What the agent may do — Read, Guard or Full")
        }
    }

    /// The capsule both composer menus wear — a status chip that is also
    /// the menu's handle (design/chatux.md). Draws a word, an optional
    /// mark and a hidden-indicator chevron; the chip knows no semantics.
    private struct StatusChip: View {
        var icon: String? = nil
        let text: String

        var body: some View {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 7.5, weight: .bold))
                }
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    // A long model id shrinks to fit rather than growing
                    // the composer (design/chatux.md — 170pt, mid-cut).
                    .truncationMode(.middle)
                    .frame(maxWidth: 170)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Palette.ground.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
    }
}

/// One line in the conversation: yours in a bubble on the right, the agent's
/// plain across the whole width with its tool calls under it, a note of the
/// system's centred and quiet. Hovering any of yours or the agent's floats
/// a small chip in the gap beneath — copy, when, and which brain answered.
private struct AskLine: View {
    let message: AskMessage
    /// True while the chat this line sits in is the one mid-turn — a tool
    /// call that hasn't answered yet is still alive only for that long.
    var live = false
    /// True when the chat speaks in more than one model's voice — the
    /// hover chip's model tail earns its place only then.
    var mixed = false
    /// The question this chat is being asked, when it is — the ask_user
    /// row goes live for it.
    var question: AskQuestion?
    @ObservedObject var browser: Browser
    @ObservedObject private var mind = Mind.shared

    @State private var hovering = false

    var body: some View {
        line
            .overlay(alignment: chipEdge) {
                if hovering, showsMeta {
                    meta
                        .offset(y: 13)
                        // The chip's own hover feeds the same flag — no
                        // dead pixel between the line and it.
                        .onHover { hovering = $0 }
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .contextMenu { menu }
    }

    @ViewBuilder
    private var line: some View {
        switch message.role {
        case .you: you
        case .agent: agent
        case .note: note
        }
    }

    /// The gap chip sits under a .you on the right, under an agent line
    /// on the left — the side the words live on.
    private var chipEdge: Alignment {
        message.role == .you ? .bottomTrailing : .bottomLeading
    }

    /// Notes get no meta and no copy — they're chrome already; a
    /// tools-only message leaves copying to its rows.
    private var showsMeta: Bool {
        message.role != .note && !message.text.isEmpty
    }

    /// The hover chip: copy the words, when they arrived, and — when the
    /// chat mixes brains — which one said them.
    private var meta: some View {
        HStack(spacing: 6) {
            CopyChip(message.text)
            Text(AskUI.ago(message.when))
            if mixed, let tail = modelTail {
                Text(tail)
            }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Palette.faint)
        .padding(.horizontal, 7)
        .frame(height: 14)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    /// The model half of a "provider/model" stamp — the tail, not the wire.
    private var modelTail: String? {
        message.model?.components(separatedBy: "/").dropFirst().joined(separator: "/")
    }

    @ViewBuilder
    private var menu: some View {
        if message.role != .note {
            Button("Copy") { AskUI.copy(message.text) }
                .disabled(message.text.isEmpty)
        }
        if message.role == .you {
            Button("Retry from here") { mind.retry(from: message) }
                .disabled(mind.running)
            Menu("Retry with…") {
                ForEach(AskPanel.models, id: \.provider) { item in
                    Button(item.title) {
                        mind.retry(from: message, with: AskModel(provider: item.provider, model: item.model))
                    }
                }
            }
            .disabled(mind.running)
        }
        Button("Fork from here") { mind.fork(from: message) }
    }

    private var you: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Palette.ink.opacity(0.08),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 12, bottomLeadingRadius: 12,
                        bottomTrailingRadius: 4, topTrailingRadius: 12
                    )
                )
            // How often this turn has been re-run — quiet, and never told
            // to the model (design/interaction.md §2).
            if message.retries > 0 {
                Text("· retried ×\(message.retries)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.faint)
            }
            // What it was sent with — consent made visible, kept on the
            // message because the composer lets its chips go: the tabs
            // first, then the files, images and sites. One scrolling row
            // like the composer's — chips keep their natural size and a
            // crowd slides instead of squishing — anchored on the bubble's
            // edge: the direction pair pins the scroll trailing while the
            // chips inside still read left to right.
            if !message.tabs.isEmpty || !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(message.tabs) { tab in
                            Chip(tab: tab, icon: browser.tabs.first { $0.id == tab.id }?.icon)
                        }
                        ForEach(message.attachments) { piece in
                            AttachChip(piece: piece)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .environment(\.layoutDirection, .leftToRight)
                }
                .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 46)
    }

    private var agent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(message.tools) { tool in
                if tool.name == "ask_user" {
                    // The card is the tool row (design/interaction.md §1).
                    QuestionRow(tool: tool, live: live, question: question)
                } else {
                    ToolRow(tool: tool, live: live)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var note: some View {
        Text(message.text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
    }
}

/// A tool call as one line: what ran, what it was given, what it gave back —
/// a ring while it is still running, red when it went badly.
private struct ToolRow: View {
    let tool: AskMessage.Tool
    /// Whether the chat this card sits in is still mid-turn — a result can
    /// only still land while it is. Relaunches and ended turns leave what
    /// they had, and what's left draws settled rather than spinning forever.
    var live = false

    /// A tool is mid-flight until its result lands — `failed` is how a
    /// landed one went, not that it hasn't yet — and only while its turn
    /// is still going.
    private var running: Bool { live && tool.result == nil && !tool.failed }

    /// It never answered and never will — the turn it belonged to is over.
    private var ended: Bool { tool.result == nil && !tool.failed && !live }

    /// What a copy takes — the full strings, not the one-lined `detail`,
    /// so it pastes into a bug. A running card has name + args only; one
    /// that ended with no answer says so.
    private var copyable: String {
        guard !running else { return "\(tool.name) \(tool.args)" }
        return "\(tool.name) \(tool.args)\n→ \(tool.result ?? "(no result)")"
    }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if running {
                Ring(size: 9)
                    .frame(width: 12, alignment: .center)
            } else {
                Image(systemName: tool.failed ? "exclamationmark.triangle" : (ended ? "checkmark" : "gearshape"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tool.failed ? Color.red : Palette.muted)
                    .frame(width: 12, alignment: .center)
            }
            Text(tool.name)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tool.failed ? Color.red : Palette.ink)
            Text(detail)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(tool.failed ? Color.red.opacity(0.8) : Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if hovering {
                CopyChip(copyable)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tool.failed ? Color.red.opacity(0.25) : Palette.hairline, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }

    /// The arguments one line deep, then " → " and the answer's first line —
    /// the card shows the shape of the call, never the whole of it.
    private var detail: String {
        let args = AskUI.oneline(tool.args)
        if let result = tool.result, !result.isEmpty {
            return args.isEmpty ? AskUI.oneline(result) : args + " → " + AskUI.oneline(result)
        }
        // One that ended before its answer landed says so, quietly — the
        // args alone would read like the answer could still arrive.
        if ended {
            return args.isEmpty ? "ended" : args + " — ended"
        }
        return args
    }
}

/// One row of the chat list — title, when, whether it is the one on
/// screen, and a small "⑂" when the chat is a branch of another.
private struct ChatRow: View {
    let chat: AskChat
    let live: Bool
    let running: Bool
    let select: () -> Void
    let remove: () -> Void
    let fork: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(live ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.ink.opacity(0.9)))
                    Text(AskUI.ago(chat.when))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 4)
                if chat.parent != nil {
                    Text("⑂")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.faint)
                }
                if running {
                    Ring(size: 9)
                } else if live {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if live {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.ground)
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Transcript") { AskUI.copy(AskUI.transcript(chat)) }
            Button("Fork", action: fork)
            Divider()
            Button("Delete", role: .destructive, action: remove)
        }
        .animation(Motion.quick, value: hovering)
    }
}

/// One row of the "@…" list — the tab's mark and name, where it is.
private struct AttachRow: View {
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

/// A tab handed to the agent, as a capsule — its mark, its name cut short,
/// and a cross while it is still in the composer's power to take back.
private struct Chip: View {
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

/// A parked op asking for the user's verdict (design/permissions.md §5):
/// what it wants in the gate's own words — never the model's — the model's
/// why under it when it gave one, a shot of the tab it would touch when
/// there is one, and the three answers.
private struct ApprovalCard: View {
    let approval: AskApproval
    @ObservedObject private var mind = Mind.shared
    @State private var shot: NSImage?

    /// The verb half of "Always: submit · acme.com" — the op's own last
    /// word, so act.submit reads "submit".
    private var verb: String {
        approval.op.split(separator: ".").last.map(String.init) ?? approval.op
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 12, alignment: .center)
                    .padding(.top, 1)
                Text("Wants to \(approval.summary)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = approval.why, !why.isEmpty {
                Text("“\(why)”")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19)
            }
            if let shot {
                Image(nsImage: shot)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1)
                    )
                    .padding(.leading, 19)
            }
            HStack(spacing: 6) {
                Pill("Allow", filled: true) { mind.resolve(approval, .allow) }
                Pill("Always: \(verb)\(approval.host.map { " · \($0)" } ?? "")") {
                    mind.resolve(approval, .always)
                }
                Pill("Deny") { mind.resolve(approval, .deny) }
            }
            .padding(.leading, 19)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .task(id: approval.id) {
            // The evidence shot, read lazily — only when the card is on.
            guard let path = approval.shotPath else { return }
            shot = NSImage(contentsOfFile: path)
        }
    }
}

/// The agent asking the person mid-turn (design/interaction.md §1): while
/// its ask.user call is parked the card carries the question, quick picks,
/// a field and a way to decline — the composer answers it too. Settled, it
/// collapses to one line like any tool row.
private struct QuestionRow: View {
    let tool: AskMessage.Tool
    /// Whether the chat this card sits in is still mid-turn.
    var live = false
    /// The live question for this chat, if one is open — it carries the
    /// full text and options; the card's args are trimmed for showing.
    var question: AskQuestion?
    @ObservedObject private var mind = Mind.shared
    @State private var draft = ""

    /// Waiting on a person — the turn alive, the call unanswered, the
    /// question still open.
    private var pending: Bool { live && tool.result == nil && question != nil }
    /// It never answered and never will — the turn is over (a stop, a
    /// relaunched app: the saved card reads honestly).
    private var ended: Bool { tool.result == nil && !live }

    var body: some View {
        if pending, let question {
            open(question)
        } else {
            row
        }
    }

    /// The open card — the question, one pill per option, a field for the
    /// rest, and Skip for "make the call yourself".
    private func open(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 12, alignment: .center)
                    .padding(.top, 1)
                Text(question.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(question.options, id: \.self) { option in
                            Pill(option) { mind.answer(option) }
                        }
                    }
                }
                .padding(.leading, 19)
            }
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text("Your answer…")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted.opacity(0.7))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                        .onSubmit(say)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button(action: say) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(draft.isEmpty ? Palette.faint : Palette.ink)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Pill("Skip") { mind.pass() }
            }
            .padding(.leading, 19)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private func say() {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        mind.answer(words)
        draft = ""
    }

    /// Settled or silent — one line, the way every other tool reads.
    private var row: some View {
        HStack(spacing: 7) {
            if live && tool.result == nil && !tool.failed {
                Ring(size: 9)
                    .frame(width: 12, alignment: .center)
            } else {
                Image(systemName: tool.failed ? "exclamationmark.triangle" : "questionmark.bubble")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tool.failed ? Color.red : Palette.muted)
                    .frame(width: 12, alignment: .center)
            }
            Text("ask_user")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tool.failed ? Color.red : Palette.ink)
            Text(detail)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(tool.failed ? Color.red.opacity(0.8) : Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tool.failed ? Color.red.opacity(0.25) : Palette.hairline, lineWidth: 1)
        )
    }

    /// `ask_user "…question…" → "…answer…"` — a declined card says so (a
    /// declined question is asked-and-answered, not a failure); one that
    /// ended with nobody home says that too.
    private var detail: String {
        let asked = "“\(questionText)”"
        if let result = tool.result {
            if let answered = field("answer", in: result) {
                return "\(asked) → “\(answered)”"
            }
            if let declined = field("declined", in: result) {
                return "\(asked) — declined: \(declined)"
            }
            return asked + " → " + AskUI.oneline(result)
        }
        if ended {
            return questionText.isEmpty ? "went unanswered" : "\(asked) — went unanswered"
        }
        return asked
    }

    /// The question as the card's args carried it.
    private var questionText: String {
        field("question", in: tool.args) ?? ""
    }

    /// One key out of a small JSON object, or nil when it isn't one.
    private func field(_ name: String, in json: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?[name] as? String
    }
}

/// The little copy affordance — `doc.on.doc` that ticks briefly into a
/// checkmark. Worn in the hover chip and at a tool row's trailing edge.
private struct CopyChip: View {
    let text: String
    @State private var copied = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            AskUI.copy(text)
            withAnimation(Motion.quick) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(Motion.quick) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(copied ? Palette.ink : Palette.faint)
                .frame(width: 12, alignment: .center)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

/// Two small helpers the panel wants, kept out of the views' names.
private enum AskUI {
    /// A string flattened to its first stretch of line: tool calls keep to
    /// one row whatever the answer carried.
    static func oneline(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "just now", "4m ago", "2d ago", then the date.
    static func ago(_ when: Date) -> String {
        let span = Date().timeIntervalSince(when)
        if span < 90 { return "just now" }
        if span < 3600 { return "\(Int(span / 60))m ago" }
        if span < 86_400 { return "\(Int(span / 3600))h ago" }
        if span < 86_400 * 7 { return "\(Int(span / 86_400))d ago" }
        return when.formatted(date: .abbreviated, time: .omitted)
    }

    /// Every copy is the same two lines of AppKit (design/chatux.md).
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The whole chat as paste-able text (design/chatux.md): who said
    /// what, the tabs it rode in on, the calls and their answers, the
    /// notes between.
    static func transcript(_ chat: AskChat) -> String {
        var lines: [String] = []
        for message in chat.messages {
            switch message.role {
            case .you:
                lines.append("You: " + message.text)
                for tab in message.tabs {
                    let host = Address.url(from: tab.address)?.host() ?? tab.address
                    lines.append("  · \(tab.title) (\(host))")
                }
                for piece in message.attachments {
                    let where_ = piece.url ?? piece.path ?? ""
                    lines.append("  · \(piece.label)\(where_.isEmpty ? "" : " (\(where_))")")
                }
            case .agent:
                if !message.text.isEmpty {
                    lines.append("Agent: " + message.text)
                }
                for tool in message.tools {
                    var row = "  • \(tool.name) \(oneline(tool.args))"
                    if let result = tool.result, !result.isEmpty {
                        row += " → \(oneline(result))"
                    }
                    lines.append(row)
                }
            case .note:
                lines.append("— " + message.text)
            }
        }
        return lines.joined(separator: "\n")
    }
}

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
        // Something alive while the rail is shut — a turn in flight, a
        // question or a parked approval — wears the dot so the quiet
        // button isn't silent about it.
        .overlay(alignment: .topTrailing) {
            if !mind.open, mind.runningChatID != nil || mind.question != nil
                || !mind.pendingApprovals.isEmpty {
                Circle()
                    .fill(FluidTone.foreground)
                    .frame(width: 4, height: 4)
                    .padding(.top, 3)
                    .padding(.trailing, 4)
            }
        }
    }
}

/// The rail: one card the window's height, in from every edge the way the
/// panels float over the page — and the page gives ground to it rather than
/// being covered, the way it does for the column on the other side. Its
/// stream, parked zone and composer are the shared AskParts — the same
/// views the fullscreen AskPage is built from (fullscreen-features §2).
struct AskPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var mind = Mind.shared

    /// The stream's bottom-pin — shared with the composer so a send can
    /// re-pin (AskParts.swift).
    @StateObject private var pin = AskPin()
    /// The composer's box — drafts live on Mind; the box holds the surface's
    /// own send-path state (site row, takeover arming, focus).
    @StateObject private var composer = AskComposerBox()
    /// The chat list, over the messages when it is asked for.
    @State private var listing = false
    /// The pop-out door's window opener.
    @Environment(\.openWindow) private var openWindow

    /// This chat's turn is the one in flight — the header's ring.
    private var runningHere: Bool {
        mind.runningChatID != nil && mind.runningChatID == mind.currentID
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            Rule(inset: 0)
            middle
            AskParked()
            AskComposer(browser: browser, box: composer, pin: pin)
        }
        .background(FluidTone.surface(1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FluidTone.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, y: 4)
        // The rail is the window's whole right column now — the strip
        // ends at its edge — so the card keeps the same air on every side.
        .padding(.top, 8)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        // A link in anything the agent wrote opens as a real tab — the
        // panel is never a browser (design/sidebar-ux.md §10).
        .environment(\.openURL, OpenURLAction { url in
            browser.open(url, foreground: true)
            return .handled
        })
        .onAppear {
            Harness.shared.attach()
            #if DEBUG
            Mind.shared.demoHooks(browser)
            #endif
            DispatchQueue.main.async { composer.typing = true }
        }
        .animation(Motion.quick, value: listing)
        .onKeyPress(.escape) {
            // Layers shed one at a time: the chat list first — the "@…"
            // tail and the site row are the composer's own Esc, reached
            // while its field has the keys — and with an empty draft the
            // rail itself.
            if listing {
                withAnimation(Motion.quick) { listing = false }
                return .handled
            }
            if mind.draft.wrappedValue.isEmpty {
                withAnimation(Motion.glide) { mind.toggle() }
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - the header

    /// A list door, the chat's name ("Ask" before there is one) with the
    /// ring after it while this chat's turn is in flight, then the new and
    /// close doors. The model moved to the composer's status row — the
    /// header reads as the conversation's name, not its wiring.
    private var head: some View {
        HStack(spacing: 6) {
            Door(icon: "list.bullet", help: "Chats") {
                withAnimation(Motion.quick) { listing.toggle() }
            }
            Text(mind.current?.title ?? "Ask")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Palette.ink)
            if runningHere {
                Ring(size: 9)
            }
            Spacer(minLength: 0)
            Door(icon: "arrow.up.right.square", help: "Open in window") {
                // The same conversation, a window of its own — one Mind,
                // so the chat on screen is the page's too.
                openWindow(id: "ask")
            }
            Door(icon: "square.and.pencil", help: "New chat") {
                mind.newChat()
                listing = false
            }
            Door(icon: "xmark", help: "Close Ask") {
                withAnimation(Motion.glide) { mind.toggle() }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
    }

    // MARK: - the middle

    @ViewBuilder
    private var middle: some View {
        if listing {
            chatList
                .transition(.opacity)
        } else if mind.current?.messages.isEmpty ?? true {
            AskEmpty(browser: browser, box: composer, pin: pin)
        } else {
            AskStream(browser: browser, pin: pin)
        }
    }

    /// Every chat it has kept, most recently alive first, with a way to
    /// start a new one and to drop one. A turn in flight wears the ring —
    /// on whichever chat owns it, not only the one on screen — a question
    /// its bubble, a parked approval its pause, and unheard news its dot.
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
                        running: chat.id == mind.runningChatID,
                        waiting: mind.question?.chat == chat.id,
                        approvals: mind.pendingApprovals.filter { $0.chat == chat.id }.count,
                        unread: chat.id != mind.currentID && !chat.messages.isEmpty
                            && chat.lastSeen != chat.messages.last?.id
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
}

/// One line in the conversation: yours in a bubble on the right, the agent's
/// plain across the whole width with its tool calls under it, a note of the
/// system's centred and quiet. Hovering any of yours or the agent's floats
/// a small chip in the gap beneath — copy, when, and which brain answered.
/// Turns draw their own .you through this, so the bubble stays one shape.
struct AskLine: View {
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
    @Environment(\.askDensity) private var density
    @Environment(\.askVerdicts) private var verdicts

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
        .font(.system(size: density.meta))
        .foregroundStyle(Palette.faint)
        .padding(.horizontal, 7)
        .frame(height: density.metaHeight)
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
        if message.role == .you, let retry = verdicts.retry {
            Button("Retry from here") { retry(message) }
                .disabled(verdicts.retryBlocked())
            if let retryWith = verdicts.retryWith {
                Menu("Retry with…") {
                    ForEach(AskChips.models, id: \.provider) { item in
                        Button(item.title) {
                            retryWith(message, AskModel(provider: item.provider, model: item.model))
                        }
                    }
                }
                .disabled(verdicts.retryBlocked())
            }
        }
        if let fork = verdicts.fork {
            Button("Fork from here") { fork(message) }
        }
    }

    private var you: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(message.text)
                .font(.system(size: density.text))
                .foregroundStyle(FluidTone.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, density.youPadH)
                .padding(.vertical, density.youPadV)
                // The bubble the mock shows: the composer's own tone, a
                // full soft radius — not a card, not an accent. `active`
                // reads on both rails; `bubble` matched surface(1) dead
                // on in light mode.
                .background(
                    FluidTone.active,
                    in: RoundedRectangle(cornerRadius: density.youRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: density.youRadius, style: .continuous)
                        .strokeBorder(FluidTone.border, lineWidth: 1)
                )
                .frame(maxWidth: density.youMaxWidth ?? .infinity, alignment: .trailing)
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
                AskMarkdown(message.text)
                    .font(.system(size: density.text))
                    .lineSpacing(density == .page ? 4 : 0)
                    .foregroundStyle(FluidTone.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(message.tools) { tool in
                if tool.name == "ask_user" {
                    // The card is the tool row (design/interaction.md §1).
                    QuestionRow(tool: tool, live: live)
                } else {
                    ToolRow(tool: tool, live: live)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A note of the system's — verdict lines and dead-turn notices —
    /// centred and quiet, or quietly red when it's the turn's own error.
    private var note: some View {
        Text(message.text)
            .font(.system(size: message.isError ? density.errorNote : density.note))
            .foregroundStyle(message.isError ? FluidTone.destructive : FluidTone.mutedForeground)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
    }
}

/// A tool call as one line: what ran, what it was given, what it gave back —
/// a ring while it is still running, red when it went badly.
struct ToolRow: View {
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

    @Environment(\.askDensity) private var density

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
                .font(.system(size: density.toolName, weight: .medium, design: .monospaced))
                .foregroundStyle(tool.failed ? Color.red : Palette.ink)
            Text(detail)
                .font(.system(size: density.toolDetail, design: .monospaced))
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

/// One row of the chat list — title, when, and the state badges it owes:
/// the ring while it runs, a bubble while it's asking, a pause while the
/// gate holds it, a dot for unheard news, a "⑂" when it's a branch.
/// Hovering swaps the badges for the × that drops the chat.
struct ChatRow: View {
    let chat: AskChat
    let live: Bool
    var running = false
    var waiting = false
    /// Parked approvals on this chat — the badge says how many wait.
    var approvals = 0
    var unread = false
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
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete chat")
                } else {
                    if chat.parent != nil {
                        Text("⑂")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.faint)
                    }
                    if running {
                        Ring(size: 9)
                    } else if waiting {
                        Image(systemName: "questionmark.bubble")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Palette.muted)
                    } else if approvals > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "pause.circle")
                                .font(.system(size: 8, weight: .medium))
                            if approvals > 1 {
                                Text("\(approvals)")
                                    .font(.system(size: 8, weight: .medium))
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(Palette.muted)
                    } else if unread {
                        Circle()
                            .fill(Palette.ink)
                            .frame(width: 5, height: 5)
                    } else if live {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.muted)
                    }
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

/// A parked action with the effect, category, destination and page evidence
/// visible before the user decides.
struct ApprovalCard: View {
    let approval: AskApproval
    var resolved = false
    @Environment(\.askVerdicts) private var verdicts
    @State private var shot: NSImage?
    @State private var enlargingShot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 12, alignment: .center)
                    .padding(.top, 1)
                Text(approval.summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 4) {
                if let host = approval.host, !host.isEmpty {
                    Text(host)
                }
                if let categories = approval.categories, !categories.isEmpty {
                    if let host = approval.host, !host.isEmpty { Text("·") }
                    Text(categories.map(\.label).joined(separator: ", "))
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.muted)
            .padding(.leading, 19)

            if let details = approval.details, !details.isEmpty {
                ScrollView {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(.leading, 19)
            }
            if let why = approval.why, !why.isEmpty {
                Text(why)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19)
            }
            if let shot {
                Button { enlargingShot = true } label: {
                    Image(nsImage: shot)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Enlarge page screenshot")
                VStack(spacing: 0) {
                    Text("Click to enlarge")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.leading, 19)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Preview unavailable")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if let unavailable = approval.previewUnavailable, !unavailable.isEmpty {
                        Text(unavailable)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                    }
                    if !resolved, let refresh = verdicts.refresh {
                        Pill("Refresh preview") {
                            shot = nil
                            refresh(approval)
                        }
                    }
                }
                .padding(.leading, 19)
            }
            if !resolved {
                HStack(spacing: 6) {
                    Pill("Cancel action") { verdicts.resolve?(approval, .deny) }
                    Spacer(minLength: 0)
                    Pill(approval.actionLabel ?? "Approve", filled: true) {
                        verdicts.resolve?(approval, .allow)
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .sheet(isPresented: $enlargingShot) {
            if let shot {
                VStack(spacing: 10) {
                    Image(nsImage: shot)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Pill("Close") { enlargingShot = false }
                }
                .frame(minWidth: 500, minHeight: 350)
                .padding(16)
            }
        }
        .task(id: "\(approval.shotPath ?? "")|\(approval.previewUnavailable ?? "")") {
            // The evidence shot, read lazily — only when the card is on.
            shot = nil
            guard let path = approval.shotPath else { return }
            shot = NSImage(contentsOfFile: path)
        }
    }
}

/// The agent asking the person mid-turn (design/interaction.md §1): while
/// its ask.user call is parked the card carries the question, quick picks,
/// a field and a way to decline — the composer answers it too. Settled, it
/// collapses to one line like any tool row. The open card is `QuestionCard`
/// — the pinned zone under the stream draws the same one.
struct QuestionRow: View {
    let tool: AskMessage.Tool
    /// Whether the chat this card sits in is still mid-turn.
    var live = false

    /// It never answered and never will — the turn is over (a stop, a
    /// relaunched app: the saved card reads honestly).
    private var ended: Bool { tool.result == nil && !live }

    /// Settled or silent — one line, the way every other tool reads. The
    /// pinned zone above the composer owns the open card while the
    /// question is live; this row only ever carries its record.
    var body: some View {
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

/// The open question card — the question, one pill per option, a field
/// for the rest, and Skip for "make the call yourself". The pinned zone
/// under the stream draws it for the chat's live question; a pending
/// ask_user row draws the same one inside itself.
struct QuestionCard: View {
    let question: AskQuestion
    @Environment(\.askVerdicts) private var verdicts
    @State private var draft = ""

    var body: some View {
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
                            Pill(option) { verdicts.answer?(option) }
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
                Pill("Skip") { verdicts.pass?() }
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
        verdicts.answer?(words)
        draft = ""
    }
}

/// The little copy affordance — `doc.on.doc` that ticks briefly into a
/// checkmark. Worn in the hover chip and at a tool row's trailing edge.
struct CopyChip: View {
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
enum AskUI {
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

    /// The chat as markdown (share menu — design/fullscreen-features §3):
    /// a title, your words as blockquotes (their tabs and attachments ride
    /// along, like the transcript's · lines), the agent's verbatim, calls
    /// and notes as list and italic.
    static func markdown(_ chat: AskChat) -> String {
        var lines: [String] = ["# \(chat.title)", ""]
        for message in chat.messages {
            switch message.role {
            case .you:
                for line in message.text.components(separatedBy: .newlines) {
                    lines.append("> " + line)
                }
                for tab in message.tabs {
                    let host = Address.url(from: tab.address)?.host() ?? tab.address
                    lines.append("> · _\(tab.title) (\(host))_")
                }
                for piece in message.attachments {
                    let where_ = piece.url ?? piece.path ?? ""
                    lines.append("> · _\(piece.label)\(where_.isEmpty ? "" : " (\(where_))")_")
                }
                lines.append("")
            case .agent:
                if !message.text.isEmpty {
                    lines.append(message.text)
                    lines.append("")
                }
                for tool in message.tools {
                    var row = "- `\(tool.name)` \(oneline(tool.args))"
                    if let result = tool.result, !result.isEmpty {
                        row += " → \(oneline(result))"
                    }
                    lines.append(row)
                }
            case .note:
                lines.append("_" + message.text + "_")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

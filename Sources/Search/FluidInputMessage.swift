import AppKit
import SwiftUI
import UniformTypeIdentifiers

// InputMessage — fluid-demo/components/ui/input-message.tsx.
// The chat composer: surface-2 container with a hairline edge ring that
// recolors per state (drag > focus > hover — contrast, never thickness),
// a growing plain-text editor (minRows…maxRows, scroll past the cap),
// ghost suggestion + Tab chip while empty, an attachment strip with
// hover-revealed × tiles (accept-filtered, maxFiles-capped), a
// drag-reorderable queued-messages strip while streaming, and a footer
// whose send button morphs between arrow-up (send/queue) and a stop
// square.
//
// Keyboard contract (verbatim from the source):
//   Enter sends, Shift+Enter newlines; Tab fills the ghost prompt into an
//   empty composer; ↑/↓ browse sent-history from the first/last line; the
//   suggestion list takes ↓/↑ (Enter fills, Esc drops) while it's open.
//   Queue rows: Enter/F2 pulls back into the composer, Delete removes,
//   ⌥↑/⌥↓ moves, drag reorders (top = next to dispatch).

struct FluidQueuedMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var files: [URL] = []
}

enum FluidComposerStatus: Equatable { case idle, streaming }

/// The context the source hands to `leftSlot`/`rightSlot` render
/// functions — `{ openFilePicker, files }`. In this port the slots are
/// plain ViewBuilders (`leading:`/`trailing:`), so the context is
/// delivered through the environment instead: slot content declares
/// `@Environment(\.fluidComposerSlot) var slot` and calls
/// `slot?.openFilePicker("image/*")` to scope the picker for that call.
struct FluidComposerSlotContext {
    /// Opens the file picker; `acceptOverride` (e.g. "image/*") narrows
    /// the accepted types for that invocation only — the source's
    /// `openFilePicker(acceptOverride)`.
    let openFilePicker: (String?) -> Void
    /// The currently attached files.
    let files: [URL]
}

extension EnvironmentValues {
    @Entry var fluidComposerSlot: FluidComposerSlotContext? = nil
}

/// Push a cursor while hovered, pop on exit — the ports' stand-in for the
/// CSS cursor-* classes (cursor-pointer on buttons, cursor-default on
/// tiles) layered over the composer's cursor-text.
private struct FluidCursor: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { h in
                if h { cursor.push(); pushed = true }
                else if pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    fileprivate func fluidCursor(_ cursor: NSCursor) -> some View {
        modifier(FluidCursor(cursor: cursor))
    }
}

struct FluidInputMessage<Trailing: View, Header: View, Leading: View>: View {
    @Binding var text: String
    var placeholder = "Ask me anything…"
    var placeholderSuggestion: String? = nil
    var suggestions: [String] = []
    var history: [String] = []
    var files: Binding<[URL]>? = nil
    var queue: Binding<[FluidQueuedMessage]>? = nil
    var status: FluidComposerStatus = .idle
    var disabled = false
    var size: FluidSize = .default
    /// Minimum visible rows before the editor grows (source: minRows).
    var minRows = 1
    /// Maximum visible rows before the editor scrolls (source: maxRows).
    var maxRows = 8
    /// When false, clicking the surrounding container won't refocus the
    /// editor (source: clickToFocus).
    var clickToFocus = true
    /// Accessible label for the send button (source: sendLabel).
    var sendLabel = "Send"
    /// Comma-separated accept tokens — MIME types, "family/*" globs, or
    /// ".ext" extensions (source: accept, same default).
    var accept = "image/png,image/jpeg,application/pdf"
    /// Maximum number of attachments; extras are dropped (source: maxFiles).
    var maxFiles: Int? = nil
    /// Side of each preview tile in points (source: filePreviewSize = 80).
    var filePreviewSize: CGFloat = 80
    /// false suppresses the built-in queue rows — enqueue + auto-dispatch
    /// still run (source: showQueue).
    var showQueue = true
    /// External focus passthrough — bidirectional (programmatic focus +
    /// reporting). AskUser embedded mode uses it for the "Other" digit.
    var focus: Binding<Bool>? = nil
    /// false → plain Return inserts a newline (freeTextMultiline answers).
    var enterSends = true
    var onCommandReturn: (() -> Void)? = nil
    var onSend: (String, [URL]) -> Void = { _, _ in }
    /// Auto-dispatch on the streaming→idle edge. Unset it routes through
    /// `onSend(text, files)`; set it to receive the originating queue
    /// item — the source's `meta.queuedId` — e.g. to morph the queued
    /// row into the sent message.
    var onAutoDispatch: ((FluidQueuedMessage) -> Void)? = nil
    /// Stop control while streaming with an empty draft. Nil → the button
    /// falls back to send (the source's `onStop ? "stop" : "send"`).
    var onStop: (() -> Void)? = nil
    /// Content rendered in the attachment slot (above the editor) — the
    /// AskUser question flow embeds here.
    @ViewBuilder var header: () -> Header
    /// The footer's right cluster, before the send button — the source's
    /// rightSlot. Read \.fluidComposerSlot inside for the render-fn ctx.
    @ViewBuilder var trailing: () -> Trailing
    /// The footer's left cluster (after the paperclip, before the spacer)
    /// — the source's leftSlot: attach menus, mode chips; anything that
    /// starts the status row. \.fluidComposerSlot for { openFilePicker,
    /// files }.
    @ViewBuilder var leading: () -> Leading

    // Plain state, not @FocusState: a FocusState bound to no .focused()
    // view gets reset to false by the focus system on the next pass, which
    // is what made updateNSView resign first responder after one keystroke.
    @State private var focused = false
    @State private var hovered = false
    @State private var dragOver = false
    @State private var activeSuggestion: Int? = nil
    @State private var historyIndex: Int? = nil
    @State private var draftBeforeHistory = ""
    @State private var fileHover: URL? = nil
    /// Keyboard focus on a tile's × reveals it like a hover does — the
    /// source's `focus-visible:opacity-100` (input-message.tsx:239).
    @FocusState private var fileXFocus: URL?
    // Queue drag-reorder: the dragged item's id, the raw pointer
    // translation since drag start, and the index it started from —
    // target = origin + round(translation/stride) keeps the mapping
    // stable while the array reorders under the drag.
    @State private var dragID: UUID? = nil
    @State private var dragY: CGFloat = 0
    @State private var dragOrigin: Int = 0
    @State private var iBeamPushed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var compact: Bool { size == .compact }
    private var canSend: Bool {
        !disabled && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || !(files?.wrappedValue.isEmpty ?? true))
    }
    private var streaming: Bool { status == .streaming }
    private var suggestionsOpen: Bool { !suggestions.isEmpty && text.isEmpty }
    private var showGhost: Bool {
        placeholderSuggestion != nil && text.isEmpty && !(dragOver && files != nil)
    }
    private var buttonMode: ButtonMode {
        if !streaming { return .send }
        if canSend && queue != nil { return .queue }
        return onStop != nil ? .stop : .send
    }
    private var buttonLabel: String {
        buttonMode == .stop ? "Stop" : buttonMode == .queue ? "Queue message" : sendLabel
    }
    private enum ButtonMode { case send, queue, stop }

    /// The { openFilePicker, files } context for slot content — read via
    /// \.fluidComposerSlot inside `leading:`/`trailing:`.
    private var slotContext: FluidComposerSlotContext {
        FluidComposerSlotContext(
            openFilePicker: { o in openFilePicker(o) },
            files: files?.wrappedValue ?? []
        )
    }

    /// Accept string → comma-split tokens (source: acceptTokens).
    private var acceptTokens: [String] {
        accept.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// kPasteboardTypeFileURLPromise — UTType has no named member for a
    /// promised-file drop (Mail attachments, browser drags).
    private static var filePromiseUTI: String { "com.apple.pasteboard.promised-file-url" }
    private static var filePromiseType: UTType { UTType(importedAs: filePromiseUTI) }

    /// The header slot pinned to the composer's step — the source's
    /// SizeProvider wraps the whole composer, so header content sees the
    /// same step as the footer slots.
    private var headerContent: some View {
        header().environment(\.fluidSize, size)
    }

    /// The footer's left cluster: the built-in paperclip only when files
    /// are supported AND no leftSlot was supplied — the source renders
    /// only leftSlot there, so a consumer-supplied leading: replaces it
    /// instead of doubling up beside it.
    private var leftCluster: some View {
        HStack(spacing: 6) {
            if files != nil, Leading.self == EmptyView.self {
                // Compact step squashes footer buttons to h-6
                // (input-message.tsx:1244-1246) — .iconSmall.
                FluidButton(variant: .ghost,
                            size: compact ? .iconSmall : .iconCompact,
                            action: { openFilePicker(nil) }) {
                    FluidIcon("paperclip", size: compact ? 13 : 14)
                }
                .fluidTooltip("Attach files", delay: 0.3)
                .accessibilityLabel("Attach files")
                .fluidCursor(.pointingHand)
            }
            leading()
        }
        .environment(\.fluidComposerSlot, slotContext)
        .environment(\.fluidSize, size)
    }

    /// The footer's right cluster — rightSlot then the send button
    /// (input-message.tsx:1250-1296).
    private var rightCluster: some View {
        HStack(spacing: 6) {
            trailing()
            sendButton
        }
        .environment(\.fluidComposerSlot, slotContext)
        .environment(\.fluidSize, size)
    }

    /// Editor + ghost/placeholder overlay (input-message.tsx:1141-1236).
    private var editorArea: some View {
        ZStack(alignment: .topLeading) {
            FluidComposerEditor(
                text: $text,
                focused: $focused,
                fontSize: compact ? 13 : 14,
                lineHeight: compact ? 18 : 20,
                inset: compact ? 6 : 8,
                minLines: minRows, maxLines: maxRows,
                // A lit suggestion is accepted even when plain Enter
                // newlines — the source's suggestion branch precedes
                // the send branch (input-message.tsx:794-798).
                enterSends: enterSends || activeSuggestion != nil,
                editable: !disabled,
                onSend: {
                    // Enter fills the lit suggestion before it sends.
                    if let i = activeSuggestion, suggestions.indices.contains(i) {
                        accept(suggestions[i])
                    } else {
                        send()
                    }
                },
                onTab: {
                    if let s = placeholderSuggestion, text.isEmpty { accept(s) }
                },
                // Tab is eaten while a suggestion is set and the draft
                // is empty — the source's `placeholderSuggestion &&
                // value === ""` gate (input-message.tsx:811-815),
                // independent of the ghost's drag-over suppression.
                shouldConsumeTab: { placeholderSuggestion != nil && text.isEmpty },
                // Esc drops a lit suggestion; with none lit it passes
                // through (the source lets the event propagate).
                shouldConsumeEscape: { activeSuggestion != nil },
                // ↑ walks the lit row back up and out, then falls to
                // readline history; ↓ enters the open list — anything
                // else is plain caret movement (input-message.tsx:779-863).
                shouldConsumeArrowUp: {
                    if suggestionsOpen, activeSuggestion != nil { return true }
                    return !history.isEmpty && (historyIndex ?? history.count) > 0
                },
                shouldConsumeArrowDown: {
                    if suggestionsOpen { return true }
                    return historyIndex != nil
                },
                onArrowDown: arrowDown,
                onArrowUp: arrowUp,
                onEscape: { activeSuggestion = nil },
                onCommandReturn: onCommandReturn,
                // Real typing exits history mode and drops the lit
                // suggestion (source: textarea onChange).
                onType: { historyIndex = nil; activeSuggestion = nil }
            )
            if showGhost, let s = placeholderSuggestion {
                HStack(spacing: 6) {
                    Text(s).lineLimit(1).truncationMode(.tail)
                    ghostCap("Tab")
                }
                .font(.system(size: compact ? 13 : 14))
                .foregroundStyle(FluidTone.mutedForeground)
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, compact ? 6 : 8)
                .allowsHitTesting(false)
            } else if text.isEmpty {
                // No ghost: the textarea's own placeholder — the drop
                // hint while files hover, else the resting placeholder.
                Text(dragOver && files != nil
                     ? "Drop files here to add to chat" : placeholder)
                    .font(.system(size: compact ? 13 : 14))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .padding(.horizontal, compact ? 6 : 8)
                    .padding(.vertical, compact ? 6 : 8)
                    .allowsHitTesting(false)
            }
        }
    }

    init(text: Binding<String>, placeholder: String = "Ask me anything…",
         placeholderSuggestion: String? = nil, suggestions: [String] = [],
         history: [String] = [], files: Binding<[URL]>? = nil,
         queue: Binding<[FluidQueuedMessage]>? = nil,
         status: FluidComposerStatus = .idle, disabled: Bool = false,
         size: FluidSize = .default,
         minRows: Int = 1, maxRows: Int = 8,
         clickToFocus: Bool = true, sendLabel: String = "Send",
         accept: String = "image/png,image/jpeg,application/pdf",
         maxFiles: Int? = nil, filePreviewSize: CGFloat = 80,
         showQueue: Bool = true,
         focus: Binding<Bool>? = nil, enterSends: Bool = true,
         onCommandReturn: (() -> Void)? = nil,
         onSend: @escaping (String, [URL]) -> Void = { _, _ in },
         onAutoDispatch: ((FluidQueuedMessage) -> Void)? = nil,
         onStop: (() -> Void)? = nil,
         @ViewBuilder header: @escaping () -> Header,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }) {
        self._text = text; self.placeholder = placeholder
        self.placeholderSuggestion = placeholderSuggestion
        self.suggestions = suggestions; self.history = history
        self.files = files; self.queue = queue; self.status = status
        self.disabled = disabled; self.size = size
        self.minRows = minRows; self.maxRows = maxRows
        self.clickToFocus = clickToFocus; self.sendLabel = sendLabel
        self.accept = accept; self.maxFiles = maxFiles
        self.filePreviewSize = filePreviewSize; self.showQueue = showQueue
        self.focus = focus; self.enterSends = enterSends
        self.onCommandReturn = onCommandReturn
        self.onSend = onSend; self.onAutoDispatch = onAutoDispatch
        self.onStop = onStop
        self.header = header; self.trailing = trailing
        self.leading = leading
    }

    private func syncExternalFocus(_ f: Bool) {
        if focus?.wrappedValue != f { focus?.wrappedValue = f }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerContent
            if let files, !files.wrappedValue.isEmpty { fileStrip }
            if let queue, showQueue, !queue.wrappedValue.isEmpty { queueStrip }

            // Editor + ghost overlay.
            editorArea

            // Footer: left cluster (paperclip + leading), spacer, right
            // cluster (trailing + send). The clusters run gap-1.5 inside a
            // justify-between row — the source's action-bar shape.
            HStack(spacing: compact ? 6 : 8) {
                leftCluster
                Spacer(minLength: 0)
                rightCluster
            }

            if suggestionsOpen { suggestionList }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .fill(FluidTone.surface(2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .strokeBorder(edgeColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
        .opacity(disabled ? 0.5 : 1)
        .allowsHitTesting(!disabled)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.08)) { hovered = h }
            // cursor-text while the container refocuses on click — tiles
            // and queue rows push their own cursors on top of this one.
            if h && clickToFocus && !disabled {
                NSCursor.iBeam.push(); iBeamPushed = true
            } else if !h && iBeamPushed {
                NSCursor.pop(); iBeamPushed = false
            }
        }
        .onDisappear { if iBeamPushed { NSCursor.pop(); iBeamPushed = false } }
        // Mousedown anywhere non-interactive refocuses the editor — the
        // source's container mousedown. Interactive children (buttons, the
        // queue strip's swallowing tap) take precedence over this gesture.
        .contentShape(Rectangle())
        .onTapGesture { if clickToFocus { focused = true } }
        .onDrop(of: [.fileURL, Self.filePromiseType], isTargeted: Binding(
            // supportsFiles && !disabled gate — the source's dragover guard.
            get: { dragOver },
            set: { dragOver = files != nil && !disabled ? $0 : false }
        )) { providers in
            guard files != nil, !disabled else { return false }
            loadDropped(providers)
            return true
        }
        .animation(.easeOut(duration: 0.08), value: edgeColor)
        // Collapsible regions (attachments, queue, suggestions) spring
        // open/closed on the moderate tier — the source's measured-height
        // motion.divs; SwiftUI animates the layout change itself.
        .animation(FluidSpring.moderate,
                   value: !(files?.wrappedValue.isEmpty ?? true))
        .animation(FluidSpring.moderate,
                   value: showQueue && !(queue?.wrappedValue.isEmpty ?? true))
        .animation(FluidSpring.moderate, value: suggestionsOpen)
        // Auto-dispatch: on the streaming → idle edge, fire the head of the
        // queue and drop it (the consumer re-arms by setting .streaming in
        // onSend, same contract as the source). onAutoDispatch receives the
        // item — the source's meta.queuedId; onSend is the default path.
        .onChange(of: status) { prev, now in
            guard prev == .streaming, now == .idle,
                  let queue, !queue.wrappedValue.isEmpty else { return }
            let next = queue.wrappedValue.removeFirst()
            if let onAutoDispatch { onAutoDispatch(next) }
            else { onSend(next.text, next.files) }
            let rest = queue.wrappedValue.count
            announce("Message sent.\(rest > 0 ? " \(rest) still queued." : "")")
        }
        // Blur drops the lit suggestion (source: textarea onBlur).
        .onChange(of: focused) { _, now in
            if !now { activeSuggestion = nil }
            syncExternalFocus(now)
        }
        .onChange(of: focus?.wrappedValue ?? false) { _, wants in
            if wants != focused { focused = wants }
        }
    }

    /// The source's aria-live "polite" line — macOS speaks it through the
    /// announcement notification on the composer's window.
    private func announce(_ msg: String) {
        guard let win = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: win, notification: .announcementRequested,
            userInfo: [.announcement: msg as NSString,
                       .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber]
        )
    }

    /// The edge ring: drag → focus-ring blue; focus → fg/20; hover →
    /// border, but only when the container would refocus on click (the
    /// source's `hovered && clickToFocus && !disabled`).
    private var edgeColor: Color {
        if dragOver { return FluidTone.focusRing }
        if focused { return FluidTone.foreground.opacity(0.2) }
        if hovered && clickToFocus && !disabled { return FluidTone.border }
        return FluidTone.border.opacity(0.6)
    }

    // MARK: - Attachments

    private var fileStrip: some View {
        FluidFlow(spacing: 8, rowSpacing: 8) {
            // Keyed by file identity (the source keys name-size-mtime) so
            // removing the first tile doesn't remount its siblings.
            ForEach(files?.wrappedValue ?? [], id: \.self) { url in
                ZStack(alignment: .topTrailing) {
                    FluidFileThumbnail(url: url, size: filePreviewSize)
                    Button {
                        if let i = files?.wrappedValue.firstIndex(of: url) {
                            files?.wrappedValue.remove(at: i)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            // XIcon size={12} (input-message.tsx:241).
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(white: 0.15)))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .opacity(fileHover == url || fileXFocus == url ? 1 : 0)
                    .focusable()
                    .focused($fileXFocus, equals: url)
                    .fluidTooltip("Remove", delay: 0.3)
                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                    .fluidCursor(.pointingHand)
                }
                .onHover { h in fileHover = h ? url : nil }
                // cursor-default over a tile — it isn't text (source).
                .fluidCursor(.arrow)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.bottom, 4)
        // Enter: spring.fast (small-state-flip tier); the exit rides the
        // same tier (source uses a 60ms linear fade — same read).
        .animation(FluidSpring.fast, value: files?.wrappedValue)
    }

    // MARK: - Queue

    /// Row pitch for drag math: fixed row height + the strip's gap.
    private var queueStride: CGFloat { (compact ? 28 : 32) + 4 }

    private var queueStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(queue?.wrappedValue ?? []) { item in
                let i = queue?.wrappedValue.firstIndex(where: { $0.id == item.id }) ?? 0
                let rowLabel = item.text.isEmpty
                    ? "\(item.files.count) attachment\(item.files.count == 1 ? "" : "s")"
                    : item.text
                FluidQueuedRow(
                    label: rowLabel,
                    // The count chip only shows beside real text — the
                    // fallback label already carries the number.
                    fileCount: item.text.isEmpty ? 0 : item.files.count,
                    badgeCount: item.files.count,
                    compact: compact,
                    dragging: dragID == item.id,
                    reduceMotion: reduceMotion,
                    onEdit: { editQueued(item) },
                    onRemove: { queue?.wrappedValue.removeAll { $0.id == item.id } },
                    onMove: { moveQueued(item, $0) }
                )
                // The row is labeled but its children (the ×) stay
                // reachable — .contain keeps them exposed (source :295
                // labels the div, the button remains in the tree).
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    "Queued message \(i + 1) of \(queue?.wrappedValue.count ?? 0): \(rowLabel)"
                )
                .offset(y: dragID == item.id
                        ? dragY - CGFloat(i - dragOrigin) * queueStride : 0)
                .zIndex(dragID == item.id ? 1 : 0)
                .gesture(queueDrag(item, index: i))
                .transition(reduceMotion
                            ? .opacity
                            : .scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .padding(.bottom, 4)
        // The queue region swallows single taps — clicks on staged rows
        // don't refocus the editor (the source's [data-im-queue] carve-out
        // of the container mousedown).
        .contentShape(Rectangle())
        .onTapGesture { }
        .animation(FluidSpring.fast, value: dragID)
        .animation(FluidSpring.moderate, value: queue?.wrappedValue)
    }

    /// Drag-to-reorder within the strip — the Reorder.Group port. Rows are
    /// a fixed pitch, so target = origin + round(translation/stride); the
    /// array moves live and the dragged row rides the pointer via .offset.
    private func queueDrag(_ item: FluidQueuedMessage, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragID == nil { dragID = item.id; dragOrigin = index }
                guard dragID == item.id, let queue else { return }
                dragY = v.translation.height
                let n = queue.wrappedValue.count
                let delta = Int((v.translation.height / queueStride).rounded())
                let target = max(0, min(n - 1, dragOrigin + delta))
                if let cur = queue.wrappedValue.firstIndex(where: { $0.id == item.id }),
                   cur != target {
                    withAnimation(FluidSpring.fast) {
                        queue.wrappedValue.move(
                            fromOffsets: IndexSet(integer: cur),
                            toOffset: target > cur ? target + 1 : target)
                    }
                }
            }
            .onEnded { _ in
                dragID = nil
                dragY = 0
            }
    }

    /// ⌥↑/⌥↓ on a focused row — the source's moveQueued.
    private func moveQueued(_ item: FluidQueuedMessage, _ dir: Int) {
        guard var q = queue?.wrappedValue,
              let i = q.firstIndex(where: { $0.id == item.id }) else { return }
        let j = i + dir
        guard j >= 0, j < q.count else { return }
        q.swapAt(i, j)
        queue?.wrappedValue = q
    }

    private func editQueued(_ item: FluidQueuedMessage) {
        historyIndex = nil
        text = item.text
        if files != nil {
            let f = item.files
            // Restoring a queued draft respects maxFiles — the source
            // slices the same way.
            files?.wrappedValue = maxFiles != nil ? Array(f.prefix(maxFiles!)) : f
        }
        queue?.wrappedValue.removeAll { $0.id == item.id }
        focused = true
    }

    // MARK: - Suggestions

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                Button { accept(s) } label: {
                    HStack(spacing: 8) {
                        Text(s)
                            .font(.system(size: compact ? 13 : 14))
                            .foregroundStyle(activeSuggestion == i
                                             ? FluidTone.foreground : FluidTone.mutedForeground)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        // ↵ on the lit row; a muted ↓ on the first row while
                        // nothing is lit — signposting the keyboard path in.
                        if i == 0 && activeSuggestion == nil {
                            FluidIcon("arrow.down", size: 13)
                                .foregroundStyle(FluidTone.mutedForeground.opacity(0.7))
                        } else {
                            FluidIcon("return", size: 13)
                                .foregroundStyle(FluidTone.mutedForeground)
                                .opacity(activeSuggestion == i ? 1 : 0)
                        }
                    }
                    .padding(.horizontal, compact ? 8 : 10)
                    .frame(height: compact ? 28 : 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                            .fill(activeSuggestion == i ? FluidTone.hover : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // role="option" + aria-selected — the lit row carries the
                // selected trait (input-message.tsx:400-401).
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(activeSuggestion == i ? [.isSelected] : [])
                .onHover { h in if h { activeSuggestion = i } else if activeSuggestion == i { activeSuggestion = nil } }
                .fluidCursor(.pointingHand)
            }
        }
        // The listbox's own chrome: px-1.5 around the rows, pt-1.5 under
        // the divider; -mx-2 runs the divider the composer's full width;
        // the extra top pad lands the divider mt-2 (8px) below the footer.
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.horizontal, -8)
        .overlay(alignment: .top) {
            Rectangle().fill(FluidTone.border.opacity(0.6)).frame(height: 1)
        }
        .padding(.top, 4)
        .padding(.bottom, -8)
        .animation(.easeOut(duration: 0.08), value: activeSuggestion)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Send button

    private var sendButton: some View {
        FluidSendButton(
            compact: compact,
            disabled: buttonMode == .stop ? disabled : !canSend,
            action: { if buttonMode == .stop { onStop?() } else { send() } }
        ) {
            ZStack {
                if buttonMode == .stop {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FluidTone.background)
                        .frame(width: 12, height: 12)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.6).combined(with: .opacity))
                } else {
                    FluidIcon("arrow.up", size: compact ? 15 : 19)
                        .foregroundStyle(FluidTone.background)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(FluidSpring.fast, value: buttonMode)
            .frame(width: 14, height: 14)
        }
        .fluidTooltip(buttonLabel, delay: 0.3)
        .accessibilityLabel(buttonLabel)
        .fluidCursor(.pointingHand)
    }

    // MARK: - Behavior

    private func send() {
        guard canSend else { return }
        // Source: setHistoryIndex(null) runs before the streaming branch.
        historyIndex = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if streaming, let queue {
            queue.wrappedValue.append(FluidQueuedMessage(
                text: t, files: files?.wrappedValue ?? []))
            text = ""
            files?.wrappedValue = []
            focused = true
            return
        }
        onSend(t, files?.wrappedValue ?? [])
    }

    private func accept(_ s: String) {
        text = s
        activeSuggestion = nil
        historyIndex = nil
        focused = true
    }

    private func arrowDown() {
        if suggestionsOpen {
            activeSuggestion = min((activeSuggestion ?? -1) + 1, suggestions.count - 1)
        } else if let i = historyIndex {
            // Past the newest entry restores the in-progress draft.
            if i + 1 >= history.count {
                historyIndex = nil
                text = draftBeforeHistory
            } else {
                historyIndex = i + 1
                text = history[i + 1]
            }
        }
    }

    private func arrowUp() {
        if suggestionsOpen, activeSuggestion != nil {
            activeSuggestion = activeSuggestion == 0 ? nil : activeSuggestion! - 1
            return
        }
        guard !history.isEmpty else { return }
        if let i = historyIndex {
            if i > 0 { historyIndex = i - 1; text = history[i - 1] }
        } else {
            draftBeforeHistory = text
            historyIndex = history.count - 1
            text = history[history.count - 1]
        }
    }

    // ── File helpers ─────────────────────────────────────────────────
    // addFiles dedups on name+size+mtime, filters through `accept`, and
    // caps at maxFiles — the source's addFiles verbatim.

    /// Identity key for dedup: name + size + lastModified — unique enough
    /// to catch "user dropped the same file twice" without false
    /// positives on legitimately distinct files (source comment verbatim).
    private func fingerprint(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.lastPathComponent)-\(v?.fileSize ?? 0)-"
            + "\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// The file's declared MIME — from its UTI (.contentTypeKey), or the
    /// extension when the file can't be stat'd (source: file.type).
    private func mimeType(of url: URL) -> String? {
        if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return t.preferredMIMEType
        }
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    private func utType(of url: URL) -> UTType? {
        if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// accept matching — "family/*" → MIME prefix; ".ext" → name suffix;
    /// anything else → exact MIME (source: matchesAccept).
    private func matchesAccept(_ url: URL) -> Bool {
        acceptTokens.contains { token in
            if token.hasSuffix("/*") {
                let family = String(token.dropLast(2))
                if let mime = mimeType(of: url) { return mime.hasPrefix(family + "/") }
                // No declared MIME — fall back to UTI conformance when the
                // family maps to a supertype (image/audio/video/text).
                guard let ut = utType(of: url), let sup = Self.familyType(family)
                else { return false }
                return ut.conforms(to: sup)
            }
            if token.hasPrefix(".") {
                return url.lastPathComponent.lowercased().hasSuffix(token.lowercased())
            }
            return mimeType(of: url) == token
        }
    }

    /// UTType supertypes for the wildcard families the picker can express.
    private static func familyType(_ family: String) -> UTType? {
        switch family {
        case "image": return .image
        case "audio": return .audio
        case "video": return UTType(importedAs: "public.video")
        case "text": return .text
        default: return nil
        }
    }

    /// accept tokens → UTTypes for NSOpenPanel.allowedContentTypes.
    /// Tokens that can't map (unknown wildcards) are skipped — addFiles
    /// still enforces accept on the result, same as the source re-checking
    /// after the native picker.
    private static func utTypes(forAccept accept: String) -> [UTType] {
        accept.split(separator: ",").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            if t.hasPrefix(".") {
                return UTType(filenameExtension: String(t.dropFirst()).lowercased())
            }
            if t.hasSuffix("/*") { return familyType(String(t.dropLast(2))) }
            return UTType(mimeType: t)
        }
    }

    private func addFiles(_ urls: [URL]) {
        guard files != nil else { return }
        var existing = Set((files?.wrappedValue ?? []).map(fingerprint))
        var accepted: [URL] = []
        for url in urls {
            if !matchesAccept(url) { continue }
            let fp = fingerprint(url)
            if existing.contains(fp) { continue }
            existing.insert(fp)
            accepted.append(url)
        }
        if accepted.isEmpty { return }
        var next = files?.wrappedValue ?? []
        next.append(contentsOf: accepted)
        if let maxFiles { next = Array(next.prefix(maxFiles)) }
        files?.wrappedValue = next
    }

    /// The picker's `accept` — `override` narrows it for this invocation
    /// only (the source's openFilePicker(acceptOverride)).
    private func openFilePicker(_ acceptOverride: String? = nil) {
        let panel = NSOpenPanel()
        // maxFiles caps selection breadth too (source: multiple={...}).
        panel.allowsMultipleSelection = maxFiles.map { $0 > 1 } ?? true
        panel.canChooseDirectories = false
        let types = Self.utTypes(forAccept: acceptOverride ?? accept)
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    var url: URL? = nil
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    } else if let u = item as? NSURL {
                        url = u as URL
                    }
                    guard let url else { return }
                    Task { @MainActor in addFiles([url]) }
                }
            } else if p.hasItemConformingToTypeIdentifier(Self.filePromiseUTI) {
                // A promised file (Mail attachments, browser drags) — the
                // source accepts anything in dataTransfer.files, so
                // materialize the promise to a real file URL.
                let type = p.registeredTypeIdentifiers.first {
                    $0 != Self.filePromiseUTI
                } ?? UTType.data.identifier
                _ = p.loadFileRepresentation(forTypeIdentifier: type) { tmp, _ in
                    guard let tmp else { return }
                    // The materialized file dies with the drag pasteboard —
                    // copy it to our own temp URL before addFiles reads it.
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "-" + tmp.lastPathComponent)
                    guard (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil
                    else { return }
                    Task { @MainActor in addFiles([dest]) }
                }
            }
        }
    }

    private func ghostCap(_ s: String) -> some View {
        Text(s)
            .font(.system(size: compact ? 10 : 11))
            .foregroundStyle(FluidTone.mutedForeground)
            .padding(.horizontal, 4)
            .frame(height: compact ? 16 : 18)
            // -translate-y-px — the keycap sits a hair above the text line.
            .offset(y: -1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FluidTone.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(FluidTone.border, lineWidth: 1)
            )
    }
}

extension FluidInputMessage where Header == EmptyView {
    /// No-header convenience — keeps the original call shape.
    init(text: Binding<String>, placeholder: String = "Ask me anything…",
         placeholderSuggestion: String? = nil, suggestions: [String] = [],
         history: [String] = [], files: Binding<[URL]>? = nil,
         queue: Binding<[FluidQueuedMessage]>? = nil,
         status: FluidComposerStatus = .idle, disabled: Bool = false,
         size: FluidSize = .default,
         minRows: Int = 1, maxRows: Int = 8,
         clickToFocus: Bool = true, sendLabel: String = "Send",
         accept: String = "image/png,image/jpeg,application/pdf",
         maxFiles: Int? = nil, filePreviewSize: CGFloat = 80,
         showQueue: Bool = true,
         focus: Binding<Bool>? = nil, enterSends: Bool = true,
         onCommandReturn: (() -> Void)? = nil,
         onSend: @escaping (String, [URL]) -> Void = { _, _ in },
         onAutoDispatch: ((FluidQueuedMessage) -> Void)? = nil,
         onStop: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder leading: @escaping () -> Leading = { EmptyView() }) {
        self.init(text: text, placeholder: placeholder,
                  placeholderSuggestion: placeholderSuggestion,
                  suggestions: suggestions, history: history, files: files,
                  queue: queue, status: status, disabled: disabled, size: size,
                  minRows: minRows, maxRows: maxRows,
                  clickToFocus: clickToFocus, sendLabel: sendLabel,
                  accept: accept, maxFiles: maxFiles,
                  filePreviewSize: filePreviewSize, showQueue: showQueue,
                  focus: focus, enterSends: enterSends,
                  onCommandReturn: onCommandReturn,
                  onSend: onSend, onAutoDispatch: onAutoDispatch, onStop: onStop,
                  header: { EmptyView() }, trailing: trailing, leading: leading)
    }
}

extension FluidInputMessage where Leading == EmptyView {
    /// No-leading convenience — header + trailing, footer's left stays bare.
    /// `trailing` stays required so a `trailing:`-only call isn't ambiguous
    /// with the no-header convenience above.
    init(text: Binding<String>, placeholder: String = "Ask me anything…",
         placeholderSuggestion: String? = nil, suggestions: [String] = [],
         history: [String] = [], files: Binding<[URL]>? = nil,
         queue: Binding<[FluidQueuedMessage]>? = nil,
         status: FluidComposerStatus = .idle, disabled: Bool = false,
         size: FluidSize = .default,
         minRows: Int = 1, maxRows: Int = 8,
         clickToFocus: Bool = true, sendLabel: String = "Send",
         accept: String = "image/png,image/jpeg,application/pdf",
         maxFiles: Int? = nil, filePreviewSize: CGFloat = 80,
         showQueue: Bool = true,
         focus: Binding<Bool>? = nil, enterSends: Bool = true,
         onCommandReturn: (() -> Void)? = nil,
         onSend: @escaping (String, [URL]) -> Void = { _, _ in },
         onAutoDispatch: ((FluidQueuedMessage) -> Void)? = nil,
         onStop: (() -> Void)? = nil,
         @ViewBuilder header: @escaping () -> Header,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(text: text, placeholder: placeholder,
                  placeholderSuggestion: placeholderSuggestion,
                  suggestions: suggestions, history: history, files: files,
                  queue: queue, status: status, disabled: disabled, size: size,
                  minRows: minRows, maxRows: maxRows,
                  clickToFocus: clickToFocus, sendLabel: sendLabel,
                  accept: accept, maxFiles: maxFiles,
                  filePreviewSize: filePreviewSize, showQueue: showQueue,
                  focus: focus, enterSends: enterSends,
                  onCommandReturn: onCommandReturn,
                  onSend: onSend, onAutoDispatch: onAutoDispatch, onStop: onStop,
                  header: header, trailing: trailing, leading: { EmptyView() })
    }
}

// MARK: - Send button (sized)

/// icon-sm at both steps — the source's footer override scales every
/// button in the row to 24px on compact. FluidButton's fixed 28/36 ladder
/// can't express it, so the send button replicates the primary recipe
/// (fg fill, bg glyph, hover 90 / press 80 + 1px inset) at its own size.
private struct FluidSendButton<Label: View>: View {
    var compact = false
    var disabled = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var pressed = false

    private var dim: CGFloat { compact ? 24 : 28 }

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: dim, height: dim)
                .foregroundStyle(FluidTone.background)
                .background {
                    RoundedRectangle(cornerRadius: FluidShape.rounded.button,
                                     style: .continuous)
                        .fill(pressed ? FluidMix.fgOverBg(80, for: scheme)
                                      : hovered ? FluidMix.fgOverBg(90, for: scheme)
                                      : FluidTone.foreground)
                        .padding(pressed ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.08)) { hovered = h } }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                }
                .onEnded { _ in
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) { pressed = false }
                }
        )
    }
}

// MARK: - Queued row

/// A staged message: recessed bg-muted row, grab cursor, hover ×,
/// double-click (or Enter/F2) pulls it back into the composer, Delete
/// removes it, ⌥↑/⌥↓ — or a drag on the row — reorders the queue.
private struct FluidQueuedRow: View {
    let label: String
    /// Count printed beside the icon — only when the label is real text
    /// (the source renders `{item.text && count}`).
    var fileCount = 0
    /// Whether to show the icon chip at all (files attached).
    var badgeCount = 0
    var compact = false
    var dragging = false
    var reduceMotion = false
    var onEdit: () -> Void
    var onRemove: () -> Void
    var onMove: (Int) -> Void
    @State private var hovered = false
    @State private var cursorPushed = false
    @FocusState private var rowFocused: Bool
    /// focus-visible on the × itself — it reveals like a row hover does
    /// (the source's focus-visible:opacity-100, input-message.tsx:350).
    @FocusState private var xFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if badgeCount > 0 {
                HStack(spacing: 2) {
                    FluidIcon("photo", size: 13)
                    if fileCount > 0 {
                        Text("\(fileCount)")
                            .font(.system(size: compact ? 12 : 13).monospacedDigit())
                    }
                }
                .foregroundStyle(FluidTone.mutedForeground)
            }
            Text(label)
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(FluidTone.foreground.opacity(0.85))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    // XIcon size={13} (input-message.tsx:355).
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(hovered ? FluidTone.hover : .clear))
            }
            .buttonStyle(.plain)
            .opacity(hovered || rowFocused || xFocused ? 1 : 0)
            .focusable()
            .focused($xFocused)
            .fluidTooltip("Remove", delay: 0.3)
            .accessibilityLabel("Remove queued message: \(label)")
            .fluidCursor(.pointingHand)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 28 : 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FluidTone.muted)
        )
        .overlay(
            // focus-visible ring — the source's 1px focus-ring outline.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .opacity(rowFocused ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.08)) { hovered = h }
            // cursor-grab / grabbing — the source's cursor styling.
            // push/pop strictly paired so we never eject another cursor.
            if h {
                (dragging ? NSCursor.closedHand : NSCursor.openHand).push()
                cursorPushed = true
            } else if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .onChange(of: dragging) { _, d in
            guard cursorPushed else { return }
            NSCursor.pop()
            (d ? NSCursor.closedHand : NSCursor.openHand).push()
        }
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
        .onTapGesture(count: 2) { onEdit() }
        // tabIndex={0} — a real focus stop (the source's row tab stop,
        // input-message.tsx:296) so the Enter/F2/Delete/⌥↑⌥↓ contract
        // and the focus ring actually work; a click lands focus like the
        // browser's mousedown-focus on a tabbable div.
        .onTapGesture { rowFocused = true }
        .focusable()
        .focused($rowFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            if press.modifiers.contains(.option) {
                switch press.key {
                case .upArrow: onMove(-1); return .handled
                case .downArrow: onMove(1); return .handled
                default: return .ignored
                }
            }
            switch press.key {
            case .return: onEdit(); return .handled
            case .delete, .deleteForward: onRemove(); return .handled
            default:
                // F2 (keyCode 120) has no KeyEquivalent constant — the
                // function-key unichar is U+F705.
                if press.key == KeyEquivalent("\u{F705}") { onEdit(); return .handled }
                return .ignored
            }
        }
    }
}

// MARK: - Editor

/// The growing plain-text editor — NSTextView so Enter/Tab/arrows and the
/// caret-line rules from the source survive intact. Height springs to a
/// measured line count between minLines and maxLines.
struct FluidComposerEditor: NSViewRepresentable {
    @Binding var text: String
    var focused: Binding<Bool>
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 20
    /// The textarea's padding — px/py track the size step (8 default, 6
    /// compact) so the ghost overlay sits exactly under the caret.
    var inset: CGFloat = 8
    var minLines = 1
    var maxLines = 8
    /// When false, plain Return inserts a newline (freeTextMultiline);
    /// ⌘Return still routes through onCommandReturn.
    var enterSends = true
    /// The textarea's `disabled` — a disabled composer can't be typed in.
    var editable = true
    var onSend: () -> Void
    var onTab: () -> Void
    /// Whether Tab is consumed by onTab or passes to focus traversal —
    /// the source eats Tab only while the ghost suggestion is up.
    /// Nil = always consume (AskUser's fields keep Tab inert).
    var shouldConsumeTab: (() -> Bool)? = nil
    /// Whether Esc is consumed by onEscape or passes through — the source
    /// handles Esc only while a suggestion row is lit. Nil = always.
    var shouldConsumeEscape: (() -> Bool)? = nil
    /// Whether ↑/↓ is consumed by suggestion/history nav — the source
    /// preventDefaults only on a real navigation step; nil = never
    /// consume (plain caret movement).
    var shouldConsumeArrowUp: (() -> Bool)? = nil
    var shouldConsumeArrowDown: (() -> Bool)? = nil
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onEscape: () -> Void
    /// Reports when the content crosses ~1.5 lines — the source uses this
    /// to top-align the AskUser Other-row chip once its textarea wraps.
    var onMultilineChange: ((Bool) -> Void)? = nil
    /// ⌘Return — bubbles to the card root in the source (Continue/Finish).
    var onCommandReturn: (() -> Void)? = nil
    /// Real typing only — the source's textarea onChange also drops
    /// history-browse mode and the lit suggestion. Programmatic writes
    /// (accept/history/editQueued) don't fire it.
    var onType: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// leading-5 / leading-[18px] (input-message.tsx:1190-1191) — pin the
    /// line pitch so a row measures exactly lineHeight and maxRows counts
    /// real lines, not the font's natural ~17px leading.
    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        return p
    }

    /// font + line pitch, as one unit — re-applied when either input
    /// changes post-mount (a step flip changes both together).
    func applyTypography(_ tv: FluidTextView) {
        tv.font = .systemFont(ofSize: fontSize)
        let p = paragraphStyle
        tv.defaultParagraphStyle = p
        tv.typingAttributes[.paragraphStyle] = p
        normalizePitch(tv)
    }

    /// Keep the fixed pitch across the whole string — pastes and
    /// programmatic writes can land attributes the typing attrs don't
    /// cover.
    func normalizePitch(_ tv: FluidTextView) {
        guard let ts = tv.textStorage, ts.length > 0 else { return }
        let want = paragraphStyle
        var span = NSRange()
        let have = ts.attribute(.paragraphStyle, at: 0, effectiveRange: &span) as? NSParagraphStyle
        guard span.length == ts.length,
              have?.minimumLineHeight == want.minimumLineHeight,
              have?.maximumLineHeight == want.maximumLineHeight else {
            ts.addAttribute(.paragraphStyle, value: want, range: NSRange(0..<ts.length))
            return
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        let tv = FluidTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.drawsBackground = false
        applyTypography(tv)
        tv.textColor = NSColor(FluidTone.foreground)
        tv.insertionPointColor = NSColor(FluidTone.foreground)
        tv.setAccessibilityLabel("Message")
        tv.textContainerInset = NSSize(width: inset, height: inset)
        // lineFragmentPadding defaults to 5 — without zeroing it the caret
        // and glyphs sit 5px right of the ghost/placeholder text (which
        // pads exactly the container inset).
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            // External write (accept/send/history) — assign + caret to end.
            // Keystrokes already reached tv.string through textDidChange,
            // so a mismatch here is never the typing echo.
            tv.string = text
            normalizePitch(tv)
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.updateHeight(scroll)
        }
        // font/pitch re-apply only on a real change — re-assigning every
        // pass invalidates the text layout, which relayouts the window,
        // which re-evaluates this representable: a permanent per-frame loop.
        // Programmatic focus requests (editQueued, accept) honor FocusState.
        // An untouched field has no height yet — textDidChange installs it,
        // and until then the scroll view stretches to whatever space it's
        // offered. Pin it to its own content size on the first pass. Also
        // re-measure if the row bounds or padding changed under us.
        let c = context.coordinator
        if c.needsHeight || c.lastInset != inset
            || c.lastMinLines != minLines || c.lastMaxLines != maxLines
            || c.lastFontSize != fontSize || c.lastLineHeight != lineHeight {
            if c.lastInset != inset {
                tv.textContainerInset = NSSize(width: inset, height: inset)
                c.lastInset = inset
            }
            if c.lastFontSize != fontSize || c.lastLineHeight != lineHeight {
                applyTypography(tv)
                c.lastFontSize = fontSize
                c.lastLineHeight = lineHeight
            }
            c.lastMinLines = minLines; c.lastMaxLines = maxLines
            c.updateHeight(scroll)
        }
        if tv.isEditable != editable { tv.isEditable = editable }
        let wantsFocus = focused.wrappedValue && editable
        let isFocused = tv.window?.firstResponder === tv
        if FluidComposerEditor.debug {
            FileHandle.standardError.write(
                "updateNSView text=\(text.debugDescription) tv=\(tv.string.debugDescription) want=\(wantsFocus) is=\(isFocused) fr=\(type(of: tv.window?.firstResponder))\n"
                    .data(using: .utf8)!)
        }
        if wantsFocus != isFocused {
            if wantsFocus {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            } else {
                tv.window?.makeFirstResponder(nil)
            }
        }
    }

    static let debug = ProcessInfo.processInfo.environment["FF_DEBUG"] == "1"

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FluidComposerEditor
        weak var textView: FluidTextView?
        private var heightConstraint: NSLayoutConstraint?
        private var lastMultiline = false
        /// Last applied geometry inputs — a prop change re-measures.
        var lastInset: CGFloat = 8
        var lastMinLines = 1
        var lastMaxLines = 8
        var lastFontSize: CGFloat
        var lastLineHeight: CGFloat

        /// No height pin installed yet — the scroll view is unbounded
        /// until one is.
        var needsHeight: Bool { heightConstraint == nil }

        init(_ parent: FluidComposerEditor) {
            self.parent = parent
            self.lastFontSize = parent.fontSize
            self.lastLineHeight = parent.lineHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.normalizePitch(tv)
            // Programmatic writes land here too (setString posts
            // didChangeText) — equal string = the echo of a binding
            // write, not a keystroke; typing is what clears history mode.
            if tv.string == parent.text { updateHeight(tv.enclosingScrollView); return }
            parent.text = tv.string
            parent.onType?()
            updateHeight(tv.enclosingScrollView)
        }

        /// Grow to content between minLines/maxLines, scrolling past the cap.
        func updateHeight(_ scroll: NSScrollView?) {
            guard let scroll, let tv = textView,
                  let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let inset = tv.textContainerInset.height * 2
            let minH = parent.lineHeight * CGFloat(parent.minLines) + inset
            let maxH = parent.lineHeight * CGFloat(parent.maxLines) + inset
            let h = min(max(used + inset, minH), maxH)
            if let c = heightConstraint {
                c.constant = h
            } else {
                let c = scroll.heightAnchor.constraint(equalToConstant: h)
                c.isActive = true
                heightConstraint = c
            }
            scroll.hasVerticalScroller = used + inset > maxH
            let multiline = used > parent.lineHeight * 1.5
            if multiline != lastMultiline {
                lastMultiline = multiline
                parent.onMultilineChange?(multiline)
            }
        }

        // Arrow/history/suggestion rules — the caret-line guard from the
        // source (multi-line editing keeps plain arrow behavior). Both
        // report whether the event was consumed so keyDown can fall
        // through to the default caret move when nothing handled it —
        // the source preventDefaults only on a real navigation.
        func arrowUp() -> Bool {
            guard let tv = textView else { return false }
            // selectedRange is a UTF-16 offset — slice in UTF-16, not
            // Characters (surrogates desync the two counts).
            let caret = (tv.string as NSString).substring(to: tv.selectedRange().location)
            guard !caret.contains("\n"),
                  parent.shouldConsumeArrowUp?() ?? false else { return false }
            parent.onArrowUp()
            return true
        }
        func arrowDown() -> Bool {
            guard let tv = textView else { return false }
            let tail = (tv.string as NSString).substring(from: tv.selectedRange().upperBound)
            guard !tail.contains("\n"),
                  parent.shouldConsumeArrowDown?() ?? false else { return false }
            parent.onArrowDown()
            return true
        }
    }
}

/// NSTextView with the composer's key contract: Enter sends (Shift+Enter
/// newlines), Tab fills the ghost, arrows walk suggestions/history.
final class FluidTextView: NSTextView {
    weak var coordinator: FluidComposerEditor.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.parent.focused.wrappedValue = true }
        if FluidComposerEditor.debug {
            FileHandle.standardError.write("BECOME ok=\(ok)\n".data(using: .utf8)!)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        if FluidComposerEditor.debug {
            FileHandle.standardError.write(
                "RESIGN caller=\(Thread.callStackSymbols.prefix(12).joined(separator: " <- "))\n".data(using: .utf8)!)
        }
        let ok = super.resignFirstResponder()
        if ok { coordinator?.parent.focused.wrappedValue = false }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // isComposing — during IME marked text the keys belong to the
        // input method (Enter confirms, arrows move its candidate list).
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
        switch event.keyCode {
        case 36, 76:                          // Return / keypad Enter
            let parent = coordinator?.parent
            // ⌘↵ keeps the port-level override when one is wired (AskUser's
            // Continue/Finish — the source's bubble-to-card). Every other
            // non-shift Enter sends, meta/alt/ctrl included — the source's
            // `e.key === "Enter" && !e.shiftKey` (input-message.tsx:866).
            if flags == .command, let cb = parent?.onCommandReturn {
                cb()
            } else if !flags.contains(.shift), parent?.enterSends ?? true {
                parent?.onSend()
            } else {
                super.keyDown(with: event)
            }
        case 48 where flags.isEmpty:          // Tab
            let parent = coordinator?.parent
            if parent?.shouldConsumeTab?() ?? true {
                parent?.onTab()
            } else {
                // No ghost to fill — resume normal focus traversal.
                window?.selectKeyView(following: self)
            }
        case 125 where flags.isEmpty:         // Down
            // preventDefault only on a real suggestion/history step —
            // otherwise the caret moves like any text field.
            if !(coordinator?.arrowDown() ?? false) { super.keyDown(with: event) }
        case 126 where flags.isEmpty:         // Up
            if !(coordinator?.arrowUp() ?? false) { super.keyDown(with: event) }
        case 53 where flags.isEmpty:          // Escape
            if coordinator?.parent.shouldConsumeEscape?() ?? true {
                coordinator?.parent.onEscape()
            } else {
                // With nothing lit the source lets Esc propagate — but NOT
                // to super (NSTextView maps it to word completion): hand it
                // to the responder chain ourselves.
                nextResponder?.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// The source re-measures height on a width change (a width-gated
    /// ResizeObserver). NSTextView relayouts on resize but the height
    /// pin never revisits — so do it here, width-gated the same way.
    override func layout() {
        super.layout()
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            coordinator?.updateHeight(enclosingScrollView)
        }
    }
    private var lastLayoutWidth: CGFloat = -1
}

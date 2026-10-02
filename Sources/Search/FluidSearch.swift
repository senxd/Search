import AppKit
import SwiftUI

// DropdownSearch — fluid-demo/components/ui/dropdown-search.tsx.
// A search field pinned to the top of a menu panel: bleed into the
// panel's 4px padding so the divider runs edge to edge, search icon
// that bolds on focus, transparent input. While the field has focus the
// first enabled row carries the hover background — what Enter picks is
// always in view. Typing while the popup is open lands in the field
// (capture-phase redirect); Escape belongs to the menu.

struct FluidMenuSearch: View {
    @Binding var query: String
    var placeholder = "Search…"
    var autoFocus = true
    /// Reset the query when the popup unmounts (clearOnClose).
    var clearOnClose = true
    /// Enabled row indices, in order — Enter picks the lit row.
    var indices: [Int] = []
    var onPick: (Int) -> Void = { _ in }

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidSize) private var size
    @FocusState private var focused: Bool

    private var compact: Bool { size == .compact }

    var body: some View {
        HStack(spacing: size.gap) {
            FluidIcon("magnifyingglass", size: size.icon, bold: focused)
                .foregroundStyle(focused ? FluidTone.foreground : FluidTone.mutedForeground)
                .frame(width: size.icon, height: size.icon)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: size.text))
                .foregroundStyle(FluidTone.foreground)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onSubmit { pick() }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .frame(height: size.controlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Sticky-field chrome: edge-to-edge divider under the row,
        // bleeding through the panel's 4px padding (-mx-1 in the source).
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FluidTone.border.opacity(0.6))
                .frame(height: 1)
                .padding(.horizontal, -4)
        }
        .padding(.horizontal, -4)
        .padding(.top, -4)
        .padding(.bottom, 2)
        .background(
            FluidSearchTypeahead(query: $query, focused: $focused, onReturn: pick)
        )
        .onAppear {
            if autoFocus { focused = true }
        }
        .onChange(of: focused) { _, f in
            if f { highlightFirst() }
        }
        .onChange(of: query) { _, _ in
            // Rows re-filter with the query — the lit row is whatever
            // Enter would pick now.
            if focused { highlightFirst() }
        }
        .onDisappear {
            if clearOnClose { query = "" }
        }
    }

    private func highlightFirst() {
        hover?.activeIndex = indices.first
    }

    private func move(_ delta: Int) {
        guard !indices.isEmpty else { return }
        let cur = hover?.activeIndex.flatMap { indices.firstIndex(of: $0) }
        let next = cur.map { ($0 + delta + indices.count) % indices.count }
            ?? (delta > 0 ? 0 : indices.count - 1)
        hover?.activeIndex = indices[next]
    }

    private func pick() {
        guard let i = hover?.activeIndex ?? indices.first else { return }
        onPick(i)
    }
}

/// The "no results" row of a filtered menu — px-2 py-6, centered,
/// caption color (DropdownEmpty).
struct FluidMenuEmpty: View {
    let text: String
    @Environment(\.fluidSize) private var size

    init(_ text: String = "No results") { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: size.text))
            .foregroundStyle(FluidTone.mutedForeground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 24)
    }
}

// MARK: - Typeahead redirect

/// Typing while a row — not the field — has the popup's attention lands
/// in the field: characters append, Backspace deletes. Space is left
/// alone (on a row it activates the item).
private struct FluidSearchTypeahead: NSViewRepresentable {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator {
        var parent: FluidSearchTypeahead
        private weak var view: NSView?
        private var monitor: Any?

        init(_ parent: FluidSearchTypeahead) { self.parent = parent }

        func attach(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Only keys aimed at our popup window, never at the field
            // itself — its own keystrokes already arrive.
            guard let view, view.window === event.window else { return event }
            guard let window = event.window,
                  !(window.firstResponder is NSTextView) else { return event }
            if event.modifierFlags.intersection([.command, .control, .option])
                .isEmpty == false { return event }

            switch event.keyCode {
            case 51: // Backspace — route into the field.
                parent.focused.wrappedValue = true
                if !parent.query.isEmpty { parent.query.removeLast() }
                return nil
            case 36: // Return still picks the lit (or first) row.
                parent.onReturn()
                return nil
            default:
                // Printable text only — arrows/F-keys arrive as private-
                // use scalars, Esc/Return/Tabs as controls; appending
                // them would inject control glyphs into the query (the
                // navKey filter's rule). Space stays out: on a row it
                // activates the item.
                guard let chars = event.characters,
                      chars.count == 1, chars != " ",
                      chars.unicodeScalars.allSatisfy({ s in
                          switch s.properties.generalCategory {
                          case .control, .privateUse, .surrogate, .unassigned,
                               .lineSeparator, .paragraphSeparator:
                              return false
                          default:
                              return true
                          }
                      })
                else { return event }
                parent.focused.wrappedValue = true
                parent.query.append(chars)
                return nil
            }
        }
    }
}

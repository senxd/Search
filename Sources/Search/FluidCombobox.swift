import AppKit
import SwiftUI

// Combobox — the filtered list under a text field (combobox.tsx). The
// field keeps focus while the list shows: arrows move a highlight through
// the filtered rows, Enter picks the lit one, Escape closes and reverts
// the field to the selection. Filtering is the registry default —
// case-insensitive "contains" on the label.
//
// The gallery renders the field with its list open directly below — the
// same stacking the popup shows (anchor = the whole field, sideOffset 6).

/// One option: `value` is the identity, `label` what renders and filters.
/// A string convenience keeps `[String]` call sites working (value=label).
struct FluidComboboxItem: Equatable {
    var value: String
    var label: String
    var icon: String? = nil
    var disabled = false

    init(_ value: String, label: String? = nil, icon: String? = nil, disabled: Bool = false) {
        self.value = value
        self.label = label ?? value
        self.icon = icon
        self.disabled = disabled
    }
}

/// The create row's sentinel value (combobox.tsx's CREATE_VALUE). The row
/// is the list's own — it reads the label from the model and picks like
/// any row; a pick asks `onCreate` for the item and selects the result.
private let fluidComboboxCreateValue = "\u{0}fluid-create\u{0}"

@Observable
final class FluidComboboxModel {
    /// All options.
    var items: [FluidComboboxItem]
    /// What the field displays. Single mode mirrors the selected label;
    /// multiple mode tracks the typed text (the chips carry the selection).
    var inputValue = ""
    /// What filters the list — typing sets it, so a single-mode selection
    /// can show its label in the field while the reopened list shows all.
    var query = ""
    /// Selected values, insertion-ordered (chips mode can hold several;
    /// the registry stores an array — order is display order and the
    /// Backspace-remove target).
    var values: [String] = []
    /// Which row Enter would pick — arrow-key or pointer driven.
    var highlight: Int? = nil
    /// A keyboard-driven highlight also draws the focus ring; a pointer
    /// highlight only marks the row Enter would pick (the registry's
    /// Highlight.keyboard flag).
    var highlightKeyboard = false
    /// Whether the list is showing.
    var open = false
    /// Chips mode: selected items leave the list (hideSelected).
    var hideSelected = false
    /// Match an item against the typed query (combobox.tsx `filter`).
    /// Default: case-insensitive contains on the label.
    var filter: ((FluidComboboxItem, String) -> Bool)? = nil
    /// Offer a last row that creates what was typed, whenever the trimmed
    /// query matches no label exactly (combobox.tsx `onCreate`). Return
    /// the new item to select it; nil reverts the field and closes.
    var onCreate: ((String) -> FluidComboboxItem?)? = nil
    /// The create row's label — default `Create “query”`.
    var createLabel: (String) -> String = { "Create “\($0)”" }
    /// The field's rendered NSView — the outside-click monitor treats it
    /// as "inside" so clicking the field while open stays open (Radix's
    /// trigger is excluded from pointer-down-outside).
    weak var fieldView: NSView?

    init(items: [FluidComboboxItem]) { self.items = items }
    /// String convenience — every item's value is its label.
    convenience init(items: [String]) {
        self.init(items: items.map { FluidComboboxItem($0) })
    }

    /// The selected item's label, for single-mode field display.
    var selectedLabel: String {
        guard let v = values.first,
              let item = items.first(where: { $0.value == v }) else { return "" }
        return item.label
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The create row exists once the trimmed query matches no label
    /// exactly (combobox.tsx:266-271).
    var createItem: FluidComboboxItem? {
        guard onCreate != nil, !trimmedQuery.isEmpty else { return nil }
        let lower = trimmedQuery.lowercased()
        let exists = items.contains { $0.label.lowercased() == lower }
        return exists ? nil : FluidComboboxItem(fluidComboboxCreateValue, label: trimmedQuery)
    }

    /// The matches less the chips when `hideSelected`, plus the create row
    /// last — Enter picks a real match while one exists and only creates
    /// once nothing matches.
    var filtered: [FluidComboboxItem] {
        let match = filter ?? { item, q in
            item.label.localizedCaseInsensitiveContains(q)
        }
        var visible = query.isEmpty ? items : items.filter { match($0, query) }
        if hideSelected { visible.removeAll { values.contains($0.value) } }
        if let c = createItem { visible.append(c) }
        return visible
    }

    /// hideSelected emptied the list with nothing typed — every item is a
    /// chip already (combobox.tsx:283-284).
    var allSelected: Bool {
        hideSelected && trimmedQuery.isEmpty && !items.isEmpty && filtered.isEmpty
    }

    /// setOpen — closing without a pick reverts the field to the
    /// selection's label and drops the query and highlight.
    func setOpen(_ next: Bool) {
        open = next
        if !next {
            query = ""
            highlight = nil
            inputValue = selectedLabel
        }
    }

    /// The field's binding: single mode writes inputValue, chips write
    /// query directly (the chips, not the text, carry the selection).
    func fieldText(multiple: Bool) -> Binding<String> {
        Binding(
            get: { multiple ? self.query : self.inputValue },
            set: { v in
                if multiple {
                    self.query = v
                } else if v == self.selectedLabel {
                    // Selection echo, not typing — the list stays unfiltered.
                    self.inputValue = v
                    self.query = ""
                } else {
                    self.inputValue = v
                    self.query = v
                }
            }
        )
    }

    /// onChange → setInputValue: typing opens the list and pre-picks the
    /// first row so Enter has a target (combobox.tsx:375-384).
    func typed(_ multiple: Bool) {
        setOpen(true)
        highlight = filtered.isEmpty ? nil : 0
        highlightKeyboard = true
    }

    /// A pick — combobox.tsx's `select`. The create row is not a
    /// selection: it asks `onCreate` for the item, selects whatever comes
    /// back, and closes like any pick made while filtering.
    func select(_ item: FluidComboboxItem, multiple: Bool) {
        if item.value == fluidComboboxCreateValue {
            let made = onCreate?(item.label)
            if let made {
                if multiple { values.append(made.value) } else { values = [made.value] }
                inputValue = multiple ? "" : made.label
            } else {
                inputValue = multiple ? "" : selectedLabel
            }
            query = ""
            highlight = nil
            open = false
            return
        }
        if multiple {
            // Toggle. A pick from an unfiltered list stays open for the
            // next one; a pick while filtering closes and clears.
            if let i = values.firstIndex(of: item.value) { values.remove(at: i) }
            else { values.append(item.value) }
            if !query.isEmpty {
                inputValue = ""
                query = ""
                highlight = nil
                open = false
            }
            return
        }
        values = [item.value]
        inputValue = item.label
        query = ""
        open = false
    }

    func remove(_ item: String) { values.removeAll { $0 == item } }
    func clear() { values.removeAll(); query = ""; inputValue = ""; highlight = nil }

    /// APG combobox pattern: arrows walk the rows; stepping past the last
    /// or first row drops the highlight (the input is the stop), and the
    /// next press wraps to the near end — no modulo wrap.
    func move(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        let next = (highlight ?? (delta > 0 ? -1 : n)) + delta
        if next < 0 || next >= n {
            highlight = nil
        } else {
            highlight = next
            highlightKeyboard = true
        }
    }

    /// Closed-list arrows open the list and pre-pick the near end.
    func openForArrow(_ delta: Int) {
        setOpen(true)
        let n = filtered.count
        guard n > 0 else { return }
        highlight = delta > 0 ? 0 : n - 1
        highlightKeyboard = true
    }
}

// MARK: - Field

/// `bordered` is framed at rest; `borderless` is the InputGroup ladder —
/// invisible until hover, muted fill + ring on hover, card + ring when
/// focused (combobox.tsx's fieldVariants).
enum FluidComboboxVariant { case bordered, borderless }

/// The field frame: ring-1 border, icon, input, clear ✕, chevron —
/// h-9, px-2.5, min-w 160. Chips mode wraps the selected values ahead of
/// the input (items-start, min-h-9 py-1.5).
struct FluidComboboxField: View {
    @Bindable var model: FluidComboboxModel
    var multiple = false
    var icon: String? = nil
    var placeholder = "Search…"
    var clearable = false
    var variant: FluidComboboxVariant = .bordered
    var error: String? = nil
    var size: FluidSize = .default
    @FocusState.Binding var focused: Bool

    var compact: Bool { size == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: multiple ? .top : .center, spacing: size.gap) {
                if let icon {
                    FluidIcon(icon, size: size.icon, bold: focused)
                        .foregroundStyle(focused ? FluidTone.foreground : FluidTone.mutedForeground)
                        .frame(height: compact ? 20 : 24)
                        .padding(.top, multiple ? compact ? 2 : 4 : 0)
                }
                if multiple {
                    chipsWrap
                } else {
                    input
                }
                controls
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, multiple ? (compact ? 4 : 6) : 0)
            .frame(minHeight: size.controlHeight, alignment: multiple ? .top : .center)
            .frame(minWidth: compact ? 128 : 160, maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FluidShape.rounded.input, style: .continuous)
                    .fill(fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FluidShape.rounded.input, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: 1)
            )
            .background(FluidViewResolver { model.fieldView = $0 })
            .onHover { hovered = $0 }
            // FieldFrame's onMouseDown: a press on the frame's padding or
            // icon focuses the input without disturbing its caret; the
            // input itself and the buttons own their clicks. A re-click
            // on an already-focused field also reopens the list.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                focused = true
                if !model.open { model.setOpen(true) }
            })
            .animation(.easeOut(duration: 0.08), value: focused)
            .animation(.easeOut(duration: 0.08), value: hovered)
            if let error {
                // text-[12px] text-destructive pl-3 — gap-1 column.
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(FluidTone.destructive)
                    .padding(.leading, 12)
            }
        }
    }

    @State private var hovered = false

    /// bordered: transparent → muted/50 hover → card focused.
    /// borderless: transparent + transparent ring → muted/50 + border
    /// ring on hover → card + border ring focused.
    private var fieldFill: Color {
        focused ? FluidTone.card : hovered ? FluidTone.muted.opacity(0.5) : .clear
    }

    private var ringColor: Color {
        if error != nil { return FluidTone.destructive.opacity(0.5) }
        switch variant {
        case .bordered: return FluidTone.border
        case .borderless:
            return (focused || hovered) ? FluidTone.border : .clear
        }
    }

    private var input: some View {
        TextField(
            multiple && !model.values.isEmpty ? "" : placeholder,
            text: model.fieldText(multiple: multiple)
        )
        .textFieldStyle(.plain)
        .font(.system(size: size.text))
        .foregroundStyle(FluidTone.foreground)
        .focused($focused)
        .frame(minWidth: 24)
        .onChange(of: focused) { _, f in model.setOpen(f) }
        .onChange(of: model.query) { _, _ in model.typed(multiple) }
        .onKeyPress(.upArrow) {
            if model.open { model.move(-1) } else { model.openForArrow(-1) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if model.open { model.move(1) } else { model.openForArrow(1) }
            return .handled
        }
        .onKeyPress(.return) {
            // Enter picks the highlighted row only — no highlight, no
            // select (combobox.tsx:588-595; the input is the stop).
            if model.open, let i = model.highlight,
               model.filtered.indices.contains(i) {
                model.select(model.filtered[i], multiple: multiple)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if model.open { model.setOpen(false) }
            return .handled
        }
        // An empty field backspaces into the last-picked chip. The field
        // editor consumes Backspace before .onKeyPress sees it, so the key
        // is intercepted at the event-monitor level while this field holds
        // focus (and only when there's actually a chip to pop).
        .onChange(of: focused) { _, f in
            if f {
                backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 51, multiple,
                          model.fieldText(multiple: true).wrappedValue.isEmpty,
                          let last = model.values.last else { return event }
                    model.remove(last)
                    return nil
                }
            } else if let m = backspaceMonitor {
                NSEvent.removeMonitor(m); backspaceMonitor = nil
            }
        }
    }

    @State private var backspaceMonitor: Any?

    /// One chip per selected value, then the input, wrapping — the
    /// registry's flex-wrap toolbar (role=toolbar, gap-1).
    private var chipsWrap: some View {
        FluidFlow(spacing: 4, rowSpacing: 4) {
            ForEach(model.values, id: \.self) { v in
                FluidComboboxChip(label: model.items.first { $0.value == v }?.label ?? v,
                                  size: size) { model.remove(v); focused = true }
            }
            input
                .layoutPriority(1)
        }
    }

    /// Clear ✕ + chevron — the field's right-side controls. The ✕'s slot
    /// is always reserved so the field's width never changes (hidden, not
    /// removed, while there is nothing to clear).
    private var controls: some View {
        HStack(spacing: 2) {
            Button(action: { model.clear(); focused = true }) {
                Image(systemName: "xmark")
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(clearable && (!model.values.isEmpty || !model.inputValue.isEmpty) ? 1 : 0)
            .disabled(!clearable || (model.values.isEmpty && model.inputValue.isEmpty))
            .accessibilityLabel("Clear")
            // The chevron is a real button in the source — a press focuses
            // the input and toggles the list. Not a tab stop (the field
            // itself opens on ArrowDown or typing).
            Button(action: { focused = true; model.setOpen(!model.open) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: compact ? 11 : 12, weight: .regular))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("Open")
        }
        .frame(height: compact ? 20 : 24)
        .padding(.top, multiple ? compact ? 2 : 4 : 0)
    }
}

/// A selected value in the chips field: bg-hover fill, pl-2 pr-0.5,
/// × remove button, pop-in on the fast tier.
struct FluidComboboxChip: View {
    let label: String
    var size: FluidSize = .default
    var onRemove: () -> Void
    @State private var hovered = false

    var compact: Bool { size == .compact }

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(FluidTone.foreground)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: compact ? 8 : 10, weight: .semibold))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(hovered ? FluidTone.active : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, 8).padding(.trailing, 2)
        .frame(height: compact ? 20 : 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(FluidTone.hover)
        )
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

/// A minimal flex-wrap layout — SwiftUI has no FlowLayout, and the chips
/// field needs chips to spill onto the next line.
struct FluidFlow: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        var maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + rowSpacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX; y += rowH + rowSpacing; rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - List

/// The filtered rows — same elevated panel as FluidMenuPanel with a
/// highlight driven by the model (arrows) AND the pointer (fluid hover).
/// Selection blocks come from the shared FluidSelectionBlocks: single
/// mode glides ONE pinned block between picks (enter-pop, exit-fade);
/// multiple merges contiguous checked runs (useSelectionRuns +
/// useMergeSplitBlocks).
struct FluidComboboxList: View {
    @Bindable var model: FluidComboboxModel
    var multiple = false
    var size: FluidSize = .default
    var emptyText = "No results"
    /// Shown instead of `emptyText` when hideSelected exhausted the list
    /// with nothing typed — every item is a chip already.
    var allSelectedText: String? = nil
    var substrate: Int = 1

    @State private var hover = FluidHover(axis: .y)
    @State private var fade = FluidScrollFadeState()

    /// The visible rows' indices whose values are selected — the create
    /// row's sentinel value can never match.
    private var checkedIndices: Set<Int> {
        Set(model.filtered.enumerated().compactMap {
            model.values.contains($0.element.value) ? $0.offset : nil
        })
    }

    var body: some View {
        let items = model.filtered
        // ComboboxContent unmounts while closed — the list only exists
        // when the field has opened it (focus, typing, arrows).
        if model.open {
            listBody(items)
        }
    }

    private func listBody(_ items: [FluidComboboxItem]) -> some View {
        // The popup caps at max-h-300 and scrolls with the scroll-fade
        // viewport mask (popupScrollAreaClass + "scroll-fade").
        ScrollViewReader { proxy in
            ScrollView {
                FluidContainer(
                    hover: hover,
                    from: multiple ? nil
                        : checkedIndices.first.flatMap { hover.rects[$0] },
                    radius: FluidShape.rounded.bg
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            FluidComboboxRow(
                                index: i,
                                label: item.value == fluidComboboxCreateValue
                                    ? model.createLabel(model.trimmedQuery)
                                    : item.label,
                                icon: item.value == fluidComboboxCreateValue
                                    ? "plus" : item.icon,
                                checked: model.values.contains(item.value),
                                disabled: item.disabled,
                                size: size
                            ) {
                                model.select(item, multiple: multiple)
                            }
                            .id(i)
                            .onHover { h in
                                if h, !item.disabled {
                                    if model.highlight != i || model.highlightKeyboard {
                                        model.highlight = i
                                        model.highlightKeyboard = false
                                    }
                                }
                            }
                        }
                    }
                    .padding(items.isEmpty ? 0 : 4)
                }
                // bg-active under the checked rows — behind the container
                // so the hover pill still draws above it.
                .background(alignment: .topLeading) {
                    FluidSelectionBlocks(
                        hover: hover,
                        checked: checkedIndices,
                        mergedRadius: FluidShape.rounded.bg,
                        // Single mode: one pinned block glides between
                        // picks and pops in (initial={false}); multiple
                        // mode merges/splits runs with fades.
                        exitFades: multiple,
                        enterFades: multiple,
                        pinIds: !multiple
                    )
                }
                .fluidFadeContent(fade)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 300)
            // popupViewportClass sets --scroll-fade-size: 32px.
            .fluidScrollFade(32, state: fade)
            // Disabled rows are skipped by the pick and inert to clicks.
            .onAppear {
                hover.isItemDisabled = { i in
                    let f = model.filtered
                    return i < 0 || i >= f.count || f[i].disabled
                }
                // Mounting/opening pre-picks the first row so Enter has
                // a row; a reopen doesn't spring from a stale row.
                if model.highlight == nil, !model.filtered.isEmpty {
                    model.highlight = 0
                    model.highlightKeyboard = true
                }
            }
            // One highlight store in the source: a keyboard highlight drives
            // the same hover pill (the only indicator, no ring) and scrolls
            // its row into view; a dropped highlight clears the pill.
            // Pointer highlights arrive through moved(), so the bridge
            // leaves them alone.
            .onChange(of: model.highlight) { _, i in
                if let i {
                    guard model.highlightKeyboard else { return }
                    hover.activeIndex = i
                    proxy.scrollTo(i)
                } else {
                    hover.activeIndex = nil
                }
            }
            // Leaving the list drops a pointer highlight; a keyboard one
            // stays so Enter still means what the pill shows.
            .onHover { inside in
                if !inside, model.highlight != nil, !model.highlightKeyboard {
                    model.highlight = nil
                }
            }
            .onChange(of: model.open) { _, o in
                if !o { hover.activeIndex = nil }
                else if model.highlight == nil, !model.filtered.isEmpty {
                    model.highlight = 0
                    model.highlightKeyboard = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // ComboboxEmpty — role=status, live region; the list's padding
        // collapses (data-[empty]:p-0) while the message owns the surface.
        .overlay {
            if items.isEmpty {
                Text(model.allSelected ? (allSelectedText ?? emptyText) : emptyText)
                    .font(.system(size: size.text))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityElement()
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        // Pointer-down-outside dismissal (Radix). macOS doesn't resign a
        // text field's first responder on an empty-area click, so focus
        // alone can't close the list — a local monitor checks each click
        // against the list's own bounds while it's mounted.
        .background(FluidOutsideClick(alsoInside: model.fieldView) { model.setOpen(false) })
        .fluidSurface(min(substrate + 2, 8), radius: FluidShape.rounded.container)
    }
}

/// Exposes the backing NSView to a closure — used to register the field
/// so the outside-click monitor can treat it as inside territory.
struct FluidViewResolver: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSView, context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Fires `onOutside` for mouse-downs that land outside the view it's
/// placed behind (or in another window). `alsoInside` names a second
/// view — the trigger field — whose clicks count as inside too.
private struct FluidOutsideClick: NSViewRepresentable {
    weak var alsoInside: NSView?
    let onOutside: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.alsoInside = alsoInside
        context.coordinator.start(onOutside)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSView, context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        weak var alsoInside: NSView?
        private var monitor: Any?

        func start(_ onOutside: @escaping () -> Void) {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, let view = self.view else { return event }
                var inside = false
                if event.window === view.window {
                    let p = view.convert(event.locationInWindow, from: nil)
                    inside = view.bounds.contains(p)
                    if !inside, let field = self.alsoInside,
                       event.window === field.window {
                        inside = field.bounds.contains(
                            field.convert(event.locationInWindow, from: nil)
                        )
                    }
                }
                if !inside { DispatchQueue.main.async { onOutside() } }
                return event
            }
        }

        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }
}

/// A filtered row: same chrome as FluidMenuItem minus the icon column —
/// the lit state is the hover pick, which keyboard highlights bridge into
/// `activeIndex`, so the row and the pill always agree (the source's
/// isActive reads contentCtx.activeIndex). The check slot is always
/// rendered so it never changes the row's intrinsic width, and the glyph
/// undraws on deselect instead of popping (pathLength exit).
private struct FluidComboboxRow: View {
    let index: Int
    let label: String
    var icon: String? = nil
    let checked: Bool
    var disabled = false
    var size: FluidSize
    var onSelect: () -> Void

    @Environment(\.fluidHover) private var hover

    private var active: Bool { hover?.activeIndex == index }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: size.gap) {
                if let icon {
                    FluidIcon(icon, size: size.icon, bold: active || checked)
                        .foregroundStyle(active || checked ? FluidTone.foreground : FluidTone.mutedForeground)
                        .animation(.easeOut(duration: 0.08), value: active || checked)
                }
                Text(label)
                    .font(.system(size: size.text))
                    .foregroundStyle(active || checked ? FluidTone.foreground : FluidTone.mutedForeground)
                    .lineLimit(1)
                    .animation(.easeOut(duration: 0.08), value: active || checked)
                Spacer(minLength: 0)
                ZStack {
                    FluidCheckmark(size: size.icon, presented: checked)
                        .foregroundStyle(FluidTone.foreground)
                }
                .frame(width: size.icon, height: size.icon)
            }
            .padding(.horizontal, size.itemPx)
            .frame(height: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityAddTraits(checked ? .isSelected : [])
        .fluidItem(index)
    }
}

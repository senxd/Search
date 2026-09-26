import SwiftUI

// Combobox — the filtered list under a text field (combobox.tsx). The
// field keeps focus while the list shows: arrows move a highlight through
// the filtered rows, Enter picks the lit one, Escape closes. Filtering is
// the registry default — case-insensitive "contains" on the label.
//
// The gallery renders the field with its list open directly below — the
// same stacking the popup shows (anchor = the whole field, sideOffset 6).

@Observable
final class FluidComboboxModel {
    /// All options.
    var items: [String]
    /// The live query.
    var query = ""
    /// Selected values (chips mode can hold several).
    var values: Set<String> = []
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

    init(items: [String]) { self.items = items }

    var filtered: [String] {
        items.filter { item in
            if hideSelected && values.contains(item) { return false }
            return query.isEmpty || item.localizedCaseInsensitiveContains(query)
        }
    }

    func select(_ item: String, multiple: Bool) {
        if multiple {
            if values.contains(item) { values.remove(item) } else { values.insert(item) }
        } else {
            values = [item]
            open = false
        }
    }

    func remove(_ item: String) { values.remove(item) }
    func clear() { values.removeAll(); query = "" }

    func move(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { highlight = nil; return }
        let i = highlight.map { ($0 + delta + n) % n } ?? (delta > 0 ? 0 : n - 1)
        highlight = i
        highlightKeyboard = true
    }
}

// MARK: - Field

/// The field frame: ring-1 border, icon, input, clear ✕, chevron —
/// `bordered` variant, h-9, px-2.5, min-w 160. Chips mode wraps the
/// selected values ahead of the input.
struct FluidComboboxField: View {
    @Bindable var model: FluidComboboxModel
    var multiple = false
    var icon: String? = nil
    var placeholder = "Search…"
    var clearable = false
    var size: FluidSize = .default
    @FocusState.Binding var focused: Bool

    var compact: Bool { size == .compact }

    var body: some View {
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
                .strokeBorder(focused ? FluidTone.border : FluidTone.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.08), value: focused)
    }

    /// bg-transparent → muted/50 on hover → card on focus.
    private var fieldFill: Color {
        focused ? FluidTone.surface(3) : .clear
    }

    private var input: some View {
        TextField(
            multiple && !model.values.isEmpty ? "" : placeholder,
            text: $model.query
        )
        .textFieldStyle(.plain)
        .font(.system(size: size.text))
        .foregroundStyle(FluidTone.foreground)
        .focused($focused)
        .frame(minWidth: 24)
        .onChange(of: focused) { _, f in model.open = f }
        .onChange(of: model.query) { _, _ in
            model.open = true
            model.highlight = model.filtered.isEmpty ? nil : 0
        }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.return) {
            if let i = model.highlight, model.filtered.indices.contains(i) {
                model.select(model.filtered[i], multiple: multiple)
                if multiple { model.query = "" }
            } else if model.filtered.count == 1, multiple {
                model.select(model.filtered[0], multiple: true)
                model.query = ""
            }
            return .handled
        }
        .onKeyPress(.escape) { model.open = false; return .handled }
        .onKeyPress(keys: [.delete]) { _ in
            if multiple && model.query.isEmpty, let last = model.values.sorted().last {
                model.remove(last)
                return .handled
            }
            return .ignored
        }
    }

    /// One chip per selected value, then the input, wrapping — the
    /// registry's flex-wrap toolbar.
    private var chipsWrap: some View {
        let sorted = model.values.sorted()
        return FluidFlow(spacing: 4, rowSpacing: 4) {
            ForEach(sorted, id: \.self) { v in
                FluidComboboxChip(label: v, size: size) { model.remove(v) }
            }
            input
                .layoutPriority(1)
        }
    }

    /// Clear ✕ + chevron — the field's right-side controls.
    private var controls: some View {
        HStack(spacing: 2) {
            Button(action: { model.clear() }) {
                Image(systemName: "xmark")
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(clearable && (!model.values.isEmpty || !model.query.isEmpty) ? 1 : 0)
            .disabled(!clearable || (model.values.isEmpty && model.query.isEmpty))
            Image(systemName: "chevron.down")
                .font(.system(size: compact ? 11 : 12, weight: .regular))
                .foregroundStyle(FluidTone.mutedForeground)
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
struct FluidComboboxList: View {
    @Bindable var model: FluidComboboxModel
    var multiple = false
    var size: FluidSize = .default
    var emptyText = "No results"
    var substrate: Int = 1

    @State private var hover = FluidHover(axis: .y)

    var body: some View {
        let items = model.filtered
        FluidContainer(hover: hover, radius: FluidShape.rounded.bg) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    FluidComboboxRow(
                        index: i,
                        label: item,
                        checked: model.values.contains(item),
                        lit: model.highlight == i,
                        size: size
                    ) {
                        model.select(item, multiple: multiple)
                        if multiple { model.query = "" }
                    }
                    .onHover { h in
                        if h { model.highlight = i; model.highlightKeyboard = false }
                    }
                }
                if items.isEmpty {
                    Text(emptyText)
                        .font(.system(size: size.text))
                        .foregroundStyle(FluidTone.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { keyboardRing }
        .fluidSurface(min(substrate + 2, 8), radius: FluidShape.rounded.container)
    }

    /// Keyboard-driven rows also draw the focus ring; pointer rows don't.
    /// In the registry the ring follows focus-visible — here a highlighted
    /// row under keyboard control reads the same.
    @ViewBuilder
    private var keyboardRing: some View {
        if let i = model.highlight, model.highlightKeyboard, let r = hover.rects[i] {
            RoundedRectangle(cornerRadius: FluidShape.rounded.focusRing, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .frame(width: r.width + 4, height: r.height + 4)
                .position(x: r.midX, y: r.midY)
                .animation(FluidSpring.fast, value: r)
                .transition(.opacity)
        }
    }
}

/// A filtered row: same chrome as FluidMenuItem minus the icon column.
private struct FluidComboboxRow: View {
    let index: Int
    let label: String
    let checked: Bool
    /// Lit by the model's highlight (arrows) in addition to fluid hover.
    let lit: Bool
    var size: FluidSize
    var onSelect: () -> Void

    @Environment(\.fluidHover) private var hover

    private var active: Bool { hover?.activeIndex == index || lit }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: size.gap) {
                Text(label)
                    .font(.system(size: size.text))
                    .foregroundStyle(active || checked ? FluidTone.foreground : FluidTone.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ZStack {
                    if checked {
                        FluidCheckmark(size: size.icon)
                            .foregroundStyle(FluidTone.foreground)
                    }
                }
                .frame(width: size.icon, height: size.icon)
            }
            .padding(.horizontal, size.itemPx)
            .frame(height: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fluidItem(index)
    }
}

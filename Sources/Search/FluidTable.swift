import SwiftUI

// Table — fluid-demo/components/ui/table.tsx. Body rows are fluid-hover
// items under one highlight; a row's bottom hairline drops when the
// highlight covers it or the row below (border-accent/40 → transparent),
// and cells flip muted → foreground while their row is lit.
//
// The source exports Table, TableHeader, TableBody, TableRow, TableHead,
// TableCell — no TableFooter/TableCaption exist upstream, and neither do
// sticky headers or row selection (checked table.tsx head to toe: thead
// carries no sticky classes and the only state is the hover pick).

/// The table surface: tracks the pick, draws the highlight, stacks rows
/// (the source's `w-full border-collapse` table inside a `relative` div).
/// The highlight is SQUARE here — table.tsx mounts FluidHoverHighlight
/// with no `shape.bg` class, unlike the accordion's rounded overlay.
struct FluidTable<Content: View>: View {
    /// `size` pins every cell to one ladder step (the source's optional
    /// `size` prop — a SizeProvider wrapper). Omitted, the table follows
    /// the surrounding fluidSize instead of forcing the default rung.
    var size: FluidSize? = nil
    @State private var hover = FluidHover(axis: .y)
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidSize) private var ambientSize

    var body: some View {
        FluidContainer(hover: hover, radius: 0) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        // w-full — the table fills whatever box it's dropped into.
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.fluidSize, size ?? ambientSize)
    }
}

/// `TableHeader` — the thead wrapper. Header-ness in the source comes from
/// a row's `index` being undefined, not from sitting inside thead, so this
/// is purely structural parity.
struct FluidTableHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
    }
}

/// `TableBody` — the tbody wrapper.
struct FluidTableBody<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
    }
}

/// One row — `index` nil marks the header row (semibold, never picked).
/// Cells are equal-width flexible columns.
struct FluidTableRow<Content: View>: View {
    var index: Int? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidSize) private var size

    private var isActive: Bool { index != nil && hover?.activeIndex == index }

    /// Header drops its border when the first row is lit; a body row drops
    /// its own when it or the row below it is lit.
    private var hideBorder: Bool {
        guard let active = hover?.activeIndex else { return false }
        guard let index else { return active == 0 }
        return index == active || index == active - 1
    }

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, size == .compact ? 10 : 12)
            .padding(.vertical, size == .compact ? 5 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(size: size.text, weight: index == nil ? .semibold : .regular))
            .foregroundStyle(index == nil || isActive ? FluidTone.foreground : FluidTone.mutedForeground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(FluidTone.accent.opacity(0.4))
                    .frame(height: 1)
                    .opacity(hideBorder ? 0 : 1)
            }
            .contentShape(Rectangle())
            .modifier(FluidTableItem(index: index))
            .animation(FluidSpring.fast, value: isActive)
            .animation(FluidSpring.fast, value: hideBorder)
    }
}

private struct FluidTableItem: ViewModifier {
    let index: Int?
    func body(content: Content) -> some View {
        if let index { content.fluidItem(index) } else { content }
    }
}

/// `TableCell` — the td: a flexible column. `width` pins a fixed column,
/// nil flexes equally. Content is any view (the source's td takes
/// children); the String init keeps text call sites one token long.
struct FluidTableCell<Content: View>: View {
    /// Width share — nil flexes equally, a value pins a fixed width.
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    init(width: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.width = width
        self.content = content
    }

    var body: some View {
        content()
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .lineLimit(1)
    }
}

extension FluidTableCell where Content == Text {
    init(_ text: String, width: CGFloat? = nil) {
        self.init(width: width) { Text(text) }
    }
}

/// `TableHead` — the th: same flexible cell, left-aligned. The header
/// row's own semibold + foreground carries through (the source th adds
/// `text-left text-foreground` over the tr's font treatment).
struct FluidTableHead<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    init(width: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.width = width
        self.content = content
    }

    var body: some View {
        FluidTableCell(width: width, content: content)
    }
}

extension FluidTableHead where Content == Text {
    init(_ text: String, width: CGFloat? = nil) {
        self.init(width: width) { Text(text) }
    }
}

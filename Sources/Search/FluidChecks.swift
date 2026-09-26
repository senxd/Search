import SwiftUI

// Choice rows — checkbox-group.tsx + radio-group.tsx. Rows are 36px, px-3,
// gap-2, fluid-hovered; the label swaps to semibold when selected (an
// invisible semibold twin keeps the row width stable, like the source's
// stacked spans). Checked rows sit on merged bg-active blocks — contiguous
// selections share one rounded block (use-merge-split), which this ports
// as one rect per contiguous run springing with the moderate tier.

// MARK: - Merged selection blocks

/// One bg-active block per contiguous run of checked indices, drawn in the
/// enclosing FluidContainer's coordinate space. React's merge-split runs a
/// two-block converge choreography; at rest and for single-row changes this
/// reads identically — a rounded block spanning the run.
struct FluidSelectionBlocks: View {
    let hover: FluidHover
    let checked: Set<Int>
    var radius: CGFloat = FluidShape.rounded.bg
    var mergedRadius: CGFloat = FluidShape.rounded.merged

    /// Contiguous index runs, each mapped to its union rect.
    private var blocks: [CGRect] {
        var runs: [(lo: Int, hi: Int)] = []
        for i in checked.sorted() {
            if let last = runs.last, i == last.hi + 1 {
                runs[runs.count - 1].hi = i
            } else {
                runs.append((i, i))
            }
        }
        return runs.compactMap { run in
            var union: CGRect?
            for i in run.lo...run.hi {
                union = union?.union(hover.rects[i] ?? .zero) ?? hover.rects[i]
            }
            return union
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: mergedRadius, style: .continuous)
                    .fill(FluidTone.active)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .animation(FluidSpring.moderate, value: blocks)
        .animation(FluidSpring.moderate, value: checked)
    }
}

// MARK: - Row label

/// The two-span label: invisible semibold sizer + visible label that
/// emboldens when selected — selection never changes the row's width.
struct FluidRowLabel: View {
    let label: String
    let selected: Bool
    var lit: Bool = false
    var size: FluidSize = .default

    var body: some View {
        ZStack {
            Text(label)
                .font(.system(size: size.text, weight: .semibold))
                .hidden()
            Text(label)
                .font(.system(size: size.text, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected || lit ? FluidTone.foreground : FluidTone.mutedForeground)
        }
        .animation(.easeOut(duration: 0.08), value: selected)
    }
}

// MARK: - Checkbox group

/// `CheckboxGroup`: fluid-hover rows with merged checked blocks.
struct FluidCheckboxGroup<Content: View>: View {
    @Binding var checked: Set<Int>
    var size: FluidSize = .default
    @ViewBuilder var content: () -> Content

    @State private var hover = FluidHover(axis: .y)

    var body: some View {
        FluidContainer(hover: hover, radius: FluidShape.rounded.bg) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .background(alignment: .topLeading) {
            FluidSelectionBlocks(hover: hover, checked: checked)
        }
    }
}

/// `CheckboxItem` — toggles on click.
struct FluidCheckboxItem: View {
    let index: Int
    let label: String
    let checked: Bool
    var size: FluidSize = .default
    var onToggle: () -> Void = {}

    @Environment(\.fluidHover) private var hover
    private var isActive: Bool { hover?.activeIndex == index }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: size.gap) {
                FluidCheckSquare(checked: checked, hovered: isActive, compact: size == .compact)
                FluidRowLabel(label: label, selected: checked, lit: isActive, size: size)
            }
            .padding(.horizontal, size.px)
            .frame(height: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fluidItem(index)
    }
}

/// The 16px box: 1.5px border (border → neutral-400 hover → transparent
/// when checked), 5px radius, check draws in on selection.
struct FluidCheckSquare: View {
    let checked: Bool
    var hovered = false
    var compact = false

    private var side: CGFloat { compact ? 14 : 16 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
                .strokeBorder(
                    checked ? .clear : (hovered ? FluidTone.borderStrong : FluidTone.border),
                    lineWidth: 1.5
                )
            if checked {
                // M6 12L10 16L18 8 — draws on in 80ms, out in 40.
                CheckArm()
                    .stroke(
                        style: StrokeStyle(lineWidth: 2 * side / 16, lineCap: .round, lineJoin: .round)
                    )
                    .foregroundStyle(FluidTone.foreground)
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .animation(.easeOut(duration: 0.08), value: checked)
    }

    private struct CheckArm: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 16
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + 4 * s, y: rect.minY + 8 * s))
            p.addLine(to: CGPoint(x: rect.minX + 7 * s, y: rect.minY + 11 * s))
            p.addLine(to: CGPoint(x: rect.minX + 12 * s, y: rect.minY + 5.5 * s))
            return p
        }
    }
}

// MARK: - Radio group

/// `RadioGroup`: same rows as the checkbox group, one selection.
struct FluidRadioGroup<Content: View>: View {
    @Binding var selection: Int?
    var size: FluidSize = .default
    @ViewBuilder var content: () -> Content

    @State private var hover = FluidHover(axis: .y)

    var body: some View {
        FluidContainer(hover: hover, radius: FluidShape.rounded.bg) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .background(alignment: .topLeading) {
            FluidSelectionBlocks(
                hover: hover,
                checked: selection.map { [$0] } ?? []
            )
        }
    }
}

/// `RadioItem` — selects on click.
struct FluidRadioItem: View {
    let index: Int
    let label: String
    let selected: Bool
    var size: FluidSize = .default
    var onSelect: () -> Void = {}

    @Environment(\.fluidHover) private var hover
    private var isActive: Bool { hover?.activeIndex == index }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: size.gap) {
                FluidRadioDot(selected: selected, hovered: isActive, compact: size == .compact)
                FluidRowLabel(label: label, selected: selected, lit: isActive, size: size)
            }
            .padding(.horizontal, size.px)
            .frame(height: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fluidItem(index)
    }
}

/// The 16px circle: border like the checkbox's; selected swaps it for an
/// 8px fg dot that scales in (scale 0.3→1, spring.fast).
struct FluidRadioDot: View {
    let selected: Bool
    var hovered = false
    var compact = false

    private var side: CGFloat { compact ? 14 : 16 }

    var body: some View {
        ZStack {
            if !selected {
                Circle()
                    .strokeBorder(
                        hovered ? FluidTone.borderStrong : FluidTone.border,
                        lineWidth: 1.5
                    )
            }
            if selected {
                Circle()
                    .fill(FluidTone.foreground)
                    .frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: side, height: side)
        .animation(FluidSpring.fast, value: selected)
    }
}

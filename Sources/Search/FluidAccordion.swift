import SwiftUI

// Accordion — accordion.tsx. Trigger rows are fluid-hover items; open
// items carry an accent/20 tint ("trigger" mode shows it only while that
// trigger is hovered, "item" mode tints the whole item persistently —
// the source's default). Panels spring open on the fast tier — height to
// a measured target, opacity running ahead so the body dissolves rather
// than slicing. Keyboard: triggers are roving-tabindex buttons —
// arrows wrap through the enabled rows, Home/End jump the ends, and a
// moving ring-1 marks the focused row.

fileprivate struct FluidAccordionCtx {
    var open: (String) -> Bool
    var toggle: (String) -> Void
    var highlight: FluidAccordionHighlight
    var size: FluidSize
    /// Roving focus — the focused item's index (Radix's roving tabindex).
    var focused: FocusState<Int?>.Binding
    /// Enabled item indices in row order — arrow nav skips disabled rows.
    var navIndices: () -> [Int]
}

enum FluidAccordionHighlight { case trigger, item }

fileprivate struct FluidAccordionCtxKey: EnvironmentKey {
    static let defaultValue: FluidAccordionCtx? = nil
}

extension EnvironmentValues {
    fileprivate var fluidAccordion: FluidAccordionCtx? {
        get { self[FluidAccordionCtxKey.self] }
        set { self[FluidAccordionCtxKey.self] = newValue }
    }
    /// Panel heights each item reports, so the group can skip re-measuring.
    var fluidAccordionHeights: [Int: CGFloat] {
        get { self[FluidAccordionHeightsKeyEnv.self] }
        set { self[FluidAccordionHeightsKeyEnv.self] = newValue }
    }
}

private struct FluidAccordionHeightsKeyEnv: EnvironmentKey {
    static let defaultValue: [Int: CGFloat] = [:]
}

/// Full-item rects of open items, in the container's space — used for the
/// expanded tint and the dead zone that suppresses hover inside panels.
/// A closed item emits CGRect.null so the merge drops it.
private struct FluidAccordionFullRectsKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// Height reports from each panel's always-mounted content.
private struct FluidAccordionHeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// Disabled flags by index — the roving focus skips these rows (Radix
/// drops disabled triggers from its tab order).
private struct FluidAccordionDisabledKey: PreferenceKey {
    static var defaultValue: [Int: Bool] { [:] }
    static func reduce(value: inout [Int: Bool], nextValue: () -> [Int: Bool]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// `Accordion`/`AccordionGroup` — single or multiple open items.
struct FluidAccordion<Content: View>: View {
    @Binding var open: Set<String>
    var collapsible = true
    var single = false
    /// The source's `highlight` — "item" (default) tints open items as
    /// blocks; "trigger" scopes it to the hovered open row.
    var highlight: FluidAccordionHighlight = .item
    /// `size` pins every row to one ladder step; omitted, rows follow the
    /// surrounding fluidSize (the source's optional SizeProvider wrap).
    var size: FluidSize? = nil
    @ViewBuilder var content: () -> Content

    @State private var hover = FluidHover(axis: .y)
    @State private var fullRects: [Int: CGRect] = [:]
    @State private var heights: [Int: CGFloat] = [:]
    @State private var disabledIndices: Set<Int> = []
    @FocusState private var focusedIndex: Int?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidSize) private var ambientSize

    /// The focus ring's target — the focused row's measured rect.
    private var focusRect: CGRect? {
        focusedIndex.flatMap { hover.rects[$0] }
    }

    var body: some View {
        FluidContainer(hover: hover, radius: FluidShape.rounded.bg) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        // w-72 max-w-full — 288 unless the box is narrower.
        .frame(minWidth: 0, idealWidth: 288, maxWidth: 288, alignment: .leading)
        .background(alignment: .topLeading) { expandedTints }
        .background(alignment: .topLeading) { focusRing }
        .animation(FluidSpring.fast, value: focusRect)
        .environment(\.fluidAccordion, FluidAccordionCtx(
            open: { open.contains($0) },
            toggle: toggle,
            highlight: highlight,
            size: size ?? ambientSize,
            focused: $focusedIndex,
            navIndices: {
                hover.rects.keys.sorted().filter { !disabledIndices.contains($0) }
            }
        ))
        .environment(\.fluidAccordionHeights, heights)
        .onPreferenceChange(FluidAccordionFullRectsKey.self) { rects in
            fullRects = rects.filter { !$0.value.isNull }
            // Cursor inside an open panel (below its trigger) picks nothing.
            hover.deadRects = fullRects.compactMap { idx, full in
                guard let t = hover.rects[idx] else { return nil }
                return CGRect(x: full.minX, y: t.maxY,
                              width: full.width, height: max(0, full.maxY - t.maxY))
            }
        }
        .onPreferenceChange(FluidAccordionHeightsKey.self) { heights = $0 }
        .onPreferenceChange(FluidAccordionDisabledKey.self) { flags in
            disabledIndices = Set(flags.filter { $0.value }.map(\.key))
        }
        // Keyboard focus lights the row like pointer hover does
        // (the group's onFocus → setActiveIndex).
        .onChange(of: focusedIndex) { _, f in hover.activeIndex = f }
    }

    private func toggle(_ value: String) {
        withAnimation(FluidSpring.fast) {
            if open.contains(value) {
                if collapsible { open.remove(value) }
            } else {
                if single { open = [value] } else { open.insert(value) }
            }
        }
    }

    /// accent/20 blocks: "item" tints each open item's whole rect
    /// persistently; "trigger" only tints the hovered open trigger row.
    /// The fill dims to 70% while the pointer sits on a non-open row.
    @ViewBuilder
    private var expandedTints: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(fullRects.keys.sorted()), id: \.self) { idx in
                let rect = highlight == .item
                    ? fullRects[idx]
                    : (hover.activeIndex == idx ? hover.rects[idx] : nil)
                if let rect {
                    RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                        .fill(FluidTone.accent.opacity(scheme == .dark ? 0.12 : 0.20))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                        .opacity(hoveringNonOpen ? 0.7 : 1)
                }
            }
        }
        .animation(FluidSpring.moderate, value: hover.activeIndex)
    }

    /// Hovering a trigger that isn't open — the open tints back off.
    private var hoveringNonOpen: Bool {
        guard let active = hover.activeIndex else { return false }
        return fullRects[active] == nil
    }

    /// The roving focus ring — 1px --focus-ring 2px out around the focused
    /// trigger, gliding between rows on spring.fast.
    @ViewBuilder
    private var focusRing: some View {
        if let r = focusRect {
            RoundedRectangle(cornerRadius: FluidShape.rounded.focusRing, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .frame(width: r.width + 4, height: r.height + 4)
                .position(x: r.midX, y: r.midY)
                .transition(.opacity)
        }
    }
}

// MARK: - Item

/// `AccordionItem` + `AccordionTrigger` + `AccordionContent` in one —
///
///     FluidAccordionItem(index: 0, value: "one") {
///         Text("What is fluid hover?")
///     } panel: {
///         Text("A highlight that follows your cursor.")
///     }
struct FluidAccordionItem<Trigger: View, Panel: View>: View {
    let index: Int
    let value: String
    var disabled = false
    @ViewBuilder var trigger: () -> Trigger
    @ViewBuilder var panel: () -> Panel

    @Environment(\.fluidAccordion) private var group
    @Environment(\.fluidAccordionHeights) private var heights
    @Environment(\.fluidHover) private var hover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { group?.open(value) ?? false }
    private var size: FluidSize { group?.size ?? .default }
    private var isActive: Bool { hover?.activeIndex == index }
    private var lit: Bool { isOpen || isActive }

    /// spring.fast.exit for the collapse — 60ms, no overshoot.
    private var heightSpring: Animation {
        isOpen ? FluidSpring.fast : .spring(duration: 0.06, bounce: 0)
    }
    /// Opacity dissolves ahead of the height — 60ms open, 40ms close
    /// (the source's opacity tween per direction, framer's default ease).
    private var opacityTween: Animation {
        .timingCurve(0.25, 0.1, 0.35, 1, duration: isOpen ? 0.06 : 0.04)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                group?.toggle(value)
            } label: {
                HStack(spacing: size.gap) {
                    // Dual-layer label: invisible semibold sizer under the
                    // visible label so emboldening never reflows the row.
                    ZStack {
                        trigger()
                            .font(.system(size: size.text, weight: .semibold))
                            .hidden()
                        trigger()
                            .font(.system(size: size.text, weight: isOpen ? .semibold : .regular))
                            .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FluidIcon("chevron.right", size: size.icon, bold: lit)
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(FluidSpring.fast, value: isOpen)
                }
                .padding(.horizontal, size.px)
                .padding(.vertical, size == .compact ? 4 : 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .focusable(!disabled)
            .modifier(FluidAccordionFocus(group: group, index: index))
            .fluidItem(index)
            .preference(key: FluidAccordionDisabledKey.self, value: [index: disabled])

            // Panel: always mounted at its ideal height (fixedSize beats
            // the clamp's zero-height proposal), measured, then clipped.
            panel()
                .font(.system(size: size.text))
                .foregroundStyle(FluidTone.mutedForeground)
                .padding(.horizontal, size.px)
                .padding(.top, 4)
                .padding(.bottom, size == .compact ? 10 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: FluidAccordionHeightsKey.self,
                            value: [index: geo.size.height]
                        )
                    }
                )
                .opacity(isOpen ? 1 : 0)
                .animation(reduceMotion ? nil : opacityTween, value: isOpen)
                .frame(height: isOpen ? heights[index] : 0, alignment: .top)
                .clipped()
                .animation(reduceMotion ? nil : heightSpring, value: isOpen)
        }
        // Full-item rect for the tint + dead zone; .null tombstones it
        // when the item closes so the merged map drops the entry.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FluidAccordionFullRectsKey.self,
                    value: isOpen && hover != nil
                        ? [index: geo.frame(in: .named(hover!.space))]
                        : [index: .null]
                )
            }
        )
    }
}

/// Roving-tabindex wiring for one trigger: `.focused(equals:)` plus the
/// arrow/Home/End moves — through the OPTIONAL group context, since an
/// item outside a group has no roving set to join.
private struct FluidAccordionFocus: ViewModifier {
    let group: FluidAccordionCtx?
    let index: Int

    func body(content: Content) -> some View {
        if let group {
            content
                .focused(group.focused, equals: index)
                .onKeyPress(.upArrow) { move(-1, in: group); return .handled }
                .onKeyPress(.downArrow) { move(1, in: group); return .handled }
                .onKeyPress(.home) { edge(first: true, in: group); return .handled }
                .onKeyPress(.end) { edge(first: false, in: group); return .handled }
        } else {
            content
        }
    }

    /// Radix wraps: past the last row lands back on the first.
    private func move(_ dir: Int, in group: FluidAccordionCtx) {
        let idxs = group.navIndices()
        guard let pos = idxs.firstIndex(of: index) else { return }
        group.focused.wrappedValue =
            idxs[(pos + dir + idxs.count) % idxs.count]
    }

    private func edge(first: Bool, in group: FluidAccordionCtx) {
        let idxs = group.navIndices()
        group.focused.wrappedValue = first ? idxs.first : idxs.last
    }
}

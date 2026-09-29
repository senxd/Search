import AppKit
import SwiftUI

// Tabs — the segmented control from tabs.tsx. A muted track (segmentPad +
// segmentItem add up to the ladder height), a surface indicator that
// springs with the moderate tier, and the hover fill that always enters
// from wherever the selected pill sits.
//
// The source rides Radix Tabs with activationMode="automatic": roving
// arrows — Left/Right horizontally, Up/Down under `orientation: .vertical`,
// plus Home/End — loop across the enabled triggers and ACTIVATE the landed
// tab; Enter/Space activate the focused one (tabs.tsx:149). Every enabled
// tab is a focus stop here — the source's roving tabindex becomes every
// row being a stop, the sidebar menu's documented divergence — and the
// source's onFocus-then-activate is mirrored, so a Tab landing on an
// unselected tab selects it. The traveling ring is the source's focusRect
// overlay — 1px --focus-ring border 2px out, shape.focusRing — gated on
// keyboard modality (:focus-visible): keyDown arms it, mouseDown clears.
//
// Content panels are linked by FluidTabPanel below — TabsPrimitive.Content
// flattened to (index, selection) instead of context, since SwiftUI panels
// sit beside the strip rather than inside it.

struct FluidTabs: View {
    /// TabItem's shape — `label` plus the optional leading `icon` (an SF
    /// Symbol name; the source takes an IconComponent).
    typealias Item = (icon: String?, label: String)

    private let tabs: [Item]
    @Binding var selection: Int
    /// Omitted, follows the ambient `\.fluidSize` (the source's `size?`
    /// falling back to the surrounding SizeProvider).
    var size: FluidSize? = nil
    /// The substrate the tabs sit on — the indicator lifts 3 levels above
    /// it (1 above the muted track + 2 for pop), capped at 8.
    var substrate: Int = 1
    /// Disabled TabItems — skipped by roving nav and activation; the hover
    /// pick still lights them (the source doesn't gate useFluidHover on
    /// disabled). It paints no disabled styling: inert, not dimmed.
    var disabledIndices: Set<Int> = []
    /// Radix `orientation`: the strip stays a horizontal inline-flex in
    /// both modes — only the arrow-key mapping flips (Up/Down under
    /// `orientation: .vertical`), matching tabs.tsx.
    var orientation: Axis = .horizontal

    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var ambientSize
    @State private var hover: FluidHover
    @FocusState private var focused: Int?
    /// :focus-visible — the ring draws only while the last input was a key.
    @State private var keyboard = false
    /// isMouseInside — picks the hover fill's exit (fade vs glide home).
    @State private var mouseInside = false
    /// The exit copy of the hover fill — spawned as the pick departs so the
    /// removal animates (source's AnimatePresence exit prop).
    @State private var vanish: (from: CGRect, to: CGRect, slide: Bool, seq: Int)? = nil
    @State private var vanishSeq = 0
    /// The pill's 80ms opacity dim runs on its own transaction — a
    /// `.animation` value-watch on the same view would let the hover flip
    /// clip the rect's moderate glide (they co-change on click).
    @State private var dimmed = false
    @State private var monitors: [Any] = []
    @State private var viewRef = FluidTabsViewRef()

    /// Full item model — TabItem's { value, icon, label } mapped onto the
    /// port's index-based API (the index stands in for Radix's value).
    init(items: [Item], selection: Binding<Int>, size: FluidSize? = nil,
         substrate: Int = 1, disabledIndices: Set<Int> = [],
         orientation: Axis = .horizontal) {
        self.tabs = items
        self._selection = selection
        self.size = size
        self.substrate = substrate
        self.disabledIndices = disabledIndices
        self.orientation = orientation
        // The source's TabsList is inline-flex + axis:"x" regardless of
        // orientation — orientation only remaps the roving keys
        // (tabs.tsx:203,305). The strip stays a row.
        self._hover = State(initialValue: FluidHover(axis: .x))
    }

    /// Label-only items — the convenience the original port shipped.
    @_disfavoredOverload
    init(items: [String], selection: Binding<Int>, size: FluidSize? = nil,
         substrate: Int = 1, disabledIndices: Set<Int> = [],
         orientation: Axis = .horizontal) {
        self.init(items: items.map { (icon: nil, label: $0) }, selection: selection,
                  size: size, substrate: substrate,
                  disabledIndices: disabledIndices, orientation: orientation)
    }

    private var resolved: FluidSize { size ?? ambientSize }
    private var indicatorLevel: Int { min(substrate + 3, 8) }
    private var selectedRect: CGRect? { hover.rects[selection] }
    private var hoverRect: CGRect? {
        guard let i = hover.activeIndex, i != selection else { return nil }
        return hover.rects[i]
    }
    /// The ring's target — focusRect, drawn only under keyboard modality.
    private var ringIndex: Int? { keyboard ? focused : nil }
    private var ringRect: CGRect? { ringIndex.flatMap { hover.rects[$0] } }

    var body: some View {
        // inline-flex — the source's List stays a row at any orientation;
        // only arrow-key mapping changes (tabs.tsx:305).
        HStack(spacing: 0) { strip }
        .padding(resolved.segmentPad)
        .coordinateSpace(name: hover.space)
        .background(alignment: .topLeading) { overlays }
        .background(
            RoundedRectangle(cornerRadius: shape.container, style: .continuous)
                .fill(FluidTone.muted)
        )
        // focusRect is z-20 in the source — the ring rides above the tabs.
        // The presence watch keys the removal to spring.fast.exit (60ms);
        // tab-to-tab glides stay on the fast watches below.
        .overlay(alignment: .topLeading) {
            focusRing
                .animation(.easeOut(duration: 0.06), value: ringRect != nil)
        }
        .overlay(alignment: .topLeading) {
            FluidTabsProbe(ref: viewRef).frame(width: 0, height: 0)
        }
        .animation(FluidSpring.fast, value: ringIndex)
        .animation(FluidSpring.fast, value: ringRect)
        .onContinuousHover(coordinateSpace: .named(hover.space)) { phase in
            switch phase {
            case .active(let point):
                mouseInside = true
                hover.moved(to: point)
            case .ended:
                mouseInside = false
                hover.exited()
            }
        }
        .environment(\.fluidHover, hover)
        // No isItemDisabled on the pick — the source passes none
        // (tabs.tsx:203), so the hover pill still lights disabled tabs;
        // only select()/nav/focusable gate them.
        .onAppear { installMonitors() }
        .onDisappear { monitors.forEach(NSEvent.removeMonitor); monitors = [] }
        .onChange(of: focused) { _, new in
            if let i = new {
                // onFocus: hoveredIndex follows focus — and under
                // activationMode="automatic" the landed tab selects.
                hover.activeIndex = i
                select(i)
            } else if !mouseInside {
                // onBlur clears the keyboard-lit pick only when the
                // pointer isn't inside to reclaim it.
                hover.activeIndex = nil
            }
        }
        .onChange(of: hoverRect) { old, new in
            // The fill's exit (AnimatePresence): watching hoverRect — the
            // rendered fill itself — means the vanish only spawns when a
            // visible fill actually departs (a focused-tab selection can't
            // flash a phantom). Pointer still inside = fast fade in place;
            // pointer left the strip = glide home to the selected pill
            // (spring.moderate) under a 60ms fade.
            if let o = old, new == nil {
                spawnVanish(from: o, to: selectedRect ?? o, slide: !mouseInside)
            }
        }
        // opacity: {duration: 0.08} — the dim's own channel, so the rect
        // keeps moderate exclusively.
        .onChange(of: hoverRect != nil) { _, hov in
            withAnimation(.easeOut(duration: 0.08)) { dimmed = hov }
        }
    }

    @ViewBuilder private var strip: some View {
        ForEach(Array(tabs.enumerated()), id: \.offset) { i, item in
            tab(item, index: i)
        }
    }

    @ViewBuilder
    private var overlays: some View {
        // Selected pill — the surface card that travels under the labels.
        if let r = selectedRect {
            TabPill(rect: r, level: indicatorLevel, radius: shape.bg)
                .opacity(dimmed ? 0.85 : 1)
                .animation(FluidSpring.moderate, value: r)
        }
        // Hover fill — enters from the selected rect; departures are
        // covered by `vanish` so exits animate instead of popping.
        if let h = hoverRect, let s = selectedRect {
            TabFill(rect: h, from: s, radius: shape.bg)
                .id(hover.session)
                .transition(.identity)
        }
        if let v = vanish {
            FluidTabVanish(from: v.from, to: v.to, slide: v.slide,
                           radius: shape.bg, fill: FluidTone.hover) {
                if vanish?.seq == v.seq { vanish = nil }
            }
            .id(v.seq)
        }
    }

    @ViewBuilder
    private var focusRing: some View {
        if let r = ringRect {
            RoundedRectangle(cornerRadius: shape.focusRing, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .frame(width: r.width + 4, height: r.height + 4)
                .position(x: r.midX, y: r.midY)
                // initial={false} — the ring mounts instantly; only the
                // exit fades.
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func spawnVanish(from: CGRect, to: CGRect, slide: Bool) {
        vanishSeq += 1
        vanish = (from, to, slide, vanishSeq)
    }

    /// Radix's activate — the source's optimisticIdx jump is free here:
    /// the binding lands synchronously, so the pill just springs across.
    private func select(_ i: Int) {
        guard !disabledIndices.contains(i) else { return }
        withAnimation(FluidSpring.moderate) { selection = i }
    }

    /// Roving arrows — Radix loops; Home/End pin the ends; the wrong-axis
    /// arrows fall through (.ignored) like Radix's orientation gate.
    /// Automatic activation rides onChange(focused) — arrows only move
    /// focus, the landing selects.
    private func keyNav(_ press: KeyPress, at index: Int) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty
        else { return .ignored }
        let order = (0..<tabs.count).filter { !disabledIndices.contains($0) }
        guard order.count > 1, let cur = order.firstIndex(of: index) else { return .ignored }
        let n = order.count
        let target: Int
        switch press.key {
        case .leftArrow:
            guard orientation == .horizontal else { return .ignored }
            target = order[(cur - 1 + n) % n]
        case .rightArrow:
            guard orientation == .horizontal else { return .ignored }
            target = order[(cur + 1) % n]
        case .upArrow:
            guard orientation == .vertical else { return .ignored }
            target = order[(cur - 1 + n) % n]
        case .downArrow:
            guard orientation == .vertical else { return .ignored }
            target = order[(cur + 1) % n]
        case .home: target = order.first ?? index
        case .end: target = order.last ?? index
        default: return .ignored
        }
        keyboard = true
        focused = target
        return .handled
    }

    /// The modality pair — a keyDown in this window arms keyboard modality
    /// (:focus-visible), a mouse click returns to pointer. Window-scoped,
    /// the same pattern as FluidSlider's installMonitors.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak viewRef] event in
            if let vw = viewRef?.view?.window, event.window === vw { keyboard = false }
            return event
        }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewRef] event in
            if let vw = viewRef?.view?.window, event.window === vw { keyboard = true }
            return event
        }!)
    }

    private func tab(_ item: Item, index: Int) -> some View {
        let disabled = disabledIndices.contains(index)
        let isSelected = selection == index
        let active = hover.activeIndex == index || isSelected
        return Button {
            select(index)
        } label: {
            HStack(spacing: resolved.gap) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: resolved.icon,
                                      weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? FluidTone.foreground : FluidTone.mutedForeground)
                        // transition-[color,stroke-width] duration-80 — its
                        // own channel so select()'s moderate wrap can't slow
                        // the tint (tabs.tsx:476).
                        .animation(.easeOut(duration: 0.08), value: active)
                }
                FluidTabLabel(item.label, textSize: resolved.text,
                              selected: isSelected, active: active)
            }
            // px-3 is fixed (not ladder-bound) in the source; the fixed
            // segmentItem height keeps the text-box-trim substitute from
            // shrinking the tab.
            .padding(.horizontal, 12)
            .frame(height: resolved.segmentItem)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(hover.space))
        } action: { frame in
            // Skip the transient zero frame — FluidItem's rule.
            guard frame != .zero, hover.rects[index] != frame else { return }
            hover.rects[index] = frame
        }
        .onDisappear { hover.rects[index] = nil }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .focusable(!disabled)
        .focused($focused, equals: index)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { keyNav($0, at: index) }
        // Radix Trigger activation — Space fires on key-up, Enter on down.
        .onKeyPress(.space, phases: [.down, .repeat]) { _ in .handled }
        .onKeyPress(.space, phases: .up) { _ in self.select(index); return .handled }
        .onKeyPress(.return, phases: [.down, .repeat]) { _ in self.select(index); return .handled }
    }

    /// The selected surface — surfaceClasses(indicatorLevel): bg-surface-N
    /// + shadow-surface-N (the shared fluidSurface recipe scales the drop
    /// ladder with the level; a hardcoded recipe was pinned at shadow-3).
    /// Springs with the moderate tier as `rect` changes.
    private struct TabPill: View {
        let rect: CGRect
        let level: Int
        let radius: CGFloat

        var body: some View {
            Color.clear
                .fluidSurface(level, radius: radius)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    /// The traveling hover fill: mounts at `from` and springs to `rect` —
    /// the same entry the FluidHighlight performs, at 40% opacity.
    private struct TabFill: View {
        let rect: CGRect
        let from: CGRect
        let radius: CGFloat
        @State private var current: CGRect
        @State private var opacity = 0.0

        init(rect: CGRect, from: CGRect, radius: CGFloat) {
            self.rect = rect; self.from = from; self.radius = radius
            _current = State(initialValue: from)
        }

        var body: some View {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(FluidTone.hover)
                .frame(width: current.width, height: current.height)
                .position(x: current.midX, y: current.midY)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.08)) { opacity = 0.4 }
                    withAnimation(FluidSpring.fast) { current = rect }
                }
                .onChange(of: rect) { _, new in
                    withAnimation(FluidSpring.fast) { current = new }
                }
        }
    }

    /// The dual-layer label — an invisible semibold twin reserves the
    /// width so the animated weight never reflows the tab (tabs.tsx:483-504).
    private struct FluidTabLabel: View {
        let label: String
        let textSize: CGFloat
        let selected: Bool
        let active: Bool

        init(_ label: String, textSize: CGFloat, selected: Bool, active: Bool) {
            self.label = label; self.textSize = textSize
            self.selected = selected; self.active = active
        }

        var body: some View {
            ZStack(alignment: .leading) {
                // aria-hidden — the invisible semibold sizer reserves the
                // width; the visible twin announces the label.
                Text(label).fontWeight(.semibold).opacity(0)
                    .accessibilityHidden(true)
                Text(label)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(active ? FluidTone.foreground : FluidTone.mutedForeground)
            }
            .font(.system(size: textSize))
            .lineLimit(1)
            .fixedSize()
            .animation(.easeOut(duration: 0.08), value: active)
            .animation(.easeOut(duration: 0.08), value: selected)
        }
    }
}

// MARK: - TabPanel

/// TabPanel — TabsPrimitive.Content (tabs.tsx:520-531). Children mount
/// only while their tab is selected, matching Radix's Presence wrapper;
/// the source's context-carried value arrives here as the explicit pair
/// (index, selection) — the same shape TabsSubtlePanel already uses.
struct FluidTabPanel<Content: View>: View {
    let index: Int
    /// The bound selection — the shared value Radix carries in context.
    let selection: Int
    @ViewBuilder var content: () -> Content

    init(index: Int, selection: Int, @ViewBuilder content: @escaping () -> Content) {
        self.index = index
        self.selection = selection
        self.content = content
    }

    var body: some View {
        if selection == index {
            content()
        }
    }
}

// MARK: - Exit fill + window probe

/// The hover fill's departure — the source's AnimatePresence exit prop.
/// Pointer still inside (`slide` false): a fast fade in place. Pointer
/// left the strip: glides back onto the selected rect (spring.moderate)
/// under a 60ms fade. Removes itself once the animations have settled.
private struct FluidTabVanish: View {
    let from: CGRect
    let to: CGRect
    let slide: Bool
    let radius: CGFloat
    let fill: Color
    let onDone: () -> Void

    @State private var current: CGRect
    @State private var opacity = 0.4

    init(from: CGRect, to: CGRect, slide: Bool, radius: CGFloat,
         fill: Color, onDone: @escaping () -> Void) {
        self.from = from; self.to = to; self.slide = slide
        self.radius = radius; self.fill = fill; self.onDone = onDone
        _current = State(initialValue: from)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: current.width, height: current.height)
            .position(x: current.midX, y: current.midY)
            .opacity(opacity)
            .onAppear {
                if slide { withAnimation(FluidSpring.moderate) { current = to } }
                // Both exit paths fade at spring.fast.exit — 60ms.
                withAnimation(.easeOut(duration: 0.06)) { opacity = 0 }
            }
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled { onDone() }
            }
    }
}

private final class FluidTabsViewRef { var view: NSView? }

/// Reports the hosting NSView so the modality monitors can scope to the
/// tabs' own window (FluidSlider's WindowProbe pattern).
private struct FluidTabsProbe: NSViewRepresentable {
    let ref: FluidTabsViewRef
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { ref.view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { ref.view = nsView }
}

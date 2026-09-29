import AppKit
import SwiftUI

// TabsSubtle — the pill tabs without a track (tabs-subtle.tsx). A bg-active
// block sits under the selected tab (spring.moderate); hovering another tab
// slides a 40% copy of it under the cursor (spring.fast) and the selected
// block dims to 0.8. `activeLabel` collapses unselected tabs to their icon,
// the label springing open when the tab is picked.
//
// The source merges Radix Root into List via asChild and runs
// activationMode="manual": roving arrows (Left/Right + Home/End, looping)
// move focus only — Enter/Space selects (tabs-subtle.tsx:127-133). Every
// tab is a focus stop here — the source's roving tabindex becomes every
// row being a stop, the sidebar menu's documented divergence. The
// traveling ring is the focusRect overlay — 1px --focus-ring 2px out —
// gated on keyboard modality (:focus-visible): keyDown arms, mouseDown
// clears. The strip scrolls horizontally on overflow (overflow-x-auto,
// scrollbar-hide) and the ±4 margin/padding pair keeps the ring's 2px
// outset out of the scroll clip.
//
// Panels are linked by FluidTabsSubtlePanel below — the source's
// deliberately un-Radix'd tabpanel, kept in sync by the caller passing
// the same `selection` + `idPrefix`.

struct FluidTabsSubtle: View {
    let items: [(icon: String?, label: String)]
    @Binding var selection: Int
    /// When true, unselected icon tabs render icon-only.
    var activeLabel = false
    /// Omitted, follows the ambient `\.fluidSize` (the source's `size?`
    /// falling back to the surrounding SizeProvider).
    var size: FluidSize? = nil
    /// ARIA link ids in the source — here it stamps accessibilityIdentifier
    /// "<prefix>-tab-N" so a FluidTabsSubtlePanel names back to its tab.
    var idPrefix: String? = nil

    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var ambientSize
    @State private var hover = FluidHover(axis: .x)
    @FocusState private var focused: Int?
    /// :focus-visible — the ring draws only while the last input was a key.
    @State private var keyboard = false
    /// isMouseInside — picks the hover pill's exit (fade vs glide home).
    @State private var mouseInside = false
    /// The exit copy of the hover pill — spawned as the pick departs so the
    /// removal animates (source's AnimatePresence exit prop).
    @State private var vanish: (from: CGRect, to: CGRect, slide: Bool, seq: Int)? = nil
    @State private var vanishSeq = 0
    /// The block's 80ms opacity dim runs on its own transaction — see
    /// FluidTabs; co-changing `.animation` watches would clip the glide.
    @State private var dimmed = false
    @State private var monitors: [Any] = []
    @State private var viewRef = FluidTabsSubtleViewRef()

    private var resolved: FluidSize { size ?? ambientSize }
    private var selectedRect: CGRect? { hover.rects[selection] }
    private var hoverRect: CGRect? {
        guard let i = hover.activeIndex, i != selection else { return nil }
        return hover.rects[i]
    }
    /// The ring's target — focusRect, drawn only under keyboard modality.
    private var ringIndex: Int? { keyboard ? focused : nil }
    private var ringRect: CGRect? { ringIndex.flatMap { hover.rects[$0] } }

    var body: some View {
        // overflow-x-auto + scrollbar-hide — the strip scrolls on overflow
        // instead of compressing. The reader backs the browser's native
        // focus scrolling: an arrowed-to tab may sit offscreen and the
        // List scrolls it into view (tabs-subtle.tsx:143-153).
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        tab(item, index: i)
                    }
                }
                // The 4px inner pad gives the 2px-outset focus ring room inside
                // the scroll clip (the source's p-1 half of -m-1 p-1).
                .padding(4)
                // The pick listens on the padded content — inside the view
                // that names hover.space below. A named space resolves only
                // for the naming view's own subtree, so this handler on the
                // outer ScrollView fell back to local space and the pick
                // drifted left by the scroll offset. Nothing is lost inside
                // the clip: off-viewport events can't arrive anyway.
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
                // Content space, not the viewport: rects measured here don't
                // shift during scroll, so the indicators ride the tabs rigidly
                // (the source renders them inside the scrolling List) and the
                // scrollport clips them for free.
                .coordinateSpace(name: hover.space)
                .background(alignment: .topLeading) { overlays }
                // focusRect is z-20 in the source — the ring rides above the
                // tabs. The presence watch keys the removal to spring.fast.exit
                // (60ms); tab-to-tab glides stay on the fast watches below.
                .overlay(alignment: .topLeading) {
                    focusRing
                        .animation(.easeOut(duration: 0.06), value: ringRect != nil)
                }
            }
            // The -m-1 half: reported box matches the content while the strip
            // bleeds 4px past it — the ring room the source carves with
            // negative margins.
            .padding(-4)
            .overlay(alignment: .topLeading) {
                FluidTabsSubtleProbe(ref: viewRef).frame(width: 0, height: 0)
            }
            .animation(FluidSpring.fast, value: ringIndex)
            .animation(FluidSpring.fast, value: ringRect)
            .environment(\.fluidHover, hover)
            .onAppear { installMonitors() }
            .onDisappear { monitors.forEach(NSEvent.removeMonitor); monitors = [] }
            .onChange(of: focused) { _, new in
                if let i = new {
                    // onFocus: hoveredIndex follows keyboard focus — the hover
                    // pill glides to the arrowed-to tab while manual mode
                    // waits for Enter/Space. The focused trigger also scrolls
                    // into view natively in the source; SwiftUI doesn't do
                    // that, so the proxy reveals it on the fast tier.
                    hover.activeIndex = i
                    withAnimation(FluidSpring.fast) { proxy.scrollTo(i) }
                } else if !mouseInside {
                    // onBlur clears the keyboard-lit pick only when the
                    // pointer isn't inside to reclaim it.
                    hover.activeIndex = nil
                }
            }
            .onChange(of: hoverRect) { old, new in
                // The pill's exit (AnimatePresence): watching hoverRect — the
                // rendered pill itself — means the vanish only spawns when a
                // visible pill actually departs (a focused-tab selection can't
                // flash a phantom). Pointer still inside = fast fade in place;
                // pointer left the strip = glide home to the selected block
                // (spring.moderate) under a 60ms fade.
                if let o = old, new == nil {
                    spawnVanish(from: o, to: selectedRect ?? o, slide: !mouseInside)
                }
            }
            // opacity: {duration: 0.08} — the dim's own channel.
            .onChange(of: hoverRect != nil) { _, hov in
                withAnimation(.easeOut(duration: 0.08)) { dimmed = hov }
            }
        }
    }

    @ViewBuilder
    private var overlays: some View {
        // Selected block — bg-active, moderate spring between tabs, dims
        // while the cursor previews a different tab.
        if let r = selectedRect {
            RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                .fill(FluidTone.active)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .opacity(dimmed ? 0.8 : 1)
                .animation(FluidSpring.moderate, value: r)
        }
        // Hover pill — enters from the selected rect at 40%, fast spring;
        // departures are covered by `vanish` so exits animate.
        if let h = hoverRect, let s = selectedRect {
            SubtleHoverFill(rect: h, from: s, radius: shape.bg)
                .id(hover.session)
                .transition(.identity)
        }
        if let v = vanish {
            FluidSubtleVanish(from: v.from, to: v.to, slide: v.slide,
                              radius: shape.bg, fill: FluidTone.active) {
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
                // initial={false} — instant mount; only the exit fades.
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func spawnVanish(from: CGRect, to: CGRect, slide: Bool) {
        vanishSeq += 1
        vanish = (from, to, slide, vanishSeq)
    }

    /// Radix's activate — manual mode, so only clicks and Enter/Space land
    /// here; arrows move focus without selecting. The selection rides the
    /// block's tier — spring.moderate (tabs-subtle.tsx:185-189).
    private func select(_ i: Int) {
        withAnimation(FluidSpring.moderate) { selection = i }
    }

    /// Roving arrows — Radix loops; Home/End pin the ends; Up/Down fall
    /// through (.ignored), the horizontal list's orientation gate.
    private func keyNav(_ press: KeyPress, at index: Int) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty
        else { return .ignored }
        let n = items.count
        guard n > 1 else { return .ignored }
        let target: Int
        switch press.key {
        case .leftArrow: target = (index - 1 + n) % n
        case .rightArrow: target = (index + 1) % n
        case .home: target = 0
        case .end: target = n - 1
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

    private func tab(_ item: (icon: String?, label: String), index: Int) -> some View {
        let isSelected = selection == index
        let isActive = hover.activeIndex == index || isSelected
        let collapse = activeLabel && item.icon != nil
        return Button {
            select(index)
        } label: {
            HStack(spacing: collapse ? 0 : resolved.gap) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: resolved.icon, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? FluidTone.foreground : FluidTone.mutedForeground)
                        // transition-[color,stroke-width] duration-80 —
                        // its own channel so select()'s moderate wrap
                        // can't slow the tint.
                        .animation(.easeOut(duration: 0.08), value: isActive)
                }
                SubtleLabel(
                    item.label,
                    size: resolved,
                    selected: isSelected,
                    active: isActive,
                    // marginLeft only exists on the collapse path — the
                    // HStack spacing already carries the resting gap. The
                    // collapse lead is deliberately gap-1.5/gap-2 (6/8), not
                    // the ladder's gap (tabs-subtle.tsx:395).
                    show: !collapse || isSelected,
                    gap: collapse ? (resolved == .compact ? 6 : 8) : 0
                )
            }
            .padding(.horizontal, resolved.px)
            .frame(height: resolved.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // aria-label on collapsed icon-only tabs — unconditional here: the
        // hidden-width label text announces the same either way.
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(FluidTabsIdent(prefix: idPrefix, index: index))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(hover.space))
        } action: { frame in
            // Skip the transient zero frame — FluidItem's rule.
            guard frame != .zero, hover.rects[index] != frame else { return }
            hover.rects[index] = frame
        }
        .onDisappear { hover.rects[index] = nil }
        // scrollTo anchor — focus arrival scrolls an offscreen tab into view.
        .id(index)
        .focusable()
        .focused($focused, equals: index)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { keyNav($0, at: index) }
        // Manual activation — Space fires on key-up, Enter on down.
        .onKeyPress(.space, phases: [.down, .repeat]) { _ in .handled }
        .onKeyPress(.space, phases: .up) { _ in self.select(index); return .handled }
        .onKeyPress(.return, phases: [.down, .repeat]) { _ in self.select(index); return .handled }
    }

    /// The traveling 40% hover block — same entry as FluidHighlight but
    /// bg-active, matching the registry's subtle pill.
    private struct SubtleHoverFill: View {
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
                .fill(FluidTone.active)
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

    /// Dual-layer label, optionally collapsing to zero width when the tab
    /// isn't selected (the `activeLabel` icon-only mode).
    private struct SubtleLabel: View {
        let label: String
        let size: FluidSize
        let selected: Bool
        let active: Bool
        let show: Bool
        let gap: CGFloat
        /// Nil until the sizer reports — `width:'auto'` in the source
        /// (tabs-subtle.tsx:389), so a selected label never renders 0-wide
        /// for the first frame.
        @State private var labelW: CGFloat? = nil

        init(_ label: String, size: FluidSize, selected: Bool, active: Bool, show: Bool, gap: CGFloat) {
            self.label = label; self.size = size
            self.selected = selected; self.active = active
            self.show = show; self.gap = gap
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
            .font(.system(size: size.text))
            .fixedSize()
            // transition-[color,font-variation-settings] duration-80 —
            // the tint/weight channel keeps its 80ms regardless of the
            // transaction that drove the state change.
            .animation(.easeOut(duration: 0.08), value: active)
            .animation(.easeOut(duration: 0.08), value: selected)
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { labelW = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in labelW = w }
                }
            )
            .frame(width: show ? labelW : 0, alignment: .leading)
            .clipped()
            .padding(.leading, show ? gap : 0)
            // spring.fast owns the width/margin collapse.
            .animation(FluidSpring.fast, value: show)
            // The fade is its own channel — spring.fast's opacity exit is
            // 60ms (springs.ts:6, tabs-subtle.tsx:398-401).
            .opacity(show ? 1 : 0)
            .animation(.easeOut(duration: 0.06), value: show)
        }
    }
}

/// Stamps "<prefix>-tab-N"/"<prefix>-panel-N" only when the caller set a
/// prefix — an empty identifier is worse than none (it shadows a real
/// one upstream).
private struct FluidTabsIdent: ViewModifier {
    let prefix: String?
    let index: Int
    var kind = "tab"
    func body(content: Content) -> some View {
        if let prefix {
            content.accessibilityIdentifier("\(prefix)-\(kind)-\(index)")
        } else {
            content
        }
    }
}

// MARK: - Tabpanel

/// TabsSubtlePanel — the source's deliberately un-Radix'd tabpanel
/// (tabs-subtle.tsx:427-448): rendered outside <TabsSubtle>, kept in
/// sync by sharing `selection` + `idPrefix`. Children mount only while
/// selected — `{isSelected && children}` — and `hidden` + `tabIndex -1`
/// collapse to the conditional: an unmounted panel is unfocusable and
/// undisplayed by definition.
struct FluidTabsSubtlePanel<Content: View>: View {
    let index: Int
    /// The bound selection — pass the same value the strip is bound to.
    let selection: Int
    /// Links the panel's identifier ("<prefix>-panel-N") to its tab's
    /// ("<prefix>-tab-N") — the source's id/aria-controls pair.
    var idPrefix: String = ""
    @ViewBuilder var content: () -> Content

    init(index: Int, selection: Int, idPrefix: String = "",
         @ViewBuilder content: @escaping () -> Content) {
        self.index = index
        self.selection = selection
        self.idPrefix = idPrefix
        self.content = content
    }

    var body: some View {
        if selection == index {
            content()
                .modifier(FluidTabsIdent(prefix: idPrefix.isEmpty ? nil : idPrefix,
                                         index: index, kind: "panel"))
        }
    }
}

// MARK: - Exit fill + window probe

/// The hover pill's departure — the source's AnimatePresence exit prop.
/// Pointer still inside (`slide` false): a fast fade in place. Pointer
/// left the strip: glides back onto the selected rect (spring.moderate)
/// under a 60ms fade. Removes itself once the animations have settled.
private struct FluidSubtleVanish: View {
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

private final class FluidTabsSubtleViewRef { var view: NSView? }

/// Reports the hosting NSView so the modality monitors can scope to the
/// tabs' own window (FluidSlider's WindowProbe pattern).
private struct FluidTabsSubtleProbe: NSViewRepresentable {
    let ref: FluidTabsSubtleViewRef
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { ref.view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { ref.view = nsView }
}

import AppKit
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
    /// Row pointer-down: latches pointer modality and lands the focus —
    /// a click-focus isn't :focus-visible.
    var pressFocus: (Int) -> Void = { _ in }
    /// Row pointer-up.
    var endPress: () -> Void = {}
    /// A handled nav/activation key arms keyboard modality — the ring and
    /// the focus-lit hover only show under it (:focus-visible,
    /// accordion.tsx:389-393).
    var armNav: () -> Void = {}
}

/// The standalone `Accordion`'s context (accordion.tsx:603) — open state
/// and the roving focus, without the group's fluid-hover pick. Items
/// under it self-render their hover fill, open tint, and focus ring.
fileprivate struct FluidAccordionStandaloneCtx {
    var open: (String) -> Bool
    var toggle: (String) -> Void
    var size: FluidSize
    /// Roving focus — Radix's standalone accordion arrows through rows
    /// the same as a group's.
    var focused: FocusState<Int?>.Binding
    var navIndices: () -> [Int]
}

enum FluidAccordionHighlight { case trigger, item }

fileprivate struct FluidAccordionCtxKey: EnvironmentKey {
    static let defaultValue: FluidAccordionCtx? = nil
}

private struct FluidAccordionStandaloneCtxKey: EnvironmentKey {
    static let defaultValue: FluidAccordionStandaloneCtx? = nil
}

extension EnvironmentValues {
    fileprivate var fluidAccordion: FluidAccordionCtx? {
        get { self[FluidAccordionCtxKey.self] }
        set { self[FluidAccordionCtxKey.self] = newValue }
    }
    fileprivate var fluidAccordionStandalone: FluidAccordionStandaloneCtx? {
        get { self[FluidAccordionStandaloneCtxKey.self] }
        set { self[FluidAccordionStandaloneCtxKey.self] = newValue }
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

/// `AccordionGroup`/`Accordion` — single or multiple open items. Given an
/// `open` binding it's the controlled group (fluid-hover pick, shared
/// focus ring); constructed with `defaultValue` instead it's the
/// standalone `Accordion` — internal state, no group chrome, items carry
/// their own hover fill / open tint / focus ring (accordion.tsx:503-598).
struct FluidAccordion<Content: View>: View {
    /// Controlled open set — nil (the `defaultValue:` init) makes this the
    /// standalone Accordion.
    private var openBinding: Binding<Set<String>>?
    var collapsible = true
    /// The source default is type="single" (accordion.tsx:114).
    var single = true
    /// The source's `highlight` — "item" (default) tints open items as
    /// blocks; "trigger" scopes it to the hovered open row. Grouped only.
    var highlight: FluidAccordionHighlight = .item
    /// `size` pins every row to one ladder step; omitted, rows follow the
    /// surrounding fluidSize (the source's optional SizeProvider wrap).
    var size: FluidSize? = nil
    @ViewBuilder var content: () -> Content

    /// Standalone open state — seeded by `defaultValue`.
    @State private var internalOpen: Set<String>
    @State private var hover = FluidHover(axis: .y)
    @State private var fullRects: [Int: CGRect] = [:]
    @State private var heights: [Int: CGFloat] = [:]
    @State private var disabledIndices: Set<Int> = []
    @FocusState private var focusedIndex: Int?
    /// The :focus-visible latch — a pointer press suppresses the ring.
    @State private var pointerFocus = false
    /// A press is in flight — its focus landing keeps the pointer latch.
    @State private var pointerDown = false
    /// Keyboard modality: only a handled nav/activation key (or a focus
    /// arriving under keyDown) arms the ring + focus-lit hover — the
    /// auto-assigned first responder must not paint at open.
    @State private var navArmed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var ambientSize

    /// `AccordionGroup` — the controlled group (accordion.tsx:109-484).
    init(
        open: Binding<Set<String>>, collapsible: Bool = true,
        single: Bool = true, highlight: FluidAccordionHighlight = .item,
        size: FluidSize? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        openBinding = open
        self.collapsible = collapsible
        self.single = single
        self.highlight = highlight
        self.size = size
        self.content = content
        _internalOpen = State(initialValue: [])
    }

    /// `Accordion` — the standalone variant: manages its own open set
    /// seeded by `defaultValue` (accordion.tsx:503-598).
    init(
        defaultValue: Set<String> = [], collapsible: Bool = true,
        single: Bool = true, size: FluidSize? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        openBinding = nil
        self.collapsible = collapsible
        self.single = single
        self.size = size
        self.content = content
        _internalOpen = State(initialValue: defaultValue)
    }

    private var open: Set<String> {
        get { openBinding?.wrappedValue ?? internalOpen }
        nonmutating set {
            if let binding = openBinding {
                binding.wrappedValue = newValue
            } else {
                internalOpen = newValue
            }
        }
    }

    /// The ring's target — nil until a keypress arms keyboard modality,
    /// and nil while the pointer owns it (:focus-visible).
    private var focusRect: CGRect? {
        guard navArmed, !pointerFocus else { return nil }
        return focusedIndex.flatMap { hover.rects[$0] }
    }

    /// Enabled rows in row order — the arrow/Home/End nav list.
    private var navIndices: [Int] {
        hover.rects.keys.sorted().filter { !disabledIndices.contains($0) }
    }
    /// Standalone ordering — there are no hover rects outside a group, so
    /// the rows' declared indices order the nav list.
    private var standaloneNavIndices: [Int] {
        heights.keys.sorted().filter { !disabledIndices.contains($0) }
    }

    var body: some View {
        if openBinding != nil { grouped } else { standalone }
    }

    @ViewBuilder
    private var grouped: some View {
        FluidContainer(hover: hover, radius: shape.bg) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        // w-72 max-w-full — 288 unless the box is narrower.
        .frame(minWidth: 0, idealWidth: 288, maxWidth: 288, alignment: .leading)
        .background(alignment: .topLeading) { expandedTints }
        .background(alignment: .topLeading) { focusRing }
        .animation(FluidSpring.fast, value: focusRect)
        // The size pin — the source's optional SizeProvider wrap.
        .environment(\.fluidSize, size ?? ambientSize)
        .environment(\.fluidAccordion, FluidAccordionCtx(
            open: { open.contains($0) },
            toggle: toggle,
            highlight: highlight,
            size: size ?? ambientSize,
            focused: $focusedIndex,
            navIndices: { navIndices },
            pressFocus: pressFocus,
            endPress: { pointerDown = false },
            armNav: { navArmed = true; pointerFocus = false }
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
        .onChange(of: focusedIndex) { _, f in
            // :focus-visible — a focus that arrives while no press is down
            // is keyboard modality and clears the latch; blur resets it.
            // A focus arriving under a keyDown (Tab entry, a nav move) is
            // keyboard modality too — the window's auto-assigned first
            // responder isn't, so it stays dark.
            if f == nil || !pointerDown { pointerFocus = false }
            // Blur drops the arming — a programmatic refocus shouldn't
            // paint the ring off stale keyboard modality.
            if f == nil { navArmed = false }
            if f != nil, !pointerDown, NSApp.currentEvent?.type == .keyDown {
                navArmed = true
                pointerFocus = false
            }
            // The group's onFocus/onBlur lights the row — only once real
            // input (a nav key or an in-flight press) proves intent, so
            // the auto-assigned first responder doesn't paint at open.
            hover.activeIndex = (navArmed || pointerDown) ? f : nil
        }
    }

    /// `Accordion` standalone — a bare w-72 column; each item renders its
    /// own chrome (accordion.tsx:578-597).
    @ViewBuilder
    private var standalone: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(minWidth: 0, idealWidth: 288, maxWidth: 288, alignment: .leading)
            .environment(\.fluidSize, size ?? ambientSize)
            .environment(\.fluidAccordionHeights, heights)
            .environment(\.fluidAccordionStandalone, FluidAccordionStandaloneCtx(
                open: { internalOpen.contains($0) },
                toggle: toggle,
                size: size ?? ambientSize,
                focused: $focusedIndex,
                navIndices: { standaloneNavIndices }
            ))
            .onPreferenceChange(FluidAccordionHeightsKey.self) { heights = $0 }
            .onPreferenceChange(FluidAccordionDisabledKey.self) { flags in
                disabledIndices = Set(flags.filter { $0.value }.map(\.key))
            }
    }

    /// Row pointer-down: latch the ring off and land focus on the row —
    /// a click-focus isn't :focus-visible, but the press lights it.
    private func pressFocus(_ i: Int) {
        guard !disabledIndices.contains(i) else { return }
        pointerFocus = true
        pointerDown = true
        // Pointer modality — drop the arming so a blur→refocus can't paint
        // a ring from stale keyboard state.
        navArmed = false
        focusedIndex = i
    }

    private func toggle(_ value: String) {
        withAnimation(FluidSpring.fast) {
            if open.contains(value) {
                // collapsible exists only on the single-type props —
                // multiple mode always toggles (accordion.tsx:88-93).
                if collapsible || !single { open.remove(value) }
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
                    RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
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
    /// trigger, gliding between rows on spring.fast (keyboard modality
    /// only — :focus-visible, accordion.tsx:454-473).
    @ViewBuilder
    private var focusRing: some View {
        if let r = focusRect {
            RoundedRectangle(cornerRadius: shape.focusRing, style: .continuous)
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
    /// Standalone only — what an open item tints ("item" the whole block,
    /// "trigger" the hovered row). A group decides for all its rows
    /// (accordion.tsx:613-614).
    var highlight: FluidAccordionHighlight = .item
    @ViewBuilder var trigger: () -> Trigger
    @ViewBuilder var panel: () -> Panel

    @Environment(\.fluidAccordion) private var group
    @Environment(\.fluidAccordionStandalone) private var standalone
    @Environment(\.fluidAccordionHeights) private var heights
    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidShape) private var shape
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Standalone row hover — the group's pick covers it when grouped.
    @State private var selfHovered = false
    /// Panels drop from the AX tree once the exit lands — the source's
    /// `hidden` after exitComplete (accordion.tsx:906).
    @State private var exitDone = true
    @State private var exitTask: Task<Void, Never>?

    private var isOpen: Bool {
        group?.open(value) ?? standalone?.open(value) ?? false
    }
    private var size: FluidSize {
        group?.size ?? standalone?.size ?? .default
    }
    private var isActive: Bool {
        group != nil ? hover?.activeIndex == index : selfHovered
    }
    private var lit: Bool { isOpen || isActive }
    /// accent/20 — dark accent/12 (the open tint).
    private var openTint: Color {
        FluidTone.accent.opacity(scheme == .dark ? 0.12 : 0.20)
    }

    /// spring.fast.exit for the collapse — 60ms, no overshoot.
    private var heightSpring: Animation {
        isOpen ? FluidSpring.fast : .spring(duration: 0.06, bounce: 0)
    }
    /// Opacity dissolves ahead of the height — 60ms open, 40ms close
    /// (the source's opacity tween per direction, framer's default ease).
    private var opacityTween: Animation {
        .timingCurve(0.25, 0.1, 0.35, 1, duration: isOpen ? 0.06 : 0.04)
    }

    private func activate() {
        if let group { group.toggle(value) } else { standalone?.toggle(value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: activate) {
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
            // Inert but visually unchanged — the source's disabled trigger
            // doesn't dim (accordion.tsx:717-726); hit-testing off and out
            // of the tab order instead of .disabled().
            .allowsHitTesting(!disabled)
            .focusable(!disabled)
            .modifier(FluidAccordionFocus(
                group: group, standalone: standalone, index: index
            ))
            // Standalone chrome, scoped to the row so the panel keeps the
            // page's own surface (accordion.tsx:786-815): the "trigger"
            // open tint under a hovered open row, then the bg-hover fill
            // on top (the source's DOM order).
            .background {
                if standalone != nil {
                    if isOpen, highlight == .trigger, selfHovered {
                        RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                            .fill(openTint)
                            .transition(.opacity)
                    }
                    if selfHovered {
                        RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                            .fill(FluidTone.hover)
                            .transition(.opacity)
                    }
                }
            }
            .fluidItem(index)
            .preference(key: FluidAccordionDisabledKey.self, value: [index: disabled])
            .onHover { h in
                guard standalone != nil else { return }
                withAnimation(.easeOut(duration: 0.08)) { selfHovered = h }
            }

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
                // display:none once the exit lands — a settled-closed
                // panel leaves the AX tree (accordion.tsx:906).
                .accessibilityHidden(exitDone)
        }
        // Standalone "item" highlight — the open tint spans trigger and
        // panel as one block (accordion.tsx:672-684). The standalone tint
        // rides moderate; grouped rows keep the toggle's ambient fast.
        .background {
            if standalone != nil, highlight == .item, isOpen {
                RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                    .fill(openTint)
                    .transition(.opacity)
            }
        }
        .animation(FluidSpring.moderate, value: isOpen && standalone != nil)
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
        .onChange(of: isOpen) { _, open in
            exitTask?.cancel()
            if open {
                // Un-hide before the open's first paint (the source resets
                // exitComplete during render).
                exitDone = false
            } else {
                // The 60ms collapse spring + a settle margin — the panel
                // stays in the AX tree while it's still animating.
                exitTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    exitDone = true
                }
            }
        }
        .onAppear { if isOpen { exitDone = false } }
    }
}

/// Roving-tabindex wiring for one trigger: `.focused(equals:)`, the
/// arrow/Home/End moves, Space/Return activation, and the pointer-down
/// focus landing. Grouped, it goes through the group context (the ring
/// itself is the group's shared one); standalone, the item draws its own
/// ring once focus settles.
private struct FluidAccordionFocus: ViewModifier {
    let group: FluidAccordionCtx?
    let standalone: FluidAccordionStandaloneCtx?
    let index: Int

    @Environment(\.fluidShape) private var shape

    /// Standalone :focus-visible latch — a pointer press suppresses the
    /// ring until a keypress or a press-free focus clears it.
    @State private var pointerFocus = false
    /// A press is in flight — its focus landing mustn't clear the latch.
    @State private var pressed = false
    /// Standalone ring target — a nav key settles it immediately.
    @State private var settledIndex: Int?

    private var focusedBinding: FocusState<Int?>.Binding? {
        group?.focused ?? standalone?.focused
    }
    private var navIndices: [Int] {
        group?.navIndices() ?? standalone?.navIndices() ?? []
    }
    private var isFocused: Bool { focusedBinding?.wrappedValue == index }

    /// A key the row handled is keyboard modality.
    private func keyArrived() {
        group?.armNav()
        pointerFocus = false
    }

    /// Radix wraps: past the last row lands back on the first.
    private func move(_ dir: Int) {
        guard let pos = navIndices.firstIndex(of: index) else { return }
        let to = navIndices[(pos + dir + navIndices.count) % navIndices.count]
        focusedBinding?.wrappedValue = to
        settledIndex = to
    }

    private func edge(first: Bool) {
        guard let to = first ? navIndices.first : navIndices.last else { return }
        focusedBinding?.wrappedValue = to
        settledIndex = to
    }

    @ViewBuilder
    private func focusedRow(_ content: Content) -> some View {
        if let focusedBinding {
            content.focused(focusedBinding, equals: index)
        } else {
            content
        }
    }

    func body(content: Content) -> some View {
        focusedRow(content)
            // Radix onPointerDown — the press keeps its :hover (the group
            // lights it via pointerDown) and a click-focus never rings.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        pressed = true
                        if let group {
                            group.pressFocus(index)
                        } else {
                            pointerFocus = true
                            standalone?.focused.wrappedValue = index
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        group?.endPress()
                    }
            )
            .onKeyPress(.upArrow) { keyArrived(); move(-1); return .handled }
            .onKeyPress(.downArrow) { keyArrived(); move(1); return .handled }
            .onKeyPress(.home) { keyArrived(); edge(first: true); return .handled }
            .onKeyPress(.end) { keyArrived(); edge(first: false); return .handled }
            // Space/Return activate through the Button's own key handling
            // (the source's trigger is a <button> too — no keydown needed).
            // Activation never arms the ring: a click-focused row stays
            // non-:focus-visible when Enter fires it.
            // The standalone ring — a group draws one shared ring instead.
            // :focus-visible only: suppressed by the pointer-down latch.
            .background {
                if standalone != nil, isFocused, settledIndex == index, !pointerFocus {
                    // Standalone ring is flush — ring-1 ring-offset-0,
                    // not the group's 2pt-out box (accordion.tsx:721-722).
                    RoundedRectangle(cornerRadius: shape.focusRing, style: .continuous)
                        .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                        .transition(.opacity)
                }
            }
            .onChange(of: standalone?.focused.wrappedValue) { _, f in
                // Standalone :focus-visible — same modality logic as the
                // group: a focus landing while a press is down keeps the
                // pointer latch; anything else clears it.
                if f == nil || !pressed { pointerFocus = false }
                if f != nil, !pressed, NSApp.currentEvent?.type == .keyDown {
                    withAnimation(FluidSpring.fast) { settledIndex = f }
                } else if f != index {
                    settledIndex = f
                }
            }
    }
}

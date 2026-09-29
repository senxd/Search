import AppKit
import SwiftUI

// Card + CardGroup — fluid-demo/components/ui/card.tsx.
// A group of cards shares one fluid-hover pick (xy axis when columns > 1);
// cards draw hairline dividers toward borderless neighbours but drop the
// hairline next to the active or selected card so the fills read clean.

enum FluidCardOrientation { case card, inline }

private struct FluidCardGroupCtx {
    var orientation: FluidCardOrientation = .card
    var columns = 1
    var count = 1
    var separated = false
    var divided = false
    var outlined = false
    var activeIndex: Int? = nil
    var selectedIndex = -1
    var activations: FluidCardActivations = FluidCardActivations()
}

private struct FluidCardCtx {
    var emphasized = false
    var orientation: FluidCardOrientation = .card
    var clickable = false
    /// A FluidCardImage lives in this card — the inline row rewraps the rest
    /// into a centred column, and the dismiss chip takes its own ground.
    var hasImage = false
    /// Inline + dismissible: the header yields 40px on the right so the
    /// corner ✕ doesn't sit on the title's tail — the source's
    /// hover/focus-within gutter-swap, instant not transitioned.
    var dismissPad = false
}

private enum FluidCardGroupKey: EnvironmentKey {
    static let defaultValue: FluidCardGroupCtx? = nil
}

private enum FluidCardKey: EnvironmentKey {
    static let defaultValue = FluidCardCtx()
}

extension EnvironmentValues {
    fileprivate var fluidCardGroup: FluidCardGroupCtx? {
        get { self[FluidCardGroupKey.self] }
        set { self[FluidCardGroupKey.self] = newValue }
    }
    fileprivate var fluidCard: FluidCardCtx {
        get { self[FluidCardKey.self] }
        set { self[FluidCardKey.self] = newValue }
    }
}

/// A FluidCardImage in the card's content bubbles this up — the port of the
/// source's child-by-type detection (`Children.toArray(children).some(
/// isCardImage)`), which React gets synchronously at render time.
private enum FluidCardImagePresentKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Slot marks read by the inline row's Layout — synchronously at layout
/// time, so the media-bleed rewrap needs no preference round-trip.
private struct FluidCardImageSlotKey: LayoutValueKey {
    static var defaultValue = false
}
private struct FluidCardFooterSlotKey: LayoutValueKey {
    static var defaultValue = false
}

/// Selected indices bubble up so the group's divider edges can drop the
/// hairline next to a selected card (the source's selectedIndex ctx).
private enum FluidCardSelectedKey: PreferenceKey {
    static let defaultValue: Int? = nil
    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        value = value ?? nextValue()
    }
}

/// index → activate, so a gap click within 16px of a card can route to it
/// (the source's gapClick maxDistance). Cards register while visible.
final class FluidCardActivations {
    private var map: [Int: () -> Void] = [:]
    func register(_ i: Int, _ a: @escaping () -> Void) { map[i] = a }
    func unregister(_ i: Int) { map[i] = nil }
    func call(_ i: Int) { map[i]?() }
}

/// Flipped probe at the group's origin — converts clicks into the hover
/// space for the gap-pick distance/containment check.
private final class FluidCardProbeView: NSView {
    override var isFlipped: Bool { true }
}
private final class FluidCardProbeBox { var view: NSView? }
private struct FluidCardProbe: NSViewRepresentable {
    let box: FluidCardProbeBox
    func makeNSView(context: Context) -> NSView {
        let v = FluidCardProbeView()
        DispatchQueue.main.async { box.view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

/// The group's surface: one continuous divided block, or separated tiles.
/// `count` is the number of cards — needed for the divider edge cases.
struct FluidCardGroup<Content: View>: View {
    let orientation: FluidCardOrientation
    let columns: Int
    let outlined: Bool
    let separated: Bool
    let count: Int
    let fluidHover: Bool
    @ViewBuilder var content: () -> Content
    @State private var hover: FluidHover
    @Environment(\.fluidShape) private var shape
    /// Cards register their activate here so gap clicks within 16px route.
    @State private var activations = FluidCardActivations()
    /// Selected card index from the preference bubble — feeds ctx.
    @State private var selectedIndex: Int? = nil
    /// The gap-pick probe at the group's origin.
    @State private var probeBox = FluidCardProbeBox()

    init(
        orientation: FluidCardOrientation = .card,
        columns: Int = 1,
        outlined: Bool = false,
        separated: Bool = false,
        count: Int,
        fluidHover: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.orientation = orientation
        self.columns = columns
        self.outlined = outlined
        self.separated = separated
        self.count = count
        self.fluidHover = fluidHover
        self.content = content
        _hover = State(initialValue: FluidHover(axis: columns > 1 ? .xy : .y))
        hover.gapClickMaxDistance = 16
    }

    var body: some View {
        let ctx = FluidCardGroupCtx(
            orientation: orientation, columns: columns, count: count,
            separated: separated, divided: !separated, outlined: outlined,
            activeIndex: hover.activeIndex, selectedIndex: selectedIndex ?? -1,
            activations: activations
        )
        Group {
            if fluidHover {
                FluidContainer(hover: hover, radius: shape.container,
                               onGapPick: gapPick) {
                    ZStack(alignment: .topLeading) {
                        FluidCardProbe(box: probeBox)
                            .frame(width: 0, height: 0)
                        grid
                    }
                }
            } else {
                grid
            }
        }
        .onPreferenceChange(FluidCardSelectedKey.self) { selectedIndex = $0 }
        .environment(\.fluidCardGroup, ctx)
    }

    /// Gap click → activate (use-fluid-hover gapClick maxDistance:16 —
    /// enforced by hover.gapClickMaxDistance). Inside ANY registered card
    /// the card's own tap owns the click — the source's
    /// element.contains(target) checks them all.
    private func gapPick(_ i: Int) {
        guard let v = probeBox.view, let w = v.window else { return }
        let p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        if hover.rects.values.contains(where: { $0.contains(p) }) { return }
        activations.call(i)
    }

    private var grid: some View {
        let spacing: CGFloat = separated ? 8 : 0
        return Group {
            if columns > 1 {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                    spacing: spacing
                ) { content() }
            } else {
                VStack(alignment: .leading, spacing: spacing) { content() }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: shape.container, style: .continuous)
                .strokeBorder(
                    outlined && !separated ? FluidTone.border.opacity(0.6) : .clear,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(
            cornerRadius: outlined && !separated ? shape.container : 0,
            style: .continuous
        ))
    }
}

/// One card — stacked (media/header over body) or inline (a single row).
/// Clickable cards join the group pick; a standalone clickable card carries
/// its own hover tint. Selected paints a persistent `active` fill.
struct FluidCard<Content: View>: View {
    var index: Int = 0
    var selected = false
    var disabled = false
    var onClick: (() -> Void)? = nil
    /// Whole-card link — the source's stretched anchor. macOS has no anchor
    /// element, so the card's tap opens the URL (after `onClick`) instead.
    var href: String? = nil
    /// The source's `target="_blank"` — NSWorkspace already opens externally,
    /// so it carries no behavior here; kept for call-site parity.
    var external = false
    /// Accessible name for the whole-card target — the source puts an
    /// aria-label on the stretched overlay because the visible title isn't
    /// wired up automatically.
    var label: String? = nil
    /// Pins the card (and every ladder-aware part inside) to one size step —
    /// the source wraps the card in a SizeProvider when `size` is set.
    var size: FluidSize? = nil
    /// Corner ✕ — revealed on card hover when `dismissOnHover` is set
    /// (default), always visible otherwise.
    var dismissible = false
    var dismissOnHover = true
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidCardGroup) private var group
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var inheritedSize
    @State private var selfHovered = false
    @State private var dismissHovered = false
    @State private var hasImage = false
    /// The stretched overlay is a real focusable target — focus-within
    /// reveals the ✕ and keyboard focus draws the ring.
    @FocusState private var cardFocused: Bool
    /// The ✕'s own focus — focus-within parity so it can't sit invisible
    /// yet focusable.
    @FocusState private var chipFocused: Bool
    /// :focus-visible approximation — pointer interaction suppresses the
    /// ring until a keypress or blur restores it.
    @State private var pointerFocus = false

    private var resolvedSize: FluidSize { size ?? inheritedSize }
    private var compact: Bool { resolvedSize == .compact }
    /// Clickable = the stretched overlay exists (onClick or href).
    private var clickable: Bool { onClick != nil || href != nil }

    /// The stretched target — `onClick` first, then the href opens.
    private func activate() {
        onClick?()
        if let href, let url = URL(string: href) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Keyboard activation — clears pointer-focus suppression so the ring
    /// can paint again. Scoped to the card's own focus: a focused child
    /// (chip, footer button) owns its keys, matching the source's sibling
    /// overlay — not a wrapping handler.
    private func activateByKey() -> KeyPress.Result {
        guard cardFocused && clickable && !disabled else { return .ignored }
        pointerFocus = false
        activate()
        return .handled
    }

    var body: some View {
        let g = group ?? FluidCardGroupCtx()
        let inGroup = group != nil
        let orientation = group?.orientation ?? .card

        // Divider edge cases — a hairline toward the neighbour below/right
        // unless that neighbour or self is active/selected (source: showBottom/
        // showRight, so the fills read clean).
        let col = index % g.columns
        let hasBelow = index + g.columns < g.count
        let hasRight = col < g.columns - 1 && index + 1 < g.count
        let hot: [Int] = [g.activeIndex ?? -1, g.selectedIndex]
        let showBottom = g.divided && hasBelow && !hot.contains(index) && !hot.contains(index + g.columns)
        let showRight = g.divided && hasRight && !hot.contains(index) && !hot.contains(index + 1)
        let tileClip = !inGroup || (g.separated && g.outlined)

        Group {
            if orientation == .inline {
                // flex-row items-center: the Layout owns the left inset — and
                // the media-bleed rewrap when a FluidCardImage is present.
                FluidCardInlineRow(compact: compact) { content() }
            } else {
                VStack(alignment: .leading, spacing: 0) { content() }
            }
        }
            .environment(\.fluidCard, FluidCardCtx(
                emphasized: selected, orientation: orientation, clickable: clickable,
                hasImage: hasImage,
                dismissPad: dismissible && orientation == .inline
                    && (!dismissOnHover || selfHovered || cardFocused || chipFocused)
            ))
            // The size prop re-pins the ladder for the parts — the source's
            // SizeProvider wrap.
            .environment(\.fluidSize, resolvedSize)
            .onPreferenceChange(FluidCardImagePresentKey.self) { hasImage = $0 }
            .frame(maxWidth: .infinity, alignment: .leading)
            // min-h-[60px] is border-box — padding counts inside it, so
            // the padding feeds the frame, not the other way round.
            .padding(.bottom, orientation == .card ? (compact ? 12 : 16) : 0)
            .frame(minHeight: 60)
            .background(alignment: .bottom) {
                if showBottom {
                    Rectangle().fill(FluidTone.border.opacity(0.6)).frame(height: 1)
                }
            }
            .background(alignment: .trailing) {
                if showRight {
                    Rectangle().fill(FluidTone.border.opacity(0.6))
                        .frame(width: 1)
                        .padding(.bottom, showBottom ? 1 : 0)
                }
            }
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: shape.container, style: .continuous)
                        .fill(FluidTone.active)
                } else if !inGroup && clickable && selfHovered && !disabled {
                    RoundedRectangle(cornerRadius: shape.container, style: .continuous)
                        .fill(FluidTone.hover)
                }
            }
            .background {
                if inGroup && g.separated && g.outlined {
                    RoundedRectangle(cornerRadius: shape.container, style: .continuous)
                        .strokeBorder(FluidTone.border.opacity(0.6), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: tileClip ? shape.container : 0, style: .continuous
            ))
            // pointer-events-none on the card's content — but the dismiss
            // chip overlays after this and self-arms on card hover even
            // when disabled (the source's pointer-events-auto).
            .allowsHitTesting(!disabled)
            .overlay(alignment: .topTrailing) {
                // The source's dismiss ✕ — muted → foreground, hidden +
                // non-hit-testable until the card is hovered when
                // dismissOnHover is set (an invisible control must not
                // swallow taps meant for the card).
                if dismissible {
                    // focus-within: the chip's own focus reveals it too —
                    // an invisible-but-focusable control is a trap.
                    Button(action: { onDismiss?() }) {
                        FluidIcon("xmark", size: compact ? 13 : 15)
                            .foregroundStyle(dismissHovered
                                ? FluidTone.foreground : FluidTone.mutedForeground)
                            .frame(width: 28, height: 28)
                            .background {
                                let chip = RoundedRectangle(
                                    cornerRadius: shape.button, style: .continuous
                                )
                                if hasImage {
                                    // Over media the control needs its own
                                    // ground — card/70 + a small blur — or
                                    // the icon reads against whatever the
                                    // image happens to be.
                                    chip.fill(.ultraThinMaterial)
                                    chip.fill(FluidTone.card.opacity(
                                        dismissHovered ? 1 : 0.7
                                    ))
                                } else {
                                    chip.fill(dismissHovered ? FluidTone.hover : .clear)
                                }
                                if chipFocused {
                                    chip.strokeBorder(FluidTone.focusRing, lineWidth: 1)
                                        .padding(-1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .focused($chipFocused)
                    .focusEffectDisabled()
                    .onHover { dismissHovered = $0 }
                    .padding(8)
                    // The chip keeps pointer-events-auto on card hover even
                    // on a disabled card (the source self-arms it).
                    .opacity(dismissOnHover && !selfHovered && !cardFocused
                             && !chipFocused ? 0 : 1)
                    .allowsHitTesting(!dismissOnHover || selfHovered || cardFocused || chipFocused)
                    .animation(.easeOut(duration: 0.08), value: selfHovered)
                    .animation(.easeOut(duration: 0.08), value: dismissHovered)
                }
            }
            .overlay {
                // focus-visible ring on the stretched target — 1px
                // focusRing 3px out, rounded one step past the card clip.
                if cardFocused && !pointerFocus {
                    RoundedRectangle(cornerRadius: shape.container + 1,
                                     style: .continuous)
                        .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                        .padding(-3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if clickable && !disabled { pointerFocus = true; activate() }
            }
            .onHover { selfHovered = $0 }
            .opacity(disabled ? 0.5 : 1)
            .focusable(clickable && !disabled)
            .focused($cardFocused)
            // The overlay is a real button/link in the source — focused,
            // Return/Space activate.
            .onKeyPress(.return) { self.activateByKey() }
            .onKeyPress(.space) { self.activateByKey() }
            .onChange(of: cardFocused) { _, f in if !f { pointerFocus = false } }
            .modifier(FluidCardA11yLabel(label: label, active: clickable && !disabled,
                                         selected: selected, activate: activate))
            .modifier(FluidCardItem(index: inGroup && clickable ? index : nil))
            // Publish selection so the group drops hairlines next to it.
            .preference(key: FluidCardSelectedKey.self,
                        value: selected ? index : nil)
            .onAppear { registerCard() }
            .onDisappear { g.activations.unregister(index) }
            // The stored closure is a struct snapshot — re-register on any
            // input that could stale it.
            .onChange(of: disabled) { _, _ in registerCard() }
            .onChange(of: index) { old, _ in
                // The map key moves — drop the stale entry, not just add
                // the new one.
                g.activations.unregister(old)
                registerCard()
            }
            .onChange(of: href) { _, _ in registerCard() }
            .onChange(of: onClick != nil) { _, _ in registerCard() }
            .animation(FluidSpring.fast, value: selfHovered)
    }

    /// Gap-click routing: the group's probe can land a click on this
    /// card — register the activate closure so it can be reached. Going
    /// inert (clickable→nil) unregisters, matching the source's
    /// registerItem-undefined cleanup.
    private func registerCard() {
        guard let group else { return }
        group.activations.unregister(index)
        guard clickable else { return }
        group.activations.register(index) { [self] in
            if !disabled { activate() }
        }
    }
}

/// The stretched overlay's accessible name — applied only when the caller
/// supplies `label`. `.combine` merges the card's text into one element;
/// the overlay is the activatable target (`isButton` + a real action), so
/// VoiceOver can trigger it — nested controls stay reachable only when no
/// label was given (callers opting in take the overlay semantics).
private struct FluidCardA11yLabel: ViewModifier {
    let label: String?
    let active: Bool
    /// `aria-pressed={selected}` — toggleable cards announce the state.
    var selected: Bool = false
    let activate: () -> Void
    func body(content: Content) -> some View {
        if let label, active {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityAction { activate() }
        } else {
            content
        }
    }
}

private struct FluidCardItem: ViewModifier {
    let index: Int?
    func body(content: Content) -> some View {
        if let index { content.fluidItem(index) } else { content }
    }
}

/// The inline row — a Layout, not an HStack, because the source's
/// media-bleed rewrap can't be a view-tree transform: when a FluidCardImage
/// is among the children it leaves the flow to pin the leading edge (flush —
/// the card's `pl` drops), and every other child stacks in a vertically
/// centred column beside it (the source's `flex-col justify-center gap-2`
/// wrapper, owning py-3.5/2.5 and pr-4/3). Without an image it's the plain
/// row: items-centred at gap-3/2.5 after the pl-4/3 inset, children at
/// their ideal widths while flexible ones (the header's max-width frame —
/// the source's `flex-1`) split the leftover, and a footer-marked child
/// taking the `ml-auto` push when nothing is flexible.
private struct FluidCardInlineRow: Layout {
    var compact: Bool

    /// gap-2.5 / gap-3 between row children (and image → column).
    private var gap: CGFloat { compact ? 10 : 12 }
    /// pl-3 / pl-4 — the row's left inset, dropped when an image bleeds.
    private var leadingInset: CGFloat { compact ? 12 : 16 }
    /// The wrapper column's gap-2 / py-2.5·3.5 / pr-3·4.
    private var columnGap: CGFloat { 8 }
    private var columnPy: CGFloat { compact ? 10 : 14 }
    private var columnPr: CGFloat { compact ? 12 : 16 }

    struct Cache {
        /// Subviews that take a slot — empty (0×0) children don't draw gaps.
        var visible: [Int] = []
        var ideals: [CGSize] = []
        /// First image-marked child — the bleed slot. Further images stay
        /// in the column, matching the source's `parts.find`.
        var image: Int? = nil
        /// First footer-marked child — carries `ml-auto`.
        var footer: Int? = nil
        /// Children that accept more than their ideal width (`flex-1`).
        var flexible: Set<Int> = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        for i in subviews.indices {
            let ideal = subviews[i].sizeThatFits(.unspecified)
            cache.ideals.append(ideal)
            if ideal == .zero { continue }
            cache.visible.append(i)
            if cache.image == nil, subviews[i][FluidCardImageSlotKey.self] {
                cache.image = i
            }
            if cache.footer == nil, subviews[i][FluidCardFooterSlotKey.self] {
                cache.footer = i
            }
            // flex-1 probe: offer more than the ideal — a greedy child
            // (frame(maxWidth: .infinity)) takes the whole offer.
            let grown = subviews[i].sizeThatFits(
                ProposedViewSize(width: ideal.width + 2048, height: nil)
            ).width
            if grown > ideal.width + 0.5 { cache.flexible.insert(i) }
        }
        return cache
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> CGSize {
        if cache.image != nil {
            return imageFit(proposal: proposal, subviews: subviews, cache: cache)
        }
        let widths = rowWidths(available: proposal.width, cache: cache)
        var height: CGFloat = 0
        for i in cache.visible {
            height = max(height, subviews[i].sizeThatFits(
                ProposedViewSize(width: widths[i], height: nil)).height)
        }
        let total = cache.visible.reduce(0) { $0 + (widths[$1] ?? 0) }
            + gap * CGFloat(max(0, cache.visible.count - 1))
        return CGSize(width: proposal.width ?? (leadingInset + total), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Cache
    ) {
        if cache.image != nil {
            placeImageRow(in: bounds, subviews: subviews, cache: cache)
            return
        }
        let widths = rowWidths(available: bounds.width, cache: cache)
        let total = cache.visible.reduce(0) { $0 + (widths[$1] ?? 0) }
            + gap * CGFloat(max(0, cache.visible.count - 1))
        // Whatever flexibles didn't absorb — only nonzero when nothing is
        // flexible — is the footer's auto margin.
        let leftover = bounds.width - leadingInset - total
        var x = bounds.minX + leadingInset
        for i in cache.visible {
            if i == cache.footer, leftover > 0 { x += leftover }
            let w = widths[i] ?? 0
            let h = subviews[i].sizeThatFits(
                ProposedViewSize(width: w, height: nil)).height
            // items-center — each child vertically centred at its own height.
            subviews[i].place(
                at: CGPoint(x: x, y: bounds.midY - h / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: w, height: h)
            )
            x += w + gap
        }
    }

    /// Each visible child's row width: ideal, with the leftover (or the
    /// shortfall) split evenly across the flexible ones — `min-w-0` lets a
    /// flexible child shrink to nothing, fixed children keep their ideal.
    private func rowWidths(available: CGFloat?, cache: Cache) -> [Int: CGFloat] {
        let n = cache.visible.count
        let spacingTotal = gap * CGFloat(max(0, n - 1))
        let idealTotal = cache.visible.reduce(0) { $0 + cache.ideals[$1].width }
        let leftover = (available ?? (leadingInset + idealTotal + spacingTotal))
            - leadingInset - idealTotal - spacingTotal
        let share = cache.flexible.isEmpty
            ? 0 : leftover / CGFloat(cache.flexible.count)
        var widths: [Int: CGFloat] = [:]
        for i in cache.visible {
            widths[i] = max(
                0, cache.ideals[i].width + (cache.flexible.contains(i) ? share : 0)
            )
        }
        return widths
    }

    /// The non-image children measured at the column width, stacked.
    private func columnHeights(
        width: CGFloat, subviews: Subviews, cache: Cache
    ) -> (items: [(Int, CGFloat)], stack: CGFloat) {
        var items: [(Int, CGFloat)] = []
        for i in cache.visible where i != cache.image {
            items.append((i, subviews[i].sizeThatFits(
                ProposedViewSize(width: width, height: nil)).height))
        }
        let stack = items.reduce(0) { $0 + $1.1 }
            + columnGap * CGFloat(max(0, items.count - 1))
        return (items, stack)
    }

    private func imageFit(
        proposal: ProposedViewSize, subviews: Subviews, cache: Cache
    ) -> CGSize {
        let img = cache.ideals[cache.image ?? 0]
        let colW: CGFloat
        if let w = proposal.width, w.isFinite {
            colW = max(0, w - img.width - gap - columnPr)
        } else {
            colW = cache.visible.filter { $0 != cache.image }
                .map { cache.ideals[$0].width }.max() ?? 0
        }
        let stack = columnHeights(width: colW, subviews: subviews, cache: cache).stack
        return CGSize(
            width: proposal.width ?? (img.width + gap + colW + columnPr),
            height: max(img.height, stack + 2 * columnPy)
        )
    }

    private func placeImageRow(
        in bounds: CGRect, subviews: Subviews, cache: Cache
    ) {
        guard let image = cache.image else { return }
        let img = cache.ideals[image]
        // Flush against the leading edge, vertically centred — the card's
        // own clip rounds whatever corners the frame exposes.
        subviews[image].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY - img.height / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(img)
        )
        let x0 = bounds.minX + img.width + gap
        let colW = max(0, bounds.maxX - columnPr - x0)
        let col = columnHeights(width: colW, subviews: subviews, cache: cache)
        // justify-center — the stack centres against the row's full height.
        var y = bounds.midY - col.stack / 2
        for (index, height) in col.items {
            subviews[index].place(
                at: CGPoint(x: x0, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: colW, height: height)
            )
            y += height + columnGap
        }
    }
}

/// `flex-wrap gap-1` for the stacked/inline-image footer — wraps the action
/// row in narrow cards the way the CSS flex row does.
private struct FluidCardWrap: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, used: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += size.width
            used = max(used, x)
            x += spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : used, height: y + rowH)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowH + spacing; x = bounds.minX; rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - Parts

/// Header: title + description stack — shadcn's grid, with CardAction
/// pinned to the top-right column (`grid-cols-[1fr_auto]`, `row-span-2`,
/// `self-start justify-self-end`). The action can't live inside the
/// ViewBuilder children — SwiftUI gives no way to pull one into a second
/// column — so it arrives through the `action:` slot instead:
///
///     FluidCardHeader(action: { FluidCardAction { … } }) {
///         FluidCardTitle(…)
///         FluidCardDescription(…)
///     }
///
/// In an inline card it's the flexible text column between the leading
/// media and the trailing footer.
struct FluidCardHeader<Content: View, Action: View>: View {
    @Environment(\.fluidCard) private var card
    @Environment(\.fluidSize) private var size
    @ViewBuilder var content: () -> Content
    @ViewBuilder var action: () -> Action

    init(@ViewBuilder content: @escaping () -> Content) where Action == EmptyView {
        self.content = content
        self.action = { EmptyView() }
    }

    init(
        action: @escaping () -> Action,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.action = action
        self.content = content
    }

    var body: some View {
        let compact = size == .compact
        let inline = card.orientation == .inline
        // An inline card holding a full image centres text + actions in a
        // column beside it — the wrapper owns the insets, so the header
        // drops all padding (the source's `min-w-0`-only branch).
        let inlineImage = inline && card.hasImage
        HStack(alignment: .top, spacing: Action.self == EmptyView.self ? 0 : 4) {
            // gap-1 between the title/description rows.
            VStack(alignment: .leading, spacing: 4) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
            if Action.self != EmptyView.self { action() }
        }
            .padding(.leading, inline ? 0 : (compact ? 12 : 16))
            .padding(.trailing, card.dismissPad
                ? 40 : (inline ? 0 : (compact ? 12 : 16)))
            .padding(.top, inline ? 0 : (compact ? 12 : 16))
            .padding(.vertical, inline && !inlineImage ? (compact ? 10 : 14) : 0)
            // flex-1 — the row's flexible element (and a stretch in the
            // image column, whose children take the full column width).
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The header's top-right action slot (`data-slot="card-action"`) — sits
/// above the stretched overlay so its controls stay independently
/// clickable. Hand to `FluidCardHeader(action:)`.
struct FluidCardAction<Content: View>: View {
    @ViewBuilder var content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View { content() }
}

/// Dual-layer title — the invisible semibold twin reserves width so the
/// emphasis flip never reflows. 14px default.
struct FluidCardTitle: View {
    let text: String
    @Environment(\.fluidCard) private var card
    @Environment(\.fluidSize) private var size

    init(_ text: String) { self.text = text }

    var body: some View {
        let pt = size == .compact ? 13.0 : 14.0
        ZStack(alignment: .leading) {
            Text(text).fontWeight(.semibold).opacity(0)
            Text(text)
                .fontWeight(card.emphasized ? .semibold : .regular)
                .foregroundStyle(FluidTone.foreground)
        }
        .font(.system(size: pt))
        // leading-snug = line-height 1.375 — the visible twin wraps inside
        // the 19.25px line box.
        .lineSpacing(pt * 1.375 - pt * 1.21)
        // duration-80 on the weight flip — the source's
        // transition-[font-variation-settings].
        .animation(.easeOut(duration: 0.08), value: card.emphasized)
    }
}

struct FluidCardDescription: View {
    let text: String
    @Environment(\.fluidSize) private var size

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: size == .compact ? 13 : 14))
            .foregroundStyle(FluidTone.mutedForeground)
    }
}

struct FluidCardContent<Content: View>: View {
    @Environment(\.fluidCard) private var card
    @Environment(\.fluidSize) private var size
    @ViewBuilder var content: () -> Content

    var body: some View {
        let compact = size == .compact
        content()
            .padding(.horizontal, card.orientation == .inline ? 0 : (compact ? 12 : 16))
            .padding(.top, card.orientation == .inline ? 0 : (compact ? 10 : 12))
    }
}

/// The actions row (`data-slot="card-footer"`). Stacked it's a wrapping
/// row padded like content; a plain inline card makes it the trailing
/// `shrink-0 ml-auto` slot that owns the right inset; an inline image card
/// drops it under the text in the centred column, wrapping, with no insets
/// of its own.
struct FluidCardFooter<Content: View>: View {
    @Environment(\.fluidCard) private var card
    @Environment(\.fluidSize) private var size
    @ViewBuilder var content: () -> Content

    var body: some View {
        let compact = size == .compact
        let inline = card.orientation == .inline
        let inlineImage = inline && card.hasImage
        Group {
            if inline && !inlineImage {
                // shrink-0 ml-auto pr-4/3 — never wraps; the row layout owns
                // the auto-margin push.
                HStack(spacing: 4) { content() }
                    .padding(.trailing, compact ? 12 : 16)
            } else {
                // flex-wrap — stacked pads like CardContent; the image
                // column owns its insets, so no padding there.
                FluidCardWrap(spacing: 4) { content() }
                    .padding(.horizontal, inline ? 0 : (compact ? 12 : 16))
                    .padding(.top, inline ? 0 : (compact ? 10 : 12))
            }
        }
        .layoutValue(key: FluidCardFooterSlotKey.self, value: true)
    }
}

/// A leading icon or brand logo — the connective-tissue media slot
/// (`data-slot="card-media"`). An icon sits in a 32×32 hover-tint tile so
/// it reads as media rather than a bare glyph; a logo renders object-
/// contain at `size`, and a pair draws the connected trigger→target tuple
/// with an 8px hairline between them.
struct FluidCardMedia: View {
    private enum Media {
        case icon(String)
        case logos([Image])
    }

    private let media: Media
    private let logoSize: CGFloat
    private let alt: String

    /// The icon variant — a 32×32 `bg-hover` tile, icon 16/18 by the ladder.
    init(icon: String) {
        media = .icon(icon)
        logoSize = 22
        alt = ""
    }

    /// One logo at `size` (default 22), object-contain, `bg` radius.
    init(logo: Image, alt: String = "", size: CGFloat = 22) {
        media = .logos([logo])
        logoSize = size
        self.alt = alt
    }

    init(logo: NSImage, alt: String = "", size: CGFloat = 22) {
        self.init(logo: Image(nsImage: logo), alt: alt, size: size)
    }

    /// The connected pair — the `[a, b]` tuple with a hairline between.
    init(logos: (Image, Image), alt: String = "", size: CGFloat = 22) {
        media = .logos([logos.0, logos.1])
        logoSize = size
        self.alt = alt
    }

    init(logos: (NSImage, NSImage), alt: String = "", size: CGFloat = 22) {
        self.init(logos: (Image(nsImage: logos.0), Image(nsImage: logos.1)),
                  alt: alt, size: size)
    }

    @Environment(\.fluidCard) private var card
    @Environment(\.fluidSize) private var size
    @Environment(\.fluidShape) private var shape

    var body: some View {
        let compact = size == .compact
        Group {
            switch media {
            case .icon(let name):
                FluidIcon(name, size: compact ? 16 : 18)
                    .foregroundStyle(FluidTone.mutedForeground)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                            // Overlay tint, not a solid surface — blends over
                            // the substrate or the hover highlight.
                            .fill(FluidTone.hover)
                    )
            case .logos(let images):
                HStack(spacing: 6) {  // gap-1.5
                    ForEach(Array(images.enumerated()), id: \.offset) { i, logo in
                        if i > 0 {
                            Rectangle().fill(FluidTone.border)
                                .frame(width: 8, height: 1)
                        }
                        logo.resizable().aspectRatio(contentMode: .fit)
                            .frame(width: logoSize, height: logoSize)
                            .clipShape(RoundedRectangle(
                                cornerRadius: shape.bg, style: .continuous
                            ))
                    }
                }
            }
        }
        .accessibilityLabel(Text(alt))
        .accessibilityHidden(alt.isEmpty)
        // mb-2 in stacked cards — the header's gap-1 plus this 8 reads as
        // the source's 12px under the media. Inline owns no padding (the
        // card owns the leading inset).
        .padding(.bottom, card.orientation == .inline ? 0 : 8)
    }
}

/// The prominent full-bleed image (`data-slot="card-image"`), distinct from
/// CardMedia's small logo. Stacked → a `w-full` 16:9 banner (media-first is
/// the top banner; media-last still sits above the card's bottom padding).
/// Inline → the 160px leading slot that bleeds past the card's left inset
/// to sit flush against the edge — the row's Layout pulls it out of the
/// flow via the slot key, so it may be written anywhere in the children.
/// The image keeps its own fixed 2px radius in every state; the card's
/// clip, when framed, still rounds the corners it exposes.
struct FluidCardImage: View {
    let image: Image
    var alt: String = ""

    init(_ image: Image, alt: String = "") {
        self.image = image
        self.alt = alt
    }

    init(nsImage: NSImage, alt: String = "") {
        self.init(Image(nsImage: nsImage), alt: alt)
    }

    init?(contentsOfFile path: String, alt: String = "") {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        self.init(Image(nsImage: img), alt: alt)
    }

    init?(contentsOf url: URL, alt: String = "") {
        guard let img = NSImage(contentsOf: url) else { return nil }
        self.init(Image(nsImage: img), alt: alt)
    }

    @Environment(\.fluidCard) private var card

    var body: some View {
        // object-cover — scaledToFill under a fixed box, clipped.
        Group {
            if card.orientation == .inline {
                image.resizable().scaledToFill()
                    .frame(width: 160, height: 160)
            } else {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { image.resizable().scaledToFill() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        // The slot mark for the row Layout, and the hasImage flag for the
        // card's context — the source's isCardImage detection.
        .layoutValue(key: FluidCardImageSlotKey.self, value: true)
        .preference(key: FluidCardImagePresentKey.self, value: true)
        .accessibilityLabel(Text(alt))
        .accessibilityHidden(alt.isEmpty)
    }
}

/// The small uppercase label above the title (`data-slot="card-eyebrow"`)
/// — the caption role of the type scale, uppercased, semibold, muted.
struct FluidCardEyebrow: View {
    let text: String
    @Environment(\.fluidSize) private var size

    init(_ text: String) { self.text = text }

    var body: some View {
        let s: CGFloat = size == .compact ? 11 : 12
        Text(text.uppercased())
            .font(.system(size: s, weight: .semibold))
            // tracking-wide — 0.025em of the rendered size.
            .tracking(s * 0.025)
            .foregroundStyle(FluidTone.mutedForeground)
    }
}

/// An icon + title + description row (`data-slot="card-feature"`) — for
/// feature lists inside FluidCardContent.
struct FluidCardFeature: View {
    let icon: String?
    let title: String
    let description: String?

    init(icon: String? = nil, title: String, description: String? = nil) {
        self.icon = icon
        self.title = title
        self.description = description
    }

    @Environment(\.fluidSize) private var size

    var body: some View {
        let compact = size == .compact
        // items-start, the ladder's gap (8/4) and icon step (16/14).
        HStack(alignment: .top, spacing: size.gap) {
            if let icon {
                FluidIcon(icon, size: size.icon)
                    .foregroundStyle(FluidTone.mutedForeground)
                    .padding(.top, 2)  // mt-0.5
            }
            VStack(alignment: .leading, spacing: 2) {  // gap-0.5
                Text(title)
                    .font(.system(size: size.text, weight: .medium))
                    .foregroundStyle(FluidTone.foreground)
                if let description {
                    Text(description)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(FluidTone.mutedForeground)
                }
            }
        }
    }
}

// MARK: - CardButton

enum FluidCardButtonVariant { case primary, secondary, ghost, link }
enum FluidCardButtonIconPosition { case start, end }

/// The self-contained footer action (`data-slot` on a `card-button`) —
/// keeps Card free of a Button dependency the way the source does. An
/// `h-7 px-2.5` 12/11px medium label, optional icon at either end (end is
/// the default when `external`), and the outward arrow on external links.
/// `href` opens via NSWorkspace after `action` — macOS's stand-in for the
/// anchor render.
struct FluidCardButton<Label: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidSize) private var size
    @Environment(\.fluidShape) private var shape
    @Environment(\.isEnabled) private var isEnabled
    var variant: FluidCardButtonVariant = .ghost
    var icon: String? = nil
    /// `nil` resolves like the source: `end` when external, else `start`.
    var iconPosition: FluidCardButtonIconPosition? = nil
    var external = false
    var href: String? = nil
    /// The source's `disabled` prop — opacity-50 + pointer-events-none,
    /// on top of the `\.isEnabled` env.
    var disabled = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovered = false
    @State private var pressed = false

    private var off: Bool { disabled || !isEnabled }

    init(
        _ title: String,
        variant: FluidCardButtonVariant = .ghost,
        icon: String? = nil,
        iconPosition: FluidCardButtonIconPosition? = nil,
        external: Bool = false,
        href: String? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void = {}
    ) where Label == Text {
        self.init(
            variant: variant, icon: icon, iconPosition: iconPosition,
            external: external, href: href, disabled: disabled, action: action
        ) { Text(title) }
    }

    init(
        variant: FluidCardButtonVariant = .ghost,
        icon: String? = nil,
        iconPosition: FluidCardButtonIconPosition? = nil,
        external: Bool = false,
        href: String? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void = {},
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.variant = variant
        self.icon = icon
        self.iconPosition = iconPosition
        self.external = external
        self.href = href
        self.disabled = disabled
        self.action = action
        self.label = label
    }

    /// The row's hover reaches the icon — `group-hover/action:stroke-[2]`,
    /// the stroke-width bump FluidIcon renders as a weight bump.
    private var hot: Bool { hovered || pressed }

    private var textColor: Color {
        switch variant {
        case .primary: return FluidTone.background
        case .ghost: return hot ? FluidTone.foreground : FluidTone.mutedForeground
        default: return FluidTone.foreground
        }
    }

    private var fill: Color {
        switch variant {
        case .primary:
            // bg-foreground → /90 hovered → /80 pressed.
            if pressed { return FluidMix.fgOverBg(80, for: scheme) }
            if hovered { return FluidMix.fgOverBg(90, for: scheme) }
            return FluidTone.foreground
        case .secondary:
            // bg-accent → accent/80 hovered → accent pressed.
            return hovered && !pressed ? FluidTone.accent.opacity(0.8) : FluidTone.accent
        case .ghost:
            return pressed ? FluidTone.active : (hovered ? FluidTone.hover : .clear)
        case .link:
            return .clear
        }
    }

    private func activate() {
        action()
        if let href, let url = URL(string: href) {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        let compact = size == .compact
        let position = iconPosition ?? (external ? .end : .start)
        // `link` drops the bounds: `!px-0 !h-auto`.
        let bounded = variant != .link
        Button(action: activate) {
            HStack(spacing: 6) {  // gap-1.5
                if let icon, position == .start {
                    FluidIcon(icon, size: compact ? 12 : 14, bold: hot)
                }
                label()
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .underline(variant == .link && hovered)
                if let icon, position == .end {
                    FluidIcon(icon, size: compact ? 12 : 14, bold: hot)
                }
                if external {
                    // arrow-right -rotate-45 — the outward-link glyph.
                    FluidIcon("arrow.right", size: 13, bold: hot)
                        .rotationEffect(.degrees(-45))
                }
            }
            .frame(height: bounded ? 28 : nil)  // h-7
            .padding(.horizontal, bounded ? 10 : 0)  // px-2.5
            .foregroundStyle(textColor)
            .background(
                RoundedRectangle(cornerRadius: shape.button, style: .continuous)
                    .fill(fill)
            )
        }
        .buttonStyle(.plain)
        .disabled(off)
        .opacity(off ? 0.5 : 1)
        // pointer-events-none freezes feedback too — not just activation.
        .onHover { h in
            guard !off else { return }
            withAnimation(.easeOut(duration: 0.08)) { hovered = h }
        }
        // transition-colors duration-80 — hover and press both ride it.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !off else { return }
                    withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                }
                .onEnded { _ in
                    guard !off else { return }
                    withAnimation(.easeOut(duration: 0.08)) { pressed = false }
                }
        )
    }
}

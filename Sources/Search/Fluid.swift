import AppKit
import SwiftUI

// Fluid Functionalism, ported: the system's three spring tiers, its hover
// palette, and the one trick everything else is built on — a highlight that
// never blinks because it glides to whichever item is nearest the cursor.
//
// The reference is the registry source installed in fluid-demo
// (hooks/use-fluid-hover.ts, lib/springs.ts, components/fluid-hover-
// highlight.tsx). Framer's duration+bounce spring model is the same model
// SwiftUI's spring(duration:bounce:) exposes, so the tiers port verbatim.

/// The three tiers, fast to slow. Moderate is the settle tier — critically
/// damped, lands exactly, for panels and merged selection backgrounds. Slow
/// is the only tier allowed to overshoot (bounce 0.12).
enum FluidSpring {
    static let fast = Animation.spring(duration: 0.08, bounce: 0)
    static let moderate = Animation.spring(duration: 0.16, bounce: 0)
    static let slow = Animation.spring(duration: 0.24, bounce: 0.12)
}

/// FF's neutral fills — the library's own tokens, carried rather than
/// mapped onto Palette so the ports stay faithful to the source. The
/// numeric comments are the globals.css values each NSColor stands for.
/// oklch neutrals decode as srgb = encode(L³), never L itself.
enum FluidTone {
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// --foreground: oklch 0.145 / 0.985 → #0A0A0A / #FAFAFA.
    static let foreground = dynamic(NSColor(white: 0.980, alpha: 1), NSColor(white: 0.039, alpha: 1))
    /// --background: white / oklch 0.145 → #0A0A0A.
    static let background = dynamic(NSColor(white: 0.039, alpha: 1), .white)
    /// --muted-foreground: oklch 0.556 / 0.708 → #737373 / #A1A1A1.
    static let mutedForeground = dynamic(NSColor(srgbRed: 0xA1/255, green: 0xA1/255, blue: 0xA1/255, alpha: 1), NSColor(srgbRed: 0x73/255, green: 0x73/255, blue: 0x73/255, alpha: 1))
    /// --accent / --muted: oklch 0.97 / 0.269 → #F5F5F5 / #262626 — the
    /// resting gray fill.
    static let accent = dynamic(NSColor(white: 0.149, alpha: 1), NSColor(white: 0.961, alpha: 1))

    /// The resting hover highlight: black 4% / white 6%.
    static let hover = dynamic(NSColor(white: 1, alpha: 0.06), NSColor(white: 0, alpha: 0.04))
    /// Pressed: black 7% / white 10%.
    static let active = dynamic(NSColor(white: 1, alpha: 0.10), NSColor(white: 0, alpha: 0.07))
    /// The merged-selection block behind checked runs: #D4D4D4 / #525252.
    static let selected = dynamic(
        NSColor(srgbRed: 0x52/255, green: 0x52/255, blue: 0x52/255, alpha: 1),
        NSColor(srgbRed: 0xD4/255, green: 0xD4/255, blue: 0xD4/255, alpha: 1)
    )
    /// The muted track segmented controls and cards sit on — the same
    /// --muted tokens as accent: oklch 0.269 / 0.97 → #262626 / #F5F5F5.
    static let muted = dynamic(NSColor(white: 0.149, alpha: 1), NSColor(white: 0.961, alpha: 1))
    /// --card: white / oklch 0.205 → #171717 — the focused input field's fill.
    static let card = dynamic(NSColor(white: 0.091, alpha: 1), .white)
    /// --destructive: oklch 0.577 0.245 27.325 → #E7000B light;
    /// oklch 0.704 0.191 22.216 → #FF6467 dark (globals.css:140, :200).
    static let destructive = dynamic(
        NSColor(srgbRed: 0xFF/255, green: 0x64/255, blue: 0x67/255, alpha: 1),
        NSColor(srgbRed: 0xE7/255, green: 0x00/255, blue: 0x0B/255, alpha: 1)
    )
    /// --destructive-light: #FEF2F2 / #450A0A — the errored field's tint.
    static let destructiveLight = dynamic(
        NSColor(srgbRed: 0x45/255, green: 0x0A/255, blue: 0x0A/255, alpha: 1),
        NSColor(srgbRed: 0xFE/255, green: 0xF2/255, blue: 0xF2/255, alpha: 1)
    )
    /// User chat-bubble fill: color-mix(in oklab, accent, background 45%) —
    /// oklab L-lerp (0.269·0.55+0.145·0.45 / 0.97·0.55+1·0.45) re-encoded
    /// → #191919 / #F9F9F9.
    static let bubble = dynamic(NSColor(white: 0.098, alpha: 1), NSColor(white: 0.978, alpha: 1))
    /// --border: oklch 0.922 → #E5E5E5 / white 10%.
    static let border = dynamic(NSColor(white: 1, alpha: 0.10), NSColor(white: 0.898, alpha: 1))
    /// The stronger border unchecked boxes show on hover: neutral-400 / -500.
    static let borderStrong = dynamic(
        NSColor(srgbRed: 0x73/255, green: 0x73/255, blue: 0x73/255, alpha: 1),
        NSColor(srgbRed: 0xA3/255, green: 0xA3/255, blue: 0xA3/255, alpha: 1)
    )
    /// --focus-ring: #6B97FF in both schemes.
    static let focusRing = Color(red: 0x6B/255, green: 0x97/255, blue: 1)
    /// The switch's on fill: #6B97FF resting, #5C89F2 hovered.
    static let switchOn = Color(red: 0x6B/255, green: 0x97/255, blue: 1)
    static let switchOnHover = Color(red: 0x5C/255, green: 0x89/255, blue: 0xF2/255)

    /// --surface-N (1-8): flat white above 2 in light; an 8-step dark ladder.
    static func surface(_ level: Int) -> Color {
        let l = max(1, min(8, level))
        let darks: [CGFloat] = [
            0x17/255, 0x1E/255, 0x25/255, 0x2C/255,
            0x33/255, 0x3A/255, 0x41/255, 0x48/255,
        ]
        let lights: [CGFloat] = [0xFA/255, 0xFC/255, 1, 1, 1, 1, 1, 1]
        return dynamic(
            NSColor(white: darks[l - 1], alpha: 1),
            NSColor(white: lights[l - 1], alpha: 1)
        )
    }
}

/// Foreground/background mixed toward each other — the ports of the
/// color-mix() calls the registry uses for hover/active fills.
enum FluidMix {
    /// mix(in oklab, foreground k%, background) — the primary button's
    /// hover (90) and pressed (80) fills. For achromatics oklab L = cbrt
    /// of linear srgb and the mix stays achromatic, so the lerp runs in
    /// L-space then re-encodes — the same pipeline overlayAccent uses.
    /// Lands #1D1D1D / #323232 light, #DEDEDE / #C3C3C3 dark.
    static func fgOverBg(_ k: CGFloat, for scheme: ColorScheme) -> Color {
        func linear(_ s: Double) -> Double {
            s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        func srgb(_ l: Double) -> Double {
            l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
        }
        // The decoded srgb endpoints (oklch 0.985 → 0.980, 0.145 → 0.039,
        // background white / #0A0A0A) — cbrt(linear()) hands the L-space
        // lerp the oklch L back.
        let fg = scheme == .dark ? 0.980 : 0.039
        let bg = scheme == .dark ? 0.039 : 1.0
        let t = Double(k) / 100
        let l = cbrt(linear(fg)) * t + cbrt(linear(bg)) * (1 - t)
        return Color(white: srgb(l * l * l))
    }

    /// color-mix(in oklab, accent, rgb(var(--overlay)) 10%) — the
    /// off-state switch track's hover. For neutrals oklab L = cbrt of
    /// linear srgb, so the mix is an L-space lerp then re-encode; overlay
    /// is black in light mode, white in dark (globals.css:162).
    static func overlayAccent(_ scheme: ColorScheme) -> Color {
        func linear(_ s: Double) -> Double {
            s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        func srgb(_ l: Double) -> Double {
            l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
        }
        // The decoded srgb accents (oklch 0.269 → 0.149, 0.97 → 0.961) —
        // cbrt(linear()) hands the L-space lerp the oklch L back.
        let accent = scheme == .dark ? 0.149 : 0.961
        let overlayL = scheme == .dark ? 1.0 : 0.0
        let l = cbrt(linear(accent)) * 0.9 + overlayL * 0.1
        return Color(white: srgb(l * l * l))
    }

    /// color-mix(in oklab, accent 80%, background) — the secondary
    /// button's hover fill (button.tsx:106). Same L-space pipeline.
    static func accentOverBg(_ scheme: ColorScheme) -> Color {
        func linear(_ s: Double) -> Double {
            s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        func srgb(_ l: Double) -> Double {
            l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
        }
        let accent = scheme == .dark ? 0.149 : 0.961
        let bg = scheme == .dark ? 0.039 : 1.0
        let l = cbrt(linear(accent)) * 0.8 + cbrt(linear(bg)) * 0.2
        return Color(white: srgb(l * l * l))
    }
}

// MARK: - Elevated surfaces
//
// globals.css's shadow-N recipes, simplified to what reads identically at
// panel scale: a 1px ring plus N-1 drop shadows doubling in radius, all at
// black 6%. Dark mode swaps the ring for an inset highlight pair.

extension View {
    /// The surface bg + shadow at a level — surfaceClasses() in the source.
    /// `shape` decides the corners; callers pair it with the panel's radius.
    func fluidSurface(_ level: Int, radius: CGFloat) -> some View {
        modifier(FluidSurface(level: level, radius: radius))
    }
}

private struct FluidSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let level: Int
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                // Shadows hang off the background composite, not the whole
                // subtree — one small render target instead of re-rasterizing
                // every text/icon layer three times.
                ZStack {
                    shape.fill(FluidTone.surface(level))
                    if scheme == .dark {
                        // dm-ring: inset ring + a top inner highlight.
                        shape.strokeBorder(.white.opacity(level >= 4 ? 0.04 : 0.02), lineWidth: 1)
                        shape.fill(
                            LinearGradient(
                                colors: [.white.opacity(level >= 5 ? 0.04 : 0.02), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        ).frame(height: 14).frame(maxHeight: .infinity, alignment: .top)
                            .clipShape(shape)
                    } else {
                        shape.strokeBorder(.black.opacity(0.06), lineWidth: 1)
                    }
                }
                .shadow(
                    color: .black.opacity(scheme == .dark ? 0.18 : 0.06),
                    radius: level >= 3 ? 1.5 : 0.5, y: 1
                )
                .shadow(
                    color: .black.opacity(scheme == .dark ? 0.18 : 0.06),
                    radius: level >= 3 ? 3 : 0, y: level >= 3 ? 1.5 : 0
                )
                .shadow(
                    color: .black.opacity(scheme == .dark ? 0.18 : 0.06),
                    radius: level >= 4 ? 6 : 0, y: level >= 4 ? 3 : 0
                )
            }
    }
}

/// One corner-radii scale per app: rounded (the default everywhere) or pill.
/// `bg` is the item radius; `focusRing` is +2 for the ring drawn 2px out;
/// `container` is the padded-group radius; `merged` the checkbox-run block.
enum FluidShape {
    case rounded, pill

    var item: CGFloat { self == .pill ? 20 : 8 }
    var bg: CGFloat { self == .pill ? 20 : 8 }
    var focusRing: CGFloat { self == .pill ? 22 : 10 }
    var merged: CGFloat { self == .pill ? 16 : 8 }
    var container: CGFloat { self == .pill ? 24 : 12 }
    var button: CGFloat { self == .pill ? 20 : 8 }
    var input: CGFloat { self == .pill ? 20 : 8 }
    var pillish: Bool { self == .pill }
}

/// The two-step size ladder every control shares — a 36px default and a
/// 28px compact for dense surfaces.
enum FluidSize {
    case `default`, compact

    var controlHeight: CGFloat { self == .compact ? 28 : 36 }
    var segmentItem: CGFloat { self == .compact ? 24 : 28 }
    var segmentPad: CGFloat { self == .compact ? 2 : 4 }
    var text: CGFloat { self == .compact ? 12 : 13 }
    var px: CGFloat { self == .compact ? 10 : 12 }
    var itemPx: CGFloat { self == .compact ? 6 : 8 }
    var gap: CGFloat { self == .compact ? 4 : 8 }
    var icon: CGFloat { self == .compact ? 14 : 16 }
}

// MARK: - Fluid hover

/// The pick, as one pure function — a straight port of pickNearest in
/// use-fluid-hover.ts. An item the pointer is inside wins; otherwise the
/// item whose center is nearest does, so a pointer in a gap, in the padding,
/// or past the last row still lands. Ties keep the earlier index.
enum FluidHoverAxis {
    case x, y, xy
}

func fluidPickNearest(
    axis: FluidHoverAxis,
    point: CGPoint,
    rects: [(Int, CGRect)],
    isDisabled: (Int) -> Bool
) -> Int? {
    var closest: Int? = nil
    var closestDistance = CGFloat.infinity
    var containing: Int? = nil

    for (index, r) in rects {
        if isDisabled(index) { continue }
        switch axis {
        case .xy:
            if r.contains(point) { containing = index }
            let d = hypot(point.x - r.midX, point.y - r.midY)
            if d < closestDistance { closestDistance = d; closest = index }
        case .x:
            if point.x >= r.minX && point.x <= r.maxX { containing = index }
            let d = abs(point.x - r.midX)
            if d < closestDistance { closestDistance = d; closest = index }
        case .y:
            if point.y >= r.minY && point.y <= r.maxY { containing = index }
            let d = abs(point.y - r.midY)
            if d < closestDistance { closestDistance = d; closest = index }
        }
    }
    return containing ?? closest
}

/// The hover state for one list — rects the items publish, the index the
/// pick resolves to, and the session counter that re-keys the highlight so a
/// fresh entry fades in place instead of sliding in from the last row.
@Observable
final class FluidHover {
    /// Unique coordinate space for this container.
    let space = "fluid-\(UUID().uuidString)"
    let axis: FluidHoverAxis
    /// Skip an item without removing it — a disabled row is never lit and
    /// never picked. Runs per move, keep it cheap.
    var isItemDisabled: (Int) -> Bool = { _ in false }
    /// A click between items goes to the lit one — the highlight is a
    /// promise about the click. False keeps gaps inert.
    var gapClick = true
    /// The source's `gapClick: { maxDistance }` — a gap click farther than
    /// this from the lit rect does nothing (card.tsx uses 16).
    var gapClickMaxDistance: CGFloat = .infinity
    /// Freeze the current pick — while a row's popup is open the source
    /// suppresses mouse-move, so the highlight stays pinned rather than
    /// tracking (or clearing) under the cursor. Mouse-leave stays live
    /// (onMouseLeave is ungated in the source).
    var frozen = false

    /// Points inside these rects produce no pick — accordion content areas
    /// register here so a cursor inside an open panel isn't "hovering"
    /// its trigger (the group's onMouseMove suppression in the source).
    var deadRects: [CGRect] = []

    var rects: [Int: CGRect] = [:] {
        didSet { ordered = rects.sorted { $0.key < $1.key } }
    }
    /// Rects pre-sorted by index — the pick walks them on every mouse move,
    /// so sorting once per layout change beats sorting per event.
    @ObservationIgnored private(set) var ordered: [(Int, CGRect)] = []
    /// Item labels for popup typeahead — the source reads textContent off
    /// the DOM; rows that have a label report it here (Radix's typeahead
    /// data). Optional; rows without a label just don't match.
    var itemLabels: [Int: String] = [:]
    /// Rows hosting a submenu — index → opener (the Bool asks for first-row
    /// focus, i.e. a keyboard open). Enter/Space/→ and gap-picks route here
    /// instead of activating (Radix SubTrigger's SUB_OPEN_KEYS).
    var submenuActions: [Int: (Bool) -> Void] = [:]
    /// Each row's own click path (onSelect + dismiss env) — keyboard
    /// activation and gap-picks dispatch here before the panel-level
    /// onPick fallback, so rows wired with only onSelect aren't
    /// keyboard-dead (Radix: Enter synthesizes the item's click).
    var rowActions: [Int: () -> Void] = [:]
    /// Set when the keyboard writes the pick (navKey's setFocus), cleared
    /// by pointer moves — submenu triggers auto-open on pointer hover
    /// only, never on roving arrow-key focus (Radix opens a Sub on
    /// →/Enter/hover, not on roving focus).
    var navDrivenFocus = false
    /// The row whose submenu is currently open — while set, this scope's
    /// nav/typeahead keys yield to the sub's own monitor (Radix moves
    /// keyboard nav into the sub rather than moving the parent's focus).
    var openSubIndex: Int? = nil
    /// Rows disabled by their own `disabled:` prop rather than the panel's
    /// `disabledIndices` — isItemDisabled unions both sets so the pick,
    /// gap-pick, and nav all skip them.
    var rowDisabled: Set<Int> = []
    var activeIndex: Int? = nil
    var session = 0
    private var inside = false

    init(axis: FluidHoverAxis = .y) { self.axis = axis }

    var activeRect: CGRect? {
        guard let i = activeIndex else { return nil }
        return rects[i]
    }

    func moved(to point: CGPoint) {
        guard !frozen else { return }
        navDrivenFocus = false
        if deadRects.contains(where: { $0.contains(point) }) {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        if !inside { inside = true; session += 1 }
        let pick = fluidPickNearest(
            axis: axis, point: point, rects: ordered, isDisabled: isItemDisabled
        )
        if pick != activeIndex { activeIndex = pick }
    }

    func exited() {
        inside = false
        if activeIndex != nil { activeIndex = nil }
    }
}

extension EnvironmentValues {
    @Entry var fluidHover: FluidHover? = nil
    /// The ambient shape context — React's ShapeProvider. Popups ignore
    /// it (always rounded); triggers/inputs follow it.
    @Entry var fluidShape: FluidShape = .rounded
    @Entry var fluidSize: FluidSize = .default
}

/// Debug/perf gate: FLUID_QUIET=1 freezes perpetual animations so idle CPU
/// can be measured without display-linked state churn.
enum FluidPerf {
    static let quiet = ProcessInfo.processInfo.environment["FLUID_QUIET"] == "1"
}

// MARK: - Modifiers

/// Marks a row as fluid-hover item `index`. The row reports its frame in the
/// enclosing container's named space — the port of registerItem.
struct FluidItem: ViewModifier {
    @Environment(\.fluidHover) private var hover
    let index: Int

    func body(content: Content) -> some View {
        content
            // onGeometryChange reports straight into the store — one callback
            // per item, no GeometryReader + preference merge per row.
            .onGeometryChange(for: CGRect.self) { proxy in
                hover.map { proxy.frame(in: .named($0.space)) } ?? .zero
            } action: { frame in
                guard let hover, frame != .zero, hover.rects[index] != frame else { return }
                hover.rects[index] = frame
            }
            // Index moves leave the old key behind — drop it explicitly.
            .onChange(of: index) { old, _ in hover?.rects[old] = nil }
            .onDisappear { hover?.rects[index] = nil }
    }
}

extension View {
    /// Registers this view as item `index` in the nearest fluid container.
    func fluidItem(_ index: Int) -> some View { modifier(FluidItem(index: index)) }
}

/// The container: names the coordinate space, tracks the pointer, publishes
/// the highlight underneath its content, and routes gap clicks to the lit
/// item. Wraps content like a VStack — put `.fluidItem(i)` on the rows.
struct FluidContainer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Bindable var hover: FluidHover
    /// Where a fresh session's highlight fades in from — a checked row, an
    /// active route. Defaults to the picked rect itself.
    var from: CGRect? = nil
    /// The highlight's corner radius — the shape system's `bg`.
    var radius: CGFloat = 8
    /// Input groups track the pick without drawing the highlight —
    /// the hovered field paints its own bg + ring instead.
    var showsHighlight = true
    /// Called when a gap click lands on the lit item — the routed click.
    var onGapPick: ((Int) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .coordinateSpace(name: hover.space)
            .background(alignment: .topLeading) {
                if showsHighlight, let rect = hover.activeRect {
                    FluidHighlight(
                        rect: rect, from: from, index: hover.activeIndex ?? -1,
                        radius: radius,
                        fill: FluidTone.hover,
                        travel: !reduceMotion
                    )
                    .id(hover.session)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.06), value: hover.activeIndex != nil)
            .onContinuousHover(coordinateSpace: .named(hover.space)) { phase in
                switch phase {
                case .active(let point): hover.moved(to: point)
                case .ended: hover.exited()
                }
            }
            .contentShape(Rectangle())
            // Gap click → activate. NOTE: SwiftUI delivers this tap only
            // over the container's own surface and gesture-less children;
            // inert child regions (e.g. a sub-menu rail strip) swallow it
            // — the DOM's document-level pointerdown has no hit-test-
            // transparent equivalent. Reachable dead surface is ~8px.
            // Interactive children keep their own clicks, which covers the
            // source's closest(input,button,a,…) exclusion.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(hover.space))
                    .onEnded { value in
                        guard hover.gapClick, let i = hover.activeIndex,
                              !hover.isItemDisabled(i) else { return }
                        // simultaneousGesture still fires over row Buttons
                        // — a tap inside a registered row rect is the row's
                        // own activation, not a gap pick (double-select).
                        if hover.rects.values.contains(where: {
                            $0.contains(value.location)
                        }) { return }
                        // gapClick:{maxDistance} — clicks beyond the cap
                        // from the lit rect are inert (use-fluid-hover).
                        if hover.gapClickMaxDistance != .infinity,
                           let r = hover.rects[i] {
                            let p = value.location
                            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
                            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
                            if hypot(dx, dy) > hover.gapClickMaxDistance { return }
                        }
                        onGapPick?(i)
                    }
            )
            .environment(\.fluidHover, hover)
    }
}

/// The one highlight every fluid list renders — the port of
/// FluidHoverHighlight. Springs between the rects the container measures;
/// a fresh session mounts at `from` (or the rect itself) and fades in while
/// it glides to the target. Exit is a 60ms fade, matching the registry.
private struct FluidHighlight: View {
    /// (index, rect) as one onChange payload — index moves spring,
    /// same-row reflows snap (the source's rowChanged rule).
    private struct Target: Equatable { var index: Int; var rect: CGRect }

    let rect: CGRect
    let from: CGRect?
    let index: Int
    let radius: CGFloat
    let fill: Color
    /// Reduced motion drops the travel but keeps the fade.
    let travel: Bool

    @State private var current: CGRect
    @State private var opacity = 0.0
    @State private var last: Target

    init(rect: CGRect, from: CGRect?, index: Int, radius: CGFloat, fill: Color, travel: Bool) {
        self.rect = rect
        self.from = from
        self.index = index
        self.radius = radius
        self.fill = fill
        self.travel = travel
        _current = State(initialValue: from ?? rect)
        _last = State(initialValue: Target(index: index, rect: rect))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .frame(width: current.width, height: current.height)
            .position(x: current.midX, y: current.midY)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.08)) { opacity = 1 }
                withAnimation(travel ? FluidSpring.fast : nil) { current = rect }
            }
            .onChange(of: Target(index: index, rect: rect)) { _, new in
                defer { last = new }
                if new.index != last.index {
                    withAnimation(travel ? FluidSpring.fast : nil) { current = new.rect }
                } else {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { current = new.rect }
                }
            }
    }
}

// MARK: - shimmer sweep (thinking styles)

/// The registry's shimmer — `background: linear-gradient(90deg, base,
/// #525252, base)` at `background-size: 300%` sliding right-to-left across
/// the glyphs (the sweep reads as a tint band because only the 35–65%
/// window differs from the base). The band lives on a CAGradientLayer
/// animated by Core Animation inside a cached `mask` of the content —
/// nothing in the app ticks per frame, and the string rasterizes once.
private struct FluidShimmerSweep: ViewModifier {
    var tint: Color
    var active: Bool
    var duration: Double = 1.5
    @State private var w: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w = $0 }
            .overlay(alignment: .leading) {
                if active, !reduceMotion, !FluidPerf.quiet, w > 0 {
                    FluidShimmerBand(tint: tint, width: w, duration: duration)
                        .mask { content }
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct FluidShimmerBand: NSViewRepresentable {
    var tint: Color
    var width: CGFloat
    var duration: Double

    func makeNSView(context: Context) -> FluidShimmerView { FluidShimmerView() }
    func updateNSView(_ view: FluidShimmerView, context: Context) {
        view.tint = NSColor(tint)
        view.contentWidth = width
        view.duration = duration
    }
}

/// The sweep band: 0.9×content wide soft-dark-soft gradient (the CSS
/// gradient's 35%→65% core), starting at 1.05× content width and sliding
/// −2× content — `background-position: 0%→100%` on a 300% gradient.
final class FluidShimmerView: NSView {
    var tint = NSColor.gray { didSet { apply() } }
    var contentWidth: CGFloat = 0 { didSet { apply() } }
    var duration: Double = 1.5 { didSet { apply() } }
    private let band = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        band.colors = nil
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(band)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() { super.layout(); apply() }

    private func apply() {
        guard bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: contentWidth * 1.05, y: 0,
                            width: contentWidth * 0.9, height: bounds.height)
        band.colors = [
            tint.withAlphaComponent(0).cgColor, tint.cgColor, tint.withAlphaComponent(0).cgColor,
        ]
        CATransaction.commit()
        band.removeAnimation(forKey: "sweep")
        guard contentWidth > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0
        sweep.toValue = -2 * contentWidth
        sweep.duration = duration
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: "sweep")
    }
}

extension View {
    /// Soft `tint` band sweeping the view's alpha — the registry's shimmer.
    func fluidShimmerSweep(_ tint: Color, active: Bool,
                           duration: Double = 1.5) -> some View {
        modifier(FluidShimmerSweep(tint: tint, active: active, duration: duration))
    }
}

// MARK: - scroll-fade (globals.css)
//
// The `.scroll-fade` viewport mask: a `--scroll-fade-size` gradient at the
// top and bottom edges. With scroll-timeline support (the demos in Chrome)
// each edge's fade ramps in only after you scroll away from it — at rest
// the top edge is crisp. `.scroll-divider` draws a hairline at each
// scrolled-away edge.

/// Tracks a scroll viewport's fade state for `fluidScrollFade` — stores the
/// derived edge alphas, not the content frame, so mid-scroll ticks (which
/// don't change the fades) don't invalidate the mask.
@Observable
final class FluidScrollFadeState {
    /// Unique coordinate space — the content sentinel measures in it.
    let space = "fluid-fade-\(UUID().uuidString)"
    /// Fade ramp length in points — set by the modifier at creation.
    var fadeSize: CGFloat = 48
    /// Edge alphas for the mask — 1 = crisp, ramps to 0 over `fadeSize`.
    var topAlpha: CGFloat = 1
    var bottomAlpha: CGFloat = 1
    var overflowing = false
    private(set) var viewHeight: CGFloat = 0
    private var lastRect: CGRect = .zero

    func update(_ rect: CGRect) {
        lastRect = rect
        let ov = rect.height > viewHeight + 0.5
        if ov != overflowing { overflowing = ov }
        let t = ov ? 1 - min(1, max(0, -rect.origin.y) / fadeSize) : 1
        let b = ov ? 1 - min(1, max(0, rect.maxY - viewHeight) / fadeSize) : 1
        if t != topAlpha { topAlpha = t }
        if b != bottomAlpha { bottomAlpha = b }
    }

    /// Recompute with the last content rect — the viewport height and the
    /// content frame arrive on separate callbacks, either can land first.
    func setViewHeight(_ h: CGFloat) {
        guard viewHeight != h else { return }
        viewHeight = h
        update(lastRect)
    }
}

extension View {
    /// Inside the ScrollView's content — reports the content frame so the
    /// enclosing `fluidScrollFade` knows the scroll position.
    func fluidFadeContent(_ state: FluidScrollFadeState) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(state.space))
        } action: { rect in
            state.update(rect)
        }
    }

    /// On the ScrollView — masks the top/bottom edges progressively (the
    /// scroll-timeline scroll-fade) and, with `dividers`, draws a hairline
    /// at each edge once scrolled away from it.
    func fluidScrollFade(
        _ size: CGFloat = 48,
        state: FluidScrollFadeState,
        dividers: Bool = false
    ) -> some View {
        state.fadeSize = size
        return modifier(FluidScrollFade(size: size, state: state, dividers: dividers))
    }
}

private struct FluidScrollFade: ViewModifier {
    var size: CGFloat
    @Bindable var state: FluidScrollFadeState
    var dividers: Bool

    func body(content: Content) -> some View {
        let viewH = max(state.viewHeight, 1)
        let p1 = min(size / viewH, 0.5), p2 = max(1 - size / viewH, 0.5)
        return content
            .coordinateSpace(name: state.space)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                state.setViewHeight(h)
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .black.opacity(state.topAlpha), location: 0),
                    .init(color: .black, location: p1),
                    .init(color: .black, location: p2),
                    .init(color: .black.opacity(state.bottomAlpha), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .top) {
                if dividers {
                    Rectangle().fill(FluidTone.border)
                        .frame(height: 1)
                        .opacity(state.overflowing && state.topAlpha < 1 ? 1 : 0)
                }
            }
            .overlay(alignment: .bottom) {
                if dividers {
                    Rectangle().fill(FluidTone.border)
                        .frame(height: 1)
                        .opacity(state.overflowing && state.bottomAlpha < 1 ? 1 : 0)
                }
            }
    }
}

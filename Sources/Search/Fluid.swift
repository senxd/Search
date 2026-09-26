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
enum FluidTone {
    private static func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// --foreground: oklch 0.145 / 0.985 (~neutral-900 / neutral-50).
    static let foreground = dynamic(NSColor(white: 0.985, alpha: 1), NSColor(srgbRed: 0x17/255, green: 0x17/255, blue: 0x17/255, alpha: 1))
    /// --background: white / oklch 0.145.
    static let background = dynamic(NSColor(srgbRed: 0x17/255, green: 0x17/255, blue: 0x17/255, alpha: 1), .white)
    /// --muted-foreground: oklch 0.556 / 0.708 (~neutral-500 / neutral-400).
    static let mutedForeground = dynamic(NSColor(srgbRed: 0xA3/255, green: 0xA3/255, blue: 0xA3/255, alpha: 1), NSColor(srgbRed: 0x73/255, green: 0x73/255, blue: 0x73/255, alpha: 1))
    /// --accent / --muted: oklch 0.97 / 0.269 — the resting gray fill.
    static let accent = dynamic(NSColor(white: 0.269, alpha: 1), NSColor(white: 0.97, alpha: 1))

    /// The resting hover highlight: black 4% / white 6%.
    static let hover = dynamic(NSColor(white: 1, alpha: 0.06), NSColor(white: 0, alpha: 0.04))
    /// Pressed: black 7% / white 10%.
    static let active = dynamic(NSColor(white: 1, alpha: 0.10), NSColor(white: 0, alpha: 0.07))
    /// The merged-selection block behind checked runs: #D4D4D4 / #525252.
    static let selected = dynamic(
        NSColor(srgbRed: 0x52/255, green: 0x52/255, blue: 0x52/255, alpha: 1),
        NSColor(srgbRed: 0xD4/255, green: 0xD4/255, blue: 0xD4/255, alpha: 1)
    )
    /// The muted track segmented controls and cards sit on: neutral-100ish.
    static let muted = dynamic(NSColor(white: 0.269, alpha: 1), NSColor(white: 0.97, alpha: 1))
    /// --border: neutral-200 / white 10%.
    static let border = dynamic(NSColor(white: 1, alpha: 0.10), NSColor(white: 0.922, alpha: 1))
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
    /// mix(foreground k%, background) — the primary button's hover (90)
    /// and pressed (80) fills.
    static func fgOverBg(_ k: CGFloat, for scheme: ColorScheme) -> Color {
        // mix(foreground k%, background): k% of fg over (100-k)% of bg.
        scheme == .dark
            ? Color(white: 0.985 * k / 100 + (0x17/255) * (100 - k) / 100)
            : Color(white: (0x17/255) * k / 100 + (100 - k) / 100)
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
    rects: [Int: CGRect],
    isDisabled: (Int) -> Bool
) -> Int? {
    var closest: Int? = nil
    var closestDistance = CGFloat.infinity
    var containing: Int? = nil

    for (index, r) in rects.sorted(by: { $0.key < $1.key }) {
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

/// Item frames, reported in the container's named coordinate space.
struct FluidItemRectsKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { a, _ in a }
    }
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

    var rects: [Int: CGRect] = [:]
    var activeIndex: Int? = nil
    var session = 0
    private var inside = false

    init(axis: FluidHoverAxis = .y) { self.axis = axis }

    var activeRect: CGRect? {
        guard let i = activeIndex else { return nil }
        return rects[i]
    }

    func moved(to point: CGPoint) {
        if !inside { inside = true; session += 1 }
        activeIndex = fluidPickNearest(
            axis: axis, point: point, rects: rects, isDisabled: isItemDisabled
        )
    }

    func exited() {
        inside = false
        activeIndex = nil
    }
}

extension EnvironmentValues {
    @Entry var fluidHover: FluidHover? = nil
    /// The ambient shape context — React's ShapeProvider. Popups ignore
    /// it (always rounded); triggers/inputs follow it.
    @Entry var fluidShape: FluidShape = .rounded
    @Entry var fluidSize: FluidSize = .default
}

// MARK: - Modifiers

/// Marks a row as fluid-hover item `index`. The row reports its frame in the
/// enclosing container's named space — the port of registerItem.
struct FluidItem: ViewModifier {
    @Environment(\.fluidHover) private var hover
    let index: Int

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FluidItemRectsKey.self,
                    value: hover.map { [index: geo.frame(in: .named($0.space))] } ?? [:]
                )
            }
        )
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
    /// Called when a gap click lands on the lit item — the routed click.
    var onGapPick: ((Int) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .coordinateSpace(name: hover.space)
            .background(alignment: .topLeading) {
                if let rect = hover.activeRect {
                    FluidHighlight(
                        rect: rect, from: from, radius: radius,
                        fill: FluidTone.hover,
                        travel: !reduceMotion
                    )
                    .id(hover.session)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.06), value: hover.activeIndex != nil)
            .onPreferenceChange(FluidItemRectsKey.self) { hover.rects = $0 }
            .onContinuousHover(coordinateSpace: .named(hover.space)) { phase in
                switch phase {
                case .active(let point): hover.moved(to: point)
                case .ended: hover.exited()
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { _ in
                    guard hover.gapClick, let i = hover.activeIndex else { return }
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
    let rect: CGRect
    let from: CGRect?
    let radius: CGFloat
    let fill: Color
    /// Reduced motion drops the travel but keeps the fade.
    let travel: Bool

    @State private var current: CGRect
    @State private var opacity = 0.0

    init(rect: CGRect, from: CGRect?, radius: CGFloat, fill: Color, travel: Bool) {
        self.rect = rect
        self.from = from
        self.radius = radius
        self.fill = fill
        self.travel = travel
        _current = State(initialValue: from ?? rect)
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
            .onChange(of: rect) { _, new in
                withAnimation(travel ? FluidSpring.fast : nil) { current = new }
            }
    }
}

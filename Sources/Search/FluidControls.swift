import AppKit
import SwiftUI

// The pilot controls — Button, Chip, Badge, Switch — ported from the
// registry sources in fluid-demo (components/ui/{button,badge,switch}.tsx,
// with the chip taking the leger.-web badge redesign the way the demo
// page does and FluidBadge carrying the registry badge itself).
//
// The press trick is verbatim: at rest the fill paints the full box (the
// source fakes it with a 1px shadow spread); on press it collapses to a
// 1px-inset box, so the surface shrinks exactly 1px per side at any width.

// MARK: - Button

enum FluidButtonVariant { case primary, secondary, tertiary, ghost }
enum FluidButtonSize { case `default`, compact, icon, iconCompact, iconSmall

    var isIconOnly: Bool { self == .icon || self == .iconCompact || self == .iconSmall }
    var isCompact: Bool { self == .compact || self == .iconCompact || self == .iconSmall }
    // iconSmall is the composer footer's compact-step rung — the source
    // squashes every footer button to h-6 / text-11 under the compact
    // step (input-message.tsx:1244-1246).
    var height: CGFloat { self == .iconSmall ? 24 : isCompact ? 28 : 36 }
    var fontSize: CGFloat { self == .iconSmall ? 11 : isCompact ? 12 : 13 }
    var iconSize: CGFloat { isCompact ? 14 : 16 }
    var hPadding: CGFloat { isCompact ? 12 : 16 }
    var gap: CGFloat { isCompact ? 4 : 6 }
}

struct FluidButton<Label: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.fluidShape) private var contextShape
    var variant: FluidButtonVariant = .primary
    var size: FluidButtonSize = .default
    var loading = false
    /// Forced visual-pressed state, e.g. while a popup it opened is showing.
    var active = false
    var leadingIcon: String? = nil
    var trailingIcon: String? = nil
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var hovered = false
    @State private var pressed = false
    /// The spread-collapse inset rides its own channel — the source's
    /// press shadow releases on transition-duration-180 while the
    /// background color releases at 80ms (button.tsx:23,44).
    @State private var pressedInset = false
    /// The focus-visible ring — button.tsx:23 (`focus-visible:ring-1
    /// ring-[#6B97FF]`). macOS has no :focus-visible, so the switch's
    /// pointerFocus latch approximates it: a pointer press suppresses the
    /// ring until key input or blur restores it.
    @FocusState private var focused: Bool
    // Assume pointer modality until a key arrives — an auto-assigned first
    // responder at window open must not paint the ring (no :focus-visible
    // on launch, mirroring the sidebar's pointerInput default).
    @State private var pointerFocus = true

    init(
        _ title: String,
        variant: FluidButtonVariant = .primary,
        size: FluidButtonSize = .default,
        loading: Bool = false,
        active: Bool = false,
        leadingIcon: String? = nil,
        trailingIcon: String? = nil,
        action: @escaping () -> Void
    ) where Label == Text {
        self.init(
            variant: variant, size: size, loading: loading, active: active,
            leadingIcon: leadingIcon, trailingIcon: trailingIcon,
            action: action, label: { Text(title) }
        )
    }

    init(
        variant: FluidButtonVariant = .primary,
        size: FluidButtonSize = .default,
        loading: Bool = false,
        active: Bool = false,
        leadingIcon: String? = nil,
        trailingIcon: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.variant = variant
        self.size = size
        self.loading = loading
        self.active = active
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.action = action
        self.label = label
    }

    private var textColor: Color {
        switch variant {
        case .primary: return FluidTone.background
        case .ghost: return hovered || pressed ? FluidTone.foreground : FluidTone.mutedForeground
        default: return FluidTone.foreground
        }
    }

    private var fill: Color {
        switch variant {
        case .primary:
            if pressed || active { return FluidMix.fgOverBg(80, for: scheme) }
            if hovered { return FluidMix.fgOverBg(90, for: scheme) }
            return FluidTone.foreground
        case .secondary:
            if hovered && !pressed && !active {
                // color-mix(in oklab, accent 80%, background) — only
                // visibly differs in light (button.tsx:106).
                return FluidMix.accentOverBg(scheme)
            }
            return FluidTone.accent
        case .tertiary:
            return pressed || active ? FluidTone.active : (hovered ? FluidTone.hover : .clear)
        case .ghost:
            return pressed || active ? FluidTone.active : (hovered ? FluidTone.hover : .clear)
        }
    }

    /// An icon sits 4px closer to its edge than text does — the source's
    /// compoundVariants: pl-3/pr-3 default, pl-2/pr-2 compact against the
    /// 16px/12px base padding (button.tsx:46-51).
    private var leadingPad: CGFloat { leadingIcon != nil ? size.hPadding - 4 : size.hPadding }
    private var trailingPad: CGFloat { trailingIcon != nil ? size.hPadding - 4 : size.hPadding }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: contextShape.button, style: .continuous)
        Button(action: action) {
            HStack(spacing: size.gap) {
                if !size.isIconOnly, let leadingIcon {
                    FluidIcon(leadingIcon, size: size.iconSize, bold: hovered || pressed)
                }
                label()
                    // Icon-only labels size on the icon step — the
                    // source's size-icon classes (button.tsx:46-51).
                    .font(.system(size: size.isIconOnly ? size.iconSize : size.fontSize))
                if !size.isIconOnly, let trailingIcon {
                    FluidIcon(trailingIcon, size: size.iconSize, bold: hovered || pressed)
                }
            }
            .opacity(loading ? 0 : 1)
            .frame(
                minWidth: size.isIconOnly ? size.height : nil,
                maxWidth: size.isIconOnly ? size.height : nil,
                minHeight: size.height, maxHeight: size.height
            )
            .padding(.leading, size.isIconOnly ? 0 : leadingPad)
            .padding(.trailing, size.isIconOnly ? 0 : trailingPad)
            .foregroundStyle(textColor)
            .overlay {
                if loading { FluidSpinner(size: size.isCompact ? 28 : 36, color: textColor) }
            }
            .background {
                // inset 1px while pressed — the spread-collapse press
                // effect, released on the shadow's 180ms channel. Forced
                // active keeps the geometric collapse too (button.tsx:119).
                shape.fill(fill).padding(pressedInset ? 1 : 0)
                if variant == .tertiary {
                    // Forced-active keeps the outer ring; only a real
                    // :active press insets it (activeBgVariants).
                    shape.strokeBorder(FluidTone.border, lineWidth: 1)
                        .padding(pressedInset ? 1 : 0)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || loading)
        // disabled:opacity-50 covers the loading-disabled state too
        // (button.tsx:268 — disabled || loading).
        .opacity(isEnabled && !loading ? 1 : 0.5)
        // focus-visible:ring-1 ring-[#6B97FF] — a bare 1px band hugging the
        // button edge (no offset in the source), shown only for keyboard
        // modality: a pointer press latches it off until a key lands.
        .overlay {
            if focused && !pointerFocus {
                shape.strokeBorder(FluidTone.focusRing, lineWidth: 1).padding(-1)
            }
        }
        .focusable(isEnabled && !loading)
        .focused($focused)
        .focusEffectDisabled()
        .onHover { h in
            withAnimation(.easeOut(duration: 0.08)) { hovered = h }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    pointerFocus = true
                    // Press-in rides the shortened :active duration
                    // (group-active:[transition-duration:80ms]).
                    withAnimation(.easeOut(duration: 0.08)) {
                        pressed = true
                        pressedInset = true
                    }
                }
                .onEnded { _ in
                    // background-color releases at 80ms; the inset
                    // (box-shadow) releases on the 180ms channel.
                    withAnimation(.easeOut(duration: 0.08)) { pressed = false }
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) {
                        pressedInset = false
                    }
                }
        )
        // Any key landing while focused is keyboard modality — observe
        // without eating the event so native Space/Return activation holds.
        .onKeyPress(phases: .down) { _ in
            pointerFocus = false
            return .ignored
        }
        .onChange(of: focused) { _, f in
            // Blur resets the latch. A focus arriving under a keyDown
            // (Tab) is :focus-visible — a press-focus or the window's
            // auto-assigned first responder keeps the pointer latch.
            if !f || (!pressed && NSApp.currentEvent?.type == .keyDown) {
                pointerFocus = false
            }
        }
    }
}

/// SF Symbol wrapper for the FF icon treatment — stroke 1.5 at rest,
/// thickening to ~2 on hover (the registry animates stroke-width on
/// lucide icons; on SF Symbols the near-equivalent is a weight bump).
struct FluidIcon: View {
    let name: String
    let size: CGFloat
    let bold: Bool

    init(_ name: String, size: CGFloat, bold: Bool = false) {
        self.name = name; self.size = size; self.bold = bold
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: bold ? .medium : .light))
            .animation(.easeOut(duration: 0.08), value: bold)
    }
}

/// The button's loading glyph — the registry's figure-8 path, trimmed and
/// run around the loop. Path is the svg from button.tsx scaled to the box.
struct FluidSpinner: NSViewRepresentable {
    let size: CGFloat
    var color: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> FluidSpinnerView {
        FluidSpinnerView(animated: !reduceMotion && !FluidPerf.quiet)
    }

    func updateNSView(_ view: FluidSpinnerView, context: Context) {
        view.strokeColor = NSColor(color)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: FluidSpinnerView, context: Context
    ) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// The spinner's rendering layer — CoreAnimation carries both loops
/// (`spinner-move` 2s linear, `spinner-dash` 4s ease-in-out) entirely on the
/// render server, so nothing in the app ticks per frame.
final class FluidSpinnerView: NSView {
    var strokeColor = NSColor.white { didSet { shape.strokeColor = resolved } }
    private let animated: Bool
    private let shape = CAShapeLayer()
    private var resolved: CGColor { strokeColor.cgColor }

    init(animated: Bool) {
        self.animated = animated
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineCap = .round
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.lineWidth = 1.125 * min(bounds.width, bounds.height) / 24
        shape.path = Self.loopedPath(in: CGRect(origin: .zero, size: bounds.size))
        shape.strokeColor = resolved
        // Model values = the first animation frame — the arc at path start,
        // 15% of one loop — so rest presentation and snapshot captures match.
        shape.strokeStart = 1.0 / 3
        shape.strokeEnd = (1.0 + 0.15) / 3
        CATransaction.commit()
        arm()
    }

    private var armed = false
    private func arm() {
        guard animated, !armed, bounds.width > 0 else { return }
        armed = true
        // The path is the lemniscate traced three times, and the arc lives
        // in the middle copy: strokeStart sweeps 1/3→2/3 linearly (the
        // dashoffset travel — one loop per 2s, the repeat boundary landing
        // on the identical trace), strokeEnd adds the breathing arc length.
        let start = CABasicAnimation(keyPath: "strokeStart")
        start.fromValue = 1.0 / 3
        start.toValue = 2.0 / 3
        start.duration = 2
        start.repeatCount = .infinity
        shape.add(start, forKey: "travel")

        var times: [NSNumber] = []
        var ends: [NSNumber] = []
        for i in 0..<96 {
            let t = Double(i) / 24 // 96 keys over 4s
            if t == 2 { times.append(NSNumber(value: (t - 0.0005) / 4)); ends.append(NSNumber(value: Self.end(t - 0.0005))) }
            times.append(NSNumber(value: t / 4)); ends.append(NSNumber(value: Self.end(t)))
        }
        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.keyTimes = times
        end.values = ends
        end.duration = 4
        end.repeatCount = .infinity
        shape.add(end, forKey: "breathe")
    }

    /// (1 + travel + length)/3 — travel runs 0→1 per 2s, length breathes
    /// 15%→40% of one loop on `spinner-dash`'s 4s ease-in-out cycle.
    private static func end(_ t: Double) -> Double {
        let u = t.truncatingRemainder(dividingBy: 4)
        let f = u < 2 ? u / 2 : (4 - u) / 2
        let b = 0.5 - 0.5 * cos(.pi * f)
        return (1 + t.truncatingRemainder(dividingBy: 2) / 2 + 0.15 + 0.25 * b) / 3
    }

    /// The 24-box lemniscate of button.tsx traced three times — identical
    /// figure, tripled param range so the moving arc never wraps.
    private static func loopedPath(in rect: CGRect) -> CGPath {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        let path = CGMutablePath()
        for _ in 0..<3 {
            path.move(to: p(12, 12))
            path.addCurve(to: p(19, 12), control1: p(14, 8.5), control2: p(19, 8.5))
            path.addCurve(to: p(12, 12), control1: p(19, 15.5), control2: p(14, 15.5))
            path.addCurve(to: p(5, 12), control1: p(10, 8.5), control2: p(5, 8.5))
            path.addCurve(to: p(12, 12), control1: p(5, 15.5), control2: p(10, 15.5))
            path.closeSubpath()
        }
        return path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shape.strokeColor = resolved
    }
}

// MARK: - Chip (the leger badge redesign)
//
// Fixed 6px radius, translucent tints, stronger text — leger's badge.tsx,
// NOT the registry's color-mix badge. Three sizes, named hues.

enum FluidChipColor: String, CaseIterable {
    case gray, red, amber, green, blue, violet

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .gray: (0xA3/255, 0xA3/255, 0xA3/255)
        case .red: (0xEF/255, 0x44/255, 0x44/255)
        case .amber: (0xF5/255, 0x9E/255, 0x0B/255)
        case .green: (0x22/255, 0xC5/255, 0x5E/255)
        case .blue: (0x3B/255, 0x82/255, 0xF6/255)
        case .violet: (0x8B/255, 0x5C/255, 0xF6/255)
        }
    }
}

enum FluidChipSize { case sm, md, lg
    var height: CGFloat { self == .sm ? 20 : self == .lg ? 28 : 24 }
    var hPadding: CGFloat { self == .sm ? 6 : self == .lg ? 12 : 10 }
    var fontSize: CGFloat { self == .sm ? 11 : self == .lg ? 13 : 12 }
}

struct FluidChip: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var color: FluidChipColor = .gray
    var size: FluidChipSize = .md

    init(_ text: String, color: FluidChipColor = .gray, size: FluidChipSize = .md) {
        self.text = text; self.color = color; self.size = size
    }

    private var chipText: Color {
        if color == .gray { return FluidTone.foreground.opacity(0.8) }
        let fg: CGFloat = scheme == .dark ? 0.980 : 0.039
        return Color(
            red: color.rgb.0 * 0.85 + fg * 0.15,
            green: color.rgb.1 * 0.85 + fg * 0.15,
            blue: color.rgb.2 * 0.85 + fg * 0.15
        )
    }

    private var chipFill: Color {
        if color == .gray { return FluidTone.foreground.opacity(0.10) }
        return Color(red: color.rgb.0, green: color.rgb.1, blue: color.rgb.2, opacity: 0.18)
    }

    var body: some View {
        Text(text)
            .font(.system(size: size.fontSize, weight: .medium))
            .foregroundStyle(chipText)
            .padding(.horizontal, size.hPadding)
            .frame(height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(chipFill)
            )
    }
}

// MARK: - Badge (the registry badge.tsx)
//
// The registry's badge — a 17-hue palette crossed with two variants.
// `solid` fills color-mix(hue 15%, background) under foreground text;
// `dot` drops the fill for a 1px --border ring and leads the label with
// a status dot. Corners follow \.fluidShape.item, size the \.fluidSize
// ladder (24/20px — shorter than controls), with the source's legacy
// sm/md/lg aliases still resolving onto it.

enum FluidBadgeColor: String, CaseIterable {
    case gray, red, orange, amber, yellow, lime, green, emerald, teal, cyan,
         blue, indigo, violet, purple, fuchsia, pink, rose

    /// badgeColors in badge.tsx, verbatim srgb hexes.
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .gray: (0xA3/255, 0xA3/255, 0xA3/255)
        case .red: (0xEF/255, 0x44/255, 0x44/255)
        case .orange: (0xF9/255, 0x73/255, 0x16/255)
        case .amber: (0xF5/255, 0x9E/255, 0x0B/255)
        case .yellow: (0xEA/255, 0xB3/255, 0x08/255)
        case .lime: (0x84/255, 0xCC/255, 0x16/255)
        case .green: (0x22/255, 0xC5/255, 0x5E/255)
        case .emerald: (0x10/255, 0xB9/255, 0x81/255)
        case .teal: (0x14/255, 0xB8/255, 0xA6/255)
        case .cyan: (0x06/255, 0xB6/255, 0xD4/255)
        case .blue: (0x3B/255, 0x82/255, 0xF6/255)
        case .indigo: (0x63/255, 0x66/255, 0xF1/255)
        case .violet: (0x8B/255, 0x5C/255, 0xF6/255)
        case .purple: (0xA8/255, 0x55/255, 0xF7/255)
        case .fuchsia: (0xD9/255, 0x46/255, 0xEF/255)
        case .pink: (0xEC/255, 0x48/255, 0x99/255)
        case .rose: (0xF4/255, 0x3F/255, 0x5E/255)
        }
    }
}

enum FluidBadgeVariant { case solid, dot }

/// The badge's own two-step ladder — h-6/h-5, not the 36/28 control rungs.
/// sm/md/lg stay as aliases the way legacySizeAliases maps them.
enum FluidBadgeSize {
    case `default`, compact

    static let sm: FluidBadgeSize = .compact
    static let md: FluidBadgeSize = .default
    static let lg: FluidBadgeSize = .default

    var height: CGFloat { self == .compact ? 20 : 24 }
    var hPadding: CGFloat { self == .compact ? 8 : 10 }
    var fontSize: CGFloat { self == .compact ? 11 : 12 }
    var gap: CGFloat { self == .compact ? 4 : 6 }
    var dotSize: CGFloat { self == .compact ? 6 : 7 }
}

struct FluidBadge: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var contextSize

    let text: String
    var variant: FluidBadgeVariant = .solid
    var color: FluidBadgeColor = .gray
    /// Omitted, the badge follows the surrounding fluidSize — the
    /// source's `sizeProp > SizeProvider > default` resolution.
    var size: FluidBadgeSize? = nil

    init(
        _ text: String,
        variant: FluidBadgeVariant = .solid,
        color: FluidBadgeColor = .gray,
        size: FluidBadgeSize? = nil
    ) {
        self.text = text; self.variant = variant; self.color = color; self.size = size
    }

    private var resolvedSize: FluidBadgeSize {
        size ?? (contextSize == .compact ? .compact : .default)
    }

    /// Solid fill — color-mix(in srgb, hue 15%, var(--background)); gray
    /// takes the accent token instead. srgb mixes interpolate per-channel
    /// in gamma space, so a plain lerp against the two --backgrounds is exact.
    private var solidFill: Color {
        if color == .gray { return FluidTone.accent }
        let bg: CGFloat = scheme == .dark ? 0.039 : 1
        return Color(
            red: color.rgb.0 * 0.15 + bg * 0.85,
            green: color.rgb.1 * 0.15 + bg * 0.85,
            blue: color.rgb.2 * 0.15 + bg * 0.85
        )
    }

    /// The dot's hue — gray dots drop to muted-foreground (the source's
    /// `dotColor = color === "gray" ? var(--muted-foreground) : colorValue`).
    private var dotFill: Color {
        if color == .gray { return FluidTone.mutedForeground }
        return Color(red: color.rgb.0, green: color.rgb.1, blue: color.rgb.2)
    }

    var body: some View {
        let s = resolvedSize
        let rect = RoundedRectangle(cornerRadius: shape.item, style: .continuous)
        return HStack(spacing: s.gap) {
            if variant == .dot {
                Circle()
                    .fill(dotFill)
                    .frame(width: s.dotSize, height: s.dotSize)
            }
            Text(text)
                .font(.system(size: s.fontSize, weight: .medium))
                // whitespace-nowrap — never wraps, never truncates.
                .lineLimit(1)
                .fixedSize()
        }
        // Both variants render text-foreground; only the chrome differs.
        .foregroundStyle(FluidTone.foreground)
        .padding(.horizontal, s.hPadding)
        .frame(height: s.height)
        .background {
            if variant == .solid { rect.fill(solidFill) }
        }
        .overlay {
            if variant == .dot { rect.strokeBorder(FluidTone.border, lineWidth: 1) }
        }
    }
}

// MARK: - Switch
//
// Track 34x20 (compact 28x16), thumb 16 (12) at a 2px inset. Hover extends
// the thumb into a pill (+2 wide); press squashes it (+4 wide, -4 tall).
// The thumb drags with a 2px dead zone and snaps past the midpoint.
// Focused, the track wears the focus-visible ring: a 1px --focus-ring
// band 2px out, over a 2px --background offset band. Space/Return toggle.

struct FluidSwitch: View {
    @Binding var isOn: Bool
    var label: String? = nil
    var size: FluidSize? = nil
    var isDisabled = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidSize) private var envSize
    /// The track's focus — the Radix root is a `tabIndex=0` button, and
    /// focus-visible paints the ring only while it holds keyboard focus.
    /// macOS has no :focus-visible, so `pointerFocus` approximates it: any
    /// pointer interaction suppresses the ring until keyboard input or
    /// blur restores it.
    @FocusState private var focused: Bool
    @State private var pointerFocus = false
    @State private var hovered = false
    @State private var pressed = false
    /// Live thumb x while dragging; nil = resting position.
    @State private var dragX: CGFloat? = nil
    @State private var didDrag = false
    /// The thumb's x at pointer-down — motionX.get() in the source —
    /// captured before `pressed` reshapes restX, and the drag's origin.
    @State private var dragOrigin: CGFloat? = nil

    private var resolvedSize: FluidSize { size ?? envSize }
    private var trackW: CGFloat { resolvedSize == .compact ? 28 : 34 }
    private var trackH: CGFloat { resolvedSize == .compact ? 16 : 20 }
    private var thumbSize: CGFloat { resolvedSize == .compact ? 12 : 16 }
    private var pillExtend: CGFloat { 2 }
    private var pressExtend: CGFloat { resolvedSize == .compact ? 3 : 4 }
    private var pressShrink: CGFloat { resolvedSize == .compact ? 3 : 4 }
    private let inset: CGFloat = 2

    private var travel: CGFloat { trackW - thumbSize - inset * 2 }
    private var thumbWidth: CGFloat {
        pressed ? thumbSize + pressExtend : hovered ? thumbSize + pillExtend : thumbSize
    }
    private var thumbHeight: CGFloat { pressed ? thumbSize - pressShrink : thumbSize }
    private var restX: CGFloat { isOn ? inset + travel - (thumbWidth - thumbSize) : inset }
    private var thumbX: CGFloat { dragX ?? restX }
    private var thumbY: CGFloat { pressed ? inset + pressShrink / 2 : inset }

    var body: some View {
        HStack(spacing: resolvedSize == .compact ? 4 : 8) {
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(trackFill)
                    .frame(width: trackW, height: trackH)
                    // transition-colors duration-80 — the fill eases on its
                    // own 80ms clock, independent of the thumb's spring.
                    .animation(.easeOut(duration: 0.08), value: isOn)
                    .animation(.easeOut(duration: 0.08), value: hovered)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .offset(x: thumbX, y: thumbY)
                    // All thumb geometry — travel, hover pill-extend,
                    // press squash — morphs on spring.moderate (the
                    // source's animate={{y,width,height}} transition).
                    .animation(FluidSpring.moderate, value: isOn)
                    .animation(FluidSpring.moderate, value: hovered)
                    .animation(FluidSpring.moderate, value: pressed)
            }
            .frame(width: trackW, height: trackH)
            .overlay {
                // focus-visible:ring-1 ring-[#6B97FF] ring-offset-2
                // ring-offset-background — a 2px background band (0–2px
                // out) under a 1px ring (2–3px out), capsule like the track.
                // strokeBorder paints inside its bounds, so the capsules
                // are padded out to each band's outer edge.
                if focused && !pointerFocus {
                    Capsule()
                        .strokeBorder(FluidTone.background, lineWidth: 2)
                        .padding(-2)
                    Capsule()
                        .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                        .padding(-3)
                }
            }
            .focusable(!isDisabled)
            .focused($focused)
            .focusEffectDisabled()
            // Button activation, like the Radix <button role=switch>:
            // Space toggles on key-up (its key-down/repeat are still
            // claimed — the browser preventDefaults them off scroll);
            // Return toggles on key-down, autorepeat included.
            .onKeyPress(.space, phases: [.down, .repeat]) { _ in .handled }
            .onKeyPress(.space, phases: .up) { _ in self.toggleByKey() }
            .onKeyPress(.return, phases: [.down, .repeat]) { _ in self.toggleByKey() }
            if let label {
                Text(label)
                    .font(.system(size: resolvedSize.text))
                    .foregroundStyle(isOn ? FluidTone.foreground : FluidTone.mutedForeground)
                    .animation(.easeOut(duration: 0.08), value: isOn)
            }
        }
        .padding(.horizontal, resolvedSize.px)
        .padding(.vertical, resolvedSize == .compact ? 4 : 8)
        .opacity(isDisabled ? 0.5 : 1)
        // pointer-events-none on the whole row when disabled.
        .allowsHitTesting(!isDisabled)
        // The source's row div is one hit area: pointerdown anywhere
        // squashes unconditionally (handlePointerDown), a drag moves the
        // thumb by translation (label drags included — pointer capture),
        // a click toggles.
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard !isDisabled else { return }
                    pointerFocus = true
                    // Anchor the drag at the thumb's pointer-down x — the
                    // source's originX = motionX.get() — captured before
                    // `pressed` reshapes restX.
                    if dragOrigin == nil { dragOrigin = thumbX }
                    pressed = true
                    if dragX == nil && !didDrag {
                        if abs(g.translation.width) < 2 { return }
                        didDrag = true
                    }
                    if didDrag {
                        let pressedW = thumbSize + pressExtend
                        let lo = inset, hi = trackW - inset - pressedW
                        dragX = min(hi, max(lo, (dragOrigin ?? restX) + g.translation.width))
                    }
                }
                .onEnded { _ in
                    guard !isDisabled else { return }
                    pressed = false
                    dragOrigin = nil
                    if didDrag {
                        // Snap past the midpoint of the pressed thumb's
                        // drag range — (dragMin + dragMax)/2 in the
                        // source, where dragMax counts the press-extend.
                        let mid = (trackW - thumbSize - pressExtend) / 2
                        let shouldBeOn = (dragX ?? restX) > mid
                        withAnimation(FluidSpring.moderate) { dragX = nil }
                        // The isOn write stays unanimated: the thumb's
                        // value-animations glide the geometry on moderate
                        // while the fill/label ease at 80ms.
                        if shouldBeOn != isOn { isOn.toggle() }
                        didDrag = false
                    } else {
                        isOn.toggle()
                    }
                }
        )
        .onHover { h in
            guard !isDisabled else { return }
            // Unanimated write — the thumb's value-animation extends the
            // pill on the moderate spring; the fill's does color at 80ms.
            hovered = h
        }
        .onChange(of: focused) { _, f in
            // Blur resets the latch; so does a focus that arrives with no
            // press in flight — a Tab landing after a pointer-down that
            // never produced focus is :focus-visible, not a click.
            if !f || !pressed { pointerFocus = false }
        }
        .accessibilityElement(children: .combine)
        // role="switch" + aria-checked — reads as a toggle with On/Off.
        .accessibilityAddTraits([.isButton, .isToggle])
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }

    /// Keyboard activation — same spring glide a track click rides (the
    /// write is unanimated; the thumb's value-animation carries it). A
    /// keypress also clears the pointer-focus suppression so the ring can
    /// paint again.
    private func toggleByKey() -> KeyPress.Result {
        guard !isDisabled else { return .ignored }
        pointerFocus = false
        isOn.toggle()
        return .handled
    }

    private var trackFill: Color {
        if isOn { return hovered ? FluidTone.switchOnHover : FluidTone.switchOn }
        // Hover mixes accent 10% toward the overlay color (fg): light
        // mode's pale gray deepens, dark mode's lifts.
        return hovered ? FluidMix.overlayAccent(scheme) : FluidTone.accent
    }
}

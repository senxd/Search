import SwiftUI

// The pilot controls — Button, Chip, Switch — ported from the registry
// sources in fluid-demo (components/ui/{button,badge,switch}.tsx, with the
// chip taking the leger.-web badge redesign the way the demo page does).
//
// The press trick is verbatim: at rest the fill paints the full box (the
// source fakes it with a 1px shadow spread); on press it collapses to a
// 1px-inset box, so the surface shrinks exactly 1px per side at any width.

// MARK: - Button

enum FluidButtonVariant { case primary, secondary, tertiary, ghost }
enum FluidButtonSize { case `default`, compact, icon, iconCompact

    var isIconOnly: Bool { self == .icon || self == .iconCompact }
    var isCompact: Bool { self == .compact || self == .iconCompact }
    var height: CGFloat { isCompact ? 28 : 36 }
    var fontSize: CGFloat { isCompact ? 12 : 13 }
    var iconSize: CGFloat { isCompact ? 14 : 16 }
    var hPadding: CGFloat { isCompact ? 12 : 16 }
    var gap: CGFloat { isCompact ? 4 : 6 }
}

struct FluidButton<Label: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
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
                // mix(accent 80%, background) — only visibly differs in light.
                return FluidTone.accent.opacity(0.8)
            }
            return FluidTone.accent
        case .tertiary:
            return pressed || active ? FluidTone.active : (hovered ? FluidTone.hover : .clear)
        case .ghost:
            return pressed || active ? FluidTone.active : (hovered ? FluidTone.hover : .clear)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FluidShape.rounded.button, style: .continuous)
        Button(action: action) {
            HStack(spacing: size.gap) {
                if loading { Color.clear.frame(width: 0, height: 0) }
                if !size.isIconOnly, let leadingIcon {
                    FluidIcon(leadingIcon, size: size.iconSize, bold: hovered || pressed)
                }
                label()
                    .font(.system(size: size.fontSize))
                    .opacity(loading ? 0 : 1)
                if !size.isIconOnly, let trailingIcon {
                    FluidIcon(trailingIcon, size: size.iconSize, bold: hovered || pressed)
                }
            }
            .frame(
                minWidth: size.isIconOnly ? size.height : nil,
                maxWidth: size.isIconOnly ? size.height : nil,
                minHeight: size.height, maxHeight: size.height
            )
            .padding(.horizontal, size.isIconOnly ? 0 : size.hPadding)
            .foregroundStyle(textColor)
            .overlay {
                if loading { FluidSpinner(size: size.isCompact ? 28 : 36, color: textColor) }
            }
            .background {
                // inset 1px while pressed — the spread-collapse press effect.
                shape.fill(fill).padding(pressed && !active ? 1 : 0)
                if variant == .tertiary {
                    if pressed || active {
                        shape.strokeBorder(FluidTone.border, lineWidth: 1).padding(1)
                    } else {
                        shape.strokeBorder(FluidTone.border, lineWidth: 1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || loading)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.08)) { hovered = h }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                }
                .onEnded { _ in
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) { pressed = false }
                }
        )
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
struct FluidSpinner: View {
    let size: CGFloat
    var color: Color = .primary
    @State private var spin = false
    @State private var phase = false

    var body: some View {
        Lemniscate()
            .trim(from: phase ? 0.25 : 0.0, to: phase ? 0.4 : 0.15)
            .stroke(
                style: StrokeStyle(lineWidth: 1.125 * size / 24, lineCap: .round)
            )
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { spin = true }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { phase = true }
            }
    }

    /// M 12 12 C 14 8.5 19 8.5 19 12 C 19 15.5 14 15.5 12 12
    /// C 10 8.5 5 8.5 5 12 C 5 15.5 10 15.5 12 12 Z — a 24-box lemniscate.
    private struct Lemniscate: Shape {
        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
            }
            var path = Path()
            path.move(to: p(12, 12))
            path.addCurve(to: p(19, 12), control1: p(14, 8.5), control2: p(19, 8.5))
            path.addCurve(to: p(12, 12), control1: p(19, 15.5), control2: p(14, 15.5))
            path.addCurve(to: p(5, 12), control1: p(10, 8.5), control2: p(5, 8.5))
            path.addCurve(to: p(12, 12), control1: p(5, 15.5), control2: p(10, 15.5))
            path.closeSubpath()
            return path
        }
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
        let fg: CGFloat = scheme == .dark ? 0.985 : 0x17/255
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

// MARK: - Switch
//
// Track 34x20 (compact 28x16), thumb 16 (12) at a 2px inset. Hover extends
// the thumb into a pill (+2 wide); press squashes it (+4 wide, -4 tall).
// The thumb drags with a 2px dead zone and snaps past the midpoint.

struct FluidSwitch: View {
    @Binding var isOn: Bool
    var label: String? = nil
    var size: FluidSize = .default
    var isDisabled = false

    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var pressed = false
    /// Live thumb x while dragging; nil = resting position.
    @State private var dragX: CGFloat? = nil
    @State private var didDrag = false

    private var trackW: CGFloat { size == .compact ? 28 : 34 }
    private var trackH: CGFloat { size == .compact ? 20 : 16 }
    private var thumbSize: CGFloat { size == .compact ? 12 : 16 }
    private var pillExtend: CGFloat { 2 }
    private var pressExtend: CGFloat { size == .compact ? 3 : 4 }
    private var pressShrink: CGFloat { size == .compact ? 3 : 4 }
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
        HStack(spacing: size == .compact ? 4 : 8) {
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(trackFill)
                    .frame(width: trackW, height: trackH)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .offset(x: thumbX, y: thumbY)
            }
            .frame(width: trackW, height: trackH)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard !isDisabled else { return }
                        if dragX == nil && !didDrag {
                            if abs(g.translation.width) < 2 { return }
                            didDrag = true
                        }
                        if didDrag {
                            pressed = true
                            let pressedW = thumbSize + pressExtend
                            let lo = inset, hi = trackW - inset - pressedW
                            dragX = min(hi, max(lo, restX + g.translation.width))
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        if didDrag {
                            let mid = inset + travel / 2
                            let shouldBeOn = (dragX ?? restX) > mid
                            withAnimation(FluidSpring.moderate) { dragX = nil }
                            if shouldBeOn != isOn { isOn.toggle() }
                            didDrag = false
                        } else {
                            isOn.toggle()
                        }
                    }
            )
            if let label {
                Text(label)
                    .font(.system(size: size.text))
                    .foregroundStyle(isOn ? FluidTone.foreground : FluidTone.mutedForeground)
            }
        }
        .padding(.horizontal, size.px)
        .padding(.vertical, size == .compact ? 4 : 8)
        .opacity(isDisabled ? 0.5 : 1)
        .onHover { h in
            guard !isDisabled else { return }
            withAnimation(.easeOut(duration: 0.08)) { hovered = h }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var trackFill: Color {
        if isOn { return hovered ? FluidTone.switchOnHover : FluidTone.switchOn }
        return hovered ? FluidTone.accent.opacity(1.25) : FluidTone.accent
    }
}

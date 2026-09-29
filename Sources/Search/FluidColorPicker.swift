import SwiftUI
import AppKit

// ColorPicker — fluid-demo/components/ui/color-picker.tsx.
// 280pt panel on surface-3: a 156pt saturation square (hue ramp × black
// falloff, cursor-none with an 18px ring thumb and a ghost hover cursor),
// hue and alpha sliders sharing the slider thumb recipe, a format dropdown,
// channel inputs per format, and an optional swatch strip. The math —
// hsv/hsl/oklch conversions and hex parsing — is ported verbatim.

// MARK: - Color math (verbatim ports)

private func clamp01(_ n: Double) -> Double { min(1, max(0, n)) }

struct FluidRGBA: Equatable {
    var r: Double; var g: Double; var b: Double; var a: Double = 1

    var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }

    var hex: String {
        let h = String(format: "#%02X%02X%02X", Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
        return a < 1 ? h + String(format: "%02X", Int((a * 255).rounded())) : h
    }
}

private func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
    let c = v * s
    let h60 = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(h60.truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    var r = 0.0, g = 0.0, b = 0.0
    switch Int(h60) {
    case 0: (r, g, b) = (c, x, 0)
    case 1: (r, g, b) = (x, c, 0)
    case 2: (r, g, b) = (0, c, x)
    case 3: (r, g, b) = (0, x, c)
    case 4: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return ((r + m) * 255, (g + m) * 255, (b + m) * 255)
}

private func rgbToHsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
    let (r, g, b) = (r / 255, g / 255, b / 255)
    let mx = max(r, g, b), mn = min(r, g, b)
    let v = mx
    let d = mx - mn
    let s = mx == 0 ? 0 : d / mx
    var h = 0.0
    if d != 0 {
        switch mx {
        case r: h = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6))
        case g: h = 60 * ((b - r) / d + 2)
        default: h = 60 * ((r - g) / d + 4)
        }
    }
    if h < 0 { h += 360 }
    return (h, s, v)
}

private func rgbToHsl(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
    let (r, g, b) = (r / 255, g / 255, b / 255)
    let mx = max(r, g, b), mn = min(r, g, b)
    let l = (mx + mn) / 2
    let d = mx - mn
    var h = 0.0, s = 0.0
    if d != 0 {
        s = d / (1 - abs(2 * l - 1))
        switch mx {
        case r: h = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6))
        case g: h = 60 * ((b - r) / d + 2)
        default: h = 60 * ((r - g) / d + 4)
        }
    }
    if h < 0 { h += 360 }
    return (h, s, l)
}

private func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
    let c = (1 - abs(2 * l - 1)) * s
    let h60 = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(h60.truncatingRemainder(dividingBy: 2) - 1))
    let m = l - c / 2
    var r = 0.0, g = 0.0, b = 0.0
    switch Int(h60) {
    case 0: (r, g, b) = (c, x, 0)
    case 1: (r, g, b) = (x, c, 0)
    case 2: (r, g, b) = (0, c, x)
    case 3: (r, g, b) = (0, x, c)
    case 4: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return ((r + m) * 255, (g + m) * 255, (b + m) * 255)
}

private func srgbToLinear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
private func linearToSrgb(_ c: Double) -> Double {
    c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
}

private func rgbToOklch(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, C: Double, H: Double) {
    let lr = srgbToLinear(r / 255), lg = srgbToLinear(g / 255), lb = srgbToLinear(b / 255)
    let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
    let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
    let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
    let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    let b2 = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    let C = (a * a + b2 * b2).squareRoot()
    var H = atan2(b2, a) * 180 / .pi
    if H < 0 { H += 360 }
    return (L, C, H)
}

private func oklchToRgb(_ L: Double, _ C: Double, _ H: Double) -> (r: Double, g: Double, b: Double) {
    let a = C * cos(H * .pi / 180), b = C * sin(H * .pi / 180)
    let l_ = L + 0.3963377774 * a + 0.2158037573 * b
    let m_ = L - 0.1055613458 * a - 0.0638541728 * b
    let s_ = L - 0.0894841775 * a - 1.2914855480 * b
    let (l, m, s) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
    let r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (linearToSrgb(r) * 255, linearToSrgb(g) * 255, linearToSrgb(bb) * 255)
}

/// #rgb / #rrggbb / #rrggbbaa → channels, or nil.
private func parseHex(_ input: String) -> FluidRGBA? {
    var s = input.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard (3...8).contains(s.count), s.allSatisfy({ $0.isHexDigit }) else { return nil }
    if s.count == 3 || s.count == 4 {
        s = s.map { "\($0)\($0)" }.joined()
    }
    guard s.count == 6 || s.count == 8 else { return nil }
    let v = { (i: Int) -> Double in
        Double(Int(s.dropFirst(i * 2).prefix(2), radix: 16) ?? 0)
    }
    return FluidRGBA(r: v(0), g: v(1), b: v(2), a: s.count == 8 ? v(3) / 255 : 1)
}

/// Hex or a named CSS color → channels, or nil. Swatches and the hex field
/// accept the same names the browser normalizes ("red", "tomato", …).
func fluidParseColor(_ input: String) -> FluidRGBA? {
    if let p = parseHex(input) { return p }
    if let hex = FluidColorPicker.cssColorNames[input.lowercased()] {
        return parseHex(hex)
    }
    return nil
}

// MARK: - The picker

enum FluidColorFormat: String, CaseIterable {
    case hex, rgb, hsl, oklch
    var label: String { rawValue.uppercased() }
}

struct FluidColorPicker: View {
    /// Hex string binding — the emitted format follows `format`.
    @Binding var value: String
    var swatches: [String] = []
    var hideEyedropper = false

    /// CSS named colors → hex (the source resolves these through canvas
    /// normalization; AppKit has no equivalent, so the names ride along).
    static let cssColorNames: [String: String] = [
        "aliceblue": "#f0f8ff", "antiquewhite": "#faebd7", "aqua": "#00ffff",
        "aquamarine": "#7fffd4", "azure": "#f0ffff", "beige": "#f5f5dc",
        "bisque": "#ffe4c4", "black": "#000000", "blanchedalmond": "#ffebcd",
        "blue": "#0000ff", "blueviolet": "#8a2be2", "brown": "#a52a2a",
        "burlywood": "#deb887", "cadetblue": "#5f9ea0", "chartreuse": "#7fff00",
        "chocolate": "#d2691e", "coral": "#ff7f50", "cornflowerblue": "#6495ed",
        "cornsilk": "#fff8dc", "crimson": "#dc143c", "cyan": "#00ffff",
        "darkblue": "#00008b", "darkcyan": "#008b8b", "darkgoldenrod": "#b8860b",
        "darkgray": "#a9a9a9", "darkgrey": "#a9a9a9", "darkgreen": "#006400",
        "darkkhaki": "#bdb76b", "darkmagenta": "#8b008b", "darkolivegreen": "#556b2f",
        "darkorange": "#ff8c00", "darkorchid": "#9932cc", "darkred": "#8b0000",
        "darksalmon": "#e9967a", "darkseagreen": "#8fbc8f", "darkslateblue": "#483d8b",
        "darkslategray": "#2f4f4f", "darkslategrey": "#2f4f4f", "darkturquoise": "#00ced1",
        "darkviolet": "#9400d3", "deeppink": "#ff1493", "deepskyblue": "#00bfff",
        "dimgray": "#696969", "dimgrey": "#696969", "dodgerblue": "#1e90ff",
        "firebrick": "#b22222", "floralwhite": "#fffaf0", "forestgreen": "#228b22",
        "fuchsia": "#ff00ff", "gainsboro": "#dcdcdc", "ghostwhite": "#f8f8ff",
        "gold": "#ffd700", "goldenrod": "#daa520", "gray": "#808080",
        "grey": "#808080", "green": "#008000", "greenyellow": "#adff2f",
        "honeydew": "#f0fff0", "hotpink": "#ff69b4", "indianred": "#cd5c5c",
        "indigo": "#4b0082", "ivory": "#fffff0", "khaki": "#f0e68c",
        "lavender": "#e6e6fa", "lavenderblush": "#fff0f5", "lawngreen": "#7cfc00",
        "lemonchiffon": "#fffacd", "lightblue": "#add8e6", "lightcoral": "#f08080",
        "lightcyan": "#e0ffff", "lightgoldenrodyellow": "#fafad2", "lightgray": "#d3d3d3",
        "lightgrey": "#d3d3d3", "lightgreen": "#90ee90", "lightpink": "#ffb6c1",
        "lightsalmon": "#ffa07a", "lightseagreen": "#20b2aa", "lightskyblue": "#87cefa",
        "lightslategray": "#778899", "lightslategrey": "#778899", "lightsteelblue": "#b0c4de",
        "lightyellow": "#ffffe0", "lime": "#00ff00", "limegreen": "#32cd32",
        "linen": "#faf0e6", "magenta": "#ff00ff", "maroon": "#800000",
        "mediumaquamarine": "#66cdaa", "mediumblue": "#0000cd", "mediumorchid": "#ba55d3",
        "mediumpurple": "#9370db", "mediumseagreen": "#3cb371", "mediumslateblue": "#7b68ee",
        "mediumspringgreen": "#00fa9a", "mediumturquoise": "#48d1cc", "mediumvioletred": "#c71585",
        "midnightblue": "#191970", "mintcream": "#f5fffa", "mistyrose": "#ffe4e1",
        "moccasin": "#ffe4b5", "navajowhite": "#ffdead", "navy": "#000080",
        "oldlace": "#fdf5e6", "olive": "#808000", "olivedrab": "#6b8e23",
        "orange": "#ffa500", "orangered": "#ff4500", "orchid": "#da70d6",
        "palegoldenrod": "#eee8aa", "palegreen": "#98fb98", "paleturquoise": "#afeeee",
        "palevioletred": "#db7093", "papayawhip": "#ffefd5", "peachpuff": "#ffdab9",
        "peru": "#cd853f", "pink": "#ffc0cb", "plum": "#dda0dd",
        "powderblue": "#b0e0e6", "purple": "#800080", "rebeccapurple": "#663399",
        "red": "#ff0000", "rosybrown": "#bc8f8f", "royalblue": "#4169e1",
        "saddlebrown": "#8b4513", "salmon": "#fa8072", "sandybrown": "#f4a460",
        "seagreen": "#2e8b57", "seashell": "#fff5ee", "sienna": "#a0522d",
        "silver": "#c0c0c0", "skyblue": "#87ceeb", "slateblue": "#6a5acd",
        "slategray": "#708090", "slategrey": "#708090", "snow": "#fffafa",
        "springgreen": "#00ff7f", "steelblue": "#4682b4", "tan": "#d2b48c",
        "teal": "#008080", "thistle": "#d8bfd8", "tomato": "#ff6347",
        "turquoise": "#40e0d0", "violet": "#ee82ee", "wheat": "#f5deb3",
        "white": "#ffffff", "whitesmoke": "#f5f5f5", "yellow": "#ffff00",
        "yellowgreen": "#9acd32",
    ]

    @State private var hsv: (h: Double, s: Double, v: Double, a: Double) = (222, 0.5, 1, 1)
    @State private var format: FluidColorFormat = .hex
    /// Sticky OKLCH hue so L/C edits don't drift the stated H.
    @State private var oklchHue: Double? = nil

    private var rgb: FluidRGBA {
        let (r, g, b) = hsvToRgb(hsv.h, hsv.s, hsv.v)
        return FluidRGBA(r: r, g: g, b: b, a: hsv.a)
    }

    var body: some View {
        VStack(spacing: 8) {
            SaturationSquare(h: hsv.h, s: hsv.s, v: hsv.v) { s, v in
                hsv.s = s; hsv.v = v; emit()
            }

            VStack(spacing: -1) {
                GradientSlider(
                    value: $hsv.h.scaled(0, 360),
                    track: AnyView(hueTrack),
                    thumbColor: Color(hue: hsv.h / 360, saturation: 1, brightness: 1)
                ) { _ in
                    oklchHue = nil; emit()
                }
                GradientSlider(
                    value: $hsv.a.scaled(0, 1),
                    track: AnyView(alphaTrack),
                    thumbColor: rgb.color.opacity(1)
                ) { _ in emit() }
            }

            HStack(spacing: 8) {
                FluidSelect(selection: Binding<String?>(
                    get: { format.rawValue },
                    set: { if let v = $0, let f = FluidColorFormat(rawValue: v) { format = f; emit() } }
                )) {
                    ForEach(Array(FluidColorFormat.allCases.enumerated()), id: \.offset) { i, f in
                        FluidSelectItem(index: i, value: f.rawValue, label: f.label)
                    }
                }
                if !hideEyedropper {
                    FluidButton(size: .icon, action: eyedrop) {
                        Image(systemName: "eyedropper").font(.system(size: 16))
                    }
                }
            }

            inputsRow

            if !swatches.isEmpty {
                FluidFlow(spacing: 8, rowSpacing: 8) {
                    ForEach(swatches, id: \.self) { sw in
                        FluidSwatch(color: sw,
                                    selected: normalized(sw) == rgb.hex.lowercased()) {
                            applyColor(sw)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 280)
        .fluidSurface(3, radius: FluidShape.rounded.container)
        .onAppear { applyHex(value, emitChange: false) }
        .onChange(of: value) { _, new in
            // External writes adopt the color; our own emits echo back equal
            // hex so the guard keeps them cheap.
            if new.lowercased() != rgb.hex.lowercased() { applyHex(new, emitChange: false) }
        }
    }

    // MARK: inputs

    @ViewBuilder
    private var inputsRow: some View {
        let aPct = Int((hsv.a * 100).rounded())
        switch format {
        case .hex:
            HStack(spacing: 8) {
                FluidChannelField(text: rgb.hex, prefix: "#") { applyColor($0) }
                FluidChannelField(text: "\(aPct)%", numeric: true) { setAlphaPercent($0) }
            }
        case .rgb:
            HStack(spacing: 4) {
                FluidChannelField(text: "\(Int(rgb.r.rounded()))", numeric: true) { setRGB(0, $0) }
                FluidChannelField(text: "\(Int(rgb.g.rounded()))", numeric: true) { setRGB(1, $0) }
                FluidChannelField(text: "\(Int(rgb.b.rounded()))", numeric: true) { setRGB(2, $0) }
                FluidChannelField(text: "\(aPct)%", numeric: true) { setAlphaPercent($0) }
            }
        case .hsl:
            let hsl = rgbToHsl(rgb.r, rgb.g, rgb.b)
            HStack(spacing: 4) {
                FluidChannelField(text: "\(Int(hsl.h.rounded()))", numeric: true) { setHSL(0, $0) }
                FluidChannelField(text: "\(Int((hsl.s * 100).rounded()))", numeric: true) { setHSL(1, $0) }
                FluidChannelField(text: "\(Int((hsl.l * 100).rounded()))", numeric: true) { setHSL(2, $0) }
                FluidChannelField(text: "\(aPct)%", numeric: true) { setAlphaPercent($0) }
            }
        case .oklch:
            let ok = rgbToOklch(rgb.r, rgb.g, rgb.b)
            HStack(spacing: 4) {
                FluidChannelField(text: "\(Int((ok.L * 100).rounded()))", numeric: true) { setOklch(0, $0) }
                FluidChannelField(text: String(format: "%.2f", ok.C), numeric: true) { setOklch(1, $0) }
                FluidChannelField(text: "\(Int((oklchHue ?? ok.H).rounded()))", numeric: true) { setOklch(2, $0) }
                FluidChannelField(text: "\(aPct)%", numeric: true) { setAlphaPercent($0) }
            }
        }
    }

    private var hueTrack: some View {
        LinearGradient(
            stops: [0, 60, 120, 180, 240, 300, 360].map {
                .init(color: Color(hue: Double($0) / 360, saturation: 1, brightness: 1),
                      location: CGFloat($0) / 360)
            },
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var alphaTrack: some View {
        ZStack {
            FluidCheckerboard(cell: 4)
            LinearGradient(
                colors: [rgb.color.opacity(0), rgb.color],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    // MARK: behavior

    private func emit() {
        value = rgb.hex
    }

    private func applyHex(_ s: String, emitChange: Bool = true) {
        guard let p = parseHex(s) else { return }
        let h = rgbToHsv(p.r, p.g, p.b)
        // Greyscale commits keep the last hue — a black pick shouldn't
        // fling the square back to red.
        hsv = (h.s == 0 ? hsv.h : h.h, h.s, h.v, p.a)
        if emitChange { emit() }
    }

    /// Same commit path for hex-or-named input (swatch pick, hex field).
    private func applyColor(_ s: String) {
        guard let p = fluidParseColor(s) else { return }
        let h = rgbToHsv(p.r, p.g, p.b)
        hsv = (h.s == 0 ? hsv.h : h.h, h.s, h.v, p.a)
        emit()
    }

    /// Normalize any accepted color string to lowercase hex for the
    /// selected-swatch comparison (the source resolves names via canvas).
    private func normalized(_ s: String) -> String {
        fluidParseColor(s)?.hex.lowercased() ?? s.lowercased()
    }

    private func setRGB(_ channel: Int, _ text: String) {
        guard let n = Double(text.filter { $0.isNumber || $0 == "." }) else { return }
        var p = rgb
        let v = min(255, max(0, n))
        switch channel { case 0: p.r = v; case 1: p.g = v; default: p.b = v }
        let h = rgbToHsv(p.r, p.g, p.b)
        hsv = (h.s == 0 ? hsv.h : h.h, h.s, h.v, hsv.a)
        oklchHue = nil; emit()
    }

    private func setHSL(_ channel: Int, _ text: String) {
        guard let n = Double(text.filter { $0.isNumber || $0 == "." }) else { return }
        let hsl = rgbToHsl(rgb.r, rgb.g, rgb.b)
        var (h, s, l) = hsl
        switch channel {
        case 0: h = (n.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360); oklchHue = nil
        case 1: s = clamp01(n / 100)
        default: l = clamp01(n / 100)
        }
        let r = hslToRgb(h, s, l)
        let hsvN = rgbToHsv(r.r, r.g, r.b)
        hsv = (hsvN.s == 0 ? h : hsvN.h, hsvN.s, hsvN.v, hsv.a)
        emit()
    }

    private func setOklch(_ channel: Int, _ text: String) {
        guard let n = Double(text.filter { $0.isNumber || $0 == "." || $0 == "-" }) else { return }
        let cur = rgbToOklch(rgb.r, rgb.g, rgb.b)
        let baseH = oklchHue ?? cur.H
        var (L, C, H) = (cur.L, cur.C, baseH)
        switch channel {
        case 0: L = clamp01(n / 100)
        case 1: C = max(0, n)
        default: H = (n.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }
        oklchHue = H
        let r = oklchToRgb(L, C, H)
        let hsvN = rgbToHsv(min(255, max(0, r.r)), min(255, max(0, r.g)), min(255, max(0, r.b)))
        hsv = (hsvN.s == 0 ? hsv.h : hsvN.h, hsvN.s, hsvN.v, hsv.a)
        emit()
    }

    private func setAlphaPercent(_ text: String) {
        guard let n = Double(text.replacingOccurrences(of: "%", with: "")) else { return }
        hsv.a = clamp01(n / 100); emit()
    }

    /// NSColorSampler — the macOS EyeDropper counterpart.
    private func eyedrop() {
        NSColorSampler().show { color in
            guard let color else { return }
            let c = color.usingColorSpace(.sRGB) ?? color
            applyHex(String(format: "#%02X%02X%02X",
                            Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)))
        }
    }
}

// MARK: - Saturation square

/// Hue ramp across, black up from the bottom; cursor-none with an 18px
/// color thumb and a translucent ghost ring tracking the pointer. AppKit-
/// hosted: SwiftUI gestures lose drags to an enclosing ScrollView's pan —
/// a modal mouse loop on a real NSView is the pointer-capture equivalent.
private struct SaturationSquare: NSViewRepresentable {
    let h: Double, s: Double, v: Double
    var onChange: (Double, Double) -> Void

    @Environment(\.fluidShape) private var shape

    func makeNSView(context: Context) -> FluidSaturationView {
        let view = FluidSaturationView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: FluidSaturationView, context: Context) {
        view.h = h; view.s = s; view.v = v
        view.cornerRadius = shape.bg
        view.onChange = onChange
    }
}

private final class FluidSaturationView: NSView {
    var h: Double = 0 { didSet { syncGradient() } }
    var s: Double = 0 { didSet { syncThumb() } }
    var v: Double = 0 { didSet { syncThumb() } }
    var cornerRadius: CGFloat = 8 {
        didSet {
            base.cornerRadius = cornerRadius
            focusRing.cornerRadius = cornerRadius + 2
        }
    }
    var onChange: ((Double, Double) -> Void)?

    /// Rounded, clipped container for the two gradients.
    private let base = CALayer()
    private let hue = CAGradientLayer()
    private let dark = CAGradientLayer()
    /// 18pt color thumb, 1px white border + 1px black outer ring.
    private let thumb = CALayer()
    private let thumbRing = CALayer()
    /// 18pt ghost ring tracking the pointer while hovering.
    private let ghost = CALayer()
    private let ghostRing = CALayer()
    /// focus-visible: 2px accent ring outside the square (keyboard focus
    /// only — clicks take first-responder silently).
    private let focusRing = CALayer()
    private var hovering = false
    private var draggingNow = false
    private var clickFocus = false
    private var ghostAt: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 156)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }

        base.masksToBounds = true
        base.cornerRadius = cornerRadius
        hue.startPoint = CGPoint(x: 0, y: 0.5)
        hue.endPoint = CGPoint(x: 1, y: 0.5)
        // "to top, #000, transparent" — clear at the top, black at bottom.
        dark.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        dark.startPoint = CGPoint(x: 0.5, y: 0)
        dark.endPoint = CGPoint(x: 0.5, y: 1)
        base.addSublayer(hue)
        base.addSublayer(dark)
        layer.addSublayer(base)

        focusRing.backgroundColor = NSColor.clear.cgColor
        focusRing.borderColor = NSColor(FluidTone.accent).cgColor
        focusRing.borderWidth = 2
        focusRing.isHidden = true
        layer.addSublayer(focusRing)

        thumbRing.frame = CGRect(origin: .zero, size: CGSize(width: 20, height: 20))
        thumbRing.cornerRadius = 10
        thumbRing.borderWidth = 1
        thumbRing.borderColor = NSColor.black.cgColor
        layer.addSublayer(thumbRing)

        thumb.frame = CGRect(origin: .zero, size: CGSize(width: 18, height: 18))
        thumb.cornerRadius = 9
        thumb.borderWidth = 1
        thumb.borderColor = NSColor.white.cgColor
        layer.addSublayer(thumb)

        ghostRing.frame = CGRect(origin: .zero, size: CGSize(width: 20, height: 20))
        ghostRing.cornerRadius = 10
        ghostRing.borderWidth = 1
        ghostRing.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
        ghostRing.isHidden = true
        layer.addSublayer(ghostRing)

        ghost.frame = CGRect(origin: .zero, size: CGSize(width: 18, height: 18))
        ghost.cornerRadius = 9
        ghost.borderWidth = 2
        ghost.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        ghost.isHidden = true
        layer.addSublayer(ghost)

        syncGradient()
        syncThumb()
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        hue.frame = bounds
        dark.frame = bounds
        focusRing.frame = bounds.insetBy(dx: -2, dy: -2)
        CATransaction.commit()
        syncThumb()
        syncGhost()
    }

    private func syncGradient() {
        hue.colors = [
            NSColor.white.cgColor,
            NSColor(hue: CGFloat(h) / 360, saturation: 1, brightness: 1, alpha: 1).cgColor,
        ]
    }

    private func syncThumb() {
        let (r, g, b) = hsvToRgb(h, s, v)
        let c = CGPoint(x: CGFloat(s) * bounds.width, y: (1 - CGFloat(v)) * bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.backgroundColor = NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1).cgColor
        thumb.position = c
        thumbRing.position = c
        CATransaction.commit()
    }

    private func syncGhost() {
        let show = hovering && !draggingNow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.isHidden = !show
        ghostRing.isHidden = !show
        ghost.position = ghostAt
        ghostRing.position = ghostAt
        CATransaction.commit()
    }

    private func apply(_ loc: CGPoint) {
        let p = convert(loc, from: nil)
        let ns = clamp01(p.x / bounds.width)
        let nv = 1 - clamp01(p.y / bounds.height)
        s = ns; v = nv
        onChange?(ns, nv)
    }

    // MARK: events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea(_:))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        ghostAt = convert(event.locationInWindow, from: nil)
        NSCursor.hide()
        syncGhost()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !draggingNow { NSCursor.unhide() }
        syncGhost()
    }
    override func mouseMoved(with event: NSEvent) {
        ghostAt = convert(event.locationInWindow, from: nil)
        syncGhost()
    }

    /// pointerdown + setPointerCapture — the modal loop keeps every drag
    /// event, so an enclosing scroll view never sees a competing sequence.
    override func mouseDown(with event: NSEvent) {
        clickFocus = true
        window?.makeFirstResponder(self)
        clickFocus = false

        draggingNow = true
        NSCursor.hide()
        syncGhost()
        apply(event.locationInWindow)
        while true {
            guard let ev = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if ev.type == .leftMouseUp { break }
            apply(ev.locationInWindow)
        }
        draggingNow = false
        // Pointer may have left the square while captured.
        let inside = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        if inside {
            hovering = true
            ghostAt = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        } else {
            hovering = false
            NSCursor.unhide()
        }
        syncGhost()
    }

    /// Arrow keys — 0.01 steps, 0.1 with Shift (the source's keydown).
    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        var ns = s, nv = v
        switch event.keyCode {
        case 123: ns = clamp01(s - step)
        case 124: ns = clamp01(s + step)
        case 126: nv = clamp01(v + step)
        case 125: nv = clamp01(v - step)
        default: super.keyDown(with: event); return
        }
        s = ns; v = nv
        onChange?(ns, nv)
    }

    override func becomeFirstResponder() -> Bool {
        // focus-visible semantics: clicks focus silently, only keyboard
        // focus draws the ring.
        focusRing.isHidden = clickFocus
        return true
    }
    override func resignFirstResponder() -> Bool {
        focusRing.isHidden = true
        return true
    }
}

// MARK: - Gradient slider

/// The picker's hue/alpha tracks: 32pt hit box, 18pt rounded track, 16pt
/// color thumb with white border — the base slider recipe minus its fill.
private struct GradientSlider: View {
    @Binding var value: Double   // normalized 0…1 via .scaled()
    var track: AnyView
    var thumbColor: Color
    var onEdit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                track
                    .frame(height: 18)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(FluidTone.border, lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .center)
                Circle()
                    .fill(thumbColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                    .frame(width: 20, height: 20)
                    .position(x: 10 + value * (geo.size.width - 20), y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            // highPriority for the same scroll-steal reason as the square.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        let usable = geo.size.width - 20
                        value = clamp01((d.location.x - 10) / usable)
                        onEdit(value)
                    }
            )
        }
        .frame(height: 32)
    }
}

// MARK: - Small pieces

/// A channel input: 28pt field, 1px border, centered text — the scrubbable
/// number inputs of the source, minus the drag-to-scrub.
private struct FluidChannelField: View {
    var text: String
    var prefix: String? = nil
    var numeric = false
    var onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 2) {
            if let prefix {
                Text(prefix).foregroundStyle(FluidTone.mutedForeground)
            }
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(FluidTone.foreground)
                .focused($editing)
                .onSubmit { onCommit(draft) }
                .onChange(of: draft) { _, new in
                    if numeric, let n = Double(new.replacingOccurrences(of: "%", with: "")) {
                        onCommit(String(n))
                    }
                }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: FluidShape.rounded.input, style: .continuous)
                .strokeBorder(FluidTone.border, lineWidth: 1)
        )
        .onAppear { draft = text }
        .onChange(of: text) { _, new in if !editing { draft = new } }
        // Focus loss commits the raw draft and resyncs from the model.
        .onChange(of: editing) { _, now in
            if !now { onCommit(draft); draft = text }
        }
    }
}

/// Checkerboard under alpha-aware tiles and tracks.
struct FluidCheckerboard: View {
    var cell: CGFloat = 4
    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / cell) + 2
            let rows = Int(size.height / cell) + 2
            for r in 0..<rows {
                for c in 0..<cols {
                    let even = (r + c) % 2 == 0
                    ctx.fill(
                        Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)),
                        with: .color(even ? .white.opacity(0.9) : .gray.opacity(0.4))
                    )
                }
            }
        }
    }
}

/// Clickable strip swatch — checkerboard tile with a hover ring; selected
/// gets the accent double ring (2pt background gap + accent outside, the
/// source's stacked box-shadow).
private struct FluidSwatch: View {
    let color: String
    let selected: Bool
    var action: () -> Void
    @Environment(\.fluidShape) private var shape
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            FluidColorTile(color: fluidParseColor(color)?.color ?? .clear, size: 28)
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: shape.bg + 2, style: .continuous)
                .strokeBorder(
                    selected
                        ? Color(red: 0x6B/255, green: 0x97/255, blue: 1)
                        : Color.gray.opacity(0.4),
                    lineWidth: 2
                )
                .padding(-3)
                .opacity(selected || hovered ? 1 : 0)
        )
        .onContinuousHover { hovered = $0 != .ended }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeOut(duration: 0.1), value: selected)
    }
}

/// The 24pt color tile — checkerboard underneath, color over, inset ring.
struct FluidColorTile: View {
    let color: Color
    var size: CGFloat = 24
    @Environment(\.fluidShape) private var shape

    var body: some View {
        ZStack {
            FluidCheckerboard(cell: 4)
            color
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: shape.bg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                .strokeBorder(.gray.opacity(0.25), lineWidth: 1)
        )
    }
}

private extension Binding where Value == Double {
    /// Present a normalized 0…1 binding over an arbitrary range.
    func scaled(_ lo: Double, _ hi: Double) -> Binding<Double> {
        Binding<Double>(
            get: { (wrappedValue - lo) / (hi - lo) },
            set: { wrappedValue = lo + $0 * (hi - lo) }
        )
    }
}

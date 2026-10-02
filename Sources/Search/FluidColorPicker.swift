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

    /// The same color at full alpha — the alpha track's "opaque" stop and
    /// thumb (the source builds them from `solidColor`, color-picker.tsx
    /// :627-629). `.opacity(1)` multiplies and would keep the alpha.
    var opaque: Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
    }

    /// Channel → 0..255 int. NaN/∞ (a 300-digit numeric field parse) would
    /// trap Int() — clamp before converting, non-finite → 0.
    private static func byte(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        return min(255, max(0, Int(v.rounded())))
    }

    /// degrees → rounded int, non-finite → 0.
    private static func deg(_ v: Double) -> Int {
        v.isFinite ? Int(v.rounded()) : 0
    }

    /// `Number(v.toFixed(3))` — 3 decimals, trailing zeros dropped.
    private static func trimmed3(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var hex: String {
        let h = String(format: "#%02X%02X%02X", Self.byte(r), Self.byte(g), Self.byte(b))
        return a < 1 ? h + String(format: "%02X", Self.byte(a * 255)) : h
    }

    /// `rgb(r, g, b)` / `rgba(r, g, b, a)` — buildParsed.rgb (:385-387).
    var rgbString: String {
        let core = "\(Self.byte(r)), \(Self.byte(g)), \(Self.byte(b))"
        return a >= 1 ? "rgb(\(core))" : "rgba(\(core), \(Self.trimmed3(a)))"
    }

    /// `hsl(h, s%, l%)` / `hsla(h, s%, l%, a)` — buildParsed.hsl (:388-390).
    var hslString: String {
        let hsl = rgbToHsl(r, g, b)
        let c = "\(Self.deg(hsl.h)), \(Self.deg(hsl.s * 100))%, \(Self.deg(hsl.l * 100))%"
        return a >= 1 ? "hsl(\(c))" : "hsla(\(c), \(Self.trimmed3(a)))"
    }

    /// `oklch(L% C H)` / `oklch(L% C H / a)` — buildParsed.oklch (:391-393):
    /// `(L*100).toFixed(1)`, `C.toFixed(3)`, `H.toFixed(1)`, a trimmed to 3.
    var oklchString: String {
        let ok = rgbToOklch(r, g, b)
        func fixed(_ v: Double, _ places: Int) -> String {
            v.isFinite ? String(format: "%.\(places)f", v) : "0"
        }
        let core = "\(fixed(ok.L * 100, 1))% \(fixed(ok.C, 3)) \(fixed(ok.H, 1))"
        return a >= 1 ? "oklch(\(core))" : "oklch(\(core) / \(Self.trimmed3(a)))"
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

/// parseFloat — the leading numeric prefix ("50%" → 50, "180deg" → 180),
/// NaN when there's no number at all (parseColor :307-341).
private func cssFloat(_ s: String) -> Double {
    guard let m = s.range(
        of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?"#, options: .regularExpression
    ) else { return .nan }
    return Double(s[m]) ?? .nan
}

/// `name(...)` argument list — splits on the CSS separators `[\s,/]+`.
private func functionalParts(_ s: String, _ names: [String]) -> [String]? {
    let lower = s.lowercased()
    for name in names where lower.hasPrefix(name + "(") && s.hasSuffix(")") {
        return s.dropFirst(name.count + 1).dropLast()
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }
    return nil
}

/// Percent-aware alpha channel — "50%" → 0.5, "0.5" → 0.5.
private func cssAlpha(_ part: String) -> Double {
    part.hasSuffix("%") ? cssFloat(part) / 100 : cssFloat(part)
}

/// Hex, `rgb()/rgba()`, `hsl()/hsla()`, `oklch()`, `transparent`, or a named
/// CSS color → channels, or nil (the source's parseColor :297-378 plus the
/// named-color table its canvas normalization resolves). Swatches, external
/// writes, and the hex field all accept these forms.
func fluidParseColor(_ input: String) -> FluidRGBA? {
    let s = input.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    // Hex-like input goes to parseHex and answers nil itself on failure —
    // no fallthrough ("#zzz" is not a functional form).
    if s.hasPrefix("#") || (3...8).contains(s.count) && s.allSatisfy({ $0.isHexDigit }) {
        return parseHex(s)
    }
    if s.lowercased() == "transparent" { return FluidRGBA(r: 0, g: 0, b: 0, a: 0) }
    if let parts = functionalParts(s, ["rgb", "rgba"]), parts.count >= 3 {
        let r = cssFloat(parts[0]), g = cssFloat(parts[1]), b = cssFloat(parts[2])
        let a = parts.count > 3 ? cssAlpha(parts[3]) : 1
        guard !r.isNaN, !g.isNaN, !b.isNaN, !a.isNaN else { return nil }
        return FluidRGBA(
            r: min(255, max(0, r)), g: min(255, max(0, g)),
            b: min(255, max(0, b)), a: clamp01(a))
    }
    if let parts = functionalParts(s, ["hsl", "hsla"]), parts.count >= 3 {
        let h = cssFloat(parts[0])
        let sat = parts[1].hasSuffix("%") ? cssFloat(parts[1]) / 100 : cssFloat(parts[1])
        let l = parts[2].hasSuffix("%") ? cssFloat(parts[2]) / 100 : cssFloat(parts[2])
        let a = parts.count > 3 ? cssAlpha(parts[3]) : 1
        guard !h.isNaN, !sat.isNaN, !l.isNaN, !a.isNaN else { return nil }
        let rgb = hslToRgb(h.isFinite ? h : 0, clamp01(sat), clamp01(l))
        return FluidRGBA(
            r: min(255, max(0, rgb.r)), g: min(255, max(0, rgb.g)),
            b: min(255, max(0, rgb.b)), a: clamp01(a))
    }
    if let parts = functionalParts(s, ["oklch"]), parts.count >= 3 {
        let L = parts[0].hasSuffix("%") ? cssFloat(parts[0]) / 100 : cssFloat(parts[0])
        let C = cssFloat(parts[1]), H = cssFloat(parts[2])
        let a = parts.count > 3 ? cssAlpha(parts[3]) : 1
        guard !L.isNaN, !C.isNaN, !H.isNaN, !a.isNaN else { return nil }
        let rgb = oklchToRgb(clamp01(L), max(0, C.isFinite ? C : 0), H.isFinite ? H : 0)
        return FluidRGBA(
            r: min(255, max(0, rgb.r)), g: min(255, max(0, rgb.g)),
            b: min(255, max(0, rgb.b)), a: clamp01(a))
    }
    if let hex = FluidColorPicker.cssColorNames[s.lowercased()] {
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
    /// Color string binding — emits in the active `format`
    /// (formatValueByFormat: lowercase hex, `rgb()`, `hsl()`, `oklch()`).
    @Binding var value: String
    var swatches: [String] = []
    var hideEyedropper = false
    /// The surface the panel sits on — the port has no surface env, so
    /// `substrate` arrives as a param like everywhere else; the panel
    /// draws `max(substrate, 3)` (:1700-1705).
    var substrate: Int = 1

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
    /// The last string emit() wrote — the source's lastEmittedRef, so our
    /// own writes echoing back through `value` don't re-sync hsv.
    @State private var lastEmitted = ""
    @Environment(\.fluidShape) private var shape

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
                    thumbColor: Color(hue: hsv.h / 360, saturation: 1, brightness: 1),
                    label: "Hue", step: 1 / 360,
                    valueLabel: "\(Int(hsv.h.rounded()))°"
                ) { _ in
                    oklchHue = nil; emit()
                }
                GradientSlider(
                    value: $hsv.a.scaled(0, 1),
                    track: AnyView(alphaTrack),
                    thumbColor: rgb.opaque,
                    label: "Alpha", step: 0.01,
                    valueLabel: "\(Int((hsv.a * 100).rounded()))%"
                ) { _ in emit() }
            }

            HStack(spacing: 8) {
                FluidSelect(
                    selection: Binding<String?>(
                        get: { format.rawValue },
                        set: { if let v = $0, let f = FluidColorFormat(rawValue: v) { format = f; emit() } }
                    ),
                    // The source's trigger is borderless in a 2-col grid
                    // (:819-840); its chevron rotates 180° while open.
                    variant: .borderless, rotatesChevron: true
                ) {
                    ForEach(Array(FluidColorFormat.allCases.enumerated()), id: \.offset) { i, f in
                        FluidSelectItem(index: i, value: f.rawValue, label: f.label)
                    }
                }
                if !hideEyedropper {
                    // Ghost button — transparent, muted icon, hover fill
                    // (:1409-1423), not the solid primary chip.
                    FluidButton(variant: .ghost, size: .icon, action: eyedrop) {
                        Image(systemName: "eyedropper").font(.system(size: 16))
                    }
                    .accessibilityLabel("Pick color from screen")
                }
            }

            inputsRow

            if !swatches.isEmpty {
                FluidFlow(spacing: 8, rowSpacing: 8) {
                    // `${sw}-${i}` keys — duplicate swatch strings mustn't
                    // collide (color-picker.tsx:1545).
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, sw in
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
        // surfaceClasses(pickerLevel=max(substrate,3), shape.container).
        .fluidSurface(max(substrate, 3), radius: shape.container)
        .onAppear { applyParsed(value, emitChange: false) }
        .onChange(of: value) { _, new in
            // External writes adopt the color; our own emits echo back the
            // exact lastEmitted string and are ignored (:1607-1622).
            guard new != lastEmitted else { return }
            applyParsed(new, emitChange: false)
        }
    }

    // MARK: inputs

    @ViewBuilder
    private var inputsRow: some View {
        let aPct = Int((hsv.a * 100).rounded())
        switch format {
        case .hex:
            HStack(spacing: 8) {
                // hexNoHash — the "#" prefix renders separately (:1852-1861).
                FluidChannelField(text: String(rgb.hex.dropFirst()),
                                  prefix: "#", label: "Hex value") { applyColor($0) }
                FluidChannelField(text: "\(aPct)%", label: "Alpha") { setAlphaPercent($0) }
            }
        case .rgb:
            HStack(spacing: 4) {
                FluidChannelField(text: "\(Int(rgb.r.rounded()))", label: "Red") { setRGB(0, $0) }
                FluidChannelField(text: "\(Int(rgb.g.rounded()))", label: "Green") { setRGB(1, $0) }
                FluidChannelField(text: "\(Int(rgb.b.rounded()))", label: "Blue") { setRGB(2, $0) }
                FluidChannelField(text: "\(aPct)%", label: "Alpha") { setAlphaPercent($0) }
            }
        case .hsl:
            let hsl = rgbToHsl(rgb.r, rgb.g, rgb.b)
            HStack(spacing: 4) {
                FluidChannelField(text: "\(Int(hsl.h.rounded()))", label: "Hue") { setHSL(0, $0) }
                FluidChannelField(text: "\(Int((hsl.s * 100).rounded()))", label: "Saturation") { setHSL(1, $0) }
                FluidChannelField(text: "\(Int((hsl.l * 100).rounded()))", label: "Lightness") { setHSL(2, $0) }
                FluidChannelField(text: "\(aPct)%", label: "Alpha") { setAlphaPercent($0) }
            }
        case .oklch:
            let ok = rgbToOklch(rgb.r, rgb.g, rgb.b)
            HStack(spacing: 4) {
                FluidChannelField(text: "\(Int((ok.L * 100).rounded()))", label: "Lightness") { setOklch(0, $0) }
                FluidChannelField(text: String(format: "%.2f", ok.C), label: "Chroma") { setOklch(1, $0) }
                FluidChannelField(text: "\(Int((oklchHue ?? ok.H).rounded()))", label: "Hue") { setOklch(2, $0) }
                FluidChannelField(text: "\(aPct)%", label: "Alpha") { setAlphaPercent($0) }
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
            // color-aware transparent → solid color: the right stop is
            // fully opaque even at a<1 (:627-629, :642).
            LinearGradient(
                colors: [rgb.opaque.opacity(0), rgb.opaque],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    // MARK: behavior

    /// formatValueByFormat — emit in the active format (:401-408); hex is
    /// lowercase like the source's to2hex output.
    private func emit() {
        let p = rgb
        let out: String
        switch format {
        case .hex: out = p.hex.lowercased()
        case .rgb: out = p.rgbString
        case .hsl: out = p.hslString
        case .oklch: out = p.oklchString
        }
        lastEmitted = out
        value = out
    }

    /// Shared adopt path: parse → adopt into hsv (greyscale commits keep
    /// the last hue — a black pick shouldn't fling the square back to red).
    /// Every non-OKLCH-internal write clears the sticky oklch hue
    /// (:1614/1662/1755/1768).
    private func applyParsed(_ s: String, emitChange: Bool) {
        guard let p = fluidParseColor(s) else { return }
        oklchHue = nil
        let h = rgbToHsv(p.r, p.g, p.b)
        hsv = (h.s == 0 ? hsv.h : h.h, h.s, h.v, p.a)
        if emitChange { emit() }
    }

    /// Commit path for hex/named/functional input (swatch pick, hex field,
    /// eyedropper result).
    private func applyColor(_ s: String) {
        applyParsed(s, emitChange: true)
    }

    /// Normalize any accepted color string to lowercase hex for the
    /// selected-swatch comparison (the source resolves names via canvas).
    private func normalized(_ s: String) -> String {
        fluidParseColor(s)?.hex.lowercased() ?? s.lowercased()
    }

    /// Wrap only when the value is out of range — exactly `max` (360) stays
    /// 360 (:1207-1213).
    private static func wrapHue(_ n: Double) -> Double {
        guard n < 0 || n > 360 else { return n }
        return (n.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// A committed numeric string → Double, or nil to revert the field's
    /// draft. Rejects non-finite (a 300-digit field parses as ∞ and would
    /// trap the Int() hex rounding downstream).
    private static func channelNumber(_ text: String, allowSign: Bool = false) -> Double? {
        let n = Double(text.filter {
            $0.isNumber || $0 == "." || (allowSign && ($0 == "-" || $0 == "+"))
        })
        guard let n, n.isFinite else { return nil }
        return n
    }

    private func setRGB(_ channel: Int, _ text: String) {
        guard let n = Self.channelNumber(text) else { return }
        var p = rgb
        let v = min(255, max(0, n))
        switch channel { case 0: p.r = v; case 1: p.g = v; default: p.b = v }
        let h = rgbToHsv(p.r, p.g, p.b)
        hsv = (h.s == 0 ? hsv.h : h.h, h.s, h.v, hsv.a)
        oklchHue = nil; emit()
    }

    private func setHSL(_ channel: Int, _ text: String) {
        guard let n = Self.channelNumber(text, allowSign: true) else { return }
        let hsl = rgbToHsl(rgb.r, rgb.g, rgb.b)
        var (h, s, l) = hsl
        switch channel {
        case 0: h = Self.wrapHue(n); oklchHue = nil
        case 1: s = clamp01(n / 100)
        default: l = clamp01(n / 100)
        }
        let r = hslToRgb(h, s, l)
        let hsvN = rgbToHsv(r.r, r.g, r.b)
        hsv = (hsvN.s == 0 ? h : hsvN.h, hsvN.s, hsvN.v, hsv.a)
        emit()
    }

    private func setOklch(_ channel: Int, _ text: String) {
        guard let n = Self.channelNumber(text, allowSign: true) else { return }
        let cur = rgbToOklch(rgb.r, rgb.g, rgb.b)
        let baseH = oklchHue ?? cur.H
        var (L, C, H) = (cur.L, cur.C, baseH)
        switch channel {
        case 0: L = clamp01(n / 100)
        case 1: C = min(0.4, max(0, n))   // max={0.4} (:1897)
        default: H = Self.wrapHue(n)
        }
        oklchHue = H
        let r = oklchToRgb(L, C, H)
        let hsvN = rgbToHsv(min(255, max(0, r.r)), min(255, max(0, r.g)), min(255, max(0, r.b)))
        hsv = (hsvN.s == 0 ? hsv.h : hsvN.h, hsvN.s, hsvN.v, hsv.a)
        emit()
    }

    private func setAlphaPercent(_ text: String) {
        let stripped = text.replacingOccurrences(of: "%", with: "")
        guard let n = Double(stripped), n.isFinite else { return }
        // Math.round the percent before storing — 33.3% → 33 → 0.33 (:1920).
        hsv.a = clamp01(n.rounded() / 100); emit()
    }

    /// NSColorSampler — the macOS EyeDropper counterpart.
    private func eyedrop() {
        NSColorSampler().show { color in
            guard let color else { return }
            let c = color.usingColorSpace(.sRGB) ?? color
            applyColor(String(format: "#%02X%02X%02X",
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
            // The inner gradient box clamps to rounded-2xl (16) under pill —
            // the outer box keeps the full shape.bg (:537-541).
            base.cornerRadius = min(cornerRadius, 16)
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
    /// NSCursor.hide/unhide are counted, not idempotent — track ours so a
    /// mid-hover teardown can un-hide exactly once (:615+).
    private var cursorHidden = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 156)
    }

    /// Paired cursor hide/unhide — every visible state change routes here
    /// so the global hide count stays balanced (enter + drag used to count
    /// two hides for one unhide).
    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // role="application" + aria-label (:514-515) — the closest AppKit
        // group; arrow keys work when focused (keyDown below).
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Saturation and brightness")
        syncA11yValue()
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
        // :focus-visible ring — --focus-ring #6B97FF (:534), not --accent.
        focusRing.borderColor = NSColor(FluidTone.focusRing).cgColor
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
        syncA11yValue()
    }

    private func syncA11yValue() {
        setAccessibilityValue(
            "saturation \(Int((s * 100).rounded()))%, brightness \(Int((v * 100).rounded()))%"
        )
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

    /// Torn down mid-drag (popup dismissed, view removed) — un-hide the
    /// cursor, otherwise the global hide count leaks and the pointer stays
    /// invisible app-wide.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hovering = false
            draggingNow = false
            setCursorHidden(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        ghostAt = convert(event.locationInWindow, from: nil)
        setCursorHidden(true)
        syncGhost()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !draggingNow { setCursorHidden(false) }
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
        setCursorHidden(true)
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
            setCursorHidden(false)
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
/// The source's tracks are borderless (trackStyle borderColor:transparent /
/// borderWidth:0 — color-picker.tsx:601, :644).
private struct GradientSlider: View {
    @Binding var value: Double   // normalized 0…1 via .scaled()
    var track: AnyView
    var thumbColor: Color
    /// aria-label + VoiceOver name (source passes "Hue" / "Alpha").
    var label: String
    /// Normalized per-key step — 1/360 for hue, 0.01 for alpha.
    var step: Double
    /// VoiceOver value text, e.g. "220°" / "100%".
    var valueLabel: String
    var onEdit: (Double) -> Void

    @FocusState private var focused: Bool
    /// :focus-visible — a pointer press suppresses the ring until a key
    /// lands (the shared pointerFocus latch, FluidButton).
    @State private var pointerFocus = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                track
                    .frame(height: 18)
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity, alignment: .center)
                Circle()
                    .fill(thumbColor)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                    .frame(width: 20, height: 20)
                    .position(x: 10 + value * (geo.size.width - 20), y: geo.size.height / 2)
                // Keyboard focus ring on the thumb — the compact slider's
                // 24px circle recipe.
                Circle()
                    .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                    .frame(width: 24, height: 24)
                    .position(x: 10 + value * (geo.size.width - 20), y: geo.size.height / 2)
                    .opacity(focused && !pointerFocus ? 1 : 0)
                    .animation(FluidSpring.fast, value: focused && !pointerFocus)
            }
            .contentShape(Rectangle())
            // highPriority for the same scroll-steal reason as the square.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        pointerFocus = true
                        let usable = geo.size.width - 20
                        value = clamp01((d.location.x - 10) / usable)
                        onEdit(value)
                    }
            )
        }
        .frame(height: 32)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            pointerFocus = false
            let shift = press.modifiers.contains(.shift)
            switch press.key {
            case .leftArrow, .downArrow: nudge(-1, shift: shift)
            case .rightArrow, .upArrow: nudge(1, shift: shift)
            case .pageDown: nudge(-10, shift: false)
            case .pageUp: nudge(10, shift: false)
            case .home: setValue(0)
            case .end: setValue(1)
            default: return .ignored
            }
            return .handled
        }
        .onChange(of: focused) { _, f in
            // Blur or a focus arriving under a keyDown (Tab) restores the
            // keyboard modality; a press-focus keeps the pointer latch.
            if !f || NSApp.currentEvent?.type == .keyDown {
                pointerFocus = false
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(valueLabel))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: nudge(1, shift: false)
            case .decrement: nudge(-1, shift: false)
            default: break
            }
        }
    }

    private func setValue(_ v: Double) {
        let nv = clamp01(v)
        guard nv != value else { return }
        value = nv
        onEdit(nv)
    }

    /// Arrow ±step, Shift ±10 steps — the Radix slider key map.
    private func nudge(_ direction: Double, shift: Bool) {
        setValue(value + direction * step * (shift ? 10 : 1))
    }
}

// MARK: - Small pieces

/// A channel input: ladder-height field (36/28), transparent → hover fill,
/// centered text — the source's ColorInput minus drag-to-scrub. Commits on
/// blur and Enter only — never per keystroke (the source ignores
/// input-change parses, :1234-1241).
private struct FluidChannelField: View {
    var text: String
    var prefix: String? = nil
    /// aria-label for the text field.
    var label: String
    var onCommit: (String) -> Void

    @State private var draft: String = ""
    /// Escape pressed — the draft was reverted before blur so the blur
    /// commit must not run (:1329-1346).
    @State private var cancelled = false
    @State private var hovered = false
    @FocusState private var editing: Bool
    @Environment(\.fluidSize) private var size
    @Environment(\.fluidShape) private var shape

    var body: some View {
        HStack(spacing: 2) {
            if let prefix {
                Text(prefix)
                    .font(.system(size: size == .compact ? 11 : 12))
                    .foregroundStyle(FluidTone.mutedForeground)
            }
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: size.text).monospacedDigit())
                .foregroundStyle(FluidTone.foreground)
                .focused($editing)
                .accessibilityLabel(label)
                .onSubmit {
                    // Enter blurs; the blur path below commits (:1112-1113).
                    editing = false
                }
                .onExitCommand {
                    // Escape: restore the committed value's text before
                    // blurring so the input-blur commit is a no-op.
                    cancelled = true
                    draft = text
                    editing = false
                }
        }
        .padding(.horizontal, 8)
        .frame(height: size.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                .fill(hovered ? FluidTone.hover : .clear)
        )
        // focus-within:ring-1 ring-[--focus-ring] — a 1px band 1px out.
        .overlay(
            RoundedRectangle(cornerRadius: shape.input + 1, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .padding(-1)
                .opacity(editing ? 1 : 0)
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.08), value: hovered)
        .animation(FluidSpring.fast, value: editing)
        .onAppear { draft = text }
        // External value changes resync the draft without committing —
        // writing `draft` here must not re-emit (the 8-bit quantization
        // feedback loop during SV drags).
        .onChange(of: text) { _, new in if !editing { draft = new } }
        // Focus loss commits the raw draft (unless Esc already reverted it)
        // and resyncs from the model.
        .onChange(of: editing) { _, now in
            if !now {
                if !cancelled { onCommit(draft) }
                cancelled = false
                draft = text
            }
        }
    }
}

/// Checkerboard under alpha-aware tiles and tracks — the conic-gradient's
/// `--checker-a`/`--checker-b` per scheme (globals.css:181-182/246-247).
struct FluidCheckerboard: View {
    var cell: CGFloat = 4
    @Environment(\.colorScheme) private var scheme

    /// #bbbbbb light / #1f1f1f dark.
    private var a: Color {
        scheme == .dark ? Color(white: 0x1F / 255) : Color(white: 0xBB / 255)
    }
    /// #ffffff light / #2a2a2a dark.
    private var b: Color {
        scheme == .dark ? Color(white: 0x2A / 255) : .white
    }

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / cell) + 2
            let rows = Int(size.height / cell) + 2
            for r in 0..<rows {
                for c in 0..<cols {
                    let even = (r + c) % 2 == 0
                    ctx.fill(
                        Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)),
                        with: .color(even ? a : b)
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
        .onContinuousHover { phase in
            switch phase {
            case .active: hovered = true
            case .ended: hovered = false
            }
        }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeOut(duration: 0.1), value: selected)
        // aria-label="Select color {color}" (:1475).
        .accessibilityLabel("Select color \(color)")
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

// MARK: - Popover compound (color-picker.tsx:1950-2133)

/// Trigger side the optional `triggerLabel` sits on (default left).
enum FluidLabelPosition { case left, right }

/// `ColorPickerPopover` — a bordered trigger (color tile + value text +
/// optional label/remove) that opens the picker in a non-activating
/// popup: edge .bottom, align .start, sideOffset 6, outside-click and
/// Escape dismiss — the Base UI Popover.Positioner defaults.
struct FluidColorPickerPopover: View {
    @Binding private var valueBinding: String
    /// Controlled open — nil leaves it internal (source `open`/`defaultOpen`).
    private var controlledOpen: Binding<Bool>?
    var defaultOpen = false
    var onOpenChange: ((Bool) -> Void)? = nil
    var swatches: [String] = []
    var hideEyedropper = false
    var triggerLabel: String? = nil
    var triggerLabelPosition: FluidLabelPosition = .left
    var triggerShowValue = true
    var triggerShowRemove = false
    var onTriggerRemove: (() -> Void)? = nil
    /// Pin the whole compound to a ladder step (source `size` — it crosses
    /// the popup like React context crosses the portal).
    var size: FluidSize? = nil
    /// The substrate the trigger sits on — the popup panel floats at
    /// `min(substrate + 2, 8)` (:1979-1980).
    var substrate: Int = 1

    init(value: Binding<String>,
         swatches: [String] = [],
         hideEyedropper: Bool = false,
         triggerLabel: String? = nil,
         triggerLabelPosition: FluidLabelPosition = .left,
         triggerShowValue: Bool = true,
         triggerShowRemove: Bool = false,
         onTriggerRemove: (() -> Void)? = nil,
         size: FluidSize? = nil,
         substrate: Int = 1,
         open: Binding<Bool>? = nil,
         defaultOpen: Bool = false,
         onOpenChange: ((Bool) -> Void)? = nil) {
        _valueBinding = value
        self.swatches = swatches
        self.hideEyedropper = hideEyedropper
        self.triggerLabel = triggerLabel
        self.triggerLabelPosition = triggerLabelPosition
        self.triggerShowValue = triggerShowValue
        self.triggerShowRemove = triggerShowRemove
        self.onTriggerRemove = onTriggerRemove
        self.size = size
        self.substrate = substrate
        self.controlledOpen = open
        self.defaultOpen = defaultOpen
        self.onOpenChange = onOpenChange
        _internalOpen = State(initialValue: defaultOpen)
    }

    @State private var controller = FluidPopupController()
    @State private var internalOpen: Bool
    @State private var hovered = false
    @State private var removeHovered = false
    @FocusState private var focused: Bool
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var ambientSize

    private var resolvedSize: FluidSize { size ?? ambientSize }
    private var compact: Bool { resolvedSize == .compact }
    private var open: Bool { controlledOpen?.wrappedValue ?? internalOpen }

    private var parsedValue: FluidRGBA? { fluidParseColor(valueBinding) }
    /// The tile shows the parsed color (or clear when unparseable).
    private var tileColor: Color { parsedValue?.color ?? .clear }
    /// Value text — opaque hex without '#', uppercase (:2018-2020);
    /// falls back to the raw value when unparseable.
    private var valueLabel: String {
        guard let p = parsedValue else { return valueBinding }
        return String(p.hex.prefix(7).dropFirst()).uppercased()
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { setOpen(!open) } label: {
                HStack(spacing: resolvedSize.gap) {
                    if let triggerLabel, triggerLabelPosition == .left {
                        Text(triggerLabel)
                            .font(.system(size: resolvedSize.text))
                            .foregroundStyle(FluidTone.mutedForeground)
                    }
                    FluidColorTile(color: tileColor, size: compact ? 16 : 20)
                    if triggerShowValue {
                        Text(valueLabel)
                            .font(.system(size: resolvedSize.text, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(FluidTone.foreground)
                    }
                    if let triggerLabel, triggerLabelPosition == .right {
                        Text(triggerLabel)
                            .font(.system(size: resolvedSize.text))
                            .foregroundStyle(FluidTone.mutedForeground)
                    }
                }
                .padding(.leading, compact ? 6 : 8)
                .padding(.trailing, triggerShowRemove ? 0 : (compact ? 6 : 8))
                .frame(height: resolvedSize.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityLabel("Color, \(valueLabel)")
            if triggerShowRemove {
                // A sibling, not a child of the trigger Button — nested
                // buttons fight over the click.
                Button { onTriggerRemove?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(removeHovered ? FluidTone.foreground
                                                       : FluidTone.mutedForeground)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { removeHovered = $0 }
                .animation(.easeOut(duration: 0.08), value: removeHovered)
                .accessibilityLabel("Remove color")
                .padding(.trailing, compact ? 6 : 8)
            }
        }
        // border border-border + hover fill on the whole trigger box.
        .background(
            RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                .fill(hovered ? FluidTone.hover : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                .strokeBorder(FluidTone.border, lineWidth: 1)
        )
        // focus-visible:ring-1 ring-[--focus-ring].
        .overlay(
            RoundedRectangle(cornerRadius: shape.input + 1, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .padding(-1)
                .opacity(focused ? 1 : 0)
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.08), value: hovered)
        .background(FluidAnchorResolver(controller: controller))
        .onChange(of: open) { _, o in
            if o { present() } else { controller.dismiss() }
            onOpenChange?(o)
        }
        .onAppear {
            // Outside click / Escape dismiss through the controller.
            controller.onDismissed = { setOpen(false) }
            if open { present() }
        }
        .onDisappear { controller.dismiss(animated: false) }
    }

    private func setOpen(_ next: Bool) {
        controlledOpen?.wrappedValue = next
        internalOpen = next
    }

    /// Popover.Positioner: side=bottom, align=start, sideOffset=6. The
    /// panel is the picker itself — SurfaceProvider(level) arrives as the
    /// picker's `substrate` param; the ladder pin and ambient shape cross
    /// into the detached hosting view via env.
    private func present() {
        guard !controller.isPresented || controller.isClosing else { return }
        let controller = self.controller
        Task { @MainActor in
            // The anchor resolves a runloop after the NSView materializes —
            // spin briefly (a mounted defaultOpen hits this; the tooltip
            // opener does the same).
            for _ in 0..<60 where controller.anchorScreenRect() == nil {
                try? await Task.sleep(nanoseconds: 4_000_000)
                guard !Task.isCancelled else { return }
            }
            guard open, !controller.isPresented || controller.isClosing else { return }
            controller.present(edge: .bottom, align: .start, offset: 6) {
                // SurfaceProvider(level) → the picker's max(substrate,3)
                // floor keeps this at substrate+2 when it's higher.
                FluidColorPicker(value: $valueBinding,
                                 swatches: swatches,
                                 hideEyedropper: hideEyedropper,
                                 substrate: min(substrate + 2, 8))
                    .environment(\.fluidSize, resolvedSize)
                    .environment(\.fluidShape, shape)
            }
            // Reinstalled per present — teardown nils the callbacks so
            // their captured state can't pin the controller in a cycle.
            controller.onDismissed = { setOpen(false) }
        }
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

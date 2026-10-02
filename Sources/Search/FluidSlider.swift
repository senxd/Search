import SwiftUI
import AppKit

/// Hit slop — expands a view's hit region without touching layout. Used
/// for the slider's -8px horizontal pointer margins: a plain
/// `contentShape(Rectangle())` is bound to the view's frame; an inset
/// shape can reach past it.
private struct FluidSliderSlop: Shape {
    var horizontal: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX - horizontal, y: rect.minY - top,
            width: rect.width + horizontal * 2,
            height: rect.height + top + bottom
        ))
    }
}

// FluidSlider — both designs from components/ui/slider.tsx behind the one
// public view, routed like the source's <Slider>:
//
//   Comfortable lane (the default size step): `.pips` — the bordered 32pt
//   box with the dot strip, --active fill, 2px handle line and label:value
//   row (the original port); or `.scrubber` — the bare edge-to-edge fill
//   with the same text row and an 8px resize strip riding the fill edge.
//
//   Compact engine — taken whenever the props leave the comfortable lane,
//   exactly as the source forces it: a range value (bind `value:` to a
//   (Double, Double)), `steps:` (a discrete list of allowed values — the
//   thumb snaps only to them and arrows walk the list), `showSteps`
//   (masked 4px dots on the track), `showValue`/`valuePosition` (the
//   "label: lo — hi" line or per-thumb tooltip chips), `hideFill`, thumb
//   tinting, or `size: .compact` (a param or the ambient \.fluidSize).
//
// Compact specifics ported verbatim: THUMB_SIZE 20 with a 16px white core
// (1px drop shadow, optional tint/border) and a 24px focus-ring circle,
// the 18px bordered capsule track inset 1px so its cap centers ride the
// thumb centers, the selected-50 (light) / accent-40 (dark) fill running
// edge→thumb or thumb→thumb, the accent-40% hover preview bar rounded on
// the far end, the 100ms-delayed value chip, click-to-edit values, the
// nearest-thumb drag pick, the 10px crossing clamp — and the Radix key
// map: arrows ±step, shift+arrow and PageUp/PageDown ±10 steps, Home/End
// to the extremes, committed sorted (keys may cross thumbs; drags can't),
// focus following the moved value. Focus rings track keyboard modality
// like :focus-visible — pointer focus never shows them.

struct FluidSlider: View {
    /// Comfortable-step layouts: `pips` (dot strip) or `scrubber` (bare fill).
    enum Variant { case pips, scrubber }
    /// Where the compact engine puts its value line. `tooltip` rides each
    /// thumb instead of a fixed row.
    enum ValuePosition { case left, right, top, bottom, tooltip }

    // MARK: API (mirrors SliderEngineProps / SliderComfortableProps)

    @Binding private var value0: Double
    @Binding private var value1: Double
    private var isRange = false

    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    /// Discrete allowed values (source `steps`). Forces the compact engine;
    /// min/max derive from the list's extremes and `step` is ignored.
    var steps: [Double]? = nil
    var label: String? = nil
    var format: (Double) -> String = FluidSlider.defaultFormat
    var isDisabled = false
    var variant: Variant = .pips
    /// Pins the size-ladder step; nil follows \.fluidSize (useSizeVariant).
    var size: FluidSize? = nil
    var showSteps: Bool? = nil
    var showValue: Bool? = nil
    var valuePosition: ValuePosition? = nil
    var hideFill: Bool? = nil
    var thumbColor: Color? = nil
    var thumbBorderColor: Color? = nil

    /// Single value — the source's `value: number`.
    init(value: Binding<Double>,
         range: ClosedRange<Double> = 0...100,
         step: Double = 1,
         steps: [Double]? = nil,
         label: String? = nil,
         format: @escaping (Double) -> String = FluidSlider.defaultFormat,
         isDisabled: Bool = false,
         variant: Variant = .pips,
         size: FluidSize? = nil,
         showSteps: Bool? = nil,
         showValue: Bool? = nil,
         valuePosition: ValuePosition? = nil,
         hideFill: Bool? = nil,
         thumbColor: Color? = nil,
         thumbBorderColor: Color? = nil) {
        _value0 = value
        _value1 = .constant(0)
        self.range = range
        self.step = step
        self.steps = steps
        self.label = label
        self.format = format
        self.isDisabled = isDisabled
        self.variant = variant
        self.size = size
        self.showSteps = showSteps
        self.showValue = showValue
        self.valuePosition = valuePosition
        self.hideFill = hideFill
        self.thumbColor = thumbColor
        self.thumbBorderColor = thumbBorderColor
    }

    /// Range value — the source's `value: [number, number]`. The pair is
    /// stored lo/hi in the binding; drags clamp the thumbs 10px apart while
    /// keyboard commits sort (same asymmetry as the source).
    init(value pair: Binding<(Double, Double)>,
         range: ClosedRange<Double> = 0...100,
         step: Double = 1,
         steps: [Double]? = nil,
         label: String? = nil,
         format: @escaping (Double) -> String = FluidSlider.defaultFormat,
         isDisabled: Bool = false,
         variant: Variant = .pips,
         size: FluidSize? = nil,
         showSteps: Bool? = nil,
         showValue: Bool? = nil,
         valuePosition: ValuePosition? = nil,
         hideFill: Bool? = nil,
         thumbColor: Color? = nil,
         thumbBorderColor: Color? = nil) {
        _value0 = Binding(get: { pair.wrappedValue.0 }, set: { pair.wrappedValue.0 = $0 })
        _value1 = Binding(get: { pair.wrappedValue.1 }, set: { pair.wrappedValue.1 = $0 })
        self.isRange = true
        self.range = range
        self.step = step
        self.steps = steps
        self.label = label
        self.format = format
        self.isDisabled = isDisabled
        self.variant = variant
        self.size = size
        self.showSteps = showSteps
        self.showValue = showValue
        self.valuePosition = valuePosition
        self.hideFill = hideFill
        self.thumbColor = thumbColor
        self.thumbBorderColor = thumbBorderColor
    }

    static func defaultFormat(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
    }

    // MARK: State (only one engine renders at a time — shared where it can be)

    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidSize) private var ambientSize
    @Environment(\.fluidShape) private var shape
    @State private var hovered = false
    @State private var pressed = false
    @State private var trackW: CGFloat = 0
    /// The snapped value under the cursor — the hover preview bar + chip.
    @State private var preview: Preview? = nil
    @State private var showTip = false
    @State private var tipTask: Task<Void, Never>? = nil
    /// Radix's "which thumb keys move" — the focused (or last-moved) thumb.
    @FocusState private var focusedThumb: Int?
    /// :focus-visible tracking — true when the last input in this window was
    /// a key, false when it was a mouse button (NSEvent monitors below).
    @State private var keyboard = false
    @State private var monitors: [Any] = []
    @State private var viewRef = ViewRef()
    // Compact engine — the motionX0/motionX1 pair (thumb left edges, px).
    @State private var px0: CGFloat = 0
    @State private var px1: CGFloat = 0
    @State private var pxSynced = false
    @State private var ready = false
    @State private var dragging = false
    @State private var activeThumb = 0
    @State private var dotScale: CGFloat = 1
    @State private var editing: Int? = nil
    @State private var editText = ""
    /// The displayText's iBeam push — tracked so teardown/startEdit can
    /// pop it when the Text is destroyed mid-hover.
    @State private var iBeamHover = false
    @FocusState private var editFocused: Bool
    // Scrubber — displayed fill fraction + zero-offset (motion values).
    @State private var scrubP: CGFloat? = nil
    @State private var scrubZO: CGFloat? = nil

    private struct Preview { let left: CGFloat; let width: CGFloat; let value: Double; let cursorX: CGFloat }

    // MARK: Derived config

    /// Sorted, deduped step list — nil unless `steps` holds ≥2 distinct values.
    private var stepValues: [Double]? {
        guard let steps else { return nil }
        let s = Array(Set(steps)).sorted()
        return s.count > 1 ? s : nil
    }
    private var effMin: Double { stepValues?.first ?? range.lowerBound }
    private var effMax: Double { stepValues?.last ?? range.upperBound }

    private var resolvedSize: FluidSize { size ?? ambientSize }
    /// The source's needsCompactEngine check — any compact-only feature set
    /// (or the compact ladder step) routes there.
    private var usesCompact: Bool {
        // Defined-but-false still routes compact — the source checks
        // showSteps !== undefined, not truthiness (slider.tsx:1676-1688).
        isRange || steps != nil || showSteps != nil || showValue != nil
            || valuePosition != nil || hideFill != nil || thumbColor != nil
            || thumbBorderColor != nil || resolvedSize == .compact
    }
    private var pos: ValuePosition { valuePosition ?? .left }
    private var showsValueLine: Bool { (showValue ?? true) && pos != .tooltip }
    private var interacting: Bool { hovered || pressed }
    /// The source's :focus-visible gate — rings only under keyboard modality.
    private var ringVisible: Bool { focusedThumb != nil && keyboard && !isDisabled }
    /// isActive (comfortable) — hovered or keyboard-focused.
    private var activeUI: Bool { hovered || ringVisible }

    // MARK: Body — engine routing

    var body: some View {
        Group {
            if usesCompact { compactBody } else { comfortableBody }
        }
        .overlay(alignment: .topLeading) { WindowProbe(ref: viewRef).frame(width: 0, height: 0) }
        .onKeyPress(phases: [.down, .repeat]) { handleKey($0) }
        .onAppear { installMonitors() }
        .onDisappear {
            monitors.forEach(NSEvent.removeMonitor); monitors = []
            teardownHover()
        }
        .onChange(of: value0) { _, _ in externalSync(0) }
        .onChange(of: value1) { _, _ in externalSync(1) }
        // Engine swap remounts the compact engine in the source — px
        // state derived for the comfortable lane is stale, so force a
        // fresh initial sync on the next measure.
        .onChange(of: usesCompact) { _, _ in ready = false; pxSynced = false }
        .onChange(of: effMin) { _, _ in externalSync(0); externalSync(1) }
        .onChange(of: effMax) { _, _ in externalSync(0); externalSync(1) }
        .opacity(isDisabled ? 0.5 : 1)
    }

    /// Programmatic/external writes animate (the source's valuesKey effect →
    /// spring.moderate on the motion values, spring.fast on the scrubber's).
    private func externalSync(_ i: Int) {
        if usesCompact {
            guard ready, !dragging else { return }
            withAnimation(FluidSpring.moderate) {
                if i == 0 { px0 = vpx(value0) } else { px1 = vpx(value1) }
            }
        } else if variant == .scrubber {
            guard !pressed else { return }
            withAnimation(FluidSpring.fast) {
                scrubP = fraction
                scrubZO = value0 == effMin ? zeroTarget : 0
            }
        }
    }

    // MARK: - Comfortable lane

    private var pipCount: Int {
        // Math.round, not truncation — a non-divisible range still emits
        // the overshoot pip the source renders (slider.tsx:1156).
        step > 0 ? Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1 : 1
    }
    private var pips: [Double] { (0..<pipCount).map { range.lowerBound + Double($0) * step } }
    private var fraction: CGFloat {
        // fillPercent clamps programmatic out-of-range values to [0,1].
        range.upperBound == range.lowerBound
            ? 0 : min(1, max(0, CGFloat((value0 - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }
    /// The px nudge that keeps the handle line visible at value == min —
    /// 8 for pips, 17 for the scrubber (zeroTarget).
    private var zeroTarget: CGFloat { variant == .pips ? 8 : 17 }
    private var zeroOffset: CGFloat { value0 == range.lowerBound ? zeroTarget : 0 }

    /// fill edge = p*W + 20 - 20p - zo*2.5  (pipsFillWidthStyle)
    private var fillWidth: CGFloat {
        fraction * trackW + 20 - 20 * fraction - zeroOffset * 2.5
    }
    /// handle line left = p*W + 11 - 24p   (pipsHandleLineLeftStyle)
    private var handleX: CGFloat { fraction * trackW + 11 - 24 * fraction }

    /// The scrubber's displayed fraction — the fillPercent motion value.
    private var displayedP: CGFloat { scrubP ?? fraction }
    private var displayedZO: CGFloat { scrubZO ?? zeroOffset }
    /// Scrubber handle line left = p*W - 9 + zo (handleLineLeftStyle);
    /// the resize strip sits 1px right of it (handleLeftStyle, -8 + zo).
    private var scrubHandleX: CGFloat { displayedP * trackW - 9 + displayedZO }

    private var comfortableBody: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .leading) {
                if variant == .pips { pipsTrack } else { scrubTrack }
            }
            .frame(height: 32)
            .clipShape(RoundedRectangle(cornerRadius: shape.bg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                    .strokeBorder(FluidTone.border, lineWidth: 1)
            )
            .overlay(
                // The focus-visible outline: 1px --focus-ring, offset 2px.
                RoundedRectangle(cornerRadius: shape.focusRing, style: .continuous)
                    .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                    .padding(-2)
                    .opacity(ringVisible ? 1 : 0)
                    .animation(FluidSpring.fast, value: ringVisible)
            )
            if let p = preview, showTip, !pressed {
                // The tooltip lives outside the clipped box, -30px up.
                Text(format(p.value))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(FluidTone.background)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                            .fill(FluidTone.foreground)
                    )
                    .fixedSize()
                    .position(x: p.cursorX, y: -18)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(height: 32)
        .coordinateSpace(name: "fluidSliderTrack")
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { trackW = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in trackW = w }
            }
        )
        // Extended hit area — 8px past each side (slider.tsx:944-952). A
        // negative-inset contentShape expands the hit region without
        // touching layout; pointer x in the margin clamps inside the
        // track math, matching the source's clientX→value path.
        .contentShape(FluidSliderSlop(horizontal: 8))
        .focusable(!isDisabled)
        .focused($focusedThumb, equals: 0)
        .focusEffectDisabled()
        .accessibilityElement()
        .accessibilityLabel(label ?? "Slider")
        .accessibilityValue(Text(format(value0)))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: nudge(thumb: 0, direction: 1, multiplier: 1)
            case .decrement: nudge(thumb: 0, direction: -1, multiplier: 1)
            default: break
            }
        }
        .onHover { h in
            guard !isDisabled else { return }
            hoverChanged(h)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !isDisabled, !pressed else { return }
            switch phase {
            case .active(let point): computePreview(at: point.x)
            case .ended: break
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard !isDisabled else { return }
                    if !pressed {
                        // pointerdown — focus the thumb (focusVisible: false)
                        // and animate the fill to the snapped value.
                        pressed = true
                        focusedThumb = 0
                        keyboard = false
                        let v = comfortableValue(at: g.location.x)
                        if variant == .scrubber {
                            scrubSet(v, animated: true)
                        } else if v != value0 {
                            value0 = v
                        }
                    } else {
                        let v = comfortableValue(at: g.location.x)
                        if variant == .scrubber {
                            scrubSet(v, animated: false)   // fillPercent.set — instant
                        } else if v != value0 {
                            value0 = v
                        }
                    }
                }
                .onEnded { _ in
                    pressed = false
                    preview = nil
                }
        )
    }

    /// Comfortable snap — pips round to the pip grid over the full width;
    /// the scrubber maps x→value continuously then snaps to `step`.
    private func comfortableValue(at x: CGFloat) -> Double {
        if variant == .scrubber {
            guard trackW > 0, step > 0 else { return range.lowerBound }
            let clamped = max(0, min(trackW, x))
            let raw = range.lowerBound + (clamped / trackW) * (range.upperBound - range.lowerBound)
            return min(max(((raw - range.lowerBound) / step).rounded() * step + range.lowerBound,
                           range.lowerBound), range.upperBound)
        }
        return snap(x: x)
    }

    /// Scrubber displayed-fraction write — animated on track pointerdown,
    /// direct set on moves and on the resize handle (the source's
    /// fillPercent.set vs animate(fast)).
    private func scrubSet(_ v: Double, animated: Bool) {
        let p = range.upperBound == range.lowerBound
            ? 0 : min(1, max(0, CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))))
        let zo: CGFloat = v == range.lowerBound ? zeroTarget : 0
        if animated {
            withAnimation(FluidSpring.fast) { scrubP = p }
        } else {
            scrubP = p
        }
        // zeroOffset eases on spring.fast on EVERY move — even instant
        // fill writes (slider.tsx:1305) — so the 17px nudge never snaps.
        withAnimation(FluidSpring.fast) { scrubZO = zo }
        if v != value0 { value0 = v }
    }

    /// Everything inside the pips box: dots, occluders, fill, handle, text.
    private var pipsTrack: some View {
        ZStack(alignment: .leading) {
            // z1 — the dot strip, masked open right of the fill edge.
            pipsLayer
            // z2 — opaque pads under the texts so no pip shows through.
            occluders
            // z3 — hover preview bar: fill edge → snapped edge. Same
            // z-index as the fill/handle and EARLIER in DOM order, so
            // they paint over it (slider.tsx:1455 before 1517/1528).
            if let p = preview, !pressed {
                Rectangle()
                    .fill(FluidTone.accent.opacity(0.4))
                    .frame(width: abs(p.width))
                    .offset(x: p.left)
                    .transition(.opacity)
            }
            // z3 — the fill.
            Rectangle()
                .fill(FluidTone.active)
                .frame(width: max(0, fillWidth))
                .animation(FluidSpring.fast, value: fillWidth)
            // z3 — the handle line, 2px, grows 1px top/bottom while active.
            RoundedRectangle(cornerRadius: 1)
                .fill(handleColor)
                .frame(width: 2)
                .padding(.vertical, activeUI ? 7 : 8)
                .offset(x: handleX)
                .animation(FluidSpring.fast, value: handleX)
                .animation(FluidSpring.fast, value: handleColor)
            // z4 — label + value.
            HStack {
                if let label {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(textColor)
                        .padding(.horizontal, 8)
                }
                Spacer(minLength: 0)
                valueText(format(value0))
                    .foregroundStyle(textColor)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .animation(FluidSpring.fast, value: textColor)
        }
    }

    /// The scrubber box: fill edge-to-edge, handle line 9px inside it,
    /// label/value in a px-4 gap-3 row, resize strip on the fill edge.
    private var scrubTrack: some View {
        ZStack(alignment: .leading) {
            // z0 — the fill (p*100% of the box).
            Rectangle()
                .fill(FluidTone.active)
                .frame(width: max(0, displayedP * trackW))
            // z3 — hover preview: over the z-auto fill, under the z-10
            // handle line and text (slider.tsx:1456 before 1588).
            if let p = preview, !pressed {
                Rectangle()
                    .fill(FluidTone.accent.opacity(0.4))
                    .frame(width: abs(p.width))
                    .offset(x: p.left)
                    .transition(.opacity)
            }
            // z10 — the handle line, 2px at left: p*W - 9 + zo.
            RoundedRectangle(cornerRadius: 1)
                .fill(handleColor)
                .frame(width: 2)
                .padding(.vertical, activeUI ? 7 : 8)
                .offset(x: scrubHandleX)
                .animation(FluidSpring.fast, value: handleColor)
            // z10 — label + value, px-4.
            HStack(spacing: 12) {
                if let label {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(textColor)
                }
                Spacer(minLength: 0)
                valueText(format(value0))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 16)
            // z20 — the 8px resize strip at left: p*W - 8 + zo. Drags set
            // the fill directly — no spring (handleResizePointer*).
            Color.clear
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .offset(x: displayedP * trackW - 8 + displayedZO)
                .highPriorityGesture(
                    // The strip is 8pt wide — gesture locations in its own
                    // space read ~0-8 regardless of pointer position; the
                    // named space lands them in container coordinates like
                    // the source's clientX → container-rect mapping.
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("fluidSliderTrack"))
                        .onChanged { g in
                            guard !isDisabled else { return }
                            if !pressed { pressed = true; focusedThumb = 0; keyboard = false }
                            scrubSet(comfortableValue(at: g.location.x), animated: false)
                        }
                        .onEnded { _ in pressed = false; preview = nil }
                )
        }
    }

    /// The transparent-text layer from the source — opaque bg rectangles
    /// exactly behind label and value.
    private var occluders: some View {
        HStack {
            if let label {
                Text(label).font(.system(size: 13)).hidden()
                    .padding(.horizontal, 8)
                    .background(FluidTone.background)
            }
            Spacer(minLength: 0)
            valueText(format(value0)).font(.system(size: 13)).hidden()
                .padding(.horizontal, 8)
                .background(FluidTone.background)
        }
        .padding(.horizontal, 8)
    }

    /// Value text with the source's `minWidth: len(format(max))ch`
    /// reservation — a hidden ghost keeps the widest value's width.
    private func valueText(_ s: String) -> some View {
        ZStack(alignment: .trailing) {
            Text(format(range.upperBound)).hidden()
            Text(s)
        }
        .fixedSize()
        .font(.system(size: 13))
        .monospacedDigit()
    }

    private var pipsLayer: some View {
        // Canvas, not an HStack of dots: 101 fixed-size children impose a
        // ~529pt min-width that inflates the whole track past its frame.
        // Positions match the source's `justify-between` inside px-3.
        Canvas { ctx, size in
            let n = pips.count
            guard n >= 1 else { return }
            let inset: CGFloat = 12
            let span = max(0, size.width - inset * 2 - 5)
            for (i, pip) in pips.enumerated() {
                // Pixel-aligned so the 5px dot doesn't straddle a
                // boundary; a lone pip parks at the left edge
                // (slider.tsx:1156).
                let x = n > 1
                    ? (inset + span * CGFloat(i) / CGFloat(n - 1)).rounded()
                    : inset
                let active = pip == value0
                ctx.fill(
                    Path(ellipseIn: CGRect(
                        x: x, y: ((size.height - 5) / 2).rounded(),
                        width: 5, height: 5
                    )),
                    with: .color(active ? FluidTone.foreground : FluidTone.mutedForeground.opacity(0.3))
                )
            }
        }
        // The mask: opaque through the fill edge, transparent past it, so
        // dots only show on the unfilled side.
        .mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(
                                    color: .clear,
                                    location: max(0, min(1, fillWidth / max(geo.size.width, 1)))
                                ),
                                .init(
                                    color: .black,
                                    location: max(
                                        0, min(1, (fillWidth + 2) / max(geo.size.width, 1))
                                    )
                                ),
                                .init(color: .black, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    // Animate inside the mask — the sibling-scope
                    // animation on the fill doesn't reach in here, and
                    // the reveal edge tracks the fill edge in the source.
                    .animation(FluidSpring.fast, value: fillWidth)
            }
        }
    }

    private var textColor: Color {
        activeUI ? FluidTone.foreground : FluidTone.mutedForeground
    }

    private var handleColor: Color {
        ringVisible ? FluidTone.foreground
            : hovered ? FluidTone.foreground.opacity(0.5) : FluidTone.foreground.opacity(0.25)
    }

    private func snap(x: CGFloat) -> Double {
        guard pipCount > 1, trackW > 0 else { return range.lowerBound }
        let clamped = max(0, min(trackW, x))
        // Math.round — nearest pip, not the one below the fraction.
        let i = Int(((clamped / trackW) * CGFloat(pipCount - 1)).rounded())
            .clamped(to: 0...(pipCount - 1))
        return pips[i]
    }

    private func computePreview(at x: CGFloat) {
        guard trackW > 0 else { return }
        // Source's `if (pipCount <= 1) return` — a degenerate grid would
        // paint a full-left bar (slider.tsx:1218).
        if variant == .pips, pipCount <= 1 { preview = nil; return }
        let v = comfortableValue(at: x)
        let snappedX = range.upperBound == range.lowerBound
            ? 0 : CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) * trackW
        let edgeX = v == range.lowerBound ? 0 : v == range.upperBound ? trackW : snappedX
        // The bar runs from the fill edge — pipsFillWidthStyle for pips,
        // fillPercent*w for the scrubber (computeHoverPreview's handleX).
        let hx = variant == .pips ? fillWidth : displayedP * trackW
        // Plain assignment — the source writes left/width/cursorX as raw
        // style (the bar tracks the pointer); only its opacity animates,
        // via the .transition on the view.
        // cursorX in the source IS snappedX — the tooltip rides the pip,
        // not the pointer.
        preview = Preview(left: min(hx, edgeX), width: abs(edgeX - hx), value: v, cursorX: snappedX)
    }

    // MARK: - Compact engine (SliderEngineProps)

    private static let thumb: CGFloat = 20      // THUMB_SIZE
    private static let thumbRest: CGFloat = 16  // THUMB_SIZE_REST
    private static let trackH: CGFloat = 18     // TRACK_BG_HEIGHT
    private static let dot: CGFloat = 4         // DOT_SIZE
    private static let inset: CGFloat = 1       // TRACK_INSET

    /// usable = trackWidth - THUMB_SIZE — the thumb left edge's travel.
    private var usable: CGFloat { max(0, trackW - Self.thumb) }

    private func vpx(_ v: Double) -> CGFloat {   // valueToPixel
        guard effMax != effMin else { return 0 }
        return CGFloat((v - effMin) / (effMax - effMin)) * usable
    }
    private func pxv(_ px: CGFloat) -> Double {  // pixelToValue
        guard usable > 0 else { return effMin }
        let raw = Double(px / usable) * (effMax - effMin) + effMin
        return snapValue(raw)
    }
    /// Snap into the allowed set — nearest `steps` entry or the step grid.
    private func snapValue(_ v: Double) -> Double {
        if let sv = stepValues { return sv[nearestStepIndex(v, sv)] }
        guard step > 0 else { return min(max(v, effMin), effMax) }
        let snapped = ((v - effMin) / step).rounded() * step + effMin
        return min(max(snapped, effMin), effMax)
    }
    private func px(_ i: Int) -> CGFloat { i == 0 ? px0 : px1 }
    private func val(_ i: Int) -> Double { i == 0 ? value0 : value1 }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pos == .top, showsValueLine { valueDisplay }
            if pos == .left || pos == .right {
                HStack(spacing: 8) {
                    if pos == .left, showsValueLine { valueDisplay }
                    compactArea
                    if pos == .right, showsValueLine { valueDisplay }
                }
                .padding(.bottom, 8)  // the source's stray mb-2 on row layout
            } else {
                compactArea
            }
            if pos == .bottom, showsValueLine { valueDisplay }
        }
    }

    /// The relative flex-1 area that hosts the track. Its reserved height is
    /// THUMB_SIZE+16 for left/right, 20 for top/bottom and 36 with a 16px
    /// top pad for tooltips — the 36px track itself always overflows the
    /// reserved box symmetrically at the bottom (source: overflow-visible).
    private var compactArea: some View {
        ZStack(alignment: .topLeading) {
            compactTrack
                .padding(.top, pos == .tooltip ? 16 : 0)
            // Tooltip mode: a chip rides each thumb while interacting.
            if pos == .tooltip, showValue ?? true, interacting {
                compactTip(format(value0))
                    .position(x: px0 + Self.thumb / 2, y: -6)
                if isRange {
                    compactTip(format(value1))
                        .position(x: px1 + Self.thumb / 2, y: -6)
                }
            }
        }
        .frame(
            height: (pos == .left || pos == .right) ? 36 : (pos == .tooltip ? 36 : 20),
            alignment: .top
        )
        .frame(maxWidth: .infinity)
        // The hit area lives HERE, not on the overflowing track — a
        // contentShape on a parent can't gate a child's, but hit delivery
        // to a child outside the parent's bounds is unreliable, so the
        // area's region covers the track's real rect plus the -8px
        // margins (slider.tsx:1376-1383). For top/bottom/tooltip the 36px
        // track overflows the shorter area by 16px at the bottom.
        .contentShape(FluidSliderSlop(
            horizontal: 8,
            // Tooltip mode reserves the top 16px for the chip — the
            // source's hit div covers only the visual track, so the pad
            // stays dead (negative top shrinks the region).
            top: pos == .tooltip ? -16 : 0,
            bottom: (pos == .left || pos == .right) ? 0 : 16
        ))
        .onHover { h in
            guard !isDisabled else { return }
            hoverChanged(h)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !isDisabled, !dragging else { return }
            switch phase {
            case .active(let point): computeCPreview(at: point.x)
            case .ended: break
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { compactDragChanged($0.location.x) }
                .onEnded { _ in compactDragEnded() }
        )
    }

    /// The 36px track div: capsule bg (z0), step dots (z1), thumbs (z10),
    /// hover chip (z20). Measured — the px motion values key on this width.
    private var compactTrack: some View {
        ZStack(alignment: .leading) {
            capsuleBox
            if !dotPercents.isEmpty { stepDotsLayer }
            compactThumb(0)
            if isRange { compactThumb(1) }
            // Hover chip — top: -20 of this box → center ≈ -10.
            if pos != .tooltip, let p = preview, showTip, !pressed {
                compactTip(format(p.value))
                    .position(x: p.cursorX, y: -10)
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .opacity(ready ? 1 : 0)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { measure(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in measure(w) }
            }
        )
    }

    /// The rounded-full bordered capsule, TRACK_INSET in from each side so
    /// its cap centers land on the thumb centers at min/max. Hosts the fill
    /// and the hover preview (both inside the border, clipped).
    private var capsuleBox: some View {
        ZStack(alignment: .leading) {
            if hideFill != true {
                Rectangle()
                    .fill(scheme == .dark
                          ? FluidTone.accent.opacity(0.4)      // dark:bg-accent/40
                          : FluidTone.selected.opacity(0.5))   // bg-selected/50
                    .frame(width: max(0, cFillW))
                    .offset(x: cFillL)
            }
            if let p = preview, !pressed {
                // Rounded on the end toward the cursor (source borderRadius).
                UnevenRoundedRectangle(
                    topLeadingRadius: p.cursorX > p.left ? 0 : 999,
                    bottomLeadingRadius: p.cursorX > p.left ? 0 : 999,
                    bottomTrailingRadius: p.cursorX > p.left ? 999 : 0,
                    topTrailingRadius: p.cursorX > p.left ? 999 : 0,
                    style: .continuous
                )
                .fill(FluidTone.accent.opacity(0.4))
                .frame(width: max(0, p.width))
                .offset(x: p.left - Self.inset)  // track coords → capsule coords
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(FluidTone.border, lineWidth: 1))
        .frame(height: Self.trackH)
        .padding(.horizontal, Self.inset)
    }

    /// Fill in capsule coords: single → [0, thumbCenter - inset] = x + 9;
    /// range → [x0 + 9, x1 - x0] — thumb center to thumb center.
    private var cFillL: CGFloat { isRange ? px0 + Self.thumb / 2 - Self.inset : 0 }
    private var cFillW: CGFloat {
        isRange ? px1 - px0 : px0 + Self.thumb / 2 - Self.inset
    }

    /// Step dots — stepValues' percents or the uniform step grid — drawn
    /// when `showSteps`; 4px, growing ×1.25 on hover (spring.moderate).
    private var dotPercents: [Double] {
        guard showSteps == true, effMax != effMin else { return [] }
        if let sv = stepValues {
            return sv.map { ($0 - effMin) / (effMax - effMin) }
        }
        guard step > 0 else { return [] }
        let n = Int(((effMax - effMin) / step).rounded()) + 1
        return (0..<n).map { Double($0) * step / (effMax - effMin) }
    }

    private var stepDotsLayer: some View {
        // Dot centers ride the thumb centers: 10 + pct*(W - 20).
        Canvas { ctx, size in
            let s = Self.dot * dotScale
            for p in dotPercents {
                let x = Self.thumb / 2 + CGFloat(p) * (size.width - Self.thumb)
                ctx.fill(
                    Path(ellipseIn: CGRect(
                        x: (x - s / 2).rounded(),
                        y: (size.height / 2 - s / 2).rounded(),
                        width: s, height: s
                    )),
                    with: .color(FluidTone.mutedForeground.opacity(0.3))
                )
            }
        }
        .mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(LinearGradient(
                        stops: dotMaskStops(width: geo.size.width),
                        startPoint: .leading, endPoint: .trailing
                    ))
            }
        }
    }

    /// The stepDotsMask gradients — single hides dots under the fill
    /// (clear through the thumb edge +2), range clears between the thumbs.
    private func dotMaskStops(width w: CGFloat) -> [Gradient.Stop] {
        let d = max(w, 1)
        func f(_ x: CGFloat) -> CGFloat { max(0, min(1, x / d)) }
        if isRange {
            let l = px0 + Self.thumb / 2, r = px1 + Self.thumb / 2
            return [
                .init(color: .black, location: 0),
                .init(color: .black, location: f(l - 2)),
                .init(color: .clear, location: f(l)),
                .init(color: .clear, location: f(r)),
                .init(color: .black, location: f(r + 2)),
                .init(color: .black, location: 1),
            ]
        }
        let e = px0 + Self.thumb / 2
        return [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: f(e)),
            .init(color: .black, location: f(e + 2)),
            .init(color: .black, location: 1),
        ]
    }

    /// One visual thumb: a 20px focus/hit box holding the 16px core
    /// (white, 1px drop shadow, optional tint/border) and the 24px ring.
    private func compactThumb(_ i: Int) -> some View {
        ZStack {
            Circle()
                .fill(thumbColor ?? .white)
                .frame(width: Self.thumbRest, height: Self.thumbRest)
                .overlay {
                    if let bc = thumbBorderColor {
                        Circle().strokeBorder(bc, lineWidth: 1)
                            .frame(width: Self.thumbRest, height: Self.thumbRest)
                    }
                }
                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
            Circle()
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .frame(width: Self.thumb + 4, height: Self.thumb + 4)
                .opacity(ringVisible && focusedThumb == i ? 1 : 0)
                .animation(FluidSpring.fast, value: ringVisible && focusedThumb == i)
        }
        .frame(width: Self.thumb, height: Self.thumb)
        .offset(x: px(i))
        .focusable(!isDisabled)
        .focused($focusedThumb, equals: i)
        .focusEffectDisabled()
        .accessibilityElement()
        .accessibilityLabel(thumbLabel(i))
        .accessibilityValue(Text(format(val(i))))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: nudge(thumb: i, direction: 1, multiplier: 1)
            case .decrement: nudge(thumb: i, direction: -1, multiplier: 1)
            default: break
            }
        }
    }

    /// thumbAriaLabel — bare label for single, "Minimum"/"Maximum" (or
    /// "<label> minimum/maximum") for ranges.
    private func thumbLabel(_ i: Int) -> String {
        if !isRange { return label ?? "Slider" }
        if let label { return i == 0 ? "\(label) minimum" : "\(label) maximum" }
        return i == 0 ? "Minimum" : "Maximum"
    }

    private func compactTip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(FluidTone.background)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                    .fill(FluidTone.foreground)
            )
            .fixedSize()
            .transition(.opacity.combined(with: .offset(y: 4)))
    }

    // --- Compact pointer trio (down picks nearest thumb + animates in,
    //     move sets directly, up settles) ---

    private func compactDragChanged(_ x: CGFloat) {
        guard !isDisabled, trackW > 0 else { return }
        let clamped = (x - Self.thumb / 2).clamped(to: 0...usable)
        if !dragging {
            dragging = true
            pressed = true
            // Nearest thumb wins the drag; focus it without showing a ring
            // (Radix's focus({ focusVisible: false }) on slide start).
            activeThumb = isRange && abs(clamped - px1) < abs(clamped - px0) ? 1 : 0
            focusedThumb = activeThumb
            keyboard = false
            moveThumb(clamped, animated: true)
        } else {
            moveThumb(clamped, animated: false)
        }
    }

    private func moveThumb(_ px: CGFloat, animated: Bool) {
        let snapped = pxv(px)
        var final = vpx(snapped)
        // clampForRange — thumbs stay THUMB_SIZE*0.5 = 10px apart.
        if isRange {
            final = activeThumb == 0 ? min(final, px1 - 10) : max(final, px0 + 10)
        }
        if animated {
            withAnimation(FluidSpring.moderate) { setPx(activeThumb, final) }
        } else {
            setPx(activeThumb, final)
        }
        emit(activeThumb, pxv(final))
    }

    private func compactDragEnded() {
        guard dragging else { return }
        dragging = false
        pressed = false
        preview = nil
        // Settle to the quantized position (spring.moderate — pointerup).
        withAnimation(FluidSpring.moderate) {
            px0 = vpx(value0)
            if isRange { px1 = vpx(value1) }
        }
    }

    private func setPx(_ i: Int, _ v: CGFloat) { if i == 0 { px0 = v } else { px1 = v } }
    private func emit(_ i: Int, _ v: Double) { if i == 0 { value0 = v } else { value1 = v } }

    private func measure(_ w: CGFloat) {
        // The source marks ready even at width 0 (a zero-width slider
        // still unhides); the px sync itself does need real width, so it
        // retries until the track actually lays out (pxSynced).
        if !ready {
            trackW = w
            if w > 0 {
                // Initial sync — direct set, before paint (useLayoutEffect).
                px0 = vpx(value0)
                px1 = isRange ? vpx(value1) : 0
                pxSynced = true
            }
            ready = true
            return
        }
        if !pxSynced {
            guard w > 0 else { return }
            // trackW first — vpx derives usable = trackW - 20 from it.
            trackW = w
            px0 = vpx(value0)
            px1 = isRange ? vpx(value1) : 0
            pxSynced = true
            return
        }
        guard w != trackW, w > 0 else { return }
        trackW = w
        // ResizeObserver path — re-sync animated (spring.moderate).
        guard !dragging else { return }
        withAnimation(FluidSpring.moderate) {
            px0 = vpx(value0)
            if isRange { px1 = vpx(value1) }
        }
    }

    /// Compact hover preview — the snapped value under the cursor, the bar
    /// from the nearest thumb center to the snapped edge (extended to the
    /// track ends at the extremes).
    private func computeCPreview(at x: CGFloat) {
        guard trackW > 0, usable > 0 else { return }
        let rawPx = (x.clamped(to: 0...trackW) - Self.thumb / 2).clamped(to: 0...usable)
        let rawVal = Double(rawPx / usable) * (effMax - effMin) + effMin
        let snapped = snapValue(rawVal)
        let snappedX = Self.thumb / 2 + vpx(snapped)
        let c0 = px0 + Self.thumb / 2, c1 = px1 + Self.thumb / 2
        let nearest = isRange && abs(snappedX - c1) < abs(snappedX - c0) ? c1 : c0
        let edgeX = snapped == effMin ? 0 : snapped == effMax ? trackW : snappedX
        // Unanimated position write (see the comfortable lane) — the bar
        // must not chase the pointer on a 150ms tween.
        preview = Preview(left: min(nearest, edgeX), width: abs(edgeX - nearest),
                          value: snapped, cursorX: snappedX)
    }

    // MARK: - Value display (compact)

    private var valueDisplay: some View {
        ZStack(alignment: .leading) {
            // Ghost — reserves the widest possible line (label + max or
            // "max — max") so live values never shift the layout.
            Text(displayGhost).hidden().fixedSize()
            HStack(spacing: 0) {
                if let label, editing == nil {
                    Text("\(label): ").foregroundStyle(FluidTone.mutedForeground)
                }
                if isRange {
                    displayPart(0)
                    Text(" — ").foregroundStyle(FluidTone.mutedForeground.opacity(0.5))
                    displayPart(1)
                } else {
                    displayPart(0)
                }
            }
            .fixedSize()
        }
        .font(.system(size: 13))
        .fontWeight(interacting ? .medium : .regular)
        .monospacedDigit()
        .foregroundStyle(FluidTone.mutedForeground)
        .animation(.easeOut(duration: 0.1), value: interacting)
    }

    private var displayGhost: String {
        let l = label.map { "\($0): " } ?? ""
        return isRange ? "\(l)\(format(effMax)) — \(format(effMax))" : "\(l)\(format(effMax))"
    }

    /// One clickable value — swaps to an inline editor on tap
    /// (the source's click-to-edit number input, w-5ch).
    @ViewBuilder
    private func displayPart(_ i: Int) -> some View {
        if editing == i {
            HStack(spacing: 4) {
                if let label {
                    Text("\(label):").foregroundStyle(FluidTone.mutedForeground)
                }
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    // w-[5ch] ≈ 40pt at 13pt mono digits.
                    .frame(width: 40)
                    // border-b border-border (slider.tsx:217-221) — the
                    // input has no fill, so the shape.input radius is a
                    // no-op here and isn't applied.
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(FluidTone.border).frame(height: 1)
                    }
                    .focused($editFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
                    .onChange(of: editFocused) { _, f in if !f { commitEdit() } }
            }
        } else {
            Text(format(val(i)))
                .contentShape(Rectangle())
                .onTapGesture { startEdit(i) }
                .onHover { h in
                    // Balanced push/pop — the Text is destroyed when the
                    // editor mounts, so teardownHover + startEdit pop too.
                    // Disabled sliders show pointer-events-none — no iBeam.
                    guard h != iBeamHover, !(h && isDisabled) else { return }
                    iBeamHover = h
                    if h { NSCursor.iBeam.push() } else { NSCursor.pop() }
                }
        }
    }

    private func startEdit(_ i: Int) {
        guard !isDisabled else { return }
        if iBeamHover { iBeamHover = false; NSCursor.pop() }
        editing = i
        editText = Self.defaultFormat(val(i))
        editFocused = true
    }

    /// Commit parses, clamps to [min, max], snaps to the grid, emits —
    /// NaN or Escape just closes the editor.
    private func commitEdit() {
        guard let i = editing else { return }
        if let parsed = Self.parseLeadingDouble(editText) {
            emit(i, snapValue(min(max(effMin, parsed), effMax)))
        }
        editing = nil
        editFocused = false
    }

    private func cancelEdit() {
        editing = nil
        editFocused = false
    }

    /// parseFloat — the longest valid leading prefix, nil when none.
    private static func parseLeadingDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.withCString { ptr -> Double? in
            var end: UnsafeMutablePointer<CChar>?
            let v = strtod(ptr, &end)
            return end == UnsafeMutablePointer(mutating: ptr) ? nil : v
        }
    }

    // MARK: - Keyboard (the hidden Radix slider's key map)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // dragging/pressed drop keys like the source's handleRadixChange
        // early-return — pointer interaction owns the value mid-drag.
        guard !isDisabled, !dragging, !pressed,
              editing == nil, focusedThumb != nil else { return .ignored }
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow, .downArrow:                    // "from-left" back keys
            nudge(thumb: focusedThumb!, direction: -1, multiplier: shift ? 10 : 1)
        case .rightArrow, .upArrow:
            nudge(thumb: focusedThumb!, direction: 1, multiplier: shift ? 10 : 1)
        case .pageDown: nudge(thumb: focusedThumb!, direction: -1, multiplier: 10)
        case .pageUp:   nudge(thumb: focusedThumb!, direction: 1, multiplier: 10)
        case .home:     commitSorted(thumb: 0, value: effMin)
        case .end:      commitSorted(thumb: isRange ? 1 : 0, value: effMax)
        default: return .ignored
        }
        keyboard = true
        return .handled
    }

    /// Arrow-key step. In `steps` mode the Radix primitive runs on list
    /// indices, so arrows walk the list; otherwise getNextStepValue —
    /// aligned values move `direction*multiplier` steps, unaligned ones
    /// round to the next step in the direction.
    private func nudge(thumb i: Int, direction: Int, multiplier: Int) {
        // Gate here, not per caller — VoiceOver's adjustable action and
        // the keyboard map both route through this (Radix disabled thumbs
        // refuse interaction entirely).
        guard !isDisabled else { return }
        let cur = val(i)
        let next: Double
        if let sv = stepValues {
            let idx = (nearestStepIndex(cur, sv) + direction * multiplier)
                .clamped(to: 0...(sv.count - 1))
            next = sv[idx]
        } else {
            next = nextStepValue(cur, direction: direction, multiplier: multiplier)
        }
        commitSorted(thumb: i, value: next)
    }

    private func nextStepValue(_ v: Double, direction: Int, multiplier: Int) -> Double {
        let s = step > 0 ? step : 1
        let fromMin = (v - effMin) / s
        let nearest = fromMin.rounded()
        let next: Double
        if nearest * s + effMin == v {
            next = nearest + Double(direction * multiplier)
        } else {
            next = direction > 0 ? fromMin.rounded(.up) : fromMin.rounded(.down)
        }
        return min(max(next * s + effMin, effMin), effMax)
    }

    /// Radix's updateValues → getNextSortedValues: write the thumb's value,
    /// re-sort (keys can cross thumbs), focus follows the moved value.
    private func commitSorted(thumb i: Int, value v: Double) {
        guard !isDisabled else { return }
        var vs = isRange ? [value0, value1] : [value0]
        vs[i] = v
        vs.sort()
        value0 = vs[0]
        if isRange { value1 = vs[1] }
        focusedThumb = vs.firstIndex(of: v) ?? i
    }

    // MARK: - Shared hover + focus-visible modality

    private func hoverChanged(_ h: Bool) {
        let was = hovered
        withAnimation(.easeOut(duration: 0.08)) { hovered = h }
        if h {
            if !was { NSCursor.resizeLeftRight.push() }
            withAnimation(FluidSpring.moderate) { dotScale = 1.25 }
            tipTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !Task.isCancelled {
                    // Mounted with spring.fast opacity+y in the source —
                    // the write needs the animation or the transition
                    // never interpolates.
                    withAnimation(FluidSpring.fast) { showTip = true }
                }
            }
        } else {
            // A stray post-teardown hover(false) mustn't pop a cursor we
            // never pushed — the stack is app-wide.
            if was { NSCursor.pop() }
            withAnimation(FluidSpring.moderate) { dotScale = 1 }
            tipTask?.cancel()
            withAnimation(FluidSpring.fast) { showTip = false; preview = nil }
        }
    }

    /// The push/pop pair can unbalance if the view dies mid-hover (the
    /// cursor push survives teardown) — pop once on disappear, and drop
    /// any live preview/chip so a remount can't flash stale chrome.
    private func teardownHover() {
        if hovered {
            hovered = false
            NSCursor.pop()
        }
        if iBeamHover {
            iBeamHover = false
            NSCursor.pop()
        }
        tipTask?.cancel()
        preview = nil
        showTip = false
        pressed = false
        dragging = false
        editing = nil
        editFocused = false
        focusedThumb = nil
    }

    /// :focus-visible — a keyDown in this window means keyboard modality
    /// (Tab arrives with the ring), a mouse button clears it (click/drag
    /// focus shows none). Mirrors the sidebar menu's monitor pair.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak viewRef] event in
            if let w = event.window, w === viewRef?.view?.window { keyboard = false }
            return event
        } { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewRef] event in
            if let w = event.window, w === viewRef?.view?.window { keyboard = true }
            return event
        } { monitors.append(m) }
    }
}

private final class ViewRef { var view: NSView? }

/// Reports the hosting NSView so the modality monitors can scope to our window.
private struct WindowProbe: NSViewRepresentable {
    let ref: ViewRef
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { ref.view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { ref.view = nsView }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private func nearestStepIndex(_ v: Double, _ steps: [Double]) -> Int {
    var idx = 0
    for i in 1..<steps.count where abs(steps[i] - v) < abs(steps[idx] - v) { idx = i }
    return idx
}

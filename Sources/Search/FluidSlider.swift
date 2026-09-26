import SwiftUI

// Slider — the comfortable "pips" layout from slider.tsx: a 32px bordered
// box, a strip of 5px dots, an --active fill that covers them from the
// left, a 2px handle line, label left / tabular value right, and a hover
// preview (accent 40% bar + tooltip) showing where a click would land.
// Click or drag anywhere inside: the value snaps to the nearest pip.

struct FluidSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var label: String? = nil
    var format: (Double) -> String = { v in
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
    }
    var isDisabled = false

    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    @State private var pressed = false
    @State private var trackW: CGFloat = 0
    /// The snapped value under the cursor — the hover preview.
    @State private var preview: Preview? = nil
    @State private var showTip = false
    @State private var tipTask: Task<Void, Never>? = nil

    private struct Preview { let edgeX: CGFloat; let value: Double; let snappedX: CGFloat }

    private var pipCount: Int { Int((range.upperBound - range.lowerBound) / step) + 1 }
    private var pips: [Double] { (0..<pipCount).map { range.lowerBound + Double($0) * step } }
    private var fraction: CGFloat {
        range.upperBound == range.lowerBound
            ? 0 : CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
    /// The 8px nudge that keeps the handle line visible at value == min.
    private var zeroOffset: CGFloat { value == range.lowerBound ? 8 : 0 }

    /// fill edge = p*W + 20 - 20p - zo*2.5  (pipsFillWidthStyle)
    private var fillWidth: CGFloat {
        fraction * trackW + 20 - 20 * fraction - zeroOffset * 2.5
    }
    /// handle line left = p*W + 11 - 24p   (pipsHandleLineLeftStyle)
    private var handleX: CGFloat { fraction * trackW + 11 - 24 * fraction }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .leading) {
                track
                if let p = preview, !pressed {
                    // Hover preview bar: from the fill edge to the snapped edge.
                    Rectangle()
                        .fill(FluidTone.accent.opacity(0.4))
                        .frame(width: abs(p.edgeX - handleX))
                        .offset(x: min(handleX, p.edgeX))
                        .transition(.opacity)
                }
            }
            .frame(height: 32)
            .clipShape(RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                    .strokeBorder(FluidTone.border, lineWidth: 1)
            )
            if let p = preview, showTip, !pressed {
                // The tooltip lives outside the clipped box, -30px up.
                Text(format(p.value))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(FluidTone.background)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                            .fill(FluidTone.foreground)
                    )
                    .fixedSize()
                    .position(x: p.snappedX, y: -18)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(height: 32)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { trackW = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in trackW = w }
            }
        )
        .opacity(isDisabled ? 0.5 : 1)
        .onHover { h in
            guard !isDisabled else { return }
            withAnimation(.easeOut(duration: 0.08)) { hovered = h }
            if h {
                NSCursor.resizeLeftRight.push()
                tipTask = Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if !Task.isCancelled { showTip = true }
                }
            } else {
                NSCursor.pop()
                tipTask?.cancel()
                withAnimation(FluidSpring.fast) { showTip = false; preview = nil }
            }
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
                    pressed = true
                    let v = snap(x: g.location.x)
                    if v != value { value = v }
                }
                .onEnded { _ in
                    pressed = false
                    preview = nil
                }
        )
    }

    /// Everything inside the box: pips, occluders, fill, handle, text.
    private var track: some View {
        ZStack(alignment: .leading) {
            // z1 — the dot strip, masked open right of the fill edge.
            pipsLayer
            // z2 — opaque pads under the texts so no pip shows through.
            occluders
            // z3 — the fill.
            Rectangle()
                .fill(FluidTone.active)
                .frame(width: max(0, fillWidth))
                .animation(FluidSpring.fast, value: fillWidth)
            // z3 — the handle line, 2px, grows 1px top/bottom while active.
            RoundedRectangle(cornerRadius: 1)
                .fill(handleColor)
                .frame(width: 2)
                .padding(.vertical, hovered || pressed ? 7 : 8)
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
                Text(format(value))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 8)
            .animation(FluidSpring.fast, value: textColor)
        }
    }

    private var pipsLayer: some View {
        HStack(spacing: 0) {
            ForEach(pips, id: \.self) { pip in
                Circle()
                    .fill(pip == value ? FluidTone.foreground : FluidTone.mutedForeground)
                    .opacity(pip == value ? 1 : 0.3)
                    .frame(width: 5, height: 5)
                if pip != pips.last { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 12)
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
            }
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
            Text(format(value)).font(.system(size: 13)).hidden()
                .padding(.horizontal, 8)
                .background(FluidTone.background)
        }
        .padding(.horizontal, 8)
    }

    private var textColor: Color {
        hovered || pressed ? FluidTone.foreground : FluidTone.mutedForeground
    }

    private var handleColor: Color {
        hovered || pressed ? FluidTone.foreground.opacity(0.5) : FluidTone.foreground.opacity(0.25)
    }

    private func snap(x: CGFloat) -> Double {
        guard pipCount > 1, trackW > 0 else { return range.lowerBound }
        let clamped = max(0, min(trackW, x))
        let i = Int((clamped / trackW) * CGFloat(pipCount - 1)).clamped(to: 0...(pipCount - 1))
        return pips[i]
    }

    private func computePreview(at x: CGFloat) {
        guard trackW > 0 else { return }
        let v = snap(x: x)
        let snappedX = CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) * trackW
        let edgeX = v == range.lowerBound ? 0 : v == range.upperBound ? trackW : snappedX
        withAnimation(.easeOut(duration: 0.15)) {
            preview = Preview(edgeX: edgeX, value: v, snappedX: snappedX)
        }
    }

}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

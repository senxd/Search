import AppKit
import SwiftUI

// ThinkingIndicator — fluid-demo/components/ui/thinking-indicator.tsx.
// A 20pt glyph morphing circle ⇄ lemniscate beside a shimmer word that
// cycles every 4s. The glyph follows the source's five-keyframe path —
// circleA → infinity → circleB → infinity → circleA over 6s — where the
// circle is drawn with opposite windings so the figure-8 forms and
// collapses on alternating sides (the source's rotating read). The word
// swaps with a y-80% rise / -80% fall, and the invisible widest word
// reserves the row's width.

private let thinkingWords = ["Thinking", "Moonwalking", "Planning", "Refining"]

struct FluidThinkingIndicator: View {
    var showIcon = true
    /// `size` pins the indicator to one ladder step; omitted, it follows
    /// the surrounding fluidSize.
    var size: FluidSize? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fluidSize) private var ambientSize
    @State private var word = 0
    @State private var wordTask: Task<Void, Never>? = nil

    private var resolvedSize: FluidSize { size ?? ambientSize }
    private var compact: Bool { resolvedSize == .compact }

    var body: some View {
        HStack(spacing: 8) {
            if showIcon {
                // The morph ticks at display rate — it lives in its own
                // subview so a frame update can't invalidate the word text
                // beside it (a shared body would re-rasterize the string
                // every commit).
                FluidMorphGlyph()
                    .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
            }
            ZStack(alignment: .leading) {
                Text("Moonwalking").opacity(0)
                Text(thinkingWords[word])
                    .id(word)
                    .transition(.asymmetric(
                        insertion: .offset(y: compact ? 10 : 13.6)
                            .combined(with: .opacity)
                            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.24)),
                        removal: .offset(y: compact ? -10 : -13.6)
                            .combined(with: .opacity)
                            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16))
                    ))
            }
            // VoiceOver reads the static label once — announcing every
            // 4s word swap would spam the user (the words are decorative).
            .accessibilityHidden(true)
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(shimmerBase)
            // The #525252 sweep — masked band overlay, so the word's glyph
            // raster is drawn once and only the band moves (background-clip:
            // text). foregroundStyle(gradient) re-drew it every frame.
            .fluidShimmerSweep(
                Color(red: 0x52/255, green: 0x52/255, blue: 0x52/255),
                active: true
            )
            .clipped()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .environment(\.fluidSize, resolvedSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking…")
        .onAppear {
            // role="status" — mounting announces the label like the
            // source's sr-only live region (thinking-indicator.tsx).
            if let win = NSApp.keyWindow ?? NSApp.mainWindow {
                NSAccessibility.post(
                    element: win, notification: .announcementRequested,
                    userInfo: [.announcement: "Thinking…" as NSString,
                               .priority: NSAccessibilityPriorityLevel.medium.rawValue as NSNumber]
                )
            }
            guard !reduceMotion, !FluidPerf.quiet else { return }
            wordTask = Task { @MainActor in
                while true {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation { word = (word + 1) % thinkingWords.count }
                }
            }
        }
        .onDisappear { wordTask?.cancel() }
    }

    /// The shimmer base — #a3a3a3 verbatim. The CSS uses literal hexes in
    /// both schemes — so does this. The #525252 sweep itself rides in the
    /// masked overlay band (`fluidShimmerSweep`).
    private var shimmerBase: Color {
        Color(red: 0xA3/255, green: 0xA3/255, blue: 0xA3/255)
    }
}

/// The indicator's morphing icon — a CAShapeLayer running the five-keyframe
/// morph as a path keyframe animation, so the 6s cycle renders entirely on
/// the render server with no per-frame view work.
private struct FluidMorphGlyph: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> FluidMorphView {
        FluidMorphView(animated: !reduceMotion && !FluidPerf.quiet)
    }

    func updateNSView(_ view: FluidMorphView, context: Context) {}
}

/// Hosts the morph layer — samples the eased keyframe blend into 96 CGPaths
/// (identical topology, so CA interpolates between them) and repeats the 6s
/// cycle forever.
final class FluidMorphView: NSView {
    private let animated: Bool
    private let shape = CAShapeLayer()
    private var armed = false

    init(animated: Bool) {
        self.animated = animated
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineCap = .round
        shape.lineJoin = .round
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let rect = CGRect(origin: .zero, size: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = rect
        shape.lineWidth = 1.5
        shape.strokeColor = NSColor(FluidTone.mutedForeground).cgColor
        shape.path = MorphGlyph.path(t: animated ? 0 : 1, in: rect)
        CATransaction.commit()
        if animated, !armed, bounds.width > 0 {
            armed = true
            let morph = CAKeyframeAnimation(keyPath: "path")
            morph.values = (0..<96).map { MorphGlyph.path(t: CGFloat($0) / 24, in: rect) }
            morph.duration = 6
            morph.repeatCount = .infinity
            shape.add(morph, forKey: "morph")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shape.strokeColor = NSColor(FluidTone.mutedForeground).cgColor
    }
}

/// The five keyframes from thinking-indicator.tsx as cubic-segment point
/// lists (move point, then c1/c2/end triples), lerped pairwise. circleB is
/// circleA reparameterized (wound the other way from the bottom) so the
/// lemniscate collapses through alternating rotations.
private enum MorphGlyph {

    /// [start, c1a, c2a, endA, c1b, c2b, endB, ...] — 13 points, 4 cubics.
    private static let circleA: [CGPoint] = [
        CGPoint(x: 12, y: 8),
        CGPoint(x: 14.21, y: 8), CGPoint(x: 16, y: 9.79), CGPoint(x: 16, y: 12),
        CGPoint(x: 16, y: 14.21), CGPoint(x: 14.21, y: 16), CGPoint(x: 12, y: 16),
        CGPoint(x: 9.79, y: 16), CGPoint(x: 8, y: 14.21), CGPoint(x: 8, y: 12),
        CGPoint(x: 8, y: 9.79), CGPoint(x: 9.79, y: 8), CGPoint(x: 12, y: 8),
    ]
    private static let infinity: [CGPoint] = [
        CGPoint(x: 12, y: 12),
        CGPoint(x: 14, y: 8.5), CGPoint(x: 19, y: 8.5), CGPoint(x: 19, y: 12),
        CGPoint(x: 19, y: 15.5), CGPoint(x: 14, y: 15.5), CGPoint(x: 12, y: 12),
        CGPoint(x: 10, y: 8.5), CGPoint(x: 5, y: 8.5), CGPoint(x: 5, y: 12),
        CGPoint(x: 5, y: 15.5), CGPoint(x: 10, y: 15.5), CGPoint(x: 12, y: 12),
    ]
    private static let circleB: [CGPoint] = [
        CGPoint(x: 12, y: 16),
        CGPoint(x: 14.21, y: 16), CGPoint(x: 16, y: 14.21), CGPoint(x: 16, y: 12),
        CGPoint(x: 16, y: 9.79), CGPoint(x: 14.21, y: 8), CGPoint(x: 12, y: 8),
        CGPoint(x: 9.79, y: 8), CGPoint(x: 8, y: 9.79), CGPoint(x: 8, y: 12),
        CGPoint(x: 8, y: 14.21), CGPoint(x: 9.79, y: 16), CGPoint(x: 12, y: 16),
    ]
    private static let keyframes: [[CGPoint]] = [circleA, infinity, circleB, infinity, circleA]

    /// t: 0...4 — the keyframe index + eased local progress.
    static func path(t: CGFloat, in rect: CGRect) -> CGPath {
        let k = min(max(Int(t), 0), 3)
        // easeInOut between keyframes — framer applies the ease per segment.
        let local = t - CGFloat(k)
        let eased = 0.5 - 0.5 * cos(.pi * local)
        let a = keyframes[k], b = keyframes[k + 1]
        func at(_ i: Int) -> CGPoint {
            CGPoint(x: (a[i].x + (b[i].x - a[i].x) * eased) / 24 * rect.width + rect.minX,
                    y: (a[i].y + (b[i].y - a[i].y) * eased) / 24 * rect.height + rect.minY)
        }
        let p = CGMutablePath()
        p.move(to: at(0))
        for s in 0..<4 {
            p.addCurve(to: at(s * 3 + 3), control1: at(s * 3 + 1), control2: at(s * 3 + 2))
        }
        p.closeSubpath()
        return p
    }
}

import SwiftUI

enum AskMotion {
    static let arrive = Animation.spring(duration: 0.42, bounce: 0.08)
    static let pop = Animation.spring(duration: 0.3, bounce: 0.15)
    static let drop = Animation.spring(duration: 0.36, bounce: 0.06)

    static func still(_ reduceMotion: Bool) -> Bool { reduceMotion || FluidPerf.quiet }
}

@MainActor
enum AskArrivals {
    private static var seen: Set<String> = []

    static func first(_ key: String) -> Bool { seen.insert(key).inserted }
}

private struct AskArrive: ViewModifier {
    let delay: Double
    let rise: CGFloat
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(key: String, delay: Double, rise: CGFloat) {
        self.delay = delay
        self.rise = rise
        _shown = State(initialValue: !AskArrivals.first(key))
    }

    func body(content: Content) -> some View {
        let calm = shown || AskMotion.still(reduceMotion)
        content
            .opacity(shown ? 1 : 0)
            .offset(y: calm ? 0 : rise)
            .onAppear {
                guard !shown else { return }
                withAnimation(AskMotion.arrive.delay(delay)) { shown = true }
            }
    }
}

private struct AskStagger: ViewModifier {
    let index: Int
    let step: Double
    let rise: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let calm = shown || AskMotion.still(reduceMotion)
        content
            .opacity(shown ? 1 : 0)
            .offset(y: calm ? 0 : rise)
            .onAppear {
                withAnimation(AskMotion.arrive.delay(Double(min(index, 12)) * step)) { shown = true }
            }
    }
}

extension View {
    func askArrive(_ key: String, anchor: UnitPoint = .bottom, delay: Double = 0, rise: CGFloat = 6) -> some View {
        modifier(AskArrive(key: key, delay: delay, rise: min(rise, 6)))
    }

    func askStagger(_ index: Int, step: Double = 0.03, rise: CGFloat = 4) -> some View {
        modifier(AskStagger(index: index, step: step, rise: min(rise, 6)))
    }
}

struct AskSpinner: View {
    var size: CGFloat = 10
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.ink.opacity(0.12), lineWidth: max(1.2, size / 7.5))
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(Palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: max(1.2, size / 7.5), lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !AskMotion.still(reduceMotion) else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityHidden(true)
    }
}

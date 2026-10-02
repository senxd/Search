import SwiftUI

@MainActor
final class AskVoice: ObservableObject {
    enum State: Equatable { case idle, live, processing }

    @Published private(set) var state: State = .idle
    private(set) var began = Date()
    private var work: DispatchWorkItem?

    private static let heard = [
        "Summarize this page in three bullet points",
        "What are the main takeaways here?",
        "Find the pricing on this site and compare the plans",
        "Open the docs and look for the getting started guide",
        "Which of my open tabs mention this topic?",
    ]

    func toggle(into draft: Binding<String>) {
        switch state {
        case .idle: listen(into: draft)
        case .live: finish(into: draft)
        case .processing: cancel()
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        withAnimation(AskMotion.drop) { state = .idle }
    }

    private func listen(into draft: Binding<String>) {
        began = Date()
        withAnimation(AskMotion.drop) { state = .live }
        schedule(after: 7) { [weak self] in self?.finish(into: draft) }
    }

    private func finish(into draft: Binding<String>) {
        guard state == .live else { return }
        withAnimation(AskMotion.drop) { state = .processing }
        schedule(after: 1.1) { [weak self] in
            guard let self, self.state == .processing else { return }
            let words = Self.heard.randomElement() ?? ""
            let now = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.wrappedValue = now.isEmpty ? words : now + " " + words
            withAnimation(AskMotion.drop) { self.state = .idle }
        }
    }

    private func schedule(after delay: TimeInterval, _ act: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: act)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

struct VoiceBeam: View {
    @ObservedObject var voice: AskVoice
    var strength: Double = 1
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lobes: [(x: Double, width: Double, weight: Double, phase: Double)] = [
        (0.18, 0.34, 0.55, 0.0),
        (0.36, 0.30, 0.8, 1.7),
        (0.5, 0.42, 1.0, 3.1),
        (0.64, 0.30, 0.8, 4.4),
        (0.82, 0.34, 0.55, 5.6),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: voice.state == .idle)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(voice.began)
                context.addFilter(.blur(radius: size.height * 0.28))
                let ink = scheme == .dark ? Color.white : Color.black
                switch voice.state {
                case .idle:
                    break
                case .live:
                    let level = Self.level(at: t)
                    for lobe in Self.lobes {
                        let sway = reduceMotion ? 0 : sin(t * 2.3 + lobe.phase) * 0.018
                        let pulse = 0.55 + 0.45 * sin(t * 5.1 + lobe.phase * 1.3)
                        let reach = size.height * (0.35 + 1.1 * level * lobe.weight * pulse)
                        let width = size.width * lobe.width
                        let rect = CGRect(
                            x: size.width * (lobe.x + sway) - width / 2,
                            y: size.height - reach * 0.55,
                            width: width,
                            height: reach
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(ink.opacity((scheme == .dark ? 0.22 : 0.13) * strength)))
                    }
                case .processing:
                    let sweep = reduceMotion ? 0.5 : 0.5 + 0.38 * sin(t * 3.2)
                    let width = size.width * 0.34
                    let rect = CGRect(
                        x: size.width * sweep - width / 2,
                        y: size.height * 0.45,
                        width: width,
                        height: size.height * 0.9
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(ink.opacity((scheme == .dark ? 0.26 : 0.15) * strength)))
                }
            }
        }
        .opacity(voice.state == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: voice.state)
        .accessibilityHidden(true)
    }

    private static func level(at t: Double) -> Double {
        let syllable = max(0, sin(t * 6.7) * sin(t * 2.9 + 0.8))
        let breath = 0.5 + 0.5 * sin(t * 0.9)
        let grain = 0.15 * sin(t * 17.3) * sin(t * 11.1)
        return min(1, max(0.08, 0.2 + 0.6 * syllable * breath + grain))
    }
}

struct AskMicButton: View {
    @ObservedObject var voice: AskVoice
    let draft: Binding<String>
    var dim: CGFloat = 30
    @State private var hovering = false

    var body: some View {
        Button { voice.toggle(into: draft) } label: {
            ZStack {
                switch voice.state {
                case .idle:
                    Image(systemName: "mic")
                        .font(.system(size: dim * 0.4, weight: .regular))
                        .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                case .live:
                    Image(systemName: "waveform")
                        .font(.system(size: dim * 0.4, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                case .processing:
                    AskSpinner(size: dim * 0.38)
                        .transition(.opacity)
                }
            }
            .frame(width: dim, height: dim)
            .background(Circle().fill(voice.state == .idle ? (hovering ? FluidTone.hover : .clear) : FluidTone.active))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(AskMotion.pop, value: voice.state)
        .help(voice.state == .live ? "Stop dictating" : voice.state == .processing ? "Cancel" : "Dictate")
        .accessibilityLabel(voice.state == .live ? "Stop dictating" : "Dictate")
    }
}

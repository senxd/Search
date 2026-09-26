import SwiftUI

// Tabs — the segmented control from tabs.tsx. A muted track (segmentPad +
// segmentItem add up to the ladder height), a surface-4 indicator that
// springs with the moderate tier, and the hover fill that always enters
// from wherever the selected pill sits.

struct FluidTabs: View {
    let items: [String]
    @Binding var selection: Int
    var size: FluidSize = .default
    /// The substrate the tabs sit on — the indicator lifts 3 levels above
    /// it (1 above the muted track + 2 for pop), capped at 8.
    var substrate: Int = 1

    @State private var hover = FluidHover(axis: .x)
    @State private var rects: [Int: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let space = "fluid-tabs-\(UUID().uuidString)"

    private var indicatorLevel: Int { min(substrate + 3, 8) }
    private var selectedRect: CGRect? { rects[selection] }
    private var hoverRect: CGRect? {
        guard let i = hover.activeIndex, i != selection else { return nil }
        return rects[i]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, label in
                tab(label, index: i)
            }
        }
        .padding(size.segmentPad)
        .background(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .fill(FluidTone.muted)
        )
        .coordinateSpace(name: space)
        .background(alignment: .topLeading) { overlays }
        .onPreferenceChange(FluidItemRectsKey.self) { rects = $0 }
        .onContinuousHover(coordinateSpace: .named(space)) { phase in
            switch phase {
            case .active(let point): hover.moved(to: point)
            case .ended: hover.exited()
            }
        }
        .environment(\.fluidHover, hover)
    }

    @ViewBuilder
    private var overlays: some View {
        // Selected pill — the surface card that travels under the labels.
        if let r = selectedRect {
            TabPill(rect: r, level: indicatorLevel, radius: FluidShape.rounded.bg)
                .opacity(hoverRect != nil ? 0.85 : 1)
                .animation(FluidSpring.moderate, value: r)
                .animation(.easeOut(duration: 0.08), value: hoverRect != nil)
        }
        // Hover fill — enters from the selected rect, exits with the fade.
        if let h = hoverRect, let s = selectedRect {
            TabFill(rect: h, from: s, radius: FluidShape.rounded.bg)
                .id(hover.session)
                .transition(.opacity)
        }
    }

    private func tab(_ label: String, index: Int) -> some View {
        let active = hover.activeIndex == index || selection == index
        return Button {
            withAnimation(FluidSpring.moderate) { selection = index }
        } label: {
            Text(label)
                .font(.system(
                    size: size.text,
                    weight: selection == index ? .semibold : .regular
                ))
                .foregroundStyle(active ? FluidTone.foreground : FluidTone.mutedForeground)
                .padding(.horizontal, 12)
                .frame(height: size.segmentItem)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: FluidItemRectsKey.self,
                    value: [index: geo.frame(in: .named(space))]
                )
            }
        )
    }

    /// The selected surface — bg + ring/shadow recipe, springs with the
    /// moderate tier as `rect` changes.
    private struct TabPill: View {
        @Environment(\.colorScheme) private var scheme
        let rect: CGRect
        let level: Int
        let radius: CGFloat

        var body: some View {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(FluidTone.surface(level))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            scheme == .dark ? .white.opacity(0.04) : .black.opacity(0.06),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.06), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.06), radius: 3, y: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    /// The traveling hover fill: mounts at `from` and springs to `rect` —
    /// the same entry the FluidHighlight performs, at 40% opacity.
    private struct TabFill: View {
        let rect: CGRect
        let from: CGRect
        let radius: CGFloat
        @State private var current: CGRect
        @State private var opacity = 0.0

        init(rect: CGRect, from: CGRect, radius: CGFloat) {
            self.rect = rect; self.from = from; self.radius = radius
            _current = State(initialValue: from)
        }

        var body: some View {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(FluidTone.hover)
                .frame(width: current.width, height: current.height)
                .position(x: current.midX, y: current.midY)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.08)) { opacity = 0.4 }
                    withAnimation(FluidSpring.fast) { current = rect }
                }
                .onChange(of: rect) { _, new in
                    withAnimation(FluidSpring.fast) { current = new }
                }
        }
    }
}

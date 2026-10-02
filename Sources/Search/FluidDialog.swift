import AppKit
import SwiftUI

// Dialog — fluid-demo/components/ui/dialog.tsx.
// Overlay dims to black/40 (dark /80); the panel enters at scale 0.97 +
// fade on spring.slow, exits on the 160ms tween. Surface sits 4 levels
// above the substrate (DIALOG_OFFSET). Sizes: sm 400 / lg 540 / xl 880.

enum FluidDialogSize {
    case sm, lg, xl

    func width(_ compact: Bool) -> CGFloat {
        switch self {
        case .sm: return compact ? 360 : 400
        case .lg: return compact ? 480 : 540
        case .xl: return compact ? 800 : 880
        }
    }
}

enum FluidDialogPosition { case center, top }

/// How a `.top` panel anchors vertically. The base rule is the source's
/// flat `top-[12dvh]` (dialog.tsx:169); the command palette overrides it
/// so the top edge sits where a cap-height panel would be centered —
/// `top-[max(12dvh,calc(50dvh-220px))]` (command-menu.tsx:1528-1534).
enum FluidDialogTopStyle {
    /// Flat 12dvh — the base dialog rule.
    case flat
    /// max(12dvh, 50dvh − cap/2) — the panel's maxHeight stands in for
    /// the source's hardcoded 440px cap (220px is its half).
    case palette
}

extension View {
    /// Presents a fluid dialog over this view — the in-window equivalent of
    /// the portal. `content` is the panel's interior (header, body, footer).
    func fluidDialog<Panel: View>(
        isPresented: Binding<Bool>,
        size: FluidDialogSize = .sm,
        position: FluidDialogPosition = .center,
        /// Only read while `position == .top` — the className override the
        /// command palette passes (flat 12dvh otherwise).
        topStyle: FluidDialogTopStyle = .flat,
        showCloseButton: Bool = true,
        /// Source `className` override — the command palette passes 0
        /// (`p-0`, command-menu.tsx:1534).
        panelPadding: CGFloat = 24,
        /// Panel height cap in points; combined with the source's 76dvh
        /// window cap (`max-h-[min(440px,76dvh)]`). Nil → uncapped.
        maxHeight: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Panel
    ) -> some View {
        modifier(FluidDialogHost(
            isPresented: isPresented, size: size, position: position,
            topStyle: topStyle, showCloseButton: showCloseButton,
            panelPadding: panelPadding, maxHeight: maxHeight, panel: content
        ))
    }
}

private struct FluidDialogHost<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let size: FluidDialogSize
    let position: FluidDialogPosition
    let topStyle: FluidDialogTopStyle
    let showCloseButton: Bool
    let panelPadding: CGFloat
    let maxHeight: CGFloat?
    @ViewBuilder var panel: () -> Panel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var fluidSize
    /// mounted = the overlay subtree exists; presented = the visual state
    /// bound to scale/opacity/scrim. Framer mounts at initial={} then
    /// animates — the visual flag must flip one runloop tick after the
    /// subtree exists or the enter transition has nothing to run from
    /// (dialog.tsx:159-186, motion initial→animate on mount).
    @State private var mounted = false
    @State private var presented = false
    @State private var escMonitor: Any?
    /// Reports the dialog's owning window so the Esc monitor stays scoped
    /// to it (modal semantics: consume Esc only in our window).
    private let windowProbe = FluidMenuPanelProbeBox()

    private var enter: Animation { FluidSpring.slow }
    private var exit: Animation { .easeOut(duration: 0.16) }

    /// The `.top` panel's top offset — flat 12dvh (dialog.tsx:169), or the
    /// palette's `max(12dvh, 50dvh − cap/2)`: the top edge a cap-height
    /// panel would keep if centered, so the field stays put while the
    /// rows under it filter down (command-menu.tsx:1528-1534).
    private func topPadding(_ h: CGFloat) -> CGFloat {
        guard position == .top else { return 0 }
        switch topStyle {
        case .flat: return h * 0.12
        case .palette: return max(h * 0.12, h * 0.5 - (maxHeight ?? 440) / 2)
        }
    }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                if mounted {
                    ZStack(alignment: position == .top ? .top : .center) {
                        Color.black
                            .opacity(presented ? (scheme == .dark ? 0.8 : 0.4) : 0)
                            .onTapGesture { isPresented = false }
                            .animation(presented ? enter : exit, value: presented)

                        panel()
                            // The cap reaches menu content too — a
                            // FluidCommandMenu inside reads it through
                            // the env so its column can't spill past
                            // the capped panel (max-h-[inherit]).
                            .environment(\.fluidCommandMenuMaxHeight,
                                         maxHeight.map {
                                             max(0, min($0, geo.size.height * 0.76)
                                                        - panelPadding * 2)
                                         })
                            .padding(panelPadding)
                            .frame(maxWidth: size.width(fluidSize == .compact),
                                   maxHeight: maxHeight.map {
                                       min($0, geo.size.height * 0.76)
                                   })
                            .fluidSurface(5, radius: shape.container)
                            .overlay(alignment: .topTrailing) {
                                if showCloseButton {
                                    FluidDialogCloseButton { isPresented = false }
                                        .padding(12)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, topPadding(geo.size.height))
                            .scaleEffect(presented ? 1 : 0.97)
                            .opacity(presented ? 1 : 0)
                            .animation(presented ? enter : exit, value: presented)
                    }
                    // Reports the window the overlay lives in — the Esc
                    // monitor's modal scope.
                    .background(
                        FluidDialogWindowProbe(box: windowProbe)
                            .frame(width: 0, height: 0)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: isPresented, initial: true) { _, open in
            if open {
                mounted = true
                // The hidden pose must be committed to the render tree
                // first — flip the visual state one runloop tick later,
                // like the source's mounted → motion animate hand-off.
                DispatchQueue.main.async {
                    if isPresented { presented = true }
                }
                // onExitCommand needs a focused responder — a bare overlay
                // often has none, so Escape is intercepted globally. But
                // scoped: modal semantics end at our window — consuming
                // Esc app-wide would eat other windows' dismissal.
                let probe = windowProbe
                escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    guard e.keyCode == 53,
                          let w = probe.view?.window, e.window === w
                    else { return e }
                    isPresented = false
                    return nil
                }
                return
            }
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
            // Exit runs on the visual flag; the subtree unmounts after
            // the exit tween lands (spring.slow.exit is a 160ms linear,
            // + 100ms buffer per exitFallbackMs).
            presented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                if !isPresented {
                    mounted = false
                    presented = false
                }
            }
        }
        .onExitCommand { isPresented = false }
        .onDisappear {
            // The modifier can drop while presented (cell unmounts) —
            // an orphaned monitor would keep eating this window's Esc.
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
    }
}

/// Reports the hosting NSView so the dialog can scope its Esc monitor to
/// the owning window (reuses the popup panel's probe box).
private struct FluidDialogWindowProbe: NSViewRepresentable {
    let box: FluidMenuPanelProbeBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { box.view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

private struct FluidDialogCloseButton: View {
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13))
                .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: FluidShape.rounded.button, style: .continuous)
                        .fill(hovered ? FluidTone.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: FluidShape.rounded.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(FluidSpring.fast, value: hovered)
    }
}

// MARK: - Parts

/// flex-col gap-1.5 mb-4.
struct FluidDialogHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.bottom, 16)
    }
}

/// The title role of the type scale — 16px, weight 700.
struct FluidDialogTitle: View {
    let text: String
    @Environment(\.fluidSize) private var size
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: size == .compact ? 15 : 16, weight: .bold))
            .foregroundStyle(FluidTone.foreground)
    }
}

struct FluidDialogDescription: View {
    let text: String
    @Environment(\.fluidSize) private var size
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: size == .compact ? 12 : 13))
            .foregroundStyle(FluidTone.mutedForeground)
    }
}

/// justify-end gap-2 mt-6.
struct FluidDialogFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 24)
    }
}

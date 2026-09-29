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

extension View {
    /// Presents a fluid dialog over this view — the in-window equivalent of
    /// the portal. `content` is the panel's interior (header, body, footer).
    func fluidDialog<Panel: View>(
        isPresented: Binding<Bool>,
        size: FluidDialogSize = .sm,
        position: FluidDialogPosition = .center,
        showCloseButton: Bool = true,
        @ViewBuilder content: @escaping () -> Panel
    ) -> some View {
        modifier(FluidDialogHost(
            isPresented: isPresented, size: size, position: position,
            showCloseButton: showCloseButton, panel: content
        ))
    }
}

private struct FluidDialogHost<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let size: FluidDialogSize
    let position: FluidDialogPosition
    let showCloseButton: Bool
    @ViewBuilder var panel: () -> Panel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var fluidSize
    @State private var mounted = false
    @State private var escMonitor: Any?

    private var enter: Animation { FluidSpring.slow }
    private var exit: Animation { .easeOut(duration: 0.16) }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                if mounted {
                    ZStack(alignment: position == .top ? .top : .center) {
                        Color.black
                            .opacity(isPresented ? (scheme == .dark ? 0.8 : 0.4) : 0)
                            .onTapGesture { isPresented = false }
                            .animation(isPresented ? enter : exit, value: isPresented)

                        panel()
                            .padding(24)
                            .frame(maxWidth: size.width(fluidSize == .compact))
                            .fluidSurface(5, radius: shape.container)
                            .overlay(alignment: .topTrailing) {
                                if showCloseButton {
                                    FluidDialogCloseButton { isPresented = false }
                                        .padding(12)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, position == .top ? geo.size.height * 0.12 : 0)
                            .scaleEffect(isPresented ? 1 : 0.97)
                            .opacity(isPresented ? 1 : 0)
                            .animation(isPresented ? enter : exit, value: isPresented)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: isPresented) { _, open in
            if open {
                mounted = true
                // onExitCommand needs a focused responder — a bare overlay
                // often has none, so Escape must be intercepted globally.
                escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    if e.keyCode == 53 { isPresented = false; return nil }
                    return e
                }
                return
            }
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
            // Deferred unmount — outlives the exit tween (spring.slow.exit
            // is a 160ms linear, + 100ms buffer per exitFallbackMs).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                if !isPresented { mounted = false }
            }
        }
        .onExitCommand { isPresented = false }
    }
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

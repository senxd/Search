import AppKit
import SwiftUI

// Tooltip — tooltip.tsx. An inverted pill (bg-foreground / text-
// background), 12px medium, px-2 py-1, shape.bg radius, sideOffset 8.
// Opens after a 200ms hover delay; a tooltip closing arms a 300ms
// skip-delay window so sweeping across adjacent triggers shows theirs
// instantly (Radix's Provider skipDelayDuration).

private enum FluidTooltipClock {
    static var lastDismiss: Date = .distantPast
}

enum FluidFollowAxis { case x, y }

private struct FluidTooltipModifier: ViewModifier {
    let text: String
    var side: FluidPopupController.Edge = .top
    var delay: TimeInterval = 0.2
    /// Axis the panel centers on the pointer (React's followCursor: "x"|"y").
    var followCursor: FluidFollowAxis? = nil

    @State private var controller = FluidPopupController()
    @State private var delayTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(FluidAnchorResolver(controller: controller))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if followCursor != nil { follow(point) }
                    guard !controller.isPresented, delayTask == nil else { return }
                    delayTask = Task { @MainActor in
                        let skip = Date().timeIntervalSince(FluidTooltipClock.lastDismiss) < 0.3
                        if !skip {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                        guard !Task.isCancelled else { return }
                        controller.present(
                            edge: side, align: .center, offset: 8,
                            motion: .tooltip(side),
                            clickDismiss: false, mouseTransparent: true
                        ) {
                            FluidTooltipPill(text)
                        }
                        delayTask = nil
                    }
                case .ended:
                    delayTask?.cancel()
                    delayTask = nil
                    if controller.isPresented {
                        controller.dismiss()
                        FluidTooltipClock.lastDismiss = Date()
                    }
                }
            }
            .onDisappear {
                delayTask?.cancel()
                controller.dismiss(animated: false)
            }
    }

    /// followCursor keeps the panel centered on the pointer along the
    /// given axis (tooltip.tsx handleFollowMove). View coords flip for
    /// screen space: anchor.maxY is the anchor's top.
    private func follow(_ point: CGPoint) {
        guard let anchor = controller.anchorScreenRect(),
              let panel = controller.panelFrame() else { return }
        var origin = panel.origin
        switch followCursor {
        case .x: origin.x = anchor.minX + point.x - panel.width / 2
        case .y: origin.y = anchor.maxY - point.y - panel.height / 2
        case nil: break
        }
        controller.move(to: origin)
    }
}

/// The pill itself — dark on light, light on dark.
struct FluidTooltipPill: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(FluidTone.background)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                    .fill(FluidTone.foreground)
            )
    }
}

extension View {
    /// `.fluidTooltip("Copy to clipboard", side: .right)` — the port of
    /// `<Tooltip content={...} side={...}>`.
    func fluidTooltip(
        _ text: String,
        side: FluidPopupController.Edge = .top,
        delay: TimeInterval = 0.2,
        followCursor: FluidFollowAxis? = nil
    ) -> some View {
        modifier(FluidTooltipModifier(
            text: text, side: side, delay: delay, followCursor: followCursor
        ))
    }
}

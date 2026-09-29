import AppKit
import SwiftUI

// Tooltip — tooltip.tsx. An inverted pill (bg-foreground / text-
// background), 12px medium, px-2 py-1, shape.bg radius, sideOffset 8.
// Opens after a 200ms hover delay; a tooltip closing arms a 300ms
// skip-delay window so sweeping across adjacent triggers shows theirs
// instantly (Radix's Provider skipDelayDuration).
// The source has no arrow and no `align` prop — Radix centers on `side`.

private enum FluidTooltipClock {
    static var lastDismiss: Date = .distantPast
}

enum FluidFollowAxis { case x, y }

private struct FluidTooltipModifier: ViewModifier {
    let text: String
    var side: FluidPopupController.Edge = .top
    /// Gap between the trigger's edge and the pill — sideOffset.
    var sideOffset: CGFloat = 8
    var delay: TimeInterval = 0.2
    /// Axis the panel centers on the pointer (React's followCursor: "x"|"y").
    var followCursor: FluidFollowAxis? = nil
    /// The source's `forceOpen` — true pins the tooltip open, false pins it
    /// shut, nil leaves normal hover/focus behavior.
    var forceOpen: Bool? = nil
    /// Fires when the tooltip's own open state changes (before forceOpen
    /// is applied) — the source's onOpenChange.
    var onOpenChange: ((Bool) -> Void)? = nil

    @State private var controller = FluidPopupController()
    @State private var delayTask: Task<Void, Never>?
    /// Last state reported to onOpenChange — dedupes double fires.
    @State private var reported = false

    func body(content: Content) -> some View {
        content
            .background(FluidAnchorResolver(controller: controller))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if followCursor != nil { follow(point) }
                    // forceOpen owns the state — hover opens are parked.
                    guard forceOpen == nil, !controller.isPresented,
                          delayTask == nil else { return }
                    delayTask = Task { @MainActor in
                        let skip = Date().timeIntervalSince(FluidTooltipClock.lastDismiss) < 0.3
                        if !skip {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                        guard !Task.isCancelled else { return }
                        presentNow()
                        delayTask = nil
                    }
                case .ended:
                    delayTask?.cancel()
                    delayTask = nil
                    if forceOpen == nil, controller.isPresented {
                        controller.dismiss()
                        FluidTooltipClock.lastDismiss = Date()
                        noteOpen(false)
                    }
                }
            }
            .onAppear { applyForce(forceOpen) }
            .onChange(of: forceOpen) { _, v in applyForce(v) }
            .onDisappear {
                delayTask?.cancel()
                controller.dismiss(animated: false)
            }
    }

    /// forceOpen transitions: true presents without the hover delay, false
    /// cancels a pending open and dismisses a live one, nil hands the state
    /// back to the pointer.
    private func applyForce(_ force: Bool?) {
        switch force {
        case .some(true):
            delayTask?.cancel()
            delayTask = nil
            presentNow()
        case .some(false):
            delayTask?.cancel()
            delayTask = nil
            if controller.isPresented {
                controller.dismiss()
                FluidTooltipClock.lastDismiss = Date()
                noteOpen(false)
            }
        case .none:
            break
        }
    }

    /// The mount — spins until the anchor resolves (it's assigned a runloop
    /// after the NSView materializes), then presents at sideOffset.
    private func presentNow() {
        Task { @MainActor in
            for _ in 0..<60 where controller.anchorScreenRect() == nil {
                try? await Task.sleep(nanoseconds: 4_000_000)
                guard !Task.isCancelled else { return }
            }
            controller.present(
                edge: side, align: .center, offset: sideOffset,
                motion: .tooltip(side),
                clickDismiss: false, mouseTransparent: true
            ) {
                FluidTooltipPill(text)
            }
            noteOpen(controller.isPresented)
        }
    }

    private func noteOpen(_ open: Bool) {
        guard open != reported else { return }
        reported = open
        onOpenChange?(open)
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
            // Tooltips never truncate — the pill takes the text's full
            // intrinsic width (fittingSize otherwise negotiates it down).
            .fixedSize()
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
    /// `<Tooltip content={...} side={...}>`. `sideOffset` is the edge gap
    /// (8 like Radix's default), `forceOpen` pins the state, `onOpenChange`
    /// reports the tooltip's own transitions.
    func fluidTooltip(
        _ text: String,
        side: FluidPopupController.Edge = .top,
        sideOffset: CGFloat = 8,
        delay: TimeInterval = 0.2,
        followCursor: FluidFollowAxis? = nil,
        forceOpen: Bool? = nil,
        onOpenChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(FluidTooltipModifier(
            text: text, side: side, sideOffset: sideOffset, delay: delay,
            followCursor: followCursor, forceOpen: forceOpen,
            onOpenChange: onOpenChange
        ))
    }
}

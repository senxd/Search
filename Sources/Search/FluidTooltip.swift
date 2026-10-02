import AppKit
import SwiftUI

// Tooltip — tooltip.tsx. An inverted pill (bg-foreground / text-
// background), 12px medium, px-2 py-1, shape.bg radius, sideOffset 8.
// Opens after a 200ms hover delay; a tooltip closing arms a 300ms
// skip-delay window so sweeping across adjacent triggers shows theirs
// instantly (Radix's Provider skipDelayDuration). Trigger focus opens on
// the same delay; Escape, blur, and pointer-down close
// (tooltip.tsx:190-191).
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
    /// The Escape monitor — installed only while open (Radix's
    /// document-level keydown close).
    @State private var escMonitor: Any?
    /// A pointer press is in flight — a click's focus landing isn't an
    /// open intent (Radix's wasPointerDownRef).
    @State private var pointerPressed = false
    /// A pointer-down close stays closed until the pointer exits — the
    /// source's hover-open needs a fresh entry.
    @State private var suppressUntilExit = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .background(FluidAnchorResolver(controller: controller))
            // The trigger is Radix's focusable element — focus opens on
            // the same delay, blur closes (tooltip.tsx:190-191). No extra
            // .focusable() here: every real trigger is already a focusable
            // control, and .focused on the wrapper reports focus within
            // its subtree — a stray tab stop would double-focus buttons.
            .focused($focused)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if followCursor != nil { follow(point) }
                    // forceOpen owns the state — hover opens are parked.
                    guard forceOpen == nil, !controller.isPresented,
                          delayTask == nil, !suppressUntilExit else { return }
                    scheduleOpen()
                case .ended:
                    suppressUntilExit = false
                    delayTask?.cancel()
                    delayTask = nil
                    if forceOpen == nil {
                        dismissOpen()
                    }
                }
            }
            .simultaneousGesture(
                // onPointerDown on the trigger: a live tooltip closes and a
                // pending open drops (tooltip.tsx:191).
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pointerDown() }
                    .onEnded { _ in pointerPressed = false }
            )
            .onChange(of: focused) { _, f in
                // Blur also drops the pointer latch — an interrupted
                // gesture (no onEnded) can't wedge focus-open dead.
                if !f { pointerPressed = false }
                if f {
                    // Focus opens on the same delay — except a click's
                    // focus landing (pointer is already down).
                    if !pointerPressed, forceOpen == nil,
                       !controller.isPresented, delayTask == nil {
                        scheduleOpen()
                    }
                } else {
                    delayTask?.cancel()
                    delayTask = nil
                    if forceOpen == nil {
                        dismissOpen()
                    }
                }
            }
            .onAppear {
                applyForce(forceOpen)
                controller.onDismissed = { removeEscMonitor() }
            }
            .onChange(of: forceOpen) { _, v in applyForce(v) }
            .onDisappear {
                delayTask?.cancel()
                removeEscMonitor()
                controller.dismiss(animated: false)
            }
    }

    /// The hover/focus delay — skipped inside the post-close skip-delay
    /// window (Radix's Provider skipDelayDuration).
    private func scheduleOpen() {
        delayTask = Task { @MainActor in
            let skip = Date().timeIntervalSince(FluidTooltipClock.lastDismiss) < 0.3
            if !skip {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            presentNow()
            delayTask = nil
        }
    }

    /// The trigger's pointer-down: closes a live tooltip, drops a pending
    /// open, and latches so the click's focus landing doesn't reopen it.
    private func pointerDown() {
        pointerPressed = true
        let wasPending = delayTask != nil
        delayTask?.cancel()
        delayTask = nil
        guard forceOpen == nil else { return }
        if controller.isPresented || wasPending { suppressUntilExit = true }
        // The close doesn't re-report: a consumer's click handler still
        // reads the pre-down open state — the source's
        // tooltipWasVisibleRef capture (input-copy.tsx:58-61).
        dismissOpen(notify: false)
    }

    /// Closes the tooltip: arms the skip-delay window and drops the Esc
    /// monitor. `notify` false keeps the last reported state — the
    /// pointer-down close isn't an onOpenChange.
    private func dismissOpen(notify: Bool = true) {
        guard controller.isPresented else { return }
        controller.dismiss()
        removeEscMonitor()
        FluidTooltipClock.lastDismiss = Date()
        if notify { noteOpen(false) }
    }

    /// Radix's document-level Escape close — the tooltip panel never
    /// takes key status, so the trigger's window keeps getting the keys.
    /// Reinstalled on forceOpen changes so the pinned check reads fresh.
    private func installEscMonitor() {
        removeEscMonitor()
        let controller = self.controller
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak controller] event in
            guard event.keyCode == 53, controller?.isPresented == true else {
                return event
            }
            // forceOpen owns the state — Esc can't close a pinned tooltip.
            guard forceOpen == nil else { return event }
            dismissOpen()
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
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
            dismissOpen()
        case .none:
            // Pinned → unpinned while open: recapture the fresh forceOpen
            // in the Esc monitor's gate.
            if controller.isPresented { installEscMonitor() }
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
            // Reinstalled per present — teardown nils the callbacks.
            controller.onDismissed = { removeEscMonitor() }
            if controller.isPresented { installEscMonitor() }
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

    /// shape.bg (tooltip.tsx:218).
    @Environment(\.fluidShape) private var shape

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
                RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
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

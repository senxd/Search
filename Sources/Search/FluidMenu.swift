import AppKit
import SwiftUI

// Menus — dropdown.tsx + menu-item.tsx. The panel is an Elevated surface
// (substrate + 2, shadow level 3) holding rows the fluid hover sweeps.
// MenuItem rows are 36px, px-2, icon left, label, trailing check slot —
// exactly the same row a ComboboxItem uses, so both live here.
//
// Dropdown opts out of the global shape context: popover surfaces always
// take the smaller "rounded" radii.

private let menuShape = FluidShape.rounded

// MARK: - Dismiss environment

/// Popups inject a dismiss closure; items call it after their own select
/// so a pick always closes the popup, whatever row was tapped.
private struct FluidMenuDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var fluidMenuDismiss: (() -> Void)? {
        get { self[FluidMenuDismissKey.self] }
        set { self[FluidMenuDismissKey.self] = newValue }
    }
}

// MARK: - Menu item

/// A menu row: icon (optional), label, trailing check slot. `checked`
/// nil = plain action item; a Bool makes it a radio/checkbox row.
struct FluidMenuItem: View {
    let index: Int
    var icon: String? = nil
    let label: String
    var checked: Bool? = nil
    var disabled = false
    /// Omitted follows the ambient `\.fluidSize` (the SizeProvider pin).
    var size: FluidSize? = nil
    var onSelect: () -> Void = {}

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidMenuDismiss) private var menuDismiss
    @Environment(\.fluidSize) private var ambientSize

    private var resolved: FluidSize { size ?? ambientSize }
    private var isActive: Bool { hover?.activeIndex == index }
    private var lit: Bool { isActive || checked == true }

    var body: some View {
        Button(action: { onSelect(); menuDismiss?() }) {
            HStack(spacing: resolved.gap) {
                if let icon {
                    // Fixed square slot — SF Symbols vary in intrinsic
                    // width, so without this each label sits at a different
                    // x. The source's lucide icons are all one box.
                    FluidIcon(icon, size: resolved.icon, bold: lit)
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .frame(width: resolved.icon, height: resolved.icon)
                }
                Text(label)
                    .font(.system(
                        size: resolved.text,
                        weight: checked == true ? .semibold : .regular
                    ))
                    .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                Spacer(minLength: 0)
                // The fixed check slot — its presence never changes the
                // row's width.
                ZStack {
                    if checked == true {
                        FluidCheckmark(size: resolved.icon)
                            .foregroundStyle(FluidTone.foreground)
                    }
                }
                .frame(width: resolved.icon, height: resolved.icon)
            }
            .padding(.horizontal, resolved.itemPx)
            .frame(height: resolved.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .fluidItem(index)
        // scroll-into-view target for the panel's keyboard nav.
        .id("mi-\(index)")
        // Typeahead data — Radix matches item text; report ours so the
        // popup's key monitor can prefix-match it.
        .onAppear { hover?.itemLabels[index] = label }
        .onDisappear { hover?.itemLabels[index] = nil }
        .onChange(of: label) { _, l in hover?.itemLabels[index] = l }
        .animation(.easeOut(duration: 0.08), value: isActive)
    }
}

/// The 4px-label: px-2 py-1.5, caption color.
struct FluidMenuLabel: View {
    let text: String
    var size: FluidSize = .default

    init(_ text: String, size: FluidSize = .default) {
        self.text = text; self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size == .compact ? 11 : 12))
            .foregroundStyle(FluidTone.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-bleed hairline: my-1 -mx-1 h-px bg-border/60.
struct FluidMenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(FluidTone.border.opacity(0.6))
            .frame(height: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, -4)
    }
}

/// The check glyph: M4 12L9 17L20 6, drawing in on appear (80ms easeOut).
/// With `presented` bound the check stays mounted and un-draws instead of
/// popping off (combobox.tsx's exit pathLength 0 over 40ms easeIn).
struct FluidCheckmark: View {
    var size: CGFloat = 16
    /// When set, drives the trim both ways (draw in 80ms easeOut, undraw
    /// 40ms easeIn). nil keeps the legacy draw-in-on-appear behavior.
    var presented: Bool? = nil
    @State private var drawn: CGFloat = 0

    var body: some View {
        CheckPath()
            .trim(from: 0, to: drawn)
            .stroke(
                style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round)
            )
            .frame(width: size, height: size)
            .onAppear {
                if let presented {
                    drawn = presented ? 1 : 0
                } else {
                    withAnimation(.easeOut(duration: 0.08)) { drawn = 1 }
                }
            }
            .onChange(of: presented) { _, p in
                guard let p else { return }
                withAnimation(p ? .easeOut(duration: 0.08)
                                : .easeIn(duration: 0.04)) { drawn = p ? 1 : 0 }
            }
    }

    private struct CheckPath: Shape {
        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / 24
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + 4 * s, y: rect.minY + 12 * s))
            p.addLine(to: CGPoint(x: rect.minX + 9 * s, y: rect.minY + 17 * s))
            p.addLine(to: CGPoint(x: rect.minX + 20 * s, y: rect.minY + 6 * s))
            return p
        }
    }
}

// MARK: - Menu panel

/// The always-rendered panel — the port of the inline `Dropdown`. An
/// Elevated surface (offset +2, shadow 3), 288pt wide, 4pt row padding,
/// with the checked row's bg-active block and the fluid highlight that
/// enters from it.
///
/// Keyboard: a window-scoped monitor ports Radix's content keydown —
/// arrows/Home/End move a virtual focus (the highlight follows), Return/
/// Space activate, characters run prefix typeahead. The focus ring draws
/// only under keyboard modality (useKeyboardNavGate: seeded by `navSeed`
/// — the trigger's :focus-visible at open — armed by any nav key after).
/// The panel is a non-activating window so focus can never be real;
/// `focusedIndex` is the virtual row the ring and activation track.
struct FluidMenuPanel<Content: View>: View {
    var checkedIndex: Int? = nil
    /// Disabled rows — skipped by the pick, dimmed by the row itself.
    var disabledIndices: Set<Int> = []
    var size: FluidSize = .default
    var substrate: Int = 1
    /// Dropdown fixes the panel at w-72; Select fits rows to content
    /// (the popup window still enforces min-width = trigger width).
    var width: CGFloat? = 288
    /// Popup lists scroll past this height with the scroll-fade mask —
    /// max-h-480 dropdowns, max-h-300 selects. nil renders inline-fully.
    var maxHeight: CGFloat? = nil
    /// The rows' natural height measured by the caller — a ScrollView
    /// collapses to 0 under fittingSize, so the panel can't discover its
    /// own height until after the window is already sized.
    var naturalHeight: CGFloat? = nil
    /// Gap-click routing: a click between rows picks the lit one.
    var onPick: ((Int) -> Void)? = nil
    /// Keyboard nav — false leaves the content inert to arrows
    /// (inline menus that already own their own nav).
    var keyboardNav = true
    /// Armed at open when the trigger held keyboard focus (the source's
    /// useKeyboardNavGate seed from :focus-visible).
    var navSeed = false
    /// The window keys actually arrive at — the popup is non-activating,
    /// so keyDowns land on the anchor's window, not ours.
    var keyWindow: (() -> NSWindow?)? = nil
    /// Tab departs the popup entirely (Radix closes on Tab).
    var onExit: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var hover = FluidHover(axis: .y)
    @State private var fade = FluidScrollFadeState()
    /// Virtual keyboard state — a class so the event monitors can hold it
    /// weakly (the panel is a struct; @State handles can't be weak).
    @State private var nav = FluidMenuPanelNav()
    private let probeBox = FluidMenuPanelProbeBox()

    private var checkedRect: CGRect? {
        checkedIndex.flatMap { hover.rects[$0] }
    }
    private var ringRect: CGRect? {
        (nav.navArmed ? nav.focusedIndex : nil).flatMap { hover.rects[$0] }
    }
    /// Visible, enabled rows top-to-bottom (the scope's `ordered` rule).
    private var navOrder: [Int] {
        hover.rects
            .filter { !disabledIndices.contains($0.key) && $0.value.height > 0 }
            .sorted {
                $0.value.minY == $1.value.minY
                    ? $0.value.minX < $1.value.minX
                    : $0.value.minY < $1.value.minY
            }
            .map(\.key)
    }

    var body: some View {
        let rows = FluidContainer(
            hover: hover,
            from: checkedRect,
            radius: menuShape.bg,
            onGapPick: onPick
        ) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(4)
        }
        Group {
            if let maxHeight {
                ScrollViewReader { proxy in
                    ScrollView { rows.fluidFadeContent(fade) }
                        .scrollIndicators(.hidden)
                        .frame(height: min(naturalHeight ?? maxHeight, maxHeight))
                        // popupViewportClass sets --scroll-fade-size: 32px.
                        .fluidScrollFade(32, state: fade)
                        .onAppear { nav.scrollProxy = proxy }
                }
            } else {
                rows
            }
        }
        .frame(width: width)
        .background(alignment: .topLeading) { checkedBackground }
        .background(
            FluidMenuPanelProbe(box: probeBox).frame(width: 0, height: 0)
        )
        // The focus ring — z-20 over rows, 1px focusRing 2px out.
        .overlay(alignment: .topLeading) {
            if let r = ringRect {
                RoundedRectangle(cornerRadius: menuShape.focusRing, style: .continuous)
                    .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                    .frame(width: r.width + 4, height: r.height + 4)
                    .position(x: r.midX, y: r.midY)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(FluidSpring.fast, value: ringRect)
        .onAppear { install() }
        .onDisappear {
            nav.monitors.forEach(NSEvent.removeMonitor)
            nav.monitors = []
        }
        .fluidSurface(min(substrate + 2, 8), radius: menuShape.container)
    }

    /// bg-active behind the checked row — springs with the moderate tier.
    /// Only the row's position animates: every row shares the panel width,
    /// so animating `r` itself would just render the first layout pass
    /// (intrinsic width → full width) as a visible width spring.
    @ViewBuilder
    private var checkedBackground: some View {
        if let r = checkedRect {
            RoundedRectangle(cornerRadius: menuShape.bg, style: .continuous)
                .fill(FluidTone.active)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .animation(FluidSpring.moderate, value: r.midY)
                .transition(.opacity)
        }
    }

    /// Keyboard focus lands on the checked row (Radix opens on the
    /// selection), falling back to the first enabled row.
    private func install() {
        hover.isItemDisabled = { disabledIndices.contains($0) }
        nav.navArmed = navSeed
        if nav.focusedIndex == nil {
            nav.focusedIndex = checkedIndex ?? navOrder.first
        }
        guard keyboardNav, nav.monitors.isEmpty else { return }
        let nav = self.nav
        let hover = self.hover
        let disabled = disabledIndices
        let keyWindow = self.keyWindow
        let probeBox = self.probeBox
        let onPick = self.onPick
        let onExit = self.onExit
        // Pointer modality — a click in the owning window clears the
        // virtual focus; mouse entering the popup clears the ring too
        // (onMouseEnter → setFocusedIndex(null)). navArmed stays.
        nav.monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak nav] event in
            if event.window === keyWindow?() {
                Task { @MainActor in nav?.focusedIndex = nil }
            }
            return event
        }!)
        nav.monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak nav] event in
            if let nav, event.window === probeBox.view?.window {
                Task { @MainActor in nav.focusedIndex = nil }
            }
            return event
        }!)
        nav.monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak nav] event in
            Self.navKey(
                event, nav: nav, hover: hover, disabled: disabled,
                keyWindow: keyWindow, onPick: onPick, onExit: onExit
            ) ?? event
        }!)
    }

    /// Arrows/Home/End move the virtual focus (the highlight follows it,
    /// like the source's onFocus), Return/Space activate, Tab exits, and
    /// printable characters run Radix's prefix typeahead.
    private static func navKey(
        _ event: NSEvent, nav: FluidMenuPanelNav?, hover: FluidHover,
        disabled: Set<Int>, keyWindow: (() -> NSWindow?)?,
        onPick: ((Int) -> Void)?, onExit: (() -> Void)?
    ) -> NSEvent? {
        guard let nav,
              let w = event.window, w === keyWindow?(), w.isKeyWindow,
              !(w.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return event }
        let items = hover.rects
            .filter { !disabled.contains($0.key) && $0.value.height > 0 }
            .sorted {
                $0.value.minY == $1.value.minY
                    ? $0.value.minX < $1.value.minX
                    : $0.value.minY < $1.value.minY
            }
            .map(\.key)
        guard !items.isEmpty else { return event }

        nav.navArmed = true
        switch event.keyCode {
        case 48: // Tab — leave the popup, pass focus onward.
            onExit?()
            return event
        case 123, 126: // ←/↑
            nav.move(in: items, by: -1, hover: hover)
            return nil
        case 124, 125: // →/↓
            nav.move(in: items, by: 1, hover: hover)
            return nil
        case 115: // Home
            nav.setFocus(items.first, hover: hover)
            return nil
        case 119: // End
            nav.setFocus(items.last, hover: hover)
            return nil
        case 36, 76, 49: // Return/Enter/Space — activate like a click.
            if let i = nav.focusedIndex ?? hover.activeIndex { onPick?(i) }
            return nil
        default:
            // Radix typeahead: printable chars accumulate into a prefix
            // matched against item text — from after the current row,
            // wrapping. The buffer resets ~1s after the last char.
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  !chars.isEmpty,
                  chars.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " })
            else { return event }
            let now = Date()
            if now.timeIntervalSince(nav.typeStamp) > 1 { nav.typeBuffer = "" }
            nav.typeStamp = now
            nav.typeBuffer += chars
            let cur = nav.focusedIndex ?? hover.activeIndex
            let start = cur.flatMap { items.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            let ring = Array(items[start...] + items[..<min(start, items.count)])
            guard let hit = ring.first(where: {
                hover.itemLabels[$0]?.lowercased().hasPrefix(nav.typeBuffer) == true
            }) else { return nil }
            nav.setFocus(hit, hover: hover)
            return nil
        }
    }
}

/// The panel's virtual keyboard state — held in a class so window-scoped
/// event monitors can weak-capture it (a View struct can't be weak).
@Observable
final class FluidMenuPanelNav {
    /// The keyboard-focused row — nil until keyboard modality produces
    /// one (seeded at the checked row: Radix opens on the selection).
    var focusedIndex: Int? = nil
    /// useKeyboardNavGate — armed by the trigger's :focus-visible at open
    /// or by any nav key; never cleared mid-session.
    var navArmed = false
    /// Radix's typeahead buffer — resets ~1s after the last char.
    var typeBuffer = ""
    var typeStamp = Date.distantPast
    var scrollProxy: ScrollViewProxy?
    var monitors: [Any] = []

    func setFocus(_ i: Int?, hover: FluidHover) {
        focusedIndex = i
        // onFocus → the hover highlight tracks the focused row.
        hover.activeIndex = i
        if let i { scrollProxy?.scrollTo("mi-\(i)") }
    }

    func move(in items: [Int], by delta: Int, hover: FluidHover) {
        let cur = focusedIndex ?? hover.activeIndex
        let next: Int
        if let cur, let i = items.firstIndex(of: cur) {
            next = items[(i + delta + items.count) % items.count]
        } else {
            next = delta > 0 ? items[0] : items[items.count - 1]
        }
        setFocus(next, hover: hover)
    }
}

/// Reports the hosting NSView so the panel can tell its own (non-
/// activating) window from the owner's when filtering monitors.
final class FluidMenuPanelProbeBox: @unchecked Sendable {
    @MainActor weak var view: NSView?
}

private struct FluidMenuPanelProbe: NSViewRepresentable {
    let box: FluidMenuPanelProbeBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { box.view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

// MARK: - Popup presentation

/// Radix positions popup content in a portal; on macOS the faithful
/// counterpart is a borderless, non-activating child panel — no system
/// chrome, no clipping at the window edge, and it never steals focus from
/// the field that opened it (which Combobox relies on).
@MainActor
final class FluidPopupController {
    enum Edge: Equatable { case top, bottom, left, right }
    enum Align { case start, center }
    /// Enter/exit motion: menu popups scaleY + rise 4pt from the opening
    /// edge; tooltips slide 4pt toward the trigger with no scale.
    enum Motion: Equatable { case popup, tooltip(Edge) }

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var motion: Motion = .popup
    var onDismissed: (() -> Void)?
    private var anchor: NSView?
    /// The anchor's owning window while presented — the popup is a
    /// non-activating child, so key events keep landing here and the
    /// panel's nav monitor filters on it (Radix keeps focus on the
    /// content's focus scope inside the same window).
    private(set) weak var ownerWindow: NSWindow?
    /// Selection-acknowledgment close — the source's selectionAckMs defer:
    /// a pick holds the popup ~300ms so the checkmark draw and the
    /// selected-bg spring land before the exit runs. Any immediate close
    /// (Escape, outside press, trigger toggle) cancels it.
    private var ackWork: DispatchWorkItem?
    /// The placement inputs from the last present() — kept so the panel
    /// can re-anchor when the parent window scrolls or resizes.
    private var placement: (edge: Edge, align: Align, offset: CGFloat)?
    /// The hidden-state transform from the last present() — the exit
    /// animation returns to it.
    private var hiddenT = CATransform3DIdentity

    var isPresented: Bool { panel != nil }

    func setAnchor(_ view: NSView) { anchor = view }

    /// Current anchor frame in screen coordinates, for follow-cursor moves.
    func anchorScreenRect() -> CGRect? {
        guard let anchor, let window = anchor.window else { return nil }
        let r = anchor.convert(anchor.bounds, to: nil)
        let origin = window.convertPoint(toScreen: r.origin)
        return CGRect(x: origin.x, y: origin.y, width: r.width, height: r.height)
    }

    /// Slides the already-open panel to a new origin (followCursor).
    func move(to origin: CGPoint) {
        guard let panel else { return }
        panel.setFrameOrigin(origin)
    }

    func panelFrame() -> CGRect? { panel?.frame }

    func present<Content: View>(
        edge: Edge = .bottom,
        align: Align = .start,
        offset: CGFloat = 6,
        motion: Motion = .popup,
        clickDismiss: Bool = true,
        mouseTransparent: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        guard let anchor, let window = anchor.window else { return }
        dismiss(animated: false)
        self.motion = motion

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = mouseTransparent

        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let screenRect = NSRect(
            x: window.frame.minX + anchorRect.minX,
            y: window.frame.minY + anchorRect.minY,
            width: anchorRect.width,
            height: anchorRect.height
        )
        // Measure raw content first: the panel's width floor is the
        // PRESENTED width (max of content and trigger for top/bottom),
        // not just the trigger — otherwise the first re-layout (fade
        // measurement, row updates) collapses the window toward the
        // trigger's narrower intrinsic size.
        let probeSize = NSHostingView(rootView: AnyView(content())).fittingSize
        let width = edge == .bottom || edge == .top
            ? max(probeSize.width, anchorRect.width)
            : probeSize.width
        let host = NSHostingView(
            rootView: FluidPopupRoot(minWidth: width, content: content)
        )
        panel.contentView = host

        let fitting = host.fittingSize
        let screen = screenRect.origin
        let x: CGFloat = popupX(
            edge: edge, align: align, offset: offset,
            width: width, anchorRect: anchorRect, screenX: screen.x
        )
        let y: CGFloat = popupY(
            edge: edge, align: align, offset: offset,
            height: fitting.height, anchorRect: anchorRect, screenY: screen.y
        )
        panel.setFrame(
            NSRect(x: x, y: y, width: width, height: fitting.height),
            display: false
        )
        // Enter state on the layer before the panel is ordered — the
        // first composited frame is already hidden + transformed.
        hiddenT = Self.hiddenTransform(for: motion, size: fitting)
        host.wantsLayer = true
        if let layer = host.layer {
            layer.transform = hiddenT
            layer.opacity = 0
        }
        window.addChildWindow(panel, ordered: .above)
        DispatchQueue.main.async { [weak self, weak host] in
            guard let layer = host?.layer else { return }
            let hiddenT = self?.hiddenT ?? CATransform3DIdentity
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            layer.add(Self.popupSpring(
                "transform", from: hiddenT,
                to: CATransform3DIdentity), forKey: "in.t")
            layer.add(Self.popupSpring("opacity", from: 0, to: 1), forKey: "in.o")
        }
        self.panel = panel
        ownerWindow = window
        placement = (edge, align, offset)
        startFollowing(anchor: anchor, window: window)

        if ProcessInfo.processInfo.environment["FLUID_POPLOG"] != nil {
            FileHandle.standardError.write(
                "POP present anchor=\(anchorRect) win=\(window.frame) x=\(x) y=\(y) w=\(width) h=\(fitting.height)\n"
                    .data(using: .utf8)!)
            for ms in [100, 350, 800] {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                    if let f = self?.panel?.frame {
                        FileHandle.standardError.write(
                            "POP t+\(ms)ms frame=\(f)\n".data(using: .utf8)!)
                    }
                }
            }
        }

        guard clickDismiss else { return }

        // Outside click (not on the anchor — the trigger toggles) and
        // Escape dismiss, like Radix's pointer-down-outside + Esc.
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            let inAnchor = anchor.window === event.window &&
                anchor.bounds.contains(
                    anchor.convert(event.locationInWindow, from: nil)
                )
            if event.window !== self.panel, !inAnchor { self.dismiss(reason: "outside-click") }
            return event
        }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(reason: "escape"); return nil }
            return event
        }!)
    }

    private func popupX(
        edge: Edge, align: Align, offset: CGFloat,
        width: CGFloat, anchorRect: CGRect, screenX: CGFloat
    ) -> CGFloat {
        switch (edge, align) {
        case (.left, _): return screenX - width - offset
        case (.right, _): return screenX + anchorRect.width + offset
        case (_, .center): return screenX + anchorRect.width / 2 - width / 2
        default: return screenX
        }
    }

    private func popupY(
        edge: Edge, align: Align, offset: CGFloat,
        height: CGFloat, anchorRect: CGRect, screenY: CGFloat
    ) -> CGFloat {
        switch (edge, align) {
        case (.bottom, _): return screenY - height - offset
        case (.top, _): return screenY + anchorRect.height + offset
        case (_, .center): return screenY + anchorRect.height / 2 - height / 2
        default: return screenY
        }
    }

    /// Radix popovers re-anchor on scroll/resize (popper autoUpdate) — the
    /// anchor lives in the window's scroll content while the panel is a
    /// fixed screen-space child, so clip-view bounds changes and window
    /// resizes must re-run the placement math.
    private func startFollowing(anchor: NSView, window: NSWindow) {
        var clip: NSClipView?
        var v: NSView? = anchor.superview
        while let s = v {
            if let c = s as? NSClipView { clip = c; break }
            v = s.superview
        }
        if let clip {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main
            ) { [weak self] _ in self?.reposition() })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window, queue: .main
        ) { [weak self] _ in self?.reposition() })
    }

    private func reposition() {
        guard let panel, let anchor, let window = anchor.window,
              let p = placement else { return }
        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let screenX = window.frame.minX + anchorRect.minX
        let screenY = window.frame.minY + anchorRect.minY
        if ProcessInfo.processInfo.environment["FLUID_POPLOG"] != nil {
            FileHandle.standardError.write(
                "POP reposition anchor=\(anchorRect) win=\(window.frame)\n"
                    .data(using: .utf8)!)
        }
        panel.setFrameOrigin(NSPoint(
            x: popupX(edge: p.edge, align: p.align, offset: p.offset,
                      width: panel.frame.width, anchorRect: anchorRect, screenX: screenX),
            y: popupY(edge: p.edge, align: p.align, offset: p.offset,
                      height: panel.frame.height, anchorRect: anchorRect, screenY: screenY)
        ))
    }

    /// The source's selection acknowledgment: a row pick defers the close
    /// so the checkmark draw + selected-bg spring are visible. Re-picking
    /// restarts the hold; immediate closes cancel it (handled in dismiss —
    /// this call is the only path that defers).
    func dismissAfter(_ delay: TimeInterval) {
        ackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.ackWork = nil
            self?.dismiss(animated: true, reason: "ack")
        }
        ackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismiss(animated: Bool = true, reason: String = "") {
        if reason != "ack" { ackWork?.cancel(); ackWork = nil }
        guard let panel else { return }
        if animated {
            // Exit on the layer — same spring back to the hidden pose.
            if let layer = panel.contentView?.layer {
                layer.transform = hiddenT
                layer.opacity = 0
                layer.add(Self.popupSpring(
                    "transform", from: CATransform3DIdentity,
                    to: hiddenT), forKey: "out.t")
                layer.add(Self.popupSpring(
                    "opacity", from: 1, to: 0), forKey: "out.o")
            }
            // spring.fast exits in ~90ms; release the window after it lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.teardown(panel)
            }
        } else {
            teardown(panel)
        }
    }

    /// Hidden-state transform in layer space (y-up, so the popup's −4pt
    /// SwiftUI offset is +4 here). The .popup scale anchors at the top
    /// edge — baked into the matrix as T(p)·S·T(−p) so the layer's
    /// anchorPoint stays default and relayouts can't fight it.
    private static func hiddenTransform(for motion: Motion, size: CGSize) -> CATransform3D {
        switch motion {
        case .popup:
            let p = CATransform3DMakeTranslation(size.width / 2, size.height, 0)
            let pinv = CATransform3DMakeTranslation(-size.width / 2, -size.height, 0)
            return CATransform3DConcat(
                CATransform3DMakeTranslation(0, 4, 0),
                CATransform3DConcat(
                    CATransform3DConcat(p, CATransform3DMakeScale(1, 0.96, 1)),
                    pinv))
        case .tooltip(.top):    return CATransform3DMakeTranslation(0, -4, 0)
        case .tooltip(.bottom): return CATransform3DMakeTranslation(0, 4, 0)
        case .tooltip(.left):   return CATransform3DMakeTranslation(4, 0, 0)
        case .tooltip(.right):  return CATransform3DMakeTranslation(-4, 0, 0)
        }
    }

    /// FluidSpring.fast (duration .08, bounce 0) as a CASpringAnimation —
    /// stiffness (2π/D)², critically-damped at 4π/D.
    private static func popupSpring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / 0.08, 2)
        a.damping = 4 * .pi / 0.08
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    private func teardown(_ panel: NSPanel) {
        ackWork?.cancel()
        ackWork = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if self.panel === panel { self.panel = nil }
        ownerWindow = nil
        onDismissed?()
    }
}

/// The popup's layout root. Enter/exit motion (popup.ts: opacity +
/// y −4→0 + scaleY 0.96→1 anchored to the opening edge; tooltips slide
/// 4pt toward the trigger, spring.fast) is applied to the panel's
/// CALayer by the controller — a transform on the hosting root gets
/// realized as a view-frame move, which SwiftUI then animates as a
/// visible slide of the whole panel content.
private struct FluidPopupRoot<Content: View>: View {
    /// Trigger-width floor for top/bottom popups — kept inside the
    /// content so re-layouts can't narrow the panel back down.
    var minWidth: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().frame(minWidth: minWidth)
    }
}

/// Reports the rendered NSView so the popup can anchor to it.
struct FluidAnchorResolver: NSViewRepresentable {
    let controller: FluidPopupController

    /// A named class so probes/tests can find the trigger's anchor view
    /// in the hosting hierarchy.
    final class AnchorView: NSView {}

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        DispatchQueue.main.async { controller.setAnchor(view) }
        return view
    }

    /// A bare NSView reports no intrinsic metric — without this it can
    /// collapse to 0×0 in `.background`, leaving the anchor rect empty and
    /// the popup's min-width = trigger-width rule dead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.setAnchor(nsView)
    }
}

/// `fluidMenuPopup` — attach a FluidMenuPanel popup to any trigger view.
/// Equivalent to `Dropdown` + `DropdownContent`: panel below the anchor,
/// dismissed by outside click, Escape, or a row pick.
struct FluidMenuPopupModifier<Rows: View>: ViewModifier {
    @Binding var isPresented: Bool
    var checkedIndex: Int? = nil
    var disabledIndices: Set<Int> = []
    var substrate: Int = 1
    var width: CGFloat? = 288
    /// Scroll cap for the popup list — max-h-480 dropdowns, 300 selects.
    var maxHeight: CGFloat? = 480
    /// Radix's side/align/sideOffset — dropdowns and selects open
    /// bottom-start at 6px by default.
    var side: FluidPopupController.Edge = .bottom
    var align: FluidPopupController.Align = .start
    var sideOffset: CGFloat = 6
    /// Selection-acknowledgment defer (the source's selectionAckMs = 300):
    /// a row pick holds the popup open this long before closing so the
    /// check draw + selected-bg spring land. 0 closes immediately.
    var selectionAck: TimeInterval = 0
    /// Armed-keyboard seed — the trigger's :focus-visible at open.
    var navSeed = false
    var onPick: ((Int) -> Void)? = nil
    @ViewBuilder var rows: () -> Rows

    @State private var controller = FluidPopupController()
    /// The rows' natural height, measured by a hidden probe on the trigger —
    /// a ScrollView reports zero height to a detached hosting view's
    /// fittingSize, so the panel must be handed a concrete height up front.
    @State private var rowsHeight: CGFloat = 0
    /// The probe mounts a live copy of the rows — without its own stores
    /// their `.fluidItem` frames and activation answers would leak into the
    /// enclosing menu's scope.
    @State private var probeHover = FluidHover()
    @State private var probeScope = FluidMenuScope()

    /// A selection-driven close (row pick or activation) defers by the
    /// acknowledgment window; outside presses, Escape, and toggles close
    /// immediately and cancel the pending hold.
    private func dismissForSelection() {
        if selectionAck > 0 {
            controller.dismissAfter(selectionAck)
        } else {
            isPresented = false
        }
    }

    func body(content: Content) -> some View {
        content
            .background(FluidAnchorResolver(controller: controller))
            .background(
                VStack(alignment: .leading, spacing: 0) { rows() }
                    .padding(4)
                    .fixedSize()
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { rowsHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in rowsHeight = h }
                    })
                    .opacity(0)
                    .allowsHitTesting(false)
                    .clipped()
                    .environment(\.fluidHover, probeHover)
                    .environment(\.fluidMenuScope, probeScope)
            )
            .onChange(of: isPresented) { _, open in
                if open {
                    controller.present(
                        edge: side, align: align, offset: sideOffset
                    ) {
                        FluidMenuPanel(
                            checkedIndex: checkedIndex,
                            disabledIndices: disabledIndices,
                            substrate: substrate,
                            width: width,
                            maxHeight: maxHeight,
                            naturalHeight: rowsHeight,
                            onPick: { i in onPick?(i); dismissForSelection() },
                            navSeed: navSeed,
                            keyWindow: { [weak controller] in
                                controller?.ownerWindow
                            },
                            onExit: { isPresented = false },
                            content: rows
                        )
                        .environment(\.fluidMenuDismiss, { dismissForSelection() })
                    }
                } else {
                    controller.dismiss()
                }
            }
            .onAppear {
                controller.onDismissed = { isPresented = false }
            }
    }
}

extension View {
    func fluidMenuPopup<Rows: View>(
        isPresented: Binding<Bool>,
        checkedIndex: Int? = nil,
        disabledIndices: Set<Int> = [],
        substrate: Int = 1,
        width: CGFloat? = 288,
        maxHeight: CGFloat? = 480,
        side: FluidPopupController.Edge = .bottom,
        align: FluidPopupController.Align = .start,
        sideOffset: CGFloat = 6,
        selectionAck: TimeInterval = 0,
        navSeed: Bool = false,
        onPick: ((Int) -> Void)? = nil,
        @ViewBuilder rows: @escaping () -> Rows
    ) -> some View {
        modifier(FluidMenuPopupModifier(
            isPresented: isPresented,
            checkedIndex: checkedIndex,
            disabledIndices: disabledIndices,
            substrate: substrate,
            width: width,
            maxHeight: maxHeight,
            side: side,
            align: align,
            sideOffset: sideOffset,
            selectionAck: selectionAck,
            navSeed: navSeed,
            onPick: onPick,
            rows: rows
        ))
    }
}

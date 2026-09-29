import AppKit
import SwiftUI

// Sidebar core — fluid-demo/components/ui/sidebar-core.tsx.
// The provider/state half of the system: a FluidSidebarState carrying
// open/width/side/variant/peek, UserDefaults persistence in place of the
// source's sidebar_state cookie, the bare-key `[`/`]` toggle scoped to the
// sidebar's own window, and the collapsed-peek overlay with its shared
// intent timer + geometric (not enter/leave) dismissal.
//
// Deliberately N/A for macOS (documented non-goals):
//   - SidebarSheet / openMobile / isMobile breakpoint — no drawer on desktop.
//   - mountedProviders multi-provider arbitration (sidebar-core.tsx:253-317):
//     simplified to "the sidebar's window contains the key event's window";
//     left/right sidebars resolve different keys ("[" vs "]") so the common
//     two-sidebar case doesn't collide anyway.
//   - SurfaceProvider substrate — no surface-context env exists here; the
//     floating card takes `substrate` as a param (floatingLevel = substrate+1).

// MARK: - Types + constants

enum FluidSidebarSide { case left, right }
enum FluidSidebarVariant { case sidebar, floating, inset }
enum FluidSidebarCollapsible { case offcanvas, none }
enum FluidSidebarPeek { case none, hover, click }

/// Provider shortcut config: `.automatic` resolves "[" for a left sidebar
/// and "]" for a right one (the source's `shortcut === undefined` path);
/// `.disabled` is the source's `shortcut={null}`.
enum FluidSidebarShortcut: Equatable {
    case automatic, key(String), disabled
}

enum FluidSidebarMetrics {
    /// SIDEBAR_WIDTH = "16rem" (sidebar-core.tsx:40).
    static let width: CGFloat = 256
    static let minWidth: CGFloat = 160   // SIDEBAR_MIN_WIDTH
    static let maxWidth: CGFloat = 360   // SIDEBAR_MAX_WIDTH
    static let collapseSlop: CGFloat = 56 // SIDEBAR_COLLAPSE_SLOP
    /// Hover-peek intent delay / leave delay (sidebar-core.tsx:242,246).
    static let peekIntent: TimeInterval = 0.150
    static let peekDismiss: TimeInterval = 0.250
    /// Geometric dismissal margin — the overlay box grows 8px (source:565-576).
    static let peekMargin: CGFloat = 8
}

extension EnvironmentValues {
    /// The nearest sidebar's state — SidebarContext. FluidSidebar injects it
    /// for its subtree; FluidSidebarProvider injects it for the whole region
    /// so FluidSidebarTrigger / FluidSidebarInset can sit outside the pane.
    @Entry var fluidSidebar: FluidSidebarState? = nil
}

// MARK: - State

/// The sidebar store — `SidebarContextValue` as an @Observable. open/width
/// proxy to external bindings when the caller is controlling them (the
/// plain `FluidSidebar(open:width:)` path keeps working unchanged); held
/// internally otherwise.
@Observable
final class FluidSidebarState {
    /// The cookie-equivalent UserDefaults keys (SIDEBAR_COOKIE_NAME).
    /// `persistKey` namespaces them — a second persisted sidebar (the Ask
    /// window's nav) must not share the first's keys
    /// (fullscreen-features §3).
    static let stateDefaultsKey = "fluid.sidebar.state"
    static let widthDefaultsKey = "fluid.sidebar.width"
    var persistKey: String? = nil
    private var stateKey: String {
        persistKey.map { "fluid.sidebar.\($0).state" } ?? Self.stateDefaultsKey
    }
    private var widthKey: String {
        persistKey.map { "fluid.sidebar.\($0).width" } ?? Self.widthDefaultsKey
    }

    // MARK: config (Sidebar pushes these in — registerSide et al.)
    var side: FluidSidebarSide = .left
    var variant: FluidSidebarVariant = .sidebar
    var collapsible: FluidSidebarCollapsible = .offcanvas
    var peek: FluidSidebarPeek = .none {
        didSet { if peek == .none { releasePeek() } }
    }
    var shortcut: FluidSidebarShortcut = .automatic
    /// Write `open`/`width` to UserDefaults (the `persist` provider prop).
    var persist = false
    var minWidth = FluidSidebarMetrics.minWidth
    var maxWidth = FluidSidebarMetrics.maxWidth
    var collapseSlop = FluidSidebarMetrics.collapseSlop

    // MARK: open / width
    @ObservationIgnored private var openBinding: Binding<Bool>?
    @ObservationIgnored private var widthBinding: Binding<CGFloat>?
    private var _open = true
    private var _width = FluidSidebarMetrics.width

    var open: Bool {
        get { openBinding?.wrappedValue ?? _open }
        set { setOpen(newValue) }
    }
    var width: CGFloat {
        get { widthBinding?.wrappedValue ?? _width }
        set { setWidth(newValue) }
    }
    /// state: "expanded" | "collapsed" as a Bool.
    var collapsed: Bool { !open }

    func setOpen(_ next: Bool) {
        let wasPeeking = isPeeking
        if let b = openBinding { b.wrappedValue = next } else { _open = next }
        if persist { UserDefaults.standard.set(next, forKey: stateKey) }
        // Pinning open always dismisses the peek — but flag the transition
        // first so the shell can keep the visible card unclipped through the
        // width spring (pinnedFromPeek, sidebar-core.tsx:619-626).
        if next && wasPeeking { holdPinFromPeek() }
        if next { releasePeek() }
    }

    func toggle() { setOpen(!open) }

    func setWidth(_ w: CGFloat) {
        if let b = widthBinding { b.wrappedValue = w } else { _width = w }
        if persist, !isResizing { persistWidth() }
    }

    // MARK: resizing (setIsResizing — disables the width spring)
    var isResizing = false {
        didSet {
            if oldValue && !isResizing, persist { persistWidth() }
        }
    }

    // MARK: peek
    /// True while the collapsed sidebar is floated out as an overlay card.
    var isPeeking = false {
        didSet {
            guard isPeeking != oldValue else { return }
            isPeeking ? installPeekDismissal() : removePeekDismissal()
        }
    }
    /// Held for one slow-spring after a peek is pinned open (pinFromPeekHold).
    var pinFromPeekHold = false

    @ObservationIgnored private var peekTimer: Task<Void, Never>?
    @ObservationIgnored private var pinHoldTask: Task<Void, Never>?
    @ObservationIgnored private var peekMonitors: [Any] = []
    @ObservationIgnored private var shortcutMonitor: Any?
    /// The sidebar's window — scopes the shortcut key and the peek's
    /// outside-click/mouse-move watchers. Written by the shell's probe.
    @ObservationIgnored weak var window: NSWindow?
    /// Peek geometry in WINDOW coordinates (NSEvent space, origin bottom-left)
    /// — published by frame probes inside the strip and the overlay card.
    @ObservationIgnored var peekStripFrame: CGRect = .zero
    @ObservationIgnored var peekCardFrame: CGRect = .zero
    @ObservationIgnored private var wasInsidePeek = true

    init(open: Binding<Bool>? = nil, width: Binding<CGFloat>? = nil,
         defaultOpen: Bool = true, defaultWidth: CGFloat = FluidSidebarMetrics.width,
         persist: Bool = false, persistKey: String? = nil,
         shortcut: FluidSidebarShortcut = .automatic,
         peek: FluidSidebarPeek = .none, side: FluidSidebarSide = .left) {
        self.openBinding = open
        self.widthBinding = width
        self.persist = persist
        self.persistKey = persistKey
        self.shortcut = shortcut
        self.peek = peek
        self.side = side
        if persist && open == nil,
           let stored = UserDefaults.standard.object(forKey: stateKey) as? Bool {
            _open = stored
        } else {
            _open = defaultOpen
        }
        if persist && width == nil,
           UserDefaults.standard.object(forKey: widthKey) != nil {
            _width = UserDefaults.standard.double(forKey: widthKey)
        } else {
            _width = defaultWidth
        }
        installShortcutMonitor()
    }

    deinit {
        peekTimer?.cancel()
        pinHoldTask?.cancel()
        peekMonitors.forEach { NSEvent.removeMonitor($0) }
        if let m = shortcutMonitor { NSEvent.removeMonitor(m) }
    }

    /// Re-evaluate peek lifecycle after an `open` change — including writes
    /// that bypassed setOpen (an external binding flip). Idempotent; the
    /// shell calls it from onChange(of: open).
    func openDidChange() {
        if open && isPeeking { holdPinFromPeek() }
        if open || peek == .none { releasePeek() }
    }

    // MARK: peek timers — ONE shared intent timer for every affordance
    // (edge strip, trigger), per sidebar-core.tsx:236-248.

    func cancelPeekTimer() {
        peekTimer?.cancel()
        peekTimer = nil
    }

    func schedulePeek() {
        cancelPeekTimer()
        peekTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(FluidSidebarMetrics.peekIntent * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.presentPeek()
        }
    }

    func scheduleDismissPeek() {
        cancelPeekTimer()
        peekTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(FluidSidebarMetrics.peekDismiss * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.dismissPeek()
        }
    }

    /// Peek entrance rides the moderate tier (source:769).
    func presentPeek() {
        cancelPeekTimer()
        guard !open else { return }
        withAnimation(FluidSpring.moderate) { isPeeking = true }
    }

    /// Exit rides moderate.exit — spring duration 0.12 (source:767).
    func dismissPeek() {
        withAnimation(.spring(duration: 0.12, bounce: 0)) { isPeeking = false }
    }

    /// Pin-or-disable cleanup (source:229-235): clears a pending intent
    /// timer too — a late timer firing setIsPeeking on an open sidebar is
    /// the leak this guards.
    private func releasePeek() {
        cancelPeekTimer()
        isPeeking = false
    }

    private func holdPinFromPeek() {
        pinFromPeekHold = true
        pinHoldTask?.cancel()
        pinHoldTask = Task { @MainActor [weak self] in
            // exitFallbackMs(spring.slow) = 160ms exit + 100ms buffer.
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            self?.pinFromPeekHold = false
        }
    }

    // MARK: peek dismissal watchers (source:551-595)

    private var peekContainmentRects: [CGRect] {
        [peekStripFrame, peekCardFrame].filter { $0 != .zero }
    }

    private func installPeekDismissal() {
        guard peekMonitors.isEmpty else { return }
        wasInsidePeek = true
        // Escape dismisses — and is consumed: the open peek is the
        // topmost layer, so letting the same press also reach the
        // window's own Esc cascade would shed two rungs at once.
        peekMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53, let self, self.isPeeking else { return event }
            self.dismissPeek()
            return nil
        }!)
        // Outside press dismisses — "outside" = outside the shell's subtree
        // (strip ∪ card), measured geometrically in window coordinates.
        peekMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let inside = event.window === self.window &&
                self.peekContainmentRects.contains { $0.contains(event.locationInWindow) }
            if !inside { self.dismissPeek() }
            return event
        }!)
        // Hover mode holds the peek by geometric containment, not hover
        // events: a portalled tooltip or menu covering the card fires
        // spurious exits even though the pointer never left the box.
        if peek == .hover {
            peekMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
                [weak self] event in
                guard let self, event.window === self.window else { return event }
                guard self.peekCardFrame != .zero else { return event }
                let box = self.peekCardFrame.insetBy(
                    dx: -FluidSidebarMetrics.peekMargin, dy: -FluidSidebarMetrics.peekMargin)
                if box.contains(event.locationInWindow) {
                    // Unconditional: a stray leave may have armed dismissal
                    // while the pointer was already inside.
                    self.wasInsidePeek = true
                    self.cancelPeekTimer()
                } else if self.wasInsidePeek {
                    self.wasInsidePeek = false
                    self.scheduleDismissPeek()
                }
                return event
            }!)
        }
    }

    private func removePeekDismissal() {
        peekMonitors.forEach { NSEvent.removeMonitor($0) }
        peekMonitors.removeAll()
    }

    // MARK: shortcut (source:253-317)

    /// The resolved toggle key for binding; nil when the shortcut is off.
    var resolvedShortcut: String? {
        switch shortcut {
        case .disabled: return nil
        case .key(let k): return k
        case .automatic: return side == .right ? "]" : "["
        }
    }

    /// The key shown in tooltips — falls back to the side's default even
    /// when the binding is disabled (useShortcutKey, source:862-870).
    var shortcutKey: String {
        resolvedShortcut ?? (side == .right ? "]" : "[")
    }

    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, let key = self.resolvedShortcut else { return event }
            // Scoped to the sidebar's own window — the single-window port of
            // the mountedProviders arbitration.
            guard event.window === self.window else { return event }
            guard event.characters?.lowercased() == key.lowercased() else { return event }
            // ⌘[/⌘] keep their app meaning; ⌥ and ⌃ chords pass too.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            // Never steal the key while typing.
            guard !Self.isEditableResponder(event.window?.firstResponder)
            else { return event }
            self.toggle()
            return nil
        }
    }

    /// INPUT/TEXTAREA/SELECT/isContentEditable equivalent: any
    /// NSTextInputClient (covers NSTextView, FluidTextView and NSTextField's
    /// field editor), an editable field, popup buttons, or a view nested
    /// inside a text view.
    private static func isEditableResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextInputClient { return true }
        if responder is NSPopUpButton || responder is NSComboBox { return true }
        var view = (responder as? NSView)?.superview
        while let v = view {
            if v is NSText { return true }
            view = v.superview
        }
        return false
    }

    private func persistWidth() {
        UserDefaults.standard.set(Double(width), forKey: widthKey)
    }
}

// MARK: - Provider

/// SidebarProvider: owns a FluidSidebarState (restored from UserDefaults
/// when `persist`), publishes it to the subtree. Wrap the HStack that
/// contains the FluidSidebar + FluidSidebarInset.
struct FluidSidebarProvider<Content: View>: View {
    @State private var state: FluidSidebarState
    @ViewBuilder var content: () -> Content

    init(defaultOpen: Bool = true,
         open: Binding<Bool>? = nil,
         persist: Bool = true,
         persistKey: String? = nil,
         shortcut: FluidSidebarShortcut = .automatic,
         peek: FluidSidebarPeek = .none,
         side: FluidSidebarSide = .left,
         width: CGFloat = FluidSidebarMetrics.width,
         @ViewBuilder content: @escaping () -> Content) {
        _state = State(initialValue: FluidSidebarState(
            open: open, width: nil, defaultOpen: defaultOpen, defaultWidth: width,
            persist: persist, persistKey: persistKey,
            shortcut: shortcut, peek: peek, side: side
        ))
        self.content = content
    }

    var body: some View {
        content()
            .environment(\.fluidSidebar, state)
            // The wrapper is the keyboard/hover scope root — a full-size
            // container like the source's group/sidebar-wrapper div.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Trigger

/// SidebarTrigger: ghost icon button calling toggleSidebar(). The icon
/// mirrors the sidebar's side; the tooltip names the action + keystroke.
/// In hover-peek mode the COLLAPSED trigger is a peek affordance too —
/// same shared intent timer as the edge strip (source:875-954).
struct FluidSidebarTrigger: View {
    var state: FluidSidebarState? = nil
    /// Extra action chained before the toggle (source's onClick prop).
    var onClick: (() -> Void)? = nil

    @Environment(\.fluidSidebar) private var env
    @Environment(\.fluidSize) private var size

    private var resolved: FluidSidebarState? { state ?? env }

    var body: some View {
        let st = resolved
        let collapsed = !(st?.open ?? true)
        let icon = st?.side == .right ? "sidebar.right" : "sidebar.left"
        let hoverPeek = st?.peek == .hover && collapsed

        let btnSize: FluidButtonSize = size == .compact ? .iconCompact : .icon
        FluidButton(variant: .ghost, size: btnSize) {
            onClick?()
            st?.toggle()
        } label: {
            FluidIcon(icon, size: btnSize.iconSize)
        }
        .fluidSidebarTooltip(side: .bottom) {
            HStack(spacing: 6) {
                Text(collapsed ? "Expand sidebar" : "Collapse sidebar")
                FluidSidebarKbd(st?.shortcutKey ?? "[")
            }
        }
        .onHover { h in
            guard hoverPeek, let st else { return }
            if h {
                if st.isPeeking { st.cancelPeekTimer() } else { st.schedulePeek() }
            } else if !st.isPeeking {
                // While peeked the geometric watcher owns dismissal; this
                // leave only retires a pending intent timer (source:939-944).
                st.cancelPeekTimer()
            }
        }
        .accessibilityLabel("Toggle Sidebar")
    }
}

// MARK: - Rail

/// SidebarRail: the grab strip on the sidebar's inner edge. Drag to resize
/// (clamped, past min−slop previews collapse), click to toggle. Hovering
/// brightens the edge hairline; the tooltip explains both gestures
/// (source:967-1091).
struct FluidSidebarRail: View {
    var state: FluidSidebarState? = nil
    /// Pin the tooltip open/closed; nil leaves it on hover (tooltipOpen).
    var tooltipOpen: Bool? = nil
    /// Strip inset from the panel's inner edge — floating moves it in to
    /// straddle the card edge (source:822-823, `right-1` → 4px).
    var edgeInset: CGFloat = 0
    /// Hairline inset from the panel's edge (floating: after:right-[3.5px]
    /// + edgeInset 4 → 7.5).
    var lineInset: CGFloat = 0
    /// Cards are rounded: fade the hairline in past the corner radius
    /// (source:828-837, mask 12→36px for the rounded shape).
    var maskEnds = false
    /// --rail-fade-start: where the masked fade begins — 12 under rounded,
    /// 24 under pill (shape.bgRadius >= 20 → 24, source:831-837); the ramp
    /// is a fixed 24px.
    var maskFade: CGFloat = 12
    var action: (() -> Void)? = nil

    @Environment(\.fluidSidebar) private var env
    @State private var hovered = false
    @State private var dragging = false
    @State private var moved = false
    @State private var collapsedPreview = false
    @State private var startWidth: CGFloat = 0
    @State private var height: CGFloat = 0

    private var resolved: FluidSidebarState? { state ?? env }

    private var left: Bool { (resolved?.side ?? .left) == .left }
    /// The panel edge the rail hugs: trailing for a left sidebar.
    private var edge: Alignment { left ? .trailing : .leading }

    var body: some View {
        let st = resolved
        ZStack(alignment: edge) {
            // The hover hairline — after:bg-foreground/25, 1px at the
            // strip's inner edge position, transition-colors duration-80.
            hairline
            Color.clear
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .padding(left ? .trailing : .leading, edgeInset)
        .contentShape(Rectangle())
        .onHover { h in
            hovered = h
            if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        // highPriority so an enclosing ScrollView can't claim the drag.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard let st else { return }
                    if !moved {
                        // 4px dead zone before the press becomes a drag —
                        // below it the release is the collapse click.
                        guard abs(v.translation.width) >= 4 else {
                            if startWidth == 0 { startWidth = st.width }
                            return
                        }
                        moved = true
                        dragging = true
                        st.isResizing = true
                        if startWidth == 0 { startWidth = st.width }
                    }
                    let delta = left ? v.translation.width : -v.translation.width
                    let raw = startWidth + delta
                    if raw < st.minWidth - st.collapseSlop {
                        // Collapse preview: the drag session stays alive so
                        // pulling back re-expands (source:997-1003). The flip
                        // rides the moderate tier, not the glued tracking.
                        if !collapsedPreview {
                            collapsedPreview = true
                            withAnimation(FluidSpring.moderate) {
                                st.setWidth(st.minWidth)
                                st.setOpen(false)
                            }
                        }
                        return
                    }
                    if collapsedPreview {
                        collapsedPreview = false
                        withAnimation(FluidSpring.moderate) { st.setOpen(true) }
                    }
                    st.setWidth(min(max(raw, st.minWidth), st.maxWidth))
                }
                .onEnded { _ in
                    // A press that never moved is the collapse click.
                    if !moved { action?() ?? resolved?.toggle() }
                    moved = false
                    dragging = false
                    collapsedPreview = false
                    startWidth = 0
                    resolved?.isResizing = false
                }
        )
        .fluidSidebarTooltip(
            side: left ? .right : .left,
            followCursor: .y,
            // Dragging always hides it; pinned overrides hover (source:1038).
            forceOpen: dragging ? false : tooltipOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Drag").fontWeight(.semibold) + Text(" to resize")
                HStack(spacing: 6) {
                    Text("Click").fontWeight(.semibold) + Text(" to collapse")
                    FluidSidebarKbd(st?.shortcutKey ?? "[")
                }
            }
        }
    }

    /// w-px hairline; `lineInset` pulls it off the panel's edge so it sits
    /// on the floating card's edge instead.
    private var hairline: some View {
        Rectangle()
            .fill(FluidTone.foreground.opacity(0.25))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(left ? .trailing : .leading, lineInset)
            .padding(.vertical, maskEnds ? 8 : 0)
            .modifier(FluidRailLineMask(enabled: maskEnds, fade: maskFade, ramp: 24))
            .opacity(hovered || tooltipOpen == true ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: hovered || tooltipOpen == true)
    }
}

/// The vertical fade that keeps the rail hairline off the rounded card
/// corners — mask-image linear-gradient transparent → black over
/// `--rail-fade-start`→`--rail-fade-end` (source:828-837).
private struct FluidRailLineMask: ViewModifier {
    let enabled: Bool
    var fade: CGFloat
    var ramp: CGFloat
    @State private var h: CGFloat = 1

    func body(content: Content) -> some View {
        if enabled {
            let s = min(max(fade / max(h, 1), 0), 1)
            let e = min(max((fade + ramp) / max(h, 1), 0), 1)
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h = $0 }
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: s),
                    .init(color: .black, location: e),
                    .init(color: .black, location: 1 - e),
                    .init(color: .clear, location: 1 - s),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom))
        } else {
            content
        }
    }
}

// MARK: - Inset

/// SidebarInset: the sibling content region (source:1098-1125). Always
/// bg-background; with the sidebar's `inset` variant it becomes the card —
/// m-2 margins (the sidebar-side margin collapses to 0 while the rail is
/// open so the card hugs the pane, and restores when collapsed), rounded
/// container, surface-2 bg + shadow. Margin changes ride duration-80.
struct FluidSidebarInset<Content: View>: View {
    @Environment(\.fluidSidebar) private var state
    @Environment(\.fluidShape) private var shape
    @ViewBuilder var content: () -> Content

    private var inset: Bool { state?.variant == .inset }
    private var open: Bool { state?.open ?? false }
    private var side: FluidSidebarSide { state?.side ?? .left }
    /// rounded-xl / rounded-3xl by shape (source:1114-1116).
    private var radius: CGFloat { shape == .pill ? 24 : 12 }

    var body: some View {
        let leftMargin: CGFloat = inset ? (side == .left && open ? 0 : 8) : 0
        let rightMargin: CGFloat = inset ? (side == .right && open ? 0 : 8) : 0
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if inset {
                    Color.clear.fluidSurface(2, radius: radius)
                } else {
                    FluidTone.background
                }
            }
            .padding(.leading, leftMargin)
            .padding(.trailing, rightMargin)
            .padding(.vertical, inset ? 8 : 0)
            .animation(.easeOut(duration: 0.08), value: open)
            .animation(.easeOut(duration: 0.08), value: inset)
    }
}

// MARK: - Tooltip (rich content: label + kbd chips, forceOpen, followCursor)
//
// Same machinery as FluidTooltip (200ms intent, 300ms skip-delay, inverted
// pill, sideOffset 8) but with a ViewBuilder so the rail/trigger tooltips
// can carry multi-line labels and keystroke chips (ShortcutKbd).

private enum FluidSidebarTooltipClock {
    static var lastDismiss: Date = .distantPast
}

/// The keystroke chip rendered inside the inverted pill (source:854-860).
struct FluidSidebarKbd: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(FluidTone.background.opacity(0.8))
            .padding(.horizontal, 4)
            .frame(minWidth: 16)
            .frame(height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(FluidTone.background.opacity(0.3), lineWidth: 1)
            )
    }
}

private struct FluidSidebarTooltipModifier<Tip: View>: ViewModifier {
    var side: FluidPopupController.Edge = .top
    var followCursor: FluidFollowAxis? = nil
    /// nil = hover (default); true = pinned; false = suppressed (dragging).
    var forceOpen: Bool? = nil
    @ViewBuilder var tip: () -> Tip

    @State private var controller = FluidPopupController()
    @State private var delayTask: Task<Void, Never>?
    @State private var hoverInside = false

    private var shown: Bool { controller.isPresented }

    func body(content: Content) -> some View {
        content
            .background(FluidAnchorResolver(controller: controller))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverInside = true
                    if followCursor != nil { follow(point) }
                    presentWithIntent()
                case .ended:
                    hoverInside = false
                    delayTask?.cancel()
                    delayTask = nil
                    // A pinned tooltip stays (it stands in for the hover).
                    if shown, forceOpen != true { dismissTooltip() }
                }
            }
            .onAppear {
                if forceOpen == true {
                    // The anchor resolves a beat after makeNSView — defer.
                    delayTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        guard !Task.isCancelled else { return }
                        presentTooltip()
                    }
                }
            }
            .onChange(of: forceOpen) { _, pin in
                if pin == true { presentTooltip() }
                if pin == false { dismissTooltip() }
            }
            .onDisappear {
                delayTask?.cancel()
                controller.dismiss(animated: false)
            }
    }

    private func presentWithIntent() {
        guard forceOpen != false, !shown, delayTask == nil else { return }
        delayTask = Task { @MainActor in
            let skip = Date().timeIntervalSince(FluidSidebarTooltipClock.lastDismiss) < 0.3
            if !skip { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard !Task.isCancelled else { return }
            presentTooltip()
            delayTask = nil
        }
    }

    private func presentTooltip() {
        guard !shown, forceOpen != false else { return }
        controller.present(
            edge: side, align: .center, offset: 8,
            motion: .tooltip(side),
            clickDismiss: false, mouseTransparent: true
        ) {
            tip()
                .font(.system(size: 12, weight: .medium))
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

    private func dismissTooltip() {
        guard shown else { return }
        controller.dismiss()
        FluidSidebarTooltipClock.lastDismiss = Date()
    }

    private func follow(_ point: CGPoint) {
        guard let anchor = controller.anchorScreenRect(),
              let panel = controller.panelFrame() else { return }
        var origin = panel.origin
        if followCursor == .y {
            origin.y = anchor.maxY - point.y - panel.height / 2
        } else {
            origin.x = anchor.minX + point.x - panel.width / 2
        }
        controller.move(to: origin)
    }
}

extension View {
    /// Sidebar tooltips — Tooltip with rich content, followCursor, and the
    /// rail's forceOpen pin. Private to the sidebar files.
    func fluidSidebarTooltip<Tip: View>(
        side: FluidPopupController.Edge = .top,
        followCursor: FluidFollowAxis? = nil,
        forceOpen: Bool? = nil,
        @ViewBuilder content: @escaping () -> Tip
    ) -> some View {
        modifier(FluidSidebarTooltipModifier(
            side: side, followCursor: followCursor, forceOpen: forceOpen, tip: content
        ))
    }
}

// MARK: - Window + frame probes

/// Reports the view's window to the sidebar state (the keyboard-shortcut
/// and peek-watcher scope) and optionally its frame in window coordinates.
struct FluidSidebarProbe: NSViewRepresentable {
    let state: FluidSidebarState
    /// Sink for the frame in NSEvent window coordinates (origin bottom-left).
    var onFrame: ((CGRect) -> Void)? = nil
    var onDetach: (() -> Void)? = nil

    func makeNSView(context: Context) -> Probe { Probe(state: state, onFrame: onFrame, onDetach: onDetach) }
    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.state = state
        nsView.onFrame = onFrame
        nsView.onDetach = onDetach
        nsView.report()
    }
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) {
        nsView.reportDetach()
    }

    final class Probe: NSView {
        var state: FluidSidebarState
        var onFrame: ((CGRect) -> Void)?
        var onDetach: (() -> Void)?
        init(state: FluidSidebarState, onFrame: ((CGRect) -> Void)?, onDetach: (() -> Void)? = nil) {
            self.state = state
            self.onFrame = onFrame
            self.onDetach = onDetach
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { state.window = window }
            report()
        }
        override func layout() { super.layout(); report() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); report() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); report() }

        func report() {
            guard window != nil else { return }
            onFrame?(convert(bounds, to: nil))
        }
        func reportDetach() { onDetach?() }
    }
}

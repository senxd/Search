import AppKit
import SwiftUI

// Sidebar menu — fluid-demo/components/ui/sidebar-menu.tsx. The fluid-hover
// list (useMenuScope): one traveling hover background, a bg-active block for
// the selected row, and a traveling keyboard focus ring that walks every
// visible row — sub-menu rows interleaved — in order.
//
// Focus ownership: each row is a real focusable view bound to one per-menu
// @FocusState (the source's roving tabindex becomes every row being a stop —
// documented divergence). A local keyDown monitor ports the container's
// onKeyDown (arrows/Home/End, Enter/Space routed through the scope's
// activation broadcast so the row's own fresh closure runs); a leftMouseDown
// monitor ports onPointerDown — any click switches to pointer modality and
// the ring stays off until a keypress (:focus-visible).
//
// The hover system measures each row's BUTTON-equivalent view (fluidItem is
// applied to the row strip, not a wrapping container) so an expanded
// sub-menu never leaks into the parent's hit-test — the source's
// rowButton() measurement rule at sidebar-menu.tsx:209-213.

// MARK: - Scope

/// One activation request — gap click or Enter/Space — broadcast to the
/// rows so the row's own (always fresh) action runs instead of a closure
/// captured at registration time.
struct FluidMenuActivation: Equatable {
    let index: Int
    let seq: Int
}

/// The per-menu MenuScope: the fluid hover store plus which rows the hover
/// and keyboard skip (disabled, or inside a closed sub-menu — the source's
/// rowSkipped), rows pinning an open popup (hover tracking is suppressed
/// while one is — the source's popupOpen() gate on mouse-move), and the
/// pointer-modality flag that keeps the ring hidden after clicks.
@Observable
final class FluidMenuScope {
    let hover = FluidHover(axis: .y)
    var skipped: Set<Int> = []
    private var popupRows: Set<Int> = []
    var pendingActivation: FluidMenuActivation? = nil
    /// Rows marked active by their own props (isActive:/status:) — the
    /// source's setRowActive registers EVERY active row and each gets a
    /// bg-active overlay (sidebar-menu.tsx:255-261, 422-437). Flags are kept
    /// separately so skipped/hidden rows drop out — `recomputeActive`
    /// re-filters `rowSkipped` on every visibility change (tsx:192-197).
    private var activeFlags: Set<Int> = []
    var activeRows: Set<Int> { activeFlags.subtracting(skipped) }
    /// Index → row state — lets the menu keep a lit row while focus moves
    /// to a trailing action (the source's relatedTarget containment).
    var rowStates: [Int: FluidMenuRowState] = [:]
    /// Pointer modality wins by default — the ring shows only after a
    /// keyboard event arrives (:focus-visible semantics).
    var pointerInput = true
    /// The row whose ring a focused trailing action hangs off — cleared on
    /// pointer input (the source's onPointerDown drops focusedRowEl).
    var lastFocusedRow: Int? = nil
    @ObservationIgnored weak var view: NSView?
    private var activationSeq = 0

    var popupOpen: Bool { !popupRows.isEmpty }

    /// Visible, enabled rows top-to-bottom — compareDocumentPosition in the
    /// source; ordering by named-space minY lands sub-rows interleaved.
    var ordered: [Int] {
        hover.rects
            .filter { !skipped.contains($0.key) && $0.value.height > 0 }
            .sorted {
                $0.value.minY == $1.value.minY
                    ? $0.value.minX < $1.value.minX
                    : $0.value.minY < $1.value.minY
            }
            .map(\.key)
    }

    func setSkipped(_ i: Int, _ s: Bool) {
        if s { skipped.insert(i) } else { skipped.remove(i) }
        // refreshVisibility — a lit row that gets skipped stops being lit
        // (collapsing a sub under the cursor can't leave a ghost highlight).
        if s, hover.activeIndex == i { hover.activeIndex = nil }
    }
    func setActive(_ i: Int, _ a: Bool) {
        if a { activeFlags.insert(i) } else { activeFlags.remove(i) }
    }
    func setPopupRow(_ i: Int, _ open: Bool) {
        if open { popupRows.insert(i) } else { popupRows.remove(i) }
        // Source suppresses mouse-move while a popup is open — the lit
        // row stays pinned under group-has-[data-state=open].
        hover.frozen = popupOpen
    }
    func activate(_ i: Int) {
        guard !skipped.contains(i) else { return }
        activationSeq += 1
        pendingActivation = FluidMenuActivation(index: i, seq: activationSeq)
    }
}

/// Per-row trailing-control bookkeeping — the MenuItemContext fields
/// actionCount/actionsShowOnHover/hasBadge that setActions/setHasBadge
/// publish (sidebar-menu.tsx:82-87).
@Observable
final class FluidMenuRowState {
    struct Reg { var showOnHover: Bool; var popupOpen: Bool; var inCluster = false; var focused = false }
    private var regs: [UUID: Reg] = [:]
    var hasBadge = false
    /// Measured badge width — standalone actions pin their right edge to
    /// right-8.5 (34px) when a badge shares the row (tsx:1074).
    var badgeWidth: CGFloat = 20
    /// Real pointer-over — the reveal term's :hover. The menu's lit index
    /// can't serve: under a frozen pick (popup open) hovering another row
    /// still reveals ITS actions in the source (peer-hover, tsx:1092).
    var hovered = false
    /// True inside a sub-item — trailing controls top-align one step
    /// closer (top-0.5 vs top-1, source's isSubRow branch).
    var isSubRow = false

    init(isSubRow: Bool = false) { self.isSubRow = isSubRow }

    var actionCount: Int { regs.count }
    /// Actions still reserved at rest (the always-visible ones).
    private var pinnedCount: Int { regs.values.filter { !$0.showOnHover }.count }
    /// Any action pinning itself open — keeps the cluster revealed and
    /// freezes the menu's hover pick (group-has-[data-state=open]).
    var popupOpen: Bool { regs.values.contains { $0.popupOpen } }
    /// focus-within — an action holding focus keeps the cluster revealed.
    var actionFocused: Bool { regs.values.contains { $0.focused } }
    /// A focused CLUSTERED action reveals regardless of modality (the
    /// source's :focus-within); a lone action reveals on :focus-visible
    /// only — the row applies the modality half.
    var actionFocusedCluster: Bool { regs.values.contains { $0.focused && $0.inCluster } }
    var actionFocusedSolo: Bool { regs.values.contains { $0.focused && !$0.inCluster } }

    /// --row-gutter / --row-gutter-hover — rowGutter() at sidebar-menu.tsx:695.
    var gutterHover: CGFloat { MenuGutter.reserve(actions: actionCount, badge: hasBadge) }
    var gutterRest: CGFloat { MenuGutter.reserve(actions: pinnedCount, badge: hasBadge) }

    func register(_ id: UUID, showOnHover: Bool, popupOpen: Bool, inCluster: Bool = false) {
        let f = regs[id]?.focused ?? false
        regs[id] = Reg(showOnHover: showOnHover, popupOpen: popupOpen, inCluster: inCluster, focused: f)
    }
    func unregister(_ id: UUID) { regs[id] = nil }
    func setFocused(_ id: UUID, _ f: Bool) { regs[id]?.focused = f }
    func setBadge(_ b: Bool) { hasBadge = b }
}

/// Trailing-gutter math — sidebar-menu.tsx:686-706 verbatim: 8px base pad,
/// 24px slots, 4px gaps, badge's run anchored at right-2, actions right-1.5.
enum MenuGutter {
    static let pad: CGFloat = 8
    static let slot: CGFloat = 24
    static let gap: CGFloat = 4
    static let badgeInset: CGFloat = 8
    static let actionInset: CGFloat = 6
    /// right-8.5 — a standalone action's right edge when a badge owns the
    /// row's rightmost slot.
    static let actionWithBadgeInset: CGFloat = 34

    static func reserve(actions: Int, badge: Bool) -> CGFloat {
        if actions == 0 && !badge { return pad }
        let w = actions > 0
            ? CGFloat(actions) * slot + CGFloat(actions - 1) * gap
            : 0
        let run = (badge ? slot : 0) + w + (badge && actions > 0 ? gap : 0)
        return (badge ? badgeInset : actionInset) + run + gap
    }
}

// MARK: - Environment

private struct FluidMenuScopeKey: EnvironmentKey {
    static let defaultValue: FluidMenuScope? = nil
}
private struct FluidMenuFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<Int?>.Binding? = nil
}
private struct FluidMenuFocusedKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}
private struct FluidMenuRowKey: EnvironmentKey {
    static let defaultValue: FluidMenuRowState? = nil
}
private struct FluidRowLitKey: EnvironmentKey { static let defaultValue = false }
private struct FluidRowActiveKey: EnvironmentKey { static let defaultValue = false }
private struct FluidRowRevealedKey: EnvironmentKey { static let defaultValue = false }
private struct FluidRowFontKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct FluidMenuHiddenKey: EnvironmentKey { static let defaultValue = false }
private struct FluidActionClusterKey: EnvironmentKey { static let defaultValue = false }
private struct FluidClusterHoverKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
private struct FluidMenuSizeKey: EnvironmentKey {
    static let defaultValue: FluidSidebarMenuSize? = nil
}

extension EnvironmentValues {
    var fluidMenuScope: FluidMenuScope? {
        get { self[FluidMenuScopeKey.self] }
        set { self[FluidMenuScopeKey.self] = newValue }
    }
    /// The menu's focus binding — rows bind `.focused(equals:)` to it.
    var fluidMenuFocus: FocusState<Int?>.Binding? {
        get { self[FluidMenuFocusKey.self] }
        set { self[FluidMenuFocusKey.self] = newValue }
    }
    var fluidMenuFocused: Int? {
        get { self[FluidMenuFocusedKey.self] }
        set { self[FluidMenuFocusedKey.self] = newValue }
    }
    var fluidMenuRow: FluidMenuRowState? {
        get { self[FluidMenuRowKey.self] }
        set { self[FluidMenuRowKey.self] = newValue }
    }
    /// Row is hovered OR active — drives icon/label tint (lit in the source).
    var fluidRowLit: Bool {
        get { self[FluidRowLitKey.self] }
        set { self[FluidRowLitKey.self] = newValue }
    }
    /// Row is the menu's active one — the badge's `isActiveRow` tint.
    var fluidRowActive: Bool {
        get { self[FluidRowActiveKey.self] }
        set { self[FluidRowActiveKey.self] = newValue }
    }
    /// Trailing controls revealed (row hovered, focused-within, or a
    /// registered popup open).
    var fluidRowRevealed: Bool {
        get { self[FluidRowRevealedKey.self] }
        set { self[FluidRowRevealedKey.self] = newValue }
    }
    /// Resolved label size for this row (sm steps down to 12).
    var fluidRowFont: CGFloat? {
        get { self[FluidRowFontKey.self] }
        set { self[FluidRowFontKey.self] = newValue }
    }
    /// Inside a collapsed sub-menu — hidden from hover, focus, and nav.
    var fluidMenuHidden: Bool {
        get { self[FluidMenuHiddenKey.self] }
        set { self[FluidMenuHiddenKey.self] = newValue }
    }
    var fluidInActionCluster: Bool {
        get { self[FluidActionClusterKey.self] }
        set { self[FluidActionClusterKey.self] = newValue }
    }
    /// A FluidSidebarMenuActions cluster's showOnHover — overrides each
    /// action's own flag for registration (inCluster in the source).
    var fluidClusterShowOnHover: Bool? {
        get { self[FluidClusterHoverKey.self] }
        set { self[FluidClusterHoverKey.self] = newValue }
    }
    /// Per-menu size override — SidebarMenu's `size` prop ladder pin.
    var fluidSidebarMenuSize: FluidSidebarMenuSize? {
        get { self[FluidMenuSizeKey.self] }
        set { self[FluidMenuSizeKey.self] = newValue }
    }
}

// MARK: - Menu

/// The fluid-hover list. A single bg-active block morphs between whichever
/// row is marked active (the source animates one overlay per level — the
/// single-binding API keeps one). `focusRing` = the source's MenuScope
/// option: off, keyboard focus moves the hover background only.
struct FluidSidebarMenu<Content: View>: View {
    @Binding var activeIndex: Int?
    /// Omitted follows the ambient `\.fluidSize` (the source's `size?`).
    var size: FluidSize? = nil
    var focusRing = true
    /// Pins rows to one size step; nil follows the ambient FluidSize.
    var menuSize: FluidSidebarMenuSize? = nil
    @ViewBuilder var content: () -> Content

    @State private var scope = FluidMenuScope()
    @FocusState private var focused: Int?
    @State private var monitors: [Any] = []
    @Environment(\.fluidShape) private var shape

    init(activeIndex: Binding<Int?> = .constant(nil),
         size: FluidSize? = nil,
         focusRing: Bool = true,
         menuSize: FluidSidebarMenuSize? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self._activeIndex = activeIndex
        self.size = size
        self.focusRing = focusRing
        self.menuSize = menuSize
        self.content = content
    }

    /// The ring's target — nil while the pointer owns the modality. A
    /// focused trailing action keeps the ring pinned on the row (the
    /// source's focusedRowEl stays the row — its onFocus ignores
    /// non-menu-button targets).
    private var ringIndex: Int? {
        guard focusRing, !scope.pointerInput else { return nil }
        if let focused { return focused }
        return scope.rowStates.values.contains { $0.actionFocused } ? scope.lastFocusedRow : nil
    }

    var body: some View {
        FluidContainer(
            hover: scope.hover,
            // A fresh hover session fades in anchored on an active row —
            // the source's hoverAnchorRect (sidebar-menu.tsx:450-457):
            // the binding's row first, else the lowest marked-active row.
            from: activeIndex.flatMap { scope.hover.rects[$0] }
                ?? scope.activeRows.min().flatMap { scope.hover.rects[$0] },
            radius: shape.bg,
            onGapPick: gapPick
        ) {
            VStack(alignment: .leading, spacing: 0) {
                FluidMenuScopeProbe(scope: scope).frame(width: 0, height: 0)
                content()
            }
            .environment(\.fluidMenuActive, activeIndex)
            .environment(\.fluidMenuScope, scope)
            .environment(\.fluidMenuFocus, $focused)
            .environment(\.fluidMenuFocused, focused)
            .environment(\.fluidSidebarMenuSize, menuSize)
            .modifier(FluidSizePin(size: size))
        }
        .background(alignment: .topLeading) {
            // bg-active: one block per (level, occurrence) of active row —
            // the source keys actives `${levelId}:${ordinal}` so a moved
            // selection GLIDES the same block between rows (rowChanged →
            // spring.moderate) instead of exit+re-enter. Levels are the
            // sub-menu vs root groupings; ordinals count DOM order.
            let sorted = scope.activeRows.sorted()
            var counts: [Bool: Int] = [:]
            let keys = sorted.map { i -> String in
                let sub = scope.rowStates[i]?.isSubRow ?? false
                defer { counts[sub, default: 0] += 1 }
                return "\(sub ? 1 : 0):\(counts[sub, default: 0])"
            }
            ForEach(Array(zip(keys, sorted)), id: \.0) { key, i in
                if let r = scope.hover.rects[i] {
                    RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                        .fill(FluidTone.active)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .animation(FluidSpring.moderate, value: i)
                        // Blocks pop on enter (initial={false}) and fade
                        // out on exit; same-row reflows snap because the
                        // animation only keys on the row index.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            // Enter pop / exit fade ~0.12 (the source's moderate exit).
            .animation(.easeOut(duration: 0.12), value: scope.activeRows)
        }
        // The traveling ring — sidebar-menu.tsx:496-514: 1px focus-ring
        // border drawn 2px out, fast-tier glide between rows.
        .overlay(alignment: .topLeading) {
            if let i = ringIndex, let r = scope.hover.rects[i] {
                RoundedRectangle(cornerRadius: shape.focusRing, style: .continuous)
                    .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                    .frame(width: r.width + 4, height: r.height + 4)
                    .position(x: r.midX, y: r.midY)
                    // initial={false} — pops on mount, only the exit fades.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        // Row changes glide; a same-row reflow snaps (the source's
        // rowChanged rule, one animation keyed on the index).
        .animation(FluidSpring.fast, value: ringIndex)
        .onAppear { install() }
        .onDisappear {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        }
        .onChange(of: focused) { old, new in
            if let i = new {
                // onFocus: the highlight follows keyboard focus.
                scope.hover.activeIndex = i
                scope.lastFocusedRow = i
            } else if let old, scope.hover.activeIndex == old {
                // relatedTarget containment — keep the lit row while focus
                // stays inside the menu (e.g. moved to a trailing action);
                // blur to outside clears it (sidebar-menu.tsx:333-340).
                Task { @MainActor in
                    if scope.rowStates.values.contains(where: { $0.actionFocused }) { return }
                    scope.hover.activeIndex = nil
                }
            }
        }
    }

    /// Gap click — use-fluid-hover.ts:454-487: a click landing between rows
    /// (outside every registered rect) activates the highlighted row; a
    /// click inside a row belongs to the row itself.
    private func gapPick(_ i: Int) {
        guard let v = scope.view, let w = v.window else { return }
        // v is flipped, so this lands in the named space's y-down space —
        // the same space hover.rects were measured in.
        let p = v.convert(w.mouseLocationOutsideOfEventStream, from: nil)
        // Skipped (collapsed/disabled) rows keep phantom rects that can
        // overlap live content — the source's element.contains() can't
        // hit them, so they don't count here either.
        let hit = scope.hover.rects.contains { scope.skipped.contains($0.key) == false && $0.value.contains(p) }
        if hit { return }
        scope.activate(i)
    }

    /// Arrows/Home/End wrap the visible rows (sidebar-menu.tsx:344-371 —
    /// Right moves down like the source's vertical-menu fold) and
    /// Return/Space activate the focused row.
    private func install() {
        guard monitors.isEmpty else { return }
        scope.hover.isItemDisabled = { [weak scope] i in
            scope?.skipped.contains(i) ?? false
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak scope] event in
            // Window-scoped like keyDown — a click in another window
            // doesn't own this menu's modality. Pointer input also drops
            // the retained focus row (the source's onPointerDown).
            if let vw = scope?.view?.window, event.window === vw {
                scope?.pointerInput = true
                scope?.lastFocusedRow = nil
            }
            return event
        }!)
        let focus = $focused
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak scope] event in
            guard let scope, let v = scope.view,
                  let w = event.window, let vw = v.window, w === vw else { return event }
            guard w.isKeyWindow,
                  // Don't steal arrows from a field editor while armed.
                  !(w.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            // A real key aimed at this menu is keyboard modality — a key
            // swallowed by a field editor or a background window isn't.
            scope.pointerInput = false
            guard let current = focus.wrappedValue else { return event }
            let items = scope.ordered
            guard let cur = items.firstIndex(of: current) else { return event }
            let n = items.count
            let target: Int
            switch event.keyCode {
            case 123, 126: target = items[(cur - 1 + n) % n]   // ←/↑
            case 124, 125: target = items[(cur + 1) % n]       // →/↓
            case 115: target = items.first ?? current          // Home
            case 119: target = items.last ?? current           // End
            case 36, 76, 49: scope.activate(current); return nil // Return/Enter/Space
            default: return event
            }
            focus.wrappedValue = target
            return nil
        }!)
    }
}

/// Reports the hosting NSView so the scope can match its window and
/// hit-test gap clicks in the menu's named coordinate space. The probe
/// view IS flipped — convert(_:from:nil) then lands in the same y-down
/// space as SwiftUI's `proxy.frame(in:)` rects.
private struct FluidMenuScopeProbe: NSViewRepresentable {
    let scope: FluidMenuScope

    private final class View: NSView {
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let v = View()
        // The probe sits at the named space's origin (0×0 first child), so
        // v.convert gives space coordinates — superview would drift off it.
        DispatchQueue.main.async { scope.view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scope.view = nsView
    }
}

/// Which row index reads as active — published by FluidSidebarMenu.
private struct FluidMenuActiveKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}
extension EnvironmentValues {
    var fluidMenuActive: Int? {
        get { self[FluidMenuActiveKey.self] }
        set { self[FluidMenuActiveKey.self] = newValue }
    }
}

// MARK: - Row chrome (the MenuItemContext wiring)

/// The per-row wiring shared by the menu button and the sub button — the
/// source's <li>/MenuItemContext pair. Registers the row's BUTTON strip as
/// the fluid item, binds the menu's roving focus, keeps the scope's skip
/// set current, answers activation broadcasts, and overlays the trailing
/// controls over the row's reserved gutter.
private struct FluidMenuRowChrome<Trailing: View>: ViewModifier {
    let index: Int
    let disabled: Bool
    let active: Bool
    let row: FluidMenuRowState
    /// The row's own popup open (the source's menu-button[data-state=open]
    /// / [data-popup-open] freeze — comes from the button, not actions).
    var popupOpen: Bool = false
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.fluidMenuScope) private var scope
    @Environment(\.fluidMenuFocus) private var focus
    @Environment(\.fluidMenuFocused) private var menuFocused
    @Environment(\.fluidMenuHidden) private var hidden
    @Environment(\.fluidHover) private var hover

    private var skipped: Bool { disabled || hidden }
    /// :focus-visible reveal — a pointer-clicked row keeps actions hidden
    /// (focusedRowEl only sets on :focus-visible in the source). A focused
    /// clustered action reveals on :focus-within (any modality); a lone
    /// action reveals on :focus-visible (keyboard) only.
    private var revealed: Bool {
        // The hover term is the row's own :hover — not the lit index, so
        // a frozen pick can't suppress another row's reveal. A solo
        // action's focus reveals on any modality for sub rows
        // (group-focus-within/menu-sub-item, tsx:1092) and keyboard-only
        // for root rows (focus-visible). Button-level popupOpen feeds the
        // freeze only — reveal keys off registered ACTION popups.
        row.hovered
            || (menuFocused == index && scope?.pointerInput == false)
            || row.popupOpen
            || row.actionFocusedCluster
            || (row.actionFocusedSolo && (scope?.pointerInput == false || row.isSubRow))
    }

    func body(content: Content) -> some View {
        content
            .onHover { row.hovered = $0 }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: MenuGutter.gap) { trailing() }
                    .padding(.trailing, row.hasBadge ? MenuGutter.badgeInset : MenuGutter.actionInset)
                    .environment(\.fluidRowRevealed, revealed)
                    .environment(\.fluidRowActive, active)
            }
            .environment(\.fluidMenuRow, row)
            .fluidItem(index)
            .modifier(FluidMenuFocusable(index: index, enabled: !skipped))
            .onAppear {
                scope?.setSkipped(index, skipped)
                scope?.setActive(index, active)
                scope?.setPopupRow(index, row.popupOpen || popupOpen)
                scope?.rowStates[index] = row
            }
            .onDisappear {
                scope?.setSkipped(index, false)
                scope?.setActive(index, false)
                scope?.setPopupRow(index, false)
                scope?.rowStates[index] = nil
            }
            .onChange(of: skipped) { _, s in scope?.setSkipped(index, s) }
            .onChange(of: active) { _, a in scope?.setActive(index, a) }
            .onChange(of: row.popupOpen || popupOpen) { _, p in
                scope?.setPopupRow(index, p)
            }
            .onChange(of: scope?.pendingActivation) { _, p in
                guard let p, p.index == index, !skipped else { return }
                action()
            }
    }
}

extension View {
    fileprivate func fluidMenuRow<Trailing: View>(
        index: Int, disabled: Bool, active: Bool, row: FluidMenuRowState,
        popupOpen: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        modifier(FluidMenuRowChrome(
            index: index, disabled: disabled, active: active,
            row: row, popupOpen: popupOpen, action: action, trailing: trailing
        ))
    }
}

/// Roving focus: rows are the menu's stops. Skipped rows aren't focusable;
/// the system ring is suppressed in favor of the scope's traveling one.
private struct FluidMenuFocusable: ViewModifier {
    let index: Int
    let enabled: Bool
    @Environment(\.fluidMenuFocus) private var focus

    func body(content: Content) -> some View {
        if let focus {
            content
                .focusable(enabled)
                .focused(focus, equals: index)
                .focusEffectDisabled()
        } else {
            content.focusable(enabled)
        }
    }
}

// MARK: - Menu button

/// sidebarMenuButtonVariants (sidebar-menu.tsx:849-867).
enum FluidSidebarMenuButtonVariant { case `default`, outline }

/// The button's explicit size steps — sm h-7 / default h-8 / lg h-12 —
/// FluidSize has no third rung, so the menu keeps its own ladder.
enum FluidSidebarMenuSize {
    case small, regular, large

    var height: CGFloat { self == .small ? 28 : self == .large ? 48 : 32 }
}

/// Visual-only dot override (the source's `dot` prop) — filled or ring,
/// superseding the status-derived dot, ignored when an icon is set.
enum FluidSidebarMenuDot { case filled, ring }

/// The ghost-weight row label — the source's MenuRowLabel: an invisible
/// semibold twin reserves the width and the visible label animates weight,
/// so a lit row never reflows. Text-box trimming is dropped (SwiftUI's
/// Text doesn't trim to cap height).
struct FluidSidebarMenuRowLabel: View {
    let label: String
    @Environment(\.fluidRowLit) private var lit
    @Environment(\.fluidRowActive) private var active
    @Environment(\.fluidRowFont) private var font
    @Environment(\.fluidSize) private var size

    var body: some View {
        let s = font ?? size.text
        ZStack {
            Text(label).font(.system(size: s, weight: .semibold)).hidden()
            Text(label)
                .font(.system(size: s, weight: active ? .semibold : .regular))
                .foregroundStyle(lit || active ? FluidTone.foreground : FluidTone.mutedForeground)
        }
        .lineLimit(1).truncationMode(.tail)
        // transition-[color,font-variation-settings] duration-80 covers
        // lit swaps too — keyed separately so an active flip on an
        // already-lit row still eases (lit||active stays true).
        .animation(.easeOut(duration: 0.08), value: lit)
        .animation(.easeOut(duration: 0.08), value: active)
    }
}

/// `SidebarMenuButton` — one menu row: icon (or status dot), label, and a
/// trailing gutter that reserves exactly the space its badge/actions need
/// once revealed. `index` registers it with the enclosing menu's hover and
/// keyboard scope. Trailing content is usually FluidSidebarMenuActions /
/// FluidSidebarMenuBadge.
struct FluidSidebarMenuButton<Label: View, Trailing: View>: View {
    let index: Int
    var icon: String? = nil
    var status: FluidSidebarStatus? = nil
    var dot: FluidSidebarMenuDot? = nil
    var variant: FluidSidebarMenuButtonVariant = .default
    var size: FluidSidebarMenuSize? = nil
    var isActive: Bool? = nil
    var disabled = false
    /// Row-hosted popup open (menu-button[data-state=open]) — freezes the
    /// hover pick on this row like a registered action's popup does.
    var popupOpen = false
    var action: () -> Void = {}
    @ViewBuilder var label: () -> Label
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidMenuActive) private var menuActive
    @Environment(\.fluidMenuFocus) private var focus
    @Environment(\.fluidMenuScope) private var scope
    @Environment(\.fluidSize) private var fluidSize
    @Environment(\.fluidSidebarMenuSize) private var envMenuSize
    @Environment(\.fluidShape) private var shape

    @State private var row = FluidMenuRowState()

    init(index: Int, icon: String? = nil, status: FluidSidebarStatus? = nil,
         dot: FluidSidebarMenuDot? = nil,
         variant: FluidSidebarMenuButtonVariant = .default,
         size: FluidSidebarMenuSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {},
         @ViewBuilder label: @escaping () -> Label,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.index = index
        self.icon = icon
        self.status = status
        self.dot = dot
        self.variant = variant
        self.size = size
        self.isActive = isActive
        self.disabled = disabled
        self.popupOpen = popupOpen
        self.action = action
        self.label = label
        self.trailing = trailing
    }

    private var compact: Bool { fluidSize == .compact }
    private var menuSize: FluidSidebarMenuSize {
        size ?? envMenuSize ?? (compact ? .small : .regular)
    }
    /// status="active" implies the active row too (source's effectiveActive).
    private var active: Bool { (isActive ?? (menuActive == index)) || status == .active }
    /// Hovered OR active — drives icon/label tint (lit in the source).
    private var lit: Bool { active || hover?.activeIndex == index }
    /// The gutter reservation is modality-agnostic — the source's
    /// group-focus-within pad grows even when actions stay hidden.
    /// Reveal itself lives in the row chrome (fluidRowRevealed).
    private var gutterExpanded: Bool {
        row.hovered
            || focus?.wrappedValue == index
            || row.popupOpen
            || row.actionFocused
    }
    private var gutter: CGFloat { gutterExpanded ? row.gutterHover : row.gutterRest }
    /// sm drops the label to 12px; otherwise it follows the size ladder.
    private var textSize: CGFloat { menuSize == .small ? 12 : fluidSize.text }

    var body: some View {
        Button {
            // A click focuses the row (DOM focus on mousedown), then runs.
            focus?.wrappedValue = index
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    FluidIcon(icon, size: fluidSize.icon, bold: lit)
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .frame(width: fluidSize.icon, height: fluidSize.icon)
                        .animation(.easeOut(duration: 0.08), value: lit)
                        .animation(.easeOut(duration: 0.08), value: active)
                } else if let dot = resolvedDot {
                    statusDot(dot)
                }
                label()
                    .environment(\.fluidRowLit, lit)
                    .environment(\.fluidRowActive, active)
                    .environment(\.fluidRowFont, textSize)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            // The exact trailing reservation — grows when the row reveals
            // its actions, so the label never sits under them.
            .padding(.trailing, gutter)
            .frame(height: menuSize.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if variant == .outline {
                    // border-border bg-background.
                    RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                        .fill(FluidTone.background)
                    RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                        .strokeBorder(FluidTone.border, lineWidth: 1)
                }
            }
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.08), value: gutterExpanded) // transition-[padding] duration-80
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        // The source's sr-only ", unread" suffix (tsx:996).
        .accessibilityValue(status == .unread ? "unread" : "")
        .fluidMenuRow(index: index, disabled: disabled, active: active,
                      row: row, popupOpen: popupOpen, action: action) {
            trailing()
        }
    }

    /// status="active" implies the row-active treatment; an explicit dot
    /// overrides the status-derived one (resolvedDot).
    private var resolvedDot: FluidSidebarMenuDot? {
        dot ?? status.map { $0 == .idle ? .ring : .filled }
    }

    /// 8px status dot: filled for active/unread, ring for idle.
    private func statusDot(_ dot: FluidSidebarMenuDot) -> some View {
        ZStack {
            if dot == .filled {
                Circle().fill(
                    lit ? FluidTone.foreground.opacity(0.6) : FluidTone.mutedForeground.opacity(0.5))
            } else {
                Circle().strokeBorder(
                    lit ? FluidTone.foreground.opacity(0.6) : FluidTone.mutedForeground.opacity(0.5),
                    lineWidth: 1)
            }
        }
        .frame(width: 8, height: 8)
        .frame(width: fluidSize.icon, height: fluidSize.icon)
        .animation(.easeOut(duration: 0.08), value: lit)
    }
}

extension FluidSidebarMenuButton {
    /// String label — renders the ghost-weight FluidSidebarMenuRowLabel.
    init(index: Int, label text: String, icon: String? = nil,
         status: FluidSidebarStatus? = nil, dot: FluidSidebarMenuDot? = nil,
         variant: FluidSidebarMenuButtonVariant = .default,
         size: FluidSidebarMenuSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {},
         @ViewBuilder trailing: @escaping () -> Trailing)
    where Label == FluidSidebarMenuRowLabel {
        self.init(index: index, icon: icon, status: status, dot: dot,
                  variant: variant, size: size, isActive: isActive,
                  disabled: disabled, popupOpen: popupOpen, action: action,
                  label: { FluidSidebarMenuRowLabel(label: text) },
                  trailing: trailing)
    }

    init(index: Int, icon: String? = nil, status: FluidSidebarStatus? = nil,
         dot: FluidSidebarMenuDot? = nil,
         variant: FluidSidebarMenuButtonVariant = .default,
         size: FluidSidebarMenuSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {},
         @ViewBuilder label: @escaping () -> Label)
    where Trailing == EmptyView {
        self.init(index: index, icon: icon, status: status, dot: dot,
                  variant: variant, size: size, isActive: isActive,
                  disabled: disabled, popupOpen: popupOpen, action: action,
                  label: label, trailing: { EmptyView() })
    }

    init(index: Int, label text: String, icon: String? = nil,
         status: FluidSidebarStatus? = nil, dot: FluidSidebarMenuDot? = nil,
         variant: FluidSidebarMenuButtonVariant = .default,
         size: FluidSidebarMenuSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {})
    where Label == FluidSidebarMenuRowLabel, Trailing == EmptyView {
        self.init(index: index, icon: icon, status: status, dot: dot,
                  variant: variant, size: size, isActive: isActive,
                  disabled: disabled, popupOpen: popupOpen, action: action,
                  label: { FluidSidebarMenuRowLabel(label: text) },
                  trailing: { EmptyView() })
    }
}

// MARK: - Menu item

/// One menu row: icon (or status dot), label, optional badge + trailing
/// actions. Composes the button over an optional hosted sub-menu — the
/// source's <li> that wraps a button and its <ul>; the hover rect stays on
/// the button strip alone.
struct FluidSidebarMenuItem: View {
    let index: Int
    let label: String
    var icon: String? = nil
    /// Semantic dot when no icon: active/unread → filled, idle → ring.
    var status: FluidSidebarStatus? = nil
    var badge: String? = nil
    var actionIcon: String? = nil
    var onAction: () -> Void = {}
    var disabled = false
    var variant: FluidSidebarMenuButtonVariant = .default
    var size: FluidSidebarMenuSize? = nil
    var dot: FluidSidebarMenuDot? = nil
    var isActive: Bool? = nil
    var popupOpen = false
    /// Extra trailing actions — each self-registers the gutter slot.
    var actions: [FluidSidebarMenuAction] = []
    private var subMenu: (() -> AnyView)? = nil
    var action: () -> Void = {}

    init(index: Int, label: String, icon: String? = nil,
         status: FluidSidebarStatus? = nil, badge: String? = nil,
         actionIcon: String? = nil, onAction: @escaping () -> Void = {},
         disabled: Bool = false,
         variant: FluidSidebarMenuButtonVariant = .default,
         size: FluidSidebarMenuSize? = nil, dot: FluidSidebarMenuDot? = nil,
         isActive: Bool? = nil, popupOpen: Bool = false,
         action: @escaping () -> Void = {}) {
        self.index = index
        self.label = label
        self.icon = icon
        self.status = status
        self.badge = badge
        self.actionIcon = actionIcon
        self.onAction = onAction
        self.disabled = disabled
        self.variant = variant
        self.size = size
        self.dot = dot
        self.isActive = isActive
        self.popupOpen = popupOpen
        self.action = action
    }

    /// Trailing action cluster without a sub-menu.
    init(index: Int, label: String, icon: String? = nil,
         status: FluidSidebarStatus? = nil, badge: String? = nil,
         actionIcon: String? = nil, onAction: @escaping () -> Void = {},
         disabled: Bool = false,
         variant: FluidSidebarMenuButtonVariant = .default,
         size: FluidSidebarMenuSize? = nil, dot: FluidSidebarMenuDot? = nil,
         isActive: Bool? = nil, popupOpen: Bool = false,
         actions: [FluidSidebarMenuAction],
         action: @escaping () -> Void = {}) {
        self.init(index: index, label: label, icon: icon, status: status,
                  badge: badge, actionIcon: actionIcon, onAction: onAction,
                  disabled: disabled, variant: variant, size: size, dot: dot,
                  isActive: isActive, popupOpen: popupOpen,
                  action: action)
        self.actions = actions
    }

    /// With a hosted sub-menu below the row — `subMenu:` is a regular
    /// argument so the trailing closure stays `action`.
    init<Sub: View>(index: Int, label: String, icon: String? = nil,
         status: FluidSidebarStatus? = nil, badge: String? = nil,
         actionIcon: String? = nil, onAction: @escaping () -> Void = {},
         disabled: Bool = false,
         variant: FluidSidebarMenuButtonVariant = .default,
         size: FluidSidebarMenuSize? = nil, dot: FluidSidebarMenuDot? = nil,
         isActive: Bool? = nil, popupOpen: Bool = false,
         actions: [FluidSidebarMenuAction] = [],
         subMenu: (() -> Sub)? = nil,
         action: @escaping () -> Void = {}) {
        self.init(index: index, label: label, icon: icon, status: status,
                  badge: badge, actionIcon: actionIcon, onAction: onAction,
                  disabled: disabled, variant: variant, size: size, dot: dot,
                  isActive: isActive, popupOpen: popupOpen,
                  action: action)
        self.actions = actions
        if let subMenu { self.subMenu = { AnyView(subMenu()) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FluidSidebarMenuButton(index: index, icon: icon, status: status,
                                   dot: dot, variant: variant, size: size,
                                   isActive: isActive, disabled: disabled,
                                   popupOpen: popupOpen, action: action) {
                FluidSidebarMenuRowLabel(label: label)
            } trailing: {
                if let actionIcon {
                    FluidSidebarMenuAction(actionIcon, showOnHover: true, action: onAction)
                }
                ForEach(actions.indices, id: \.self) { actions[$0] }
                if let badge {
                    FluidSidebarMenuBadge(badge)
                }
            }
            if let subMenu { subMenu() }
        }
    }
}

// MARK: - Trailing controls

/// `SidebarMenuAction` — a 24px ghost icon button sitting in the row's
/// gutter; its own hover bg + bold, never activates the row. `showOnHover`
/// hides it until the row is revealed (hovered, focused, or a registered
/// popup open); `popupOpen` pins it while a popup it opened is up.
struct FluidSidebarMenuAction: View {
    let icon: String
    var showOnHover = false
    var popupOpen = false
    var action: () -> Void = {}

    @Environment(\.fluidMenuRow) private var row
    @Environment(\.fluidMenuScope) private var scope
    @Environment(\.fluidRowRevealed) private var revealed
    @Environment(\.fluidInActionCluster) private var inCluster
    @Environment(\.fluidClusterShowOnHover) private var clusterHover
    @Environment(\.fluidMenuFocused) private var menuFocused
    @Environment(\.fluidSize) private var size
    @Environment(\.fluidShape) private var shape
    @State private var id = UUID()
    @State private var hovered = false
    @FocusState private var focused: Bool

    init(_ icon: String, showOnHover: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {}) {
        self.icon = icon
        self.showOnHover = showOnHover
        self.popupOpen = popupOpen
        self.action = action
    }

    /// The cluster's flag wins inside one (inCluster in the source).
    private var effectiveShowOnHover: Bool { clusterHover ?? showOnHover }
    private var visible: Bool {
        inCluster || !effectiveShowOnHover || revealed
    }

    var body: some View {
        Button(action: action) {
            FluidIcon(icon, size: size.icon, bold: hovered)
                .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
        }
        .buttonStyle(.plain)
        .frame(width: MenuGutter.slot, height: MenuGutter.slot)
        // size-6 hover bg (the source hovers the whole 24px box, not the
        // 20px glyph frame) — rounded on shape.item.
        .background(
            RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                .fill(hovered ? FluidTone.hover : .clear)
        )
        // focus-visible:ring-1 — the source's 1px ring on the action box,
        // keyboard modality only.
        .overlay(
            RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .opacity(focused && scope?.pointerInput == false ? 1 : 0)
        )
        // Absolute in the source — top-1, or top-0.5 on sub/compact rows.
        .padding(.top, (row?.isSubRow ?? false) || size == .compact ? 2 : 4)
        // With a badge on the row, the source pins the action's right edge
        // at right-8.5 (34px) instead of flowing badge-relative — the badge
        // keeps right-2's rightmost spot (tsx:1074-1075).
        .padding(.trailing, !inCluster && (row?.hasBadge ?? false)
            ? max(0, MenuGutter.actionWithBadgeInset - MenuGutter.badgeInset
                    - (row?.badgeWidth ?? 20) - MenuGutter.gap)
            : 0)
        .contentShape(Rectangle())
        // Tabbable like the source's actions — focus publishes to the row
        // so focus-within keeps the cluster revealed.
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, f in
            row?.setFocused(id, f)
            if !f {
                // Blur leg of the source's relatedTarget rule: when the
                // action was the last focused thing in the menu and focus
                // left entirely, the lit row clears (sidebar-menu.tsx:333).
                Task { @MainActor in
                    guard let scope, menuFocused == nil,
                          !scope.rowStates.values.contains(where: { $0.actionFocused })
                    else { return }
                    scope.hover.activeIndex = nil
                }
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.08)) { hovered = h } }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.08), value: visible)
        .onAppear { register() }
        .onDisappear { row?.unregister(id) }
        .onChange(of: popupOpen) { _, _ in register() }
        .onChange(of: effectiveShowOnHover) { _, _ in register() }
    }

    private func register() {
        row?.register(id, showOnHover: effectiveShowOnHover,
                      popupOpen: popupOpen, inCluster: inCluster)
    }
}

/// `SidebarMenuActions` — the row-level cluster for more than one action:
/// owns the reveal as a unit (hover / focus-within / nested popup open)
/// and lets the row reserve the whole run in its gutter.
struct FluidSidebarMenuActions<Content: View>: View {
    var showOnHover = false
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidRowRevealed) private var revealed
    @Environment(\.fluidMenuRow) private var row

    init(showOnHover: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.showOnHover = showOnHover
        self.content = content
    }

    var body: some View {
        HStack(spacing: MenuGutter.gap) { content() }
            // A badge on the row pushes the cluster's right edge to
            // right-8.5 too (same rule standalone actions get).
            .padding(.trailing, (row?.hasBadge ?? false)
                ? max(0, MenuGutter.actionWithBadgeInset - MenuGutter.badgeInset
                        - (row?.badgeWidth ?? 20) - MenuGutter.gap)
                : 0)
            .opacity(!showOnHover || revealed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: revealed)
            .environment(\.fluidInActionCluster, true)
            .environment(\.fluidClusterShowOnHover, showOnHover)
    }
}

/// `SidebarMenuBadge` — the rightmost trailing slot (right-2, min-w-5,
/// h-5, tabular digits). Lights up only on the row's ACTIVE state, like
/// the source's isActiveRow tint.
struct FluidSidebarMenuBadge: View {
    let text: String
    @Environment(\.fluidMenuRow) private var row
    @Environment(\.fluidRowActive) private var active
    @Environment(\.fluidSize) private var size

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: size == .compact ? 10 : 11,
                          weight: active ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(active ? FluidTone.foreground : FluidTone.mutedForeground)
            .lineLimit(1)
            // min-w-5 px-1 — grows past the 24px run for long text,
            // exactly like the source.
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.top, size == .compact ? 4 : 6)
            .animation(.easeOut(duration: 0.08), value: active)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                row?.badgeWidth = $0
            }
            .onAppear { row?.setBadge(true) }
            .onDisappear { row?.setBadge(false) }
    }
}

// MARK: - Skeleton

/// `SidebarMenuSkeleton` — a loading row: 16px icon block + a text bar on a
/// deterministic width cycle (the source hashes useId for SSR stability; a
/// process sequence does the same here). The bar's % width is measured off
/// the row — containerRelativeFrame collapses the whole pane inside the
/// AppKit-backed scroll hierarchy.
struct FluidSidebarMenuSkeleton: View {
    var showIcon = false
    private let widthIndex: Int

    @Environment(\.fluidSize) private var size
    /// The row's measured width so the bar can take the source's %.
    @State private var rowWidth: CGFloat = 0

    private static let widths: [CGFloat] = [0.62, 0.74, 0.55, 0.82, 0.68]
    private enum Seq {
        nonisolated(unsafe) static var next = 0
        static func take() -> Int { defer { next += 1 }; return next }
    }

    init(showIcon: Bool = false, widthIndex: Int? = nil) {
        self.showIcon = showIcon
        self.widthIndex = widthIndex ?? Seq.take()
    }

    var body: some View {
        HStack(spacing: 8) {
            if showIcon { bar.frame(width: 16, height: 16) }
            bar
                .frame(width: max(24, (rowWidth - 16) * Self.widths[widthIndex % Self.widths.count]),
                       height: 16)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: size == .compact ? 28 : 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            rowWidth = $0
        }
        // animate-pulse — the whole row breathes opacity (2s, source's
        // cubic-bezier(0.4,0,0.6,1) ≈ easeInOut).
        .opacity(pulsing ? 0.5 : 1)
        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
    }

    @State private var pulsing = false

    private var bar: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(FluidTone.hover)
    }
}

// MARK: - Sub-menu

/// Indented sub-items on a 1px left rail (ml-15px + border-l + pl-8 in the
/// source lands the label under the parent's text). `open` is the built-in
/// measured-height collapse: content stays mounted (rows stay registered
/// and skipped — the source's rowHidden), the frame animates to the
/// content's real height only when this sub-tree itself toggles.
struct FluidSidebarSubMenu<Content: View>: View {
    var open = true
    var size: FluidSize? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidMenuHidden) private var hidden
    @State private var contentHeight: CGFloat? = nil

    init(open: Bool = true, size: FluidSize? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.open = open
        self.size = size
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            // The rail is an overlay and doesn't consume the 1px the
            // source's border-l does — ul-pad is 9 so content still
            // lands at 15+1+8=24 before the row's own pad.
            .padding(.leading, 9)
            .overlay(alignment: .leading) {
                Rectangle().fill(FluidTone.border).frame(width: 1)
            }
            // ml-[15px] rail margin + the sub-row's own pl-2 (8px) land
            // the label at the source's 32px (15+1 rail + 8 + 8 row pad).
            .padding(.leading, 15)
            // rowHidden is ancestor-or — a closed ancestor above this
            // sub-menu must still hide its rows. (Divergence: we also OR
            // collapsed-GROUP hidden state — the source only marks
            // menu-sub[data-state=closed]; ours is a strict superset that
            // matches the visual collapse.)
            .environment(\.fluidMenuHidden, hidden || !open)
            .modifier(FluidSizePin(size: size))
            .accessibilityHidden(!open)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                contentHeight = $0
            }
            .frame(height: open ? contentHeight : 0, alignment: .top)
            .clipped()
            .opacity(open ? 1 : 0)
            // Springs only when THIS sub-tree toggles — a re-measure from a
            // nested collapse snaps (the source's togglingRef rule).
            .animation(FluidSpring.moderate, value: open)
    }
}

/// Pins `\.fluidSize` only when the caller actually passed one — omitted
/// means inherit the ambient provider (the source's `size?` prop).
private struct FluidSizePin: ViewModifier {
    let size: FluidSize?
    func body(content: Content) -> some View {
        if let size { content.environment(\.fluidSize, size) } else { content }
    }
}

/// The sub-row's explicit size steps — sm h-6 / md h-7.
enum FluidSidebarSubButtonSize {
    case small, medium

    var height: CGFloat { self == .small ? 24 : 28 }
}

/// `SidebarMenuSubButton` — same chrome as the menu button on the shorter
/// row (h-6 sm / h-7 md, 24 under compact), same gutter rules, same roving
/// focus — sub rows share the menu's ordered keyboard sequence.
struct FluidSidebarSubButton<Label: View, Trailing: View>: View {
    let index: Int
    var icon: String? = nil
    var size: FluidSidebarSubButtonSize? = nil
    var isActive: Bool? = nil
    var disabled = false
    /// Row-hosted popup open — same freeze rule as the menu button.
    var popupOpen = false
    var action: () -> Void = {}
    @ViewBuilder var label: () -> Label
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidMenuActive) private var menuActive
    @Environment(\.fluidMenuFocus) private var focus
    @Environment(\.fluidMenuScope) private var scope
    @Environment(\.fluidSize) private var fluidSize

    @State private var row = FluidMenuRowState(isSubRow: true)

    init(index: Int, icon: String? = nil,
         size: FluidSidebarSubButtonSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {},
         @ViewBuilder label: @escaping () -> Label,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.index = index
        self.icon = icon
        self.size = size
        self.isActive = isActive
        self.disabled = disabled
        self.popupOpen = popupOpen
        self.action = action
        self.label = label
        self.trailing = trailing
    }

    private var compact: Bool { fluidSize == .compact }
    private var short: Bool { size == .small || compact }
    private var active: Bool { isActive ?? (menuActive == index) }
    private var lit: Bool { active || hover?.activeIndex == index }
    /// The gutter reservation is modality-agnostic — the source's
    /// group-focus-within pad grows even when actions stay hidden.
    /// Reveal itself lives in the row chrome (fluidRowRevealed).
    private var gutterExpanded: Bool {
        row.hovered
            || focus?.wrappedValue == index
            || row.popupOpen
            || row.actionFocused
    }
    private var gutter: CGFloat { gutterExpanded ? row.gutterHover : row.gutterRest }
    /// sm drops the label to 12px; sub-rows otherwise keep the parent's size.
    private var textSize: CGFloat { size == .small ? 12 : fluidSize.text }

    var body: some View {
        Button {
            focus?.wrappedValue = index
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    FluidIcon(icon, size: fluidSize.icon, bold: lit)
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .frame(width: fluidSize.icon, height: fluidSize.icon)
                        .animation(.easeOut(duration: 0.08), value: lit)
                        .animation(.easeOut(duration: 0.08), value: active)
                }
                label()
                    .environment(\.fluidRowLit, lit)
                    .environment(\.fluidRowActive, active)
                    .environment(\.fluidRowFont, textSize)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, gutter)
            .frame(height: short ? 24 : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.08), value: gutterExpanded)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .fluidMenuRow(index: index, disabled: disabled, active: active,
                      row: row, popupOpen: popupOpen, action: action) {
            trailing()
        }
    }
}

extension FluidSidebarSubButton {
    init(index: Int, label text: String, icon: String? = nil,
         size: FluidSidebarSubButtonSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {},
         @ViewBuilder trailing: @escaping () -> Trailing)
    where Label == FluidSidebarMenuRowLabel {
        self.init(index: index, icon: icon, size: size, isActive: isActive,
                  disabled: disabled, popupOpen: popupOpen, action: action,
                  label: { FluidSidebarMenuRowLabel(label: text) },
                  trailing: trailing)
    }

    init(index: Int, label text: String, icon: String? = nil,
         size: FluidSidebarSubButtonSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         action: @escaping () -> Void = {})
    where Label == FluidSidebarMenuRowLabel, Trailing == EmptyView {
        self.init(index: index, icon: icon, size: size, isActive: isActive,
                  disabled: disabled, popupOpen: popupOpen, action: action,
                  label: { FluidSidebarMenuRowLabel(label: text) },
                  trailing: { EmptyView() })
    }
}

/// Convenience row for a sub-menu — label, optional badge, same chrome as
/// the menu item's compact form.
struct FluidSidebarSubItem: View {
    let index: Int
    let label: String
    var icon: String? = nil
    var badge: String? = nil
    var size: FluidSidebarSubButtonSize? = nil
    var isActive: Bool? = nil
    var popupOpen = false
    var disabled = false
    var actions: [FluidSidebarMenuAction] = []
    var action: () -> Void = {}

    init(index: Int, label: String, icon: String? = nil, badge: String? = nil,
         size: FluidSidebarSubButtonSize? = nil, isActive: Bool? = nil,
         disabled: Bool = false, popupOpen: Bool = false,
         actions: [FluidSidebarMenuAction] = [],
         action: @escaping () -> Void = {}) {
        self.index = index
        self.label = label
        self.icon = icon
        self.badge = badge
        self.size = size
        self.isActive = isActive
        self.popupOpen = popupOpen
        self.disabled = disabled
        self.actions = actions
        self.action = action
    }

    var body: some View {
        FluidSidebarSubButton(index: index, icon: icon, size: size,
                              isActive: isActive, disabled: disabled,
                              popupOpen: popupOpen, action: action) {
            FluidSidebarMenuRowLabel(label: label)
        } trailing: {
            ForEach(actions.indices, id: \.self) { actions[$0] }
            if let badge {
                FluidSidebarMenuBadge(badge)
            }
        }
    }
}

enum FluidSidebarStatus { case active, unread, idle }

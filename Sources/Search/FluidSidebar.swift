import AppKit
import SwiftUI

// Sidebar pane — fluid-demo/components/ui/sidebar.tsx + the SidebarShell
// (sidebar-core.tsx:521-847): the in-flow column whose width spring reflows
// the inset sibling, the inner-edge resize/collapse rail, the floating and
// inset variants, side mirroring, and the collapsed-peek edge strip +
// overlay card wired onto FluidSidebarState's peek machinery.
//
// The pane drives FluidSidebarState when one is in scope (the `state:`
// param or the \.fluidSidebar env from FluidSidebarProvider); the plain
// `FluidSidebar(open:width:)` binding path still works statelessly — same
// chrome, minus the state-only features (peek overlay, shortcut key,
// isResizing tracking, provider persistence).
//
// Deliberately N/A on macOS:
//   - SidebarSheet / isMobile drawer (sidebar.tsx:36-138).
//   - data-*/aria attrs — FluidSidebarInset reads the state object instead
//     of peer-data selectors; `registerSide` becomes syncConfig().
//   - `order-last` — DOM order is the caller's: put FluidSidebar after the
//     content when side == .right (same rule as the source).

// MARK: - Pane

struct FluidSidebar<Content: View>: View {
    /// Binding-driven open/width — used on the stateless path; a resolved
    /// FluidSidebarState wins (its own open/width may proxy bindings).
    @Binding var open: Bool
    @Binding var width: CGFloat
    var minWidth: CGFloat = FluidSidebarMetrics.minWidth
    var maxWidth: CGFloat = FluidSidebarMetrics.maxWidth
    /// Drag past (minWidth - slop) collapses; drag back out reopens.
    var collapseSlop: CGFloat = FluidSidebarMetrics.collapseSlop
    /// Explicit state; nil falls back to \.fluidSidebar.
    var state: FluidSidebarState? = nil
    var side: FluidSidebarSide = .left
    var variant: FluidSidebarVariant = .sidebar
    var collapsible: FluidSidebarCollapsible = .offcanvas
    /// The `sidebar` variant's inner-edge hairline (sidebar.tsx:152).
    var bordered = true
    /// The built-in resize/collapse rail (sidebar.tsx:157).
    var rail = true
    /// Pin the rail's tooltip open/closed; nil = hover (railTooltipOpen).
    var railTooltipOpen: Bool? = nil
    /// The surface level under the sidebar — the floating card and the peek
    /// overlay paint at substrate+1 (floatingLevel, sidebar-core.tsx:597).
    var substrate = 0
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidSidebar) private var env
    @Environment(\.fluidShape) private var shape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Stateless-drag bookkeeping — the stateful rail keeps its own.
    @State private var dragging = false
    @State private var moved = false
    @State private var collapsedPreview = false
    @State private var startWidth: CGFloat = 0
    @State private var startOpen = true
    // Peek edge-strip hover/focus.
    @State private var stripHover = false
    @FocusState private var stripFocused: Bool

    init(open: Binding<Bool>? = nil, width: Binding<CGFloat>? = nil,
         minWidth: CGFloat = FluidSidebarMetrics.minWidth,
         maxWidth: CGFloat = FluidSidebarMetrics.maxWidth,
         collapseSlop: CGFloat = FluidSidebarMetrics.collapseSlop,
         state: FluidSidebarState? = nil,
         side: FluidSidebarSide = .left,
         variant: FluidSidebarVariant = .sidebar,
         collapsible: FluidSidebarCollapsible = .offcanvas,
         bordered: Bool = true,
         rail: Bool = true,
         railTooltipOpen: Bool? = nil,
         substrate: Int = 0,
         @ViewBuilder content: @escaping () -> Content) {
        self._open = open ?? .constant(true)
        self._width = width ?? .constant(FluidSidebarMetrics.width) // 16rem
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.collapseSlop = collapseSlop
        self.state = state
        self.side = side
        self.variant = variant
        self.collapsible = collapsible
        self.bordered = bordered
        self.rail = rail
        self.railTooltipOpen = railTooltipOpen
        self.substrate = substrate
        self.content = content
    }

    private var resolved: FluidSidebarState? { state ?? env }
    private var isOpen: Bool { resolved?.open ?? open }
    private var liveWidth: CGFloat { resolved?.width ?? width }
    private var resizing: Bool { resolved?.isResizing ?? dragging }
    private var left: Bool { side == .left }
    private var floating: Bool { variant == .floating }
    private var floatingLevel: Int { min(substrate + 1, 8) }
    /// The panel edge toward the sibling content — trailing for a left
    /// sidebar, leading for a right one.
    private var innerEdge: Alignment { left ? .trailing : .leading }

    /// peekEnabled (sidebar-core.tsx:550): the collapsed shell swaps its
    /// column for the edge strip + overlay card — suppressed mid-resize so
    /// a drag's collapse preview can't unmount the rail holding it.
    private var peekEnabled: Bool {
        guard let st = resolved, collapsible == .offcanvas else { return false }
        return st.peek != .none && !isOpen && !st.isResizing
    }

    /// z-40 + lifted clip while peek is armed — and through the
    /// pin-from-peek width spring, so the card the shell is growing into
    /// doesn't wipe through a mask it never left (sidebar-core.tsx:672).
    private var peekArmed: Bool { peekEnabled || (resolved?.pinFromPeekHold ?? false) }

    /// The shell's width transition (sidebar-core.tsx:639-649): slow for
    /// open/close; while resizing, open flips (the rail's collapse preview
    /// and its drag-back rescue) ride moderate instead of glued tracking.
    private var openAnimation: Animation? {
        if reduceMotion { return nil }
        if resizing { return isOpen ? FluidSpring.moderate : .spring(duration: 0.12, bounce: 0) }
        return isOpen ? FluidSpring.slow : .spring(duration: 0.16, bounce: 0)
    }

    /// The overlay card's transition — enter moderate, exit moderate.exit,
    /// regardless of who flipped isPeeking (sidebar-core.tsx:767-769).
    private var peekAnimation: Animation? {
        if reduceMotion { return nil }
        return (resolved?.isPeeking ?? false)
            ? FluidSpring.moderate
            : .spring(duration: 0.12, bounce: 0)
    }

    /// Equatable bundle so one onChange covers every pushed field.
    private var pushedConfig: FluidSidebarConfig {
        FluidSidebarConfig(side: side, variant: variant, collapsible: collapsible,
                           minWidth: minWidth, maxWidth: maxWidth,
                           collapseSlop: collapseSlop)
    }

    /// registerSide + the rest (sidebar.tsx:169): the pane's side, variant,
    /// collapsible and width bounds all live on the state so the rail, the
    /// inset sibling, and the shortcut resolve them identically.
    private func syncConfig() {
        guard let st = resolved else { return }
        st.side = side
        st.variant = variant
        st.collapsible = collapsible
        st.minWidth = minWidth
        st.maxWidth = maxWidth
        st.collapseSlop = collapseSlop
        // A persisted or bound width can predate the bounds being pushed —
        // clamp when they land, or a stale 2000px restore holds the column
        // at an unusable size until the next drag.
        if st.width < minWidth || st.width > maxWidth {
            st.setWidth(min(max(st.width, minWidth), maxWidth))
        }
    }

    var body: some View {
        Group {
            if collapsible == .none { fixedColumn } else { shell }
        }
        .frame(maxHeight: .infinity)
        .environment(\.fluidSidebar, resolved)
        // The probe scopes the shortcut key and the peek watchers to the
        // sidebar's own window.
        .background { if let st = resolved { FluidSidebarProbe(state: st) } }
        .task(id: resolved.map(ObjectIdentifier.init)) { syncConfig() }
        .onChange(of: pushedConfig) { _, _ in syncConfig() }
        // Catches open writes that bypassed setOpen (external binding flip).
        .onChange(of: isOpen) { _, _ in resolved?.openDidChange() }
    }

    // MARK: collapsible="none" — fixed column, no rail, no collapse
    // (sidebar.tsx:171-199); the source drops variant dressing here too.

    private var fixedColumn: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(width: liveWidth)
            .frame(maxHeight: .infinity)
            .background { flatColumnBackground }
            .overlay(alignment: innerEdge) { panelHairline }
    }

    // MARK: offcanvas shell — the in-flow column, 0↔width

    private var shell: some View {
        ZStack(alignment: left ? .topLeading : .topTrailing) {
            if peekEnabled {
                peekStrip
                if let st = resolved, st.isPeeking { peekCard(st) }
            } else {
                panel
            }
        }
        .frame(width: isOpen ? liveWidth : 0, alignment: left ? .leading : .trailing)
        .modifier(FluidSidebarClip(disabled: peekArmed))
        .zIndex(peekArmed ? 40 : 0)
        // Order: the isOpen modifier must win shared commits (a mid-drag
        // flip changes both), so liveWidth's glued nil is applied first.
        .animation(reduceMotion || resizing ? nil : FluidSpring.slow, value: liveWidth)
        .animation(openAnimation, value: isOpen)
        .animation(peekAnimation, value: resolved?.isPeeking ?? false)
    }

    /// The fixed-width sliding column — slides out under the shell's clip
    /// (x: ∓100%) as the shell's width springs, so rows stay glued to the
    /// hairline edge instead of being squeezed (sidebar-core.tsx:777-841).
    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { panelBackground }
            // floating floats its card inside a full gutter; inset takes
            // only the vertical inset (sidebar-core.tsx:783-784).
            .padding(floating ? 8 : 0)
            .padding(.vertical, variant == .inset ? 8 : 0)
            .frame(width: liveWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: innerEdge) { panelHairline }
            .overlay(alignment: innerEdge) { panelRail }
            .offset(x: isOpen ? 0 : (left ? -liveWidth : liveWidth))
    }

    @ViewBuilder private var panelBackground: some View {
        if floating {
            Color.clear.fluidSurface(floatingLevel, radius: shape.container)
        } else {
            flatColumnBackground
        }
    }

    /// `sidebar` keeps the flat surface(0) column; `inset` drops it — the
    /// source's column is transparent there and the SIBLING is the card.
    @ViewBuilder private var flatColumnBackground: some View {
        if variant == .inset {
            FluidTone.background
        } else {
            FluidTone.surface(0)
        }
    }

    /// border-r / border-l — only the `sidebar` variant draws it
    /// (sidebar-core.tsx:806-809).
    @ViewBuilder private var panelHairline: some View {
        if bordered && variant == .sidebar {
            Rectangle().fill(FluidTone.border)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var panelRail: some View {
        if rail {
            if resolved != nil {
                // Floating moves the strip in to straddle the card edge
                // (source:822-823); non-sidebar variants mask the hairline
                // in past the card's corner radius (source:828-837).
                FluidSidebarRail(
                    tooltipOpen: railTooltipOpen,
                    edgeInset: floating ? 4 : 0,
                    lineInset: floating ? 3.5 : 0,
                    maskEnds: variant != .sidebar,
                    maskFade: shape == .pill ? 24 : 12
                )
            } else {
                legacyRail
            }
        }
    }

    // MARK: peek — edge strip + floated card (sidebar-core.tsx:707-774)

    /// The collapsed sidebar's 12px reveal strip: a w-px hairline at the
    /// window edge brightening on hover/focus; hover mode peeks on the
    /// shared intent timer, click mode (and any click) on press.
    private var peekStrip: some View {
        Color.clear
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .overlay(alignment: left ? .leading : .trailing) {
                Rectangle().fill(FluidTone.border)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .opacity(stripLit ? 1 : 0)
                    .animation(.easeOut(duration: 0.08), value: stripLit)
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($stripFocused)
            .focusEffectDisabled()
            .accessibilityLabel("Peek sidebar")
            .onKeyPress(.return) { presentPeek(); return .handled }
            .onKeyPress(.space) { presentPeek(); return .handled }
            .onHover { h in
                stripHover = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                guard let st = resolved, st.peek == .hover else { return }
                if h {
                    st.schedulePeek()
                } else if !st.isPeeking {
                    // A leave before the intent delay lands retires the
                    // pending arm; while peeked the geometric watcher owns
                    // dismissal (sidebar-core.tsx:698-704).
                    st.cancelPeekTimer()
                }
            }
            .onTapGesture { presentPeek() }
            .background {
                if let st = resolved {
                    FluidSidebarProbe(state: st,
                        onFrame: { st.peekStripFrame = $0 },
                        onDetach: { st.peekStripFrame = .zero })
                }
            }
            .zIndex(40)
    }

    private var stripLit: Bool { stripHover || stripFocused }

    private func presentPeek() {
        guard let st = resolved else { return }
        st.cancelPeekTimer()
        st.presentPeek()
    }

    /// The overlay card (data-sidebar="peek"): inset-y-2, edge inset
    /// matching where the pinned column's content sits (floating: left-2,
    /// else flush), width −16 floating / −8 otherwise, sliding in on
    /// moderate and out on moderate.exit (sidebar-core.tsx:741-773).
    private func peekCard(_ st: FluidSidebarState) -> some View {
        let w = max(0, liveWidth - (floating ? 16 : 8))
        return VStack(alignment: .leading, spacing: 0) { content() }
            .frame(width: w, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .fluidSurface(floatingLevel, radius: shape.container)
            .clipShape(RoundedRectangle(cornerRadius: shape.container, style: .continuous))
            // The probe reports the CARD rect — the +8px dismissal margin
            // lands on it exactly (sidebar-core.tsx:565-576).
            .background {
                FluidSidebarProbe(state: st,
                    onFrame: { st.peekCardFrame = $0 },
                    onDetach: { st.peekCardFrame = .zero })
            }
            .padding(.vertical, 8)
            .padding(left ? .leading : .trailing, floating ? 8 : 0)
            .transition(reduceMotion
                ? .identity
                : .offset(x: left ? -w * 1.08 : w * 1.08, y: 0))
            .zIndex(50)
    }

    // MARK: stateless rail — same gestures as FluidSidebarRail (4px dead
    // zone, click to collapse, collapse preview past min−slop) minus the
    // state fields it would write.

    private var legacyRail: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { h in
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // highPriority so an enclosing ScrollView can't claim the drag.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !moved {
                            // 4px dead zone before the press becomes a drag —
                            // below it the release is the collapse click.
                            guard abs(v.translation.width) >= 4 else {
                                if startWidth == 0 { startWidth = width; startOpen = open }
                                return
                            }
                            moved = true
                            dragging = true
                            if startWidth == 0 { startWidth = width; startOpen = open }
                        }
                        let delta = left ? v.translation.width : -v.translation.width
                        let raw = startWidth + delta
                        if startOpen {
                            if raw < minWidth - collapseSlop {
                                if !collapsedPreview {
                                    collapsedPreview = true
                                    withAnimation(FluidSpring.moderate) {
                                        width = minWidth
                                        open = false
                                    }
                                }
                                return
                            }
                            if collapsedPreview {
                                collapsedPreview = false
                                withAnimation(FluidSpring.moderate) { open = true }
                            }
                            width = min(max(raw, minWidth), maxWidth)
                        } else if raw > minWidth - collapseSlop {
                            // Closed: dragging out past slop reopens at min.
                            withAnimation(FluidSpring.moderate) { open = true }
                            width = minWidth
                        }
                    }
                    .onEnded { _ in
                        // A press that never moved is the collapse click.
                        if !moved { open.toggle() }
                        moved = false
                        dragging = false
                        collapsedPreview = false
                        startWidth = 0
                    }
            )
            .fluidSidebarTooltip(
                side: left ? .right : .left,
                followCursor: .y,
                // Dragging always hides it; pinned overrides hover.
                forceOpen: dragging ? false : railTooltipOpen
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Drag").fontWeight(.semibold) + Text(" to resize")
                    HStack(spacing: 6) {
                        Text("Click").fontWeight(.semibold) + Text(" to collapse")
                        // No state to resolve the binding — the side default.
                        FluidSidebarKbd(left ? "[" : "]")
                    }
                }
            }
    }
}

/// Equatable config the pane pushes into FluidSidebarState.
private struct FluidSidebarConfig: Equatable {
    var side: FluidSidebarSide
    var variant: FluidSidebarVariant
    var collapsible: FluidSidebarCollapsible
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var collapseSlop: CGFloat
}

/// Conditional `overflow-hidden` — the shell lifts its clip while peek is
/// armed or a peek is being pinned open (sidebar-core.tsx:672); a group
/// lifts it once open+settled so rows' focus rings aren't shaved
/// (sidebar-core.tsx:1265-1271).
private struct FluidSidebarClip: ViewModifier {
    let disabled: Bool
    func body(content: Content) -> some View {
        if disabled { content } else { content.clipped() }
    }
}

// MARK: - Group

/// Per-group chrome — the source's SidebarGroupContext plus the
/// group/group-header hover scope as an env-published reveal flag.
@Observable
final class FluidSidebarGroupState {
    /// The header cluster's measured width — a collapsible label pads its
    /// trailing edge past it (--group-actions-pad, sidebar-core.tsx:1436-1443).
    var actionsWidth: CGFloat = 0
    @ObservationIgnored private var popupPins: Set<UUID> = []
    /// A group action pinning a popup open keeps the header revealed — the
    /// group-has-[data-state=open]/[data-popup-open] selectors
    /// (sidebar-core.tsx:1474).
    var popupOpen: Bool { !popupPins.isEmpty }

    func setPopupPin(_ id: UUID, _ on: Bool) {
        if on { popupPins.insert(id) } else { popupPins.remove(id) }
    }
}

extension EnvironmentValues {
    /// The enclosing FluidSidebarGroup's chrome state.
    @Entry var fluidSidebarGroup: FluidSidebarGroupState? = nil
    /// Header focus scope — the label toggle and its actions share one
    /// FocusState so focus-within reveals the chevron.
    @Entry var fluidSidebarGroupFocus: FocusState<UUID?>.Binding? = nil
    /// Header revealed — hover over the label or the cluster, focus-within,
    /// or a descendant action's open popup.
    @Entry var fluidSidebarGroupRevealed = false
    /// Inside a FluidSidebarGroupActions cluster — the source's
    /// GroupActionsContext; members don't self-position or self-gate.
    @Entry var fluidInGroupCluster = false
}

/// `SidebarGroup` (sidebar-core.tsx:1228-1383): a p-2 section column with
/// an optional label; `collapsible` turns the label into a measured-height
/// accordion toggle. Header actions come through `actions:` — SwiftUI can't
/// hoist children like the source's child surgery (sidebar-core.tsx:1289-1359).
struct FluidSidebarGroup<Content: View>: View {
    var label: String? = nil
    var collapsible = false
    var size: FluidSize = .default
    var actions: (() -> AnyView)? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidMenuHidden) private var hidden

    @State private var open = true
    /// Measured-height collapse — animate to the content's real height,
    /// never to "auto" (sidebar-core.tsx:1249-1263).
    @State private var contentHeight: CGFloat? = nil
    /// Clip lifts once an open group settles so rows' focus rings survive.
    @State private var settled = true
    @State private var group = FluidSidebarGroupState()
    @State private var labelID = UUID()
    @State private var labelHover = false
    @State private var clusterHover = false
    @State private var settleTask: Task<Void, Never>?
    @FocusState private var headerFocus: UUID?

    init(_ label: String? = nil, collapsible: Bool = false,
         size: FluidSize = .default,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.collapsible = collapsible
        self.size = size
        self.content = content
    }

    init<Actions: View>(_ label: String? = nil, collapsible: Bool = false,
         size: FluidSize = .default,
         @ViewBuilder actions: @escaping () -> Actions,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.collapsible = collapsible
        self.size = size
        self.actions = { AnyView(actions()) }
        self.content = content
    }

    /// The group-header reveal: hover over the label row OR the overlaid
    /// cluster (it never :hovers the label itself), focus inside the
    /// header, or a pinned-open action popup (sidebar-core.tsx:1470-1476).
    private var revealed: Bool {
        labelHover || clusterHover || headerFocus != nil || group.popupOpen
    }

    private var compact: Bool { size == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label { labelRow(label) }
            if collapsible {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
                    .frame(height: open ? contentHeight : CGFloat(0), alignment: .top)
                    .modifier(FluidSidebarClip(disabled: open && settled))
                    .opacity(open ? 1 : 0)
                    .accessibilityHidden(!open)
                    // Closed groups keep content mounted but hidden — rows
                    // stay registered and skipped (rowHidden). OR with any
                    // hidden ancestor above — an open group inside a closed
                    // one stays hidden.
                    .environment(\.fluidMenuHidden, hidden || !open)
            } else {
                content()
            }
        }
        .padding(8) // p-2 — the group's own gutters
        .overlay(alignment: .topTrailing) {
            if let actions {
                // right-3.5 top-2 — the cluster anchors on the group's box
                // so it lands on the rows' action axis (sidebar-core.tsx:1580).
                actions()
                    .padding(.top, 8)
                    .padding(.trailing, 14)
                    .onHover { clusterHover = $0 }
            }
        }
        .environment(\.fluidSidebarGroup, group)
        .environment(\.fluidSidebarGroupFocus, $headerFocus)
        .environment(\.fluidSidebarGroupRevealed, revealed)
        // Height animates only when THIS group toggles — a re-measure from
        // a nested collapse snaps since `open` didn't move (togglingRef).
        .animation(FluidSpring.moderate, value: open)
        .onChange(of: open) { _, o in
            settled = false
            settleTask?.cancel()
            settleTask = Task { @MainActor in
                // exitFallbackMs(spring.moderate) — the clip lifts once the
                // toggle's animation has had time to land.
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                settled = o
            }
        }
    }

    /// The 32px label row (sidebar-core.tsx:1390-1509): muted/70, bumping
    /// to full contrast on hover only when it's the collapsible toggle.
    /// The chevron's box collapses to w-0 at rest while open — revealed by
    /// the header scope — and stays put while collapsed as the reopen cue.
    /// No width/opacity transition: the glyph just appears (source:1467-1469).
    private func labelRow(_ text: String) -> some View {
        // --group-actions-pad = cluster width + 10: the 6px between the
        // label's edge and the cluster's plus one cluster gap
        // (sidebar-core.tsx:1434-1443).
        let actionsPad = collapsible && group.actionsWidth > 0
            ? group.actionsWidth + 10 : 0
        let row = HStack(spacing: 8) {
            Text(text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if collapsible {
                FluidIcon("chevron.right", size: size.icon)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(FluidSpring.fast, value: open)
                    // The collapse reveal is instant in the source ("no
                    // width/opacity transition") — only the rotation
                    // springs, so it sits above these modifiers.
                    .frame(width: revealed || !open ? 24 : 0, height: 24)
                    .clipped()
                    .opacity(revealed || !open ? 1 : 0)
            }
        }
        .font(.system(size: compact ? 11 : 12))
        .foregroundStyle(FluidTone.mutedForeground.opacity(collapsible && labelHover ? 1 : 0.7))
        // transition-colors duration-80 on the label (tsx:1447).
        .animation(.easeOut(duration: 0.08), value: labelHover)
        .padding(.horizontal, 8)
        .padding(.trailing, actionsPad)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { h in labelHover = h }

        guard collapsible else { return AnyView(row) }
        return AnyView(
            Button {
                headerFocus = labelID
                open.toggle()
            } label: { row }
                .buttonStyle(.plain)
                .focusable()
                .focused($headerFocus, equals: labelID)
                .focusEffectDisabled()
                .overlay {
                    // focus-visible:ring-1 — macOS can't split click vs
                    // keyboard focus; shown whenever the toggle holds it.
                    if headerFocus == labelID {
                        RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                            .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                    }
                }
        )
    }
}

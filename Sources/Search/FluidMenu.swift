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

private struct FluidMenuExitKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var fluidMenuDismiss: (() -> Void)? {
        get { self[FluidMenuDismissKey.self] }
        set { self[FluidMenuDismissKey.self] = newValue }
    }
    /// Immediate whole-chain exit (Esc/Tab semantics) — unlike
    /// `fluidMenuDismiss`, which can carry a selection-acknowledgment
    /// defer, this closes the popup now.
    var fluidMenuExit: (() -> Void)? {
        get { self[FluidMenuExitKey.self] }
        set { self[FluidMenuExitKey.self] = newValue }
    }
    /// The popup controller's available-height cap for this presentation —
    /// the `--radix-available-height` half of `max-h-[min(cap,var(…))]`.
    /// Nil outside a popup (inline panels are uncapped unless they pass
    /// their own maxHeight).
    @Entry var fluidPopupMaxHeight: CGFloat? = nil
}

// MARK: - Menu item

/// A menu row: icon (optional), label, trailing check slot. `checked`
/// nil = plain action item; a Bool makes it a radio/checkbox row.
struct FluidMenuItem: View {
    let index: Int
    var icon: String? = nil
    let label: String
    var detail: String? = nil
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(
                            size: resolved.text,
                            weight: checked == true ? .semibold : .regular
                        ))
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: resolved.text - 2))
                            .foregroundStyle(FluidTone.mutedForeground)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // The fixed check slot — its presence never changes the
                // row's width. Radio/checkbox rows keep the glyph mounted
                // so a deselect un-draws instead of popping off
                // (combobox's pathLength exit — FluidComboboxRow).
                ZStack {
                    if checked != nil {
                        FluidCheckmark(size: resolved.icon, presented: checked == true)
                            .foregroundStyle(FluidTone.foreground)
                    }
                }
                .frame(width: resolved.icon, height: resolved.icon)
            }
            .padding(.horizontal, resolved.itemPx)
            .padding(.vertical, detail == nil ? 0 : 5)
            .frame(minHeight: resolved.controlHeight)
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
        // popup's key monitor can prefix-match it. The `disabled:` prop
        // registers into the same set the pick/gap-pick/nav consult —
        // prop-disabled rows are never lit and never picked.
        .onAppear {
            hover?.itemLabels[index] = label
            // Click parity for keyboard/gap activation — captures only
            // the two callbacks (never the view) so the registration
            // can't pin the row's env into the hover store.
            let select = onSelect
            let dismiss = menuDismiss
            hover?.rowActions[index] = { select(); dismiss?() }
            if disabled { hover?.rowDisabled.insert(index) }
        }
        .onDisappear {
            hover?.itemLabels[index] = nil
            hover?.rowActions[index] = nil
            hover?.rowDisabled.remove(index)
        }
        .onChange(of: label) { _, l in hover?.itemLabels[index] = l }
        .onChange(of: disabled) { _, d in
            if d { hover?.rowDisabled.insert(index) }
            else { hover?.rowDisabled.remove(index) }
        }
        .onChange(of: index) { old, new in
            // Index moves carry the row's registrations with them.
            hover?.itemLabels[old] = nil
            hover?.itemLabels[new] = label
            let select = onSelect
            let dismiss = menuDismiss
            hover?.rowActions[old] = nil
            hover?.rowActions[new] = { select(); dismiss?() }
            if hover?.rowDisabled.contains(old) == true {
                hover?.rowDisabled.remove(old)
                hover?.rowDisabled.insert(new)
            }
        }
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

struct FluidSubmenu<Rows: View>: View {
    let index: Int
    var icon: String? = nil
    let label: String
    var detail: String? = nil
    var checked = false
    var disabled = false
    var width: CGFloat? = 220
    var checkedIndex: Int? = nil
    var onPick: ((Int) -> Void)? = nil
    @ViewBuilder var rows: () -> Rows

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidMenuDismiss) private var menuDismiss
    @Environment(\.fluidMenuExit) private var menuExit
    @Environment(\.fluidSize) private var size
    @State private var controller = FluidPopupController()
    @State private var open = false
    @State private var pending: DispatchWorkItem?
    /// Open requests from the parent panel's nav-pick/gap-pick — a seq
    /// counter (the sidebar's pendingActivation pattern) so the closure
    /// the row registers doesn't snapshot stale props.
    @State private var openSeq = 0
    @State private var openWantsFocus = false
    /// The sub rows' natural height, measured by a hidden probe — the
    /// popup modifier's trick: a detached ScrollView can't self-report,
    /// so without this the env cap pins the panel to screen height. The
    /// shared box carries updates into the open panel (live refit).
    @State private var sizeBox = FluidPopupSizeBox()
    @State private var probeHover = FluidHover()
    @State private var probeScope = FluidMenuScope()

    private var isActive: Bool { hover?.activeIndex == index }
    private var lit: Bool { isActive || open || checked }

    var body: some View {
        Button(action: { present() }) {
            HStack(spacing: size.gap) {
                if let icon {
                    FluidIcon(icon, size: size.icon, bold: lit)
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .frame(width: size.icon, height: size.icon)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: size.text, weight: checked ? .semibold : .regular))
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: size.text - 2))
                            .foregroundStyle(FluidTone.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: size.icon * 0.6, weight: .semibold))
                    .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                    .frame(width: size.icon, height: size.icon)
            }
            .padding(.horizontal, size.itemPx)
            .padding(.vertical, detail == nil ? 0 : 5)
            .frame(minHeight: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if open && !isActive {
                    RoundedRectangle(cornerRadius: menuShape.bg, style: .continuous)
                        .fill(FluidTone.hover)
                }
            }
            .contentShape(Rectangle())
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .fluidItem(index)
        .id("mi-\(index)")
        .background(FluidAnchorResolver(controller: controller))
        .background(
            VStack(alignment: .leading, spacing: 0) { rows() }
                .padding(4)
                .fixedSize()
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { sizeBox.height = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in sizeBox.height = h }
                    })
                .opacity(0)
                .allowsHitTesting(false)
                .clipped()
                .environment(\.fluidHover, probeHover)
                .environment(\.fluidMenuScope, probeScope)
                .accessibilityHidden(true)
        )
        .onAppear {
            hover?.itemLabels[index] = label
            if disabled { hover?.rowDisabled.insert(index) }
            // Radix SubTrigger — Enter/Space/→ on the row (and gap-picks
            // routed to it) open the submenu instead of activating.
            hover?.submenuActions[index] = { focusFirst in
                $openWantsFocus.wrappedValue = focusFirst
                $openSeq.wrappedValue += 1
            }
        }
        .onDisappear {
            hover?.itemLabels[index] = nil
            hover?.submenuActions[index] = nil
            hover?.rowDisabled.remove(index)
            pending?.cancel()
            controller.dismiss(animated: false)
        }
        .onChange(of: label) { _, l in hover?.itemLabels[index] = l }
        .onChange(of: disabled) { _, d in
            if d { hover?.rowDisabled.insert(index) }
            else { hover?.rowDisabled.remove(index) }
        }
        .onChange(of: index) { old, new in
            // Index moves carry the trigger's registrations with them.
            hover?.itemLabels[old] = nil
            hover?.itemLabels[new] = label
            if let action = hover?.submenuActions.removeValue(forKey: old) {
                hover?.submenuActions[new] = action
            }
            if hover?.rowDisabled.contains(old) == true {
                hover?.rowDisabled.remove(old)
                hover?.rowDisabled.insert(new)
            }
        }
        .onChange(of: openSeq) { _, _ in
            guard openSeq > 0 else { return }
            present(keyboardFocus: openWantsFocus)
        }
        .onChange(of: hover?.activeIndex) { _, now in
            pending?.cancel()
            pending = nil
            // Pointer hover auto-opens after the grace delay; roving
            // ARROW-key focus must not (Radix opens a Sub on →/Enter or
            // pointer, never on roving focus).
            if now == index, hover?.navDrivenFocus != true {
                let work = DispatchWorkItem { present() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            } else if now != nil {
                controller.dismiss()
            } else {
                // Pointer left the container (into the submenu, or out of
                // the menu entirely) — release the pick pin so re-entry
                // over a sibling row picks it and closes this sub.
                hover?.frozen = false
            }
        }
    }

    private func present(keyboardFocus: Bool = false) {
        pending?.cancel()
        pending = nil
        // A mid-exit panel takes present()'s instant swap-dismiss; only
        // a fully-settled open is a no-op.
        guard !controller.isPresented || controller.isClosing else { return }
        open = true
        let dismissAll = menuDismiss
        let size = self.size
        let controller = self.controller
        let parentHover = self.hover
        controller.present(edge: .right, align: .start, offset: 2) {
            FluidMenuPanel(
                checkedIndex: checkedIndex,
                size: size,
                width: width,
                maxHeight: nil,
                naturalHeight: sizeBox.height > 0 ? sizeBox.height : nil,
                onPick: { i in onPick?(i); controller.dismissAfter(0.16); dismissAll?() },
                focusFirstRow: keyboardFocus,
                // Keys land on the app's key window — the parent panel
                // is non-activating, so this sub's monitor scopes there.
                keyWindow: { NSApp.keyWindow },
                // Tab exits the WHOLE chain instantly — the ack-deferring
                // fluidMenuDismiss is for selections, not key exits.
                onExit: { controller.dismiss(); menuExit?() ?? dismissAll?() },
                // ← inside a sub closes back to the parent (Radix).
                onLeft: { controller.dismiss() },
                // Once the exit starts the sub's nav monitor goes inert —
                // keys belong to the parent again, not a dying panel.
                deadWhen: { [weak controller] in controller?.isClosing ?? true },
                content: rows
            )
            .environment(\.fluidSize, size)
            .environment(\.fluidMenuDismiss, { controller.dismissAfter(0.16); dismissAll?() })
            // Forward the root's instant-exit to nested subs.
            .environment(\.fluidMenuExit, menuExit)
            .environment(\.fluidPopupSize, sizeBox)
        }
        guard controller.isPresented else {
            // Anchor wasn't resolved yet — don't leave a pin behind.
            open = false
            return
        }
        // Pointer grace: the parent's pick is pinned on this row while the
        // sub is open — pointer travel across sibling rows can't dismiss
        // it mid-flight (the source's pointer-grace intent). openSubIndex
        // also routes the parent's nav/typeahead keys to the sub's own
        // monitor (Radix moves keyboard nav into the sub). Installed AFTER
        // present() — its internal swap-dismiss fires onWillDismiss, which
        // would strip pins set only moments earlier on a re-present.
        parentHover?.frozen = true
        parentHover?.openSubIndex = index
        controller.onWillDismiss = { [weak parentHover] in
            // Released at close-start, not teardown — the exit window's
            // ~200ms must not eat the parent's nav keys.
            if parentHover?.openSubIndex == index {
                parentHover?.openSubIndex = nil
                parentHover?.frozen = false
            }
        }
        controller.onDismissed = { [weak parentHover] in
            open = false
            // Release only if we're still the open sub — a sibling may
            // have re-pinned during our exit window.
            if parentHover?.openSubIndex == index {
                parentHover?.openSubIndex = nil
                parentHover?.frozen = false
            }
        }
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
    /// In a popup the controller also injects the available-height cap
    /// (`max-h-[min(cap,var(--radix-available-height))]`).
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
    /// Keyboard-opened submenu: highlight + ring land on the first row
    /// once rows have measured (Radix's content.focus() on sub open).
    var focusFirstRow = false
    /// The window keys actually arrive at — the popup is non-activating,
    /// so keyDowns land on the anchor's window, not ours.
    var keyWindow: (() -> NSWindow?)? = nil
    /// Tab departs the popup entirely (Radix closes on Tab).
    var onExit: (() -> Void)? = nil
    /// ← inside a submenu closes back to the parent (Radix); nil keeps
    /// the root menu's prev-row mapping.
    var onLeft: (() -> Void)? = nil
    /// When this reports true the panel's nav monitor goes inert — a
    /// closing sub must stop eating keys its parent should own again.
    var deadWhen: (() -> Bool)? = nil
    @ViewBuilder var content: () -> Content

    @State private var hover = FluidHover(axis: .y)
    @State private var fade = FluidScrollFadeState()
    /// Virtual keyboard state — a class so the event monitors can hold it
    /// weakly (the panel is a struct; @State handles can't be weak).
    @State private var nav = FluidMenuPanelNav()
    private let probeBox = FluidMenuPanelProbeBox()
    /// The popup controller's available-height cap — the source's
    /// `var(--radix-available-height)` half of the max-h rule.
    @Environment(\.fluidPopupMaxHeight) private var popupHeightCap
    /// Live content measurement + refit request (Popper autoUpdate) —
    /// updates arriving while open re-place the panel.
    @Environment(\.fluidPopupSize) private var liveSize
    @Environment(\.fluidPopupRefit) private var refitAction

    private var checkedRect: CGRect? {
        checkedIndex.flatMap { hover.rects[$0] }
    }
    private var ringRect: CGRect? {
        (nav.navArmed ? nav.focusedIndex : nil).flatMap { hover.rects[$0] }
    }
    /// min(configured cap, available-height cap) — nil when neither binds.
    private var resolvedMaxHeight: CGFloat? {
        let cap = min(
            maxHeight ?? .greatestFiniteMagnitude,
            popupHeightCap ?? .greatestFiniteMagnitude
        )
        guard cap != .greatestFiniteMagnitude else { return nil }
        return max(cap, 0)
    }
    /// Natural height — the live measured value wins while open (content
    /// can grow/shrink mid-session); the baked param is the pre-present
    /// fallback the detached fittingSize probe reads.
    private var liveNatural: CGFloat? {
        if let h = liveSize?.height, h > 0 { return h }
        return naturalHeight
    }
    /// Visible, enabled rows top-to-bottom (the scope's `ordered` rule).
    private var navOrder: [Int] {
        hover.rects
            .filter { !hover.isItemDisabled($0.key) && $0.value.height > 0 }
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
            // A gap click landing on a submenu row opens the sub instead
            // of picking (Radix: the trigger keeps its own activation).
            onGapPick: { i in
                if let open = hover.submenuActions[i] { open(false) }
                // A gap click routed to a lit row fires that row's own
                // click path — identical to tapping the row itself.
                else if let activate = hover.rowActions[i] { activate() }
                else { onPick?(i) }
            }
        ) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(4)
        }
        Group {
            // Scroll only against a real measurement — an unmeasured
            // ScrollView collapses under fittingSize, and forcing the
            // env cap as the height pins submenus screen-tall.
            if let cap = resolvedMaxHeight, let natural = liveNatural, natural > 0 {
                ScrollViewReader { proxy in
                    ScrollView { rows.fluidFadeContent(fade) }
                        .scrollIndicators(.hidden)
                        .frame(height: min(natural, cap))
                        // popupViewportClass sets --scroll-fade-size: 32px.
                        .fluidScrollFade(32, state: fade)
                        .onAppear { nav.scrollProxy = proxy }
                }
            } else {
                rows.frame(maxHeight: resolvedMaxHeight)
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
        // Popper autoUpdate — a content resize while open re-places the
        // panel (the refit env is nil for inline panels — no-op there).
        .onChange(of: liveSize?.height ?? 0) { _, _ in refitAction?() }
        .onChange(of: disabledIndices) { _, v in nav.disabledIndices = v }
        // Inline panels release the nav gate when the pointer leaves —
        // the source's menu keydown lives under menu DOM focus, which
        // exits on blur; an engaged-once inline menu must not keep
        // eating its window's arrows forever. Popup panels keep the
        // armed session (their :focus-visible gate never un-arms).
        .onContinuousHover { phase in
            if case .ended = phase,
               !(probeBox.view?.window is FluidPopupPanel) {
                nav.navArmed = false
            }
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
        // One skip set for pick/gap-pick/nav: the panel's disabledIndices
        // unioned with rows' own `disabled:` prop registrations. The nav
        // box carries the live copy — prop changes while open propagate.
        nav.disabledIndices = disabledIndices
        hover.isItemDisabled = { [weak hover, weak nav] i in
            nav?.disabledIndices.contains(i) == true
                || hover?.rowDisabled.contains(i) == true
        }
        nav.navArmed = navSeed || focusFirstRow
        // Keyboard-opened subs seed the FIRST row (Radix content.focus());
        // root menus open on the selection — unless that checked row is
        // disabled (navOrder already excludes disabled rows).
        if nav.focusedIndex == nil, !focusFirstRow {
            let seed = checkedIndex.flatMap {
                self.hover.isItemDisabled($0) ? nil : $0
            }
            nav.focusedIndex = seed ?? navOrder.first
        }
        if focusFirstRow {
            // Rows measure a beat after onAppear — seed the topmost
            // enabled row once rects have landed.
            let nav = self.nav
            let hover = self.hover
            DispatchQueue.main.async {
                guard nav.focusedIndex == nil else { return }
                let first = hover.rects
                    .filter { !hover.isItemDisabled($0.key) && $0.value.height > 0 }
                    .sorted {
                        $0.value.minY == $1.value.minY
                            ? $0.value.minX < $1.value.minX
                            : $0.value.minY < $1.value.minY
                    }
                    .map(\.key).first
                nav.setFocus(first, hover: hover)
            }
        }
        guard keyboardNav, nav.monitors.isEmpty else { return }
        let nav = self.nav
        let hover = self.hover
        let keyWindow = self.keyWindow
        let probeBox = self.probeBox
        let onPick = self.onPick
        let onExit = self.onExit
        let onLeft = self.onLeft
        nav.deadWhen = deadWhen
        // Monitors install one runloop out — the detached fittingSize
        // probe SwiftUI builds inside present() mounts this view too and
        // would leak a set of monitors on a dead hierarchy; its probe
        // NSView never joins a window, which is the liveness gate.
        DispatchQueue.main.async {
            guard nav.monitors.isEmpty, probeBox.view?.window != nil else { return }
            // Pointer modality — a click in the owning window clears the
            // virtual focus; mouse entering the popup clears the ring too
            // (onMouseEnter → setFocusedIndex(null)). navArmed stays.
            nav.monitors.append(NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak nav] event in
                // Popup panels hear the owner window; inline panels (no
                // popup window) scope to their own.
                if event.window === (keyWindow?() ?? probeBox.view?.window) {
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
                    event, nav: nav, hover: hover,
                    keyWindow: keyWindow, probeBox: probeBox,
                    onPick: onPick, onExit: onExit, onLeft: onLeft
                ) ?? event
            }!)
        }
    }

    /// Arrows/Home/End move the virtual focus (the highlight follows it,
    /// like the source's onFocus), Return/Space activate, Tab exits, and
    /// printable characters run Radix's prefix typeahead.
    private static func navKey(
        _ event: NSEvent, nav: FluidMenuPanelNav?, hover: FluidHover,
        keyWindow: (() -> NSWindow?)?, probeBox: FluidMenuPanelProbeBox,
        onPick: ((Int) -> Void)?, onExit: (() -> Void)?,
        onLeft: (() -> Void)? = nil
    ) -> NSEvent? {
        // Popup panels hear the owner window (keys land there since the
        // panel is non-activating); inline panels scope to their own.
        // FLUID_RELAXKEY is probe-only: headless runs can't key a window,
        // so the synthetic-event harness drops just the isKeyWindow check.
        let relaxKey = ProcessInfo.processInfo.environment["FLUID_RELAXKEY"] == "1"
        guard let nav,
              let w = event.window,
              w === (keyWindow?() ?? probeBox.view?.window),
              w.isKeyWindow || relaxKey,
              !(w.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return event }
        // A closing panel is dead to keys — its exit window must not
        // shadow the parent (or a sibling that reopened in its place).
        if nav.deadWhen?() == true { return event }
        // Inline panels (not hosted in a popup window) own keys only once
        // engaged — the source's menu onKeyDown fires under menu focus,
        // so an untouched inline menu can't eat the window's arrows.
        if !(probeBox.view?.window is FluidPopupPanel),
           !nav.navArmed, hover.activeIndex == nil {
            return event
        }
        // An open submenu owns navigation — the sub's own monitor handles
        // arrows/activation/typeahead while the parent's focus stays
        // pinned on its trigger row (Radix moves nav into the sub).
        guard hover.openSubIndex == nil else { return event }
        let items = hover.rects
            .filter { !hover.isItemDisabled($0.key) && $0.value.height > 0 }
            .sorted {
                $0.value.minY == $1.value.minY
                    ? $0.value.minX < $1.value.minX
                    : $0.value.minY < $1.value.minY
            }
            .map(\.key)
        guard !items.isEmpty else { return event }

        // The focus-visible gate arms on NAV keys only (POPUP_NAV_KEYS) —
        // a typeahead match lights a row without drawing the ring.
        if [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) {
            nav.navArmed = true
        }
        switch event.keyCode {
        case 48: // Tab — leave the popup, pass focus onward.
            onExit?()
            return event
        case 123: // ← — inside a submenu Radix closes back to the parent.
            if let onLeft { onLeft() } else { nav.move(in: items, by: -1, hover: hover) }
            return nil
        case 126: // ↑
            nav.move(in: items, by: -1, hover: hover)
            return nil
        case 124, 125: // →/↓
            // SUB_OPEN_KEYS — → on a submenu row opens the sub.
            if event.keyCode == 124,
               let i = nav.focusedIndex ?? hover.activeIndex,
               let open = hover.submenuActions[i] {
                open(true)
            } else {
                nav.move(in: items, by: 1, hover: hover)
            }
            return nil
        case 115, 116: // Home / PageUp — first row.
            nav.setFocus(items.first, hover: hover)
            return nil
        case 119, 121: // End / PageDown — last row.
            nav.setFocus(items.last, hover: hover)
            return nil
        case 36, 76, 49: // Return/Enter/Space — activate like a click,
                         // except a submenu row opens its sub instead
                         // (Radix: Enter/Space open a SubTrigger).
            if let i = nav.focusedIndex ?? hover.activeIndex {
                if let open = hover.submenuActions[i] {
                    open(true)
                } else if let activate = hover.rowActions[i] {
                    // The row's own click path — onSelect + its dismiss
                    // env — so rows wired with only onSelect aren't
                    // keyboard-dead (Radix: Enter synthesizes a click).
                    activate()
                } else {
                    onPick?(i)
                }
            }
            return nil
        default:
            // Radix typeahead: printable chars accumulate into a prefix
            // matched against item text — from after the current row,
            // wrapping. The buffer resets ~1s after the last char.
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  chars.count == 1,
                  // Any printable single char (Radix: event.key.length
                  // === 1). Function keys/forward-delete arrive as
                  // private-use scalars — category filter lets them
                  // pass through instead of being eaten as typeahead
                  // (same rule as FluidSearchTypeahead).
                  chars.unicodeScalars.allSatisfy({ s in
                      switch s.properties.generalCategory {
                      case .control, .privateUse, .surrogate, .unassigned,
                           .lineSeparator, .paragraphSeparator:
                          return false
                      default:
                          return true
                      }
                  })
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
    /// The panel's live disabled set — synced by onChange so prop edits
    /// while open reach the monitors' closures.
    var disabledIndices: Set<Int> = []
    /// Reports true once the panel is closing — nav keys go inert rather
    /// than handling events for a dying popup.
    var deadWhen: (() -> Bool)? = nil

    func setFocus(_ i: Int?, hover: FluidHover) {
        focusedIndex = i
        // onFocus → the hover highlight tracks the focused row. Marked
        // keyboard-driven so submenu triggers don't auto-open on roving
        // focus (Radix opens a Sub on →/Enter/pointer, not arrows).
        hover.navDrivenFocus = true
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

/// Popup panels — the marker class lets a parent tell "a popup is open
/// below me" from other child windows. `handlesEscape` distinguishes
/// Esc-owning popups from passive ones (tooltips): a parent only yields
/// Esc to a child that would actually consume it.
private final class FluidPopupPanel: NSPanel {
    var handlesEscape = true
}

/// The panel's content view. Borderless windows accept clicks anywhere in
/// their frame — including the transparent shadow-bleed ring — which
/// would swallow a "pointer-down outside" instead of dismissing. Falling
/// through on hits that land outside the hosted content's real bounds
/// puts the click on the window beneath (Radix's pointerdown-outside).
private final class FluidBleedPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Live natural-height channel — the hidden measurement probes write
/// here and the hosted panel reads it, so content that changes size
/// while open reaches the panel across the detached hosting boundary
/// (plain params freeze at present time; the box is shared state).
@Observable
final class FluidPopupSizeBox {
    var height: CGFloat = 0
}

extension EnvironmentValues {
    /// The live measured content height for a popup panel (nil = unmeasured).
    @Entry var fluidPopupSize: FluidPopupSizeBox? = nil
    /// Injected by the popup controller — asks for a re-placement after
    /// the content's size changed (Radix Popper's autoUpdate).
    @Entry var fluidPopupRefit: (() -> Void)? = nil
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
    /// The SwiftUI host inside the panel — inset by shadowBleed so the
    /// surface's drop shadows aren't clipped at the window bounds.
    private weak var hostView: NSView?
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
    /// Bumped on every present/dismiss — the deferred teardown captures
    /// it so a stale close can never wipe a freshly-presented panel.
    private var generation = 0
    /// The pending end-of-exit teardown — cancelable so a re-present or
    /// an immediate dismiss can't leave a stale cleanup armed.
    private var teardownWork: DispatchWorkItem?
    /// The placement inputs from the last present() — kept so the panel
    /// can re-anchor when the parent window scrolls or resizes.
    private var placement: (edge: Edge, align: Align, offset: CGFloat)?
    /// The hidden-state transform from the last present() — the exit
    /// animation returns to it.
    private var hiddenT = CATransform3DIdentity

    /// Room around the content for the elevated surface's drop shadows —
    /// a borderless window clips at its own bounds, so the panel is
    /// oversized and the host inset inside it.
    static let shadowBleed: CGFloat = 24
    /// Margin kept between a clamped popup and the visible frame edges
    /// (Radix collision padding).
    static let screenMargin: CGFloat = 8
    /// The menu panel's own vertical padding (p-1) — a start-aligned side
    /// popup rises by it so its first row aligns with the trigger row.
    static let menuTopPad: CGFloat = 4

    var isPresented: Bool { panel != nil }
    /// Mid-exit: the panel is animating out and its teardown is queued.
    /// Callers guarding on `isPresented` should treat a closing popup as
    /// re-presentable — present() swap-dismisses it instantly.
    private(set) var isClosing = false

    static let closing = Notification.Name("FluidPopupClosing")

    /// Fires when a dismiss BEGINS (before the exit animation/teardown)
    /// — subscribers release latches like submenu key-routing early so
    /// the dying window can't shadow live UI. Always paired with a
    /// later onDismissed once the panel is fully torn down.
    var onWillDismiss: (() -> Void)?

    /// The clip view we enabled bounds notifications on — restored on
    /// teardown so the anchor's scroll view doesn't keep posting.
    private var followedClip: NSClipView?
    /// Several controllers can follow the same clip view (a menu and a
    /// submenu anchored inside one scroll view); only the last teardown
    /// restores the original posting flag.
    private static var clipFollows: [ObjectIdentifier: (count: Int, wasPosting: Bool)] = [:]

    /// SwiftUI can drop the owning modifier without onDisappear —
    /// take the panel down so a dead popup can't linger.
    isolated deinit {
        teardownWork?.cancel()
        ackWork?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
        unfollowClip()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// Release our claim on the followed clip view — the last release
    /// restores its original posting flag.
    private func unfollowClip() {
        guard let clip = followedClip else { return }
        followedClip = nil
        let k = ObjectIdentifier(clip)
        guard var e = Self.clipFollows[k] else { return }
        e.count -= 1
        if e.count > 0 {
            Self.clipFollows[k] = e
        } else {
            Self.clipFollows.removeValue(forKey: k)
            clip.postsBoundsChangedNotifications = e.wasPosting
        }
    }

    private func owns(_ window: NSWindow?) -> Bool {
        var w = window
        while let x = w {
            if x === panel { return true }
            w = x.parent
        }
        return false
    }

    func setAnchor(_ view: NSView) { anchor = view }

    /// Current anchor frame in screen coordinates, for follow-cursor moves.
    /// convertToScreen everywhere — window.frame.min + rect.min
    /// skews when titlebar/accessory views sit in the frame.
    func anchorScreenRect() -> CGRect? {
        guard let anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    /// Slides the already-open panel to a new origin (followCursor).
    func move(to origin: CGPoint) {
        guard let panel else { return }
        panel.setFrameOrigin(origin)
    }

    func panelFrame() -> CGRect? { panel?.frame }

    /// Radix Popper's autoUpdate: content that changed size while open
    /// re-measures and re-places the panel — re-resolving the edge and
    /// clamping against the screen, like present() but without the
    /// enter animation.
    func refit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel,
                  let host = self.hostView, let anchor = self.anchor,
                  let window = anchor.window,
                  let placement = self.placement else { return }
            let fitting = host.fittingSize
            guard fitting.width > 0, fitting.height > 0 else { return }
            let anchorRect = window.convertToScreen(
                anchor.convert(anchor.bounds, to: nil))
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: -20_000, y: -20_000, width: 40_000, height: 40_000)
            let resEdge = resolveEdge(placement.edge, size: fitting,
                                      anchor: anchorRect,
                                      offset: placement.offset, visible: visible)
            // A content-driven refit can flip the resolved side — write it
            // back (as reposition() does) so the exit's hidden transform
            // aims at the edge the panel actually sits on.
            if resEdge != placement.edge {
                self.placement = (resEdge, placement.align, placement.offset)
                hiddenT = Self.hiddenTransform(for: motion, size: fitting,
                                               edge: resEdge)
            }
            var x = popupX(edge: resEdge, align: placement.align,
                           offset: placement.offset,
                           width: fitting.width, anchor: anchorRect)
            var y = popupY(edge: resEdge, align: placement.align,
                           offset: placement.offset,
                           height: fitting.height, anchor: anchorRect)
            (x, y) = clamped(x: x, y: y, size: fitting, visible: visible)
            let bleed = Self.shadowBleed
            host.frame = NSRect(x: bleed, y: bleed,
                                width: fitting.width, height: fitting.height)
            panel.setFrame(NSRect(x: x - bleed, y: y - bleed,
                                  width: fitting.width + 2 * bleed,
                                  height: fitting.height + 2 * bleed),
                           display: true)
        }
    }

    func present<Content: View>(
        edge: Edge = .bottom,
        align: Align = .start,
        offset: CGFloat = 6,
        motion: Motion = .popup,
        clickDismiss: Bool = true,
        mouseTransparent: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        // Swap without notification — the caller already knows the old
        // popup is going away; firing onDismissed here would flip the
        // driving binding and requeue a dismiss onto the NEW panel.
        // Runs before the anchor guard so a stale panel can't orphan
        // when the anchor has already lost its window.
        dismiss(animated: false, notify: false)
        guard let anchor, let window = anchor.window else { return }
        generation += 1
        self.motion = motion

        let panel = FluidPopupPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.handlesEscape = clickDismiss
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = mouseTransparent

        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let screenAnchor = window.convertToScreen(anchorRect)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: -20_000, y: -20_000, width: 40_000, height: 40_000)
        // Measure raw content first: the panel's width floor is the
        // PRESENTED width (max of content and trigger for top/bottom),
        // not just the trigger — otherwise the first re-layout (fade
        // measurement, row updates) collapses the window toward the
        // trigger's narrower intrinsic size.
        let probeSize = NSHostingView(rootView: AnyView(content())).fittingSize
        let width = edge == .bottom || edge == .top
            ? max(probeSize.width, screenAnchor.width)
            : probeSize.width
        // Radix collision flip + the available-height cap — resolve on
        // the natural size so the cap lands inside the content's env
        // before the real host is measured.
        var resEdge = resolveEdge(edge, size: CGSize(
            width: width, height: probeSize.height
        ), anchor: screenAnchor, offset: offset, visible: visible)
        let heightCap = availableHeight(resEdge, anchor: screenAnchor,
                                        offset: offset, visible: visible)
        let host = NSHostingView(
            rootView: FluidPopupRoot(minWidth: width, content: content)
                .environment(\.fluidPopupMaxHeight, heightCap)
                .environment(\.fluidPopupRefit, { [weak self] in self?.refit() })
        )
        let container = FluidBleedPassthroughView()
        container.addSubview(host)
        panel.contentView = container

        let fitting = host.fittingSize
        // Re-resolve with the real (possibly capped) height — a capped
        // list may now fit the preferred side, or the flip may stand.
        resEdge = resolveEdge(edge, size: CGSize(
            width: width, height: fitting.height
        ), anchor: screenAnchor, offset: offset, visible: visible)
        var x = popupX(edge: resEdge, align: align, offset: offset,
                       width: width, anchor: screenAnchor)
        var y = popupY(edge: resEdge, align: align, offset: offset,
                       height: fitting.height, anchor: screenAnchor)
        (x, y) = clamped(
            x: x, y: y,
            size: CGSize(width: width, height: fitting.height),
            visible: visible
        )
        // The window is oversized by shadowBleed on every side and the
        // host inset inside it — a borderless panel clips the surface's
        // drop shadows at its own bounds otherwise.
        let bleed = Self.shadowBleed
        host.frame = NSRect(x: bleed, y: bleed,
                            width: width, height: fitting.height)
        container.frame = NSRect(x: 0, y: 0,
                                 width: width + 2 * bleed,
                                 height: fitting.height + 2 * bleed)
        panel.setFrame(
            NSRect(x: x - bleed, y: y - bleed,
                   width: width + 2 * bleed, height: fitting.height + 2 * bleed),
            display: false
        )
        // Enter state on the layer before the panel is ordered — the
        // first composited frame is already hidden + transformed.
        hiddenT = Self.hiddenTransform(for: motion, size: fitting, edge: resEdge)
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
        hostView = host
        ownerWindow = window
        isClosing = false
        placement = (resEdge, align, offset)
        startFollowing(anchor: anchor, window: window)
        if window is NSPanel {
            observers.append(NotificationCenter.default.addObserver(
                forName: Self.closing, object: window, queue: nil
            ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        }

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
        // Escape dismiss, like Radix's pointer-down-outside + Esc. The
        // mask covers every button — pointerdown doesn't discriminate.
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak anchor] event in
            guard let self, self.panel != nil else { return event }
            let inAnchor: Bool = {
                guard let anchor else { return false }
                return anchor.window === event.window &&
                    anchor.bounds.contains(
                        anchor.convert(event.locationInWindow, from: nil)
                    )
            }()
            if !self.owns(event.window), !inAnchor { self.dismiss(reason: "outside-click") }
            return event
        }!)
        // Esc is scoped to this popup's own window chain — a local
        // monitor sees every keyDown app-wide, and consuming somebody
        // else's Esc while merely open eats their dismissal. KeyDown
        // lands on the app's key window: the panel's parent chain walks
        // owner → … → key window, so roots and nested subs both match
        // while an unrelated key window doesn't. A controller with an
        // open CHILD popup that handles Esc yields — innermost dismisses
        // first (Radix layer order).
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            // Mid-exit this popup is already going away — pass Esc down
            // so the parent chain (or the field) sees it instead of the
            // dying panel eating it.
            if self.isClosing { return event }
            var w: NSWindow? = self.panel
            var inChain = event.window === self.ownerWindow
            while let cur = w, !inChain {
                inChain = cur === event.window
                w = cur.parent
            }
            guard inChain else { return event }
            if self.panel?.childWindows?.contains(where: {
                ($0 as? FluidPopupPanel)?.handlesEscape == true
            }) == true { return event }
            self.dismiss(reason: "escape")
            return nil
        }!)
    }

    /// `a` is the anchor rect in SCREEN coordinates (y-up: minY is the
    /// anchor's bottom edge).
    private func popupX(
        edge: Edge, align: Align, offset: CGFloat,
        width: CGFloat, anchor a: CGRect
    ) -> CGFloat {
        switch (edge, align) {
        case (.left, _): return a.minX - width - offset
        case (.right, _): return a.maxX + offset
        case (_, .center): return a.midX - width / 2
        default: return a.minX
        }
    }

    private func popupY(
        edge: Edge, align: Align, offset: CGFloat,
        height: CGFloat, anchor a: CGRect
    ) -> CGFloat {
        switch (edge, align) {
        case (.bottom, _): return a.minY - height - offset
        case (.top, _): return a.maxY + offset
        case (_, .center): return a.midY - height / 2
        default:
            // .start on a side popup (submenus): the panel's top sits one
            // row-padding ABOVE the trigger's top so the first submenu
            // row aligns with the trigger row (Radix align=start + p-1).
            return a.maxY + Self.menuTopPad - height
        }
    }

    /// Radix collision flip — a popup that doesn't fit its side lands on
    /// the opposite one when there's more room there (popper flip +
    /// best-fit). Left/right flip on width, top/bottom on height.
    private func resolveEdge(
        _ edge: Edge, size: CGSize, anchor a: CGRect,
        offset: CGFloat, visible: CGRect
    ) -> Edge {
        let m = Self.screenMargin
        let below = a.minY - offset - (visible.minY + m)
        let above = (visible.maxY - m) - a.maxY - offset
        let right = (visible.maxX - m) - a.maxX - offset
        let left = a.minX - offset - (visible.minX + m)
        switch edge {
        case .bottom where size.height > below && above > below: return .top
        case .top where size.height > above && below > above: return .bottom
        case .right where size.width > right && left > right: return .left
        case .left where size.width > left && right > left: return .right
        default: return edge
        }
    }

    /// The space the resolved side offers — the `var(--radix-available-
    /// height)` the popup's max-h is capped by. Side popups get the
    /// visible column height (their align axis is vertical).
    private func availableHeight(
        _ edge: Edge, anchor a: CGRect, offset: CGFloat, visible: CGRect
    ) -> CGFloat {
        let m = Self.screenMargin
        switch edge {
        case .bottom: return max(0, a.minY - offset - (visible.minY + m))
        case .top: return max(0, (visible.maxY - m) - a.maxY - offset)
        case .left, .right: return max(0, visible.height - 2 * m)
        }
    }

    /// Clamp the resolved origin inside the visible frame (Radix shift)
    /// — flipped or not, the popup never renders off-screen.
    private func clamped(
        x: CGFloat, y: CGFloat, size: CGSize, visible: CGRect
    ) -> (CGFloat, CGFloat) {
        let m = Self.screenMargin
        let cx = min(
            max(x, visible.minX + m),
            max(visible.minX + m, visible.maxX - m - size.width)
        )
        let cy = min(
            max(y, visible.minY + m),
            max(visible.minY + m, visible.maxY - m - size.height)
        )
        return (cx, cy)
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
            let k = ObjectIdentifier(clip)
            if var e = Self.clipFollows[k] {
                e.count += 1
                Self.clipFollows[k] = e
            } else {
                Self.clipFollows[k] = (1, clip.postsBoundsChangedNotifications)
                clip.postsBoundsChangedNotifications = true
            }
            followedClip = clip
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
    }

    private func reposition() {
        guard let panel, let anchor, let window = anchor.window,
              let p = placement else { return }
        let a = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: -20_000, y: -20_000, width: 40_000, height: 40_000)
        let bleed = Self.shadowBleed
        let content = CGSize(
            width: panel.frame.width - 2 * bleed,
            height: panel.frame.height - 2 * bleed
        )
        // Re-resolve the flip — a resize can move the anchor to a side
        // with more room than the one chosen at present time.
        let edge = resolveEdge(p.edge, size: content, anchor: a,
                               offset: p.offset, visible: visible)
        if edge != p.edge {
            placement = (edge, p.align, p.offset)
            hiddenT = Self.hiddenTransform(for: motion, size: content, edge: edge)
        }
        var x = popupX(edge: edge, align: p.align, offset: p.offset,
                       width: content.width, anchor: a)
        var y = popupY(edge: edge, align: p.align, offset: p.offset,
                       height: content.height, anchor: a)
        (x, y) = clamped(x: x, y: y, size: content, visible: visible)
        if ProcessInfo.processInfo.environment["FLUID_POPLOG"] != nil {
            FileHandle.standardError.write(
                "POP reposition anchor=\(a) win=\(window.frame)\n"
                    .data(using: .utf8)!)
        }
        panel.setFrameOrigin(NSPoint(x: x - bleed, y: y - bleed))
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

    /// `notify` suppresses onDismissed for the present-swap path — the
    /// caller knows the popup is going; reporting it would bounce the
    /// driving binding closed and land a dismiss on the NEW panel.
    func dismiss(animated: Bool = true, reason: String = "", notify: Bool = true) {
        if reason != "ack" { ackWork?.cancel(); ackWork = nil }
        // A second ANIMATED dismiss mid-exit is a no-op — the armed
        // teardown already lands it (an instant dismiss still forces the
        // teardown through below).
        if isClosing, animated { return }
        // Every dismissal invalidates any teardown already queued —
        // generation-guarded so a stale one can't wipe a new panel.
        generation += 1
        teardownWork?.cancel()
        teardownWork = nil
        guard let panel else { isClosing = false; return }
        // Dying panels stop answering Esc at close-start — a parent's
        // yield check must see through to itself during our exit window.
        (panel as? FluidPopupPanel)?.handlesEscape = false
        // NOTE: notify:false suppresses onDismissed only — the closing
        // post and onWillDismiss still fire (they release routing state,
        // which a silent swap must do too). Unreachable outside the
        // mid-exit swap today, where isClosing short-circuits anyway.
        if !isClosing {
            NotificationCenter.default.post(name: Self.closing, object: panel)
            // Subscribers release routing latches at close-start — the exit
            // window (~200ms) must not keep owning the parent's keys.
            onWillDismiss?()
        }
        if animated {
            isClosing = true
            // Exit on the layer — same spring back to the hidden pose,
            // from wherever the enter spring actually is right now.
            if let layer = hostView?.layer ?? panel.contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let liveT = layer.presentation()?.transform
                    ?? CATransform3DIdentity
                let liveO = layer.presentation()?.opacity ?? 1
                layer.transform = hiddenT
                layer.opacity = 0
                CATransaction.commit()
                layer.removeAnimation(forKey: "in.t")
                layer.removeAnimation(forKey: "in.o")
                layer.add(Self.popupSpring(
                    "transform", from: NSValue(caTransform3D: liveT),
                    to: NSValue(caTransform3D: hiddenT)), forKey: "out.t")
                layer.add(Self.popupSpring(
                    "opacity", from: liveO, to: 0), forKey: "out.o")
            }
            // Release the window once the exit spring lands — duration
            // derived from the spring itself, not a hardcoded guess.
            let gen = generation
            let work = DispatchWorkItem { [weak self, weak panel] in
                guard let self, let panel,
                      gen == self.generation, self.panel === panel
                else { return }
                self.teardownWork = nil
                self.teardown(panel, notify: notify)
            }
            teardownWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.exitSettle, execute: work
            )
        } else {
            teardown(panel, notify: notify)
        }
    }

    /// The fast exit spring's real settle time plus a safety buffer —
    /// the source's exitFallbackMs(spring.fast) = 60ms + 100.
    private static let exitSettle: TimeInterval = {
        popupSpring("opacity", from: 1, to: 0).settlingDuration + 0.06
    }()

    /// Hidden-state transform in layer space (y-up, so the popup's −4pt
    /// SwiftUI offset is +4 here). The .popup scale anchors at the
    /// OPENING edge — popup.ts's data-[side=…] origin rules (top→bottom,
    /// left→right, right→left) — baked into the matrix as T(p)·S·T(−p)
    /// so the layer's anchorPoint stays default and relayouts can't
    /// fight it. Enter y is ±4 toward the anchor on top/bottom only.
    private static func hiddenTransform(
        for motion: Motion, size: CGSize, edge: Edge
    ) -> CATransform3D {
        switch motion {
        case .popup:
            let pivot: CGPoint
            var dy: CGFloat = 0
            switch edge {
            case .bottom: pivot = CGPoint(x: size.width / 2, y: size.height); dy = 4
            case .top:    pivot = CGPoint(x: size.width / 2, y: 0); dy = -4
            case .left:   pivot = CGPoint(x: size.width, y: size.height / 2)
            case .right:  pivot = CGPoint(x: 0, y: size.height / 2)
            }
            // CALayer applies the transform about anchorPoint (center),
            // so the pivot shift is pivot−center — T(p−a₀)·S·T(a₀−p),
            // not T(p)·S·T(−p) (that leaves a (I−S)·a₀ residual pushing
            // every popup 2% of its height toward the pivot).
            let tx = pivot.x - size.width / 2
            let ty = pivot.y - size.height / 2
            let p = CATransform3DMakeTranslation(tx, ty, 0)
            let pinv = CATransform3DMakeTranslation(-tx, -ty, 0)
            return CATransform3DConcat(
                CATransform3DMakeTranslation(0, dy, 0),
                CATransform3DConcat(
                    CATransform3DConcat(p, CATransform3DMakeScale(1, 0.96, 1)),
                    pinv))
        case .tooltip:
            switch edge {
            case .top:    return CATransform3DMakeTranslation(0, -4, 0)
            case .bottom: return CATransform3DMakeTranslation(0, 4, 0)
            case .left:   return CATransform3DMakeTranslation(4, 0, 0)
            case .right:  return CATransform3DMakeTranslation(-4, 0, 0)
            }
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

    /// The real teardown — only ever run against the CURRENT panel (the
    /// deferred exit path double-checks generation + identity before
    /// landing here, and this guard is the last line of defense: a stale
    /// teardown must not strip the live panel's monitors or emit a
    /// phantom onDismissed).
    private func teardown(_ panel: NSPanel, notify: Bool = true) {
        guard self.panel === panel else { return }
        ackWork?.cancel()
        ackWork = nil
        teardownWork?.cancel()
        teardownWork = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        unfollowClip()
        isClosing = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        hostView = nil
        ownerWindow = nil
        if notify { onDismissed?() }
        // Released AFTER firing — these closures capture subscriber
        // state (view bindings → the controller's own @State storage),
        // so holding them past teardown keeps every controller alive in
        // a retain cycle. Callers reinstall on each present.
        onDismissed = nil
        onWillDismiss = nil
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
    /// The shared box keeps the open panel's height live (Popper's
    /// ResizeObserver half of autoUpdate).
    @State private var sizeBox = FluidPopupSizeBox()
    /// The pending present — spins until the anchor resolves so a menu
    /// bound open at mount still opens (the tooltip's anchor spin).
    @State private var presentTask: Task<Void, Never>?
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
                            .onAppear { sizeBox.height = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in sizeBox.height = h }
                    })
                    .opacity(0)
                    .allowsHitTesting(false)
                    .clipped()
                    .environment(\.fluidHover, probeHover)
                    .environment(\.fluidMenuScope, probeScope)
                    .accessibilityHidden(true)
            )
            // initial: true — a menu bound open at mount must still open.
            .onChange(of: isPresented, initial: true) { _, open in
                presentTask?.cancel()
                presentTask = nil
                if open {
                    let controller = self.controller
                    presentTask = Task { @MainActor in
                        // The anchor's NSView materializes a runloop after
                        // the modifier — spin briefly rather than letting
                        // present()'s anchor.window guard silently no-op
                        // (the tooltip does the same in presentNow()).
                        for _ in 0..<60 where controller.anchorScreenRect() == nil {
                            try? await Task.sleep(nanoseconds: 4_000_000)
                            guard !Task.isCancelled else { return }
                        }
                        guard !Task.isCancelled, isPresented else { return }
                        controller.present(
                            edge: side, align: align, offset: sideOffset
                        ) {
                            FluidMenuPanel(
                                checkedIndex: checkedIndex,
                                disabledIndices: disabledIndices,
                                substrate: substrate,
                                width: width,
                                maxHeight: maxHeight,
                                naturalHeight: sizeBox.height > 0 ? sizeBox.height : nil,
                                onPick: { i in onPick?(i); dismissForSelection() },
                                navSeed: navSeed,
                                keyWindow: { [weak controller] in
                                    controller?.ownerWindow
                                },
                                onExit: { isPresented = false },
                                // During our own exit animation nav keys
                                // go inert — the window eats them
                                // otherwise.
                                deadWhen: { [weak controller] in
                                    controller?.isClosing ?? true
                                },
                                content: rows
                            )
                            .environment(\.fluidMenuDismiss, { dismissForSelection() })
                            // Instant exits (Esc/Tab) bypass the
                            // selection-acknowledgment defer.
                            .environment(\.fluidMenuExit, { isPresented = false })
                            // Live content height — resizes while open
                            // refit the panel (Popper autoUpdate).
                            .environment(\.fluidPopupSize, sizeBox)
                        }
                        // Reinstalled per present — teardown nils the
                        // callbacks so their captured state can't pin
                        // the controller in a retain cycle.
                        let presented = $isPresented
                        controller.onDismissed = { presented.wrappedValue = false }
                    }
                } else {
                    controller.dismiss()
                }
            }
            .onAppear {
                let presented = $isPresented
                controller.onDismissed = { presented.wrappedValue = false }
            }
            .onDisappear {
                // SwiftUI can drop the modifier while the popup is open —
                // the anchor view is going away so the panel must too.
                presentTask?.cancel()
                presentTask = nil
                controller.dismiss(animated: false)
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

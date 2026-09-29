import SwiftUI

// Choice rows — checkbox-group.tsx + radio-group.tsx. Rows are 36px, px-3,
// gap-2, fluid-hovered; the label swaps to semibold when selected (an
// invisible semibold twin keeps the row width stable, like the source's
// stacked spans). Checked rows sit on merged bg-active blocks — contiguous
// selections share one rounded block (use-merge-split), which this ports
// as one rect per contiguous run springing with the moderate tier.
//
// Keyboard: every enabled row binds one shared per-group @FocusState.
// Checkbox rows are all tab stops (the source's tabIndex=0 on each row);
// radio rows rove — only the selected row is tabbable, or the first
// enabled one when nothing is selected (the source's tabIndex={0|-1}).
// Arrows wrap through the enabled rows — up/down for checkbox, all four
// for radio, whose nav also selects the target (items[next].click()).
// Home/End jump the ends; disabled rows skip out of nav and hover. The
// ring is focus-visible: a pointer press latches it off until a keypress.

// MARK: - Merged selection blocks

/// One bg-active block per contiguous run of checked indices, drawn in the
/// enclosing FluidContainer's coordinate space. React's merge-split runs a
/// two-block converge choreography; at rest and for single-row changes this
/// reads identically — a rounded block spanning the run.
///
/// Blocks carry stable ids (the source's prevGroupMap member-overlap
/// reuse) so a growing/shrinking run morphs instead of exit+re-enter.
/// Fresh blocks fade in over 80ms (the transition's `opacity: 0.08`);
/// dropped ids linger as ghosts fading out over the exit tier's 120ms.
struct FluidSelectionBlocks: View {
    let hover: FluidHover
    let checked: Set<Int>
    var mergedRadius: CGFloat = FluidShape.rounded.merged
    /// Radio groups drop the block instantly on deselect — the source
    /// mounts no AnimatePresence around it (radio-group.tsx:153); the
    /// checkbox's merged runs keep the 120ms ghost.
    var exitFades = true
    /// Fresh blocks fade in over 80ms by default; surfaces whose source
    /// mounts `initial={false}` (radio, combobox single) pop instead.
    var enterFades = true
    /// Pin every block to one identity — single-select surfaces (radio,
    /// combobox) glide the ONE block between rows instead of splitting a
    /// run (the source's single checkedRect / pinned radio block).
    var pinIds = false

    /// What the ZStack draws: live runs plus departed ghosts mid-fade.
    private struct Block: Equatable {
        let id: Int
        var rect: CGRect
        var departing = false
    }
    private struct BlockSpec: Equatable { let id: Int; let rect: CGRect }

    @State private var shown: [Block] = []
    @State private var runIds = RunIds()

    /// Stable per-run ids — a run keeps the id any of its members carried
    /// last layout (useSelectionRuns in the source).
    private final class RunIds {
        private var map: [Int: Int] = [:]
        private var next = 0

        func ids(for runs: [[Int]]) -> [Int] {
            var used = Set<Int>()
            var newMap: [Int: Int] = [:]
            let out = runs.map { members -> Int in
                let reuse = members
                    .compactMap { map[$0] }
                    .first { !used.contains($0) }
                let id = reuse ?? { next += 1; return next }()
                used.insert(id)
                for m in members { newMap[m] = id }
                return id
            }
            map = newMap
            return out
        }
    }

    /// Contiguous index runs → (stableId, unionRect) pairs. A missing rect
    /// skips its row — the source's rectOf returns null rather than
    /// unioning a zero rect that stretches the block to the origin. In
    /// single-select mode (exitFades false) the one block keeps a pinned
    /// id so a selection MOVE glides on the moderate spring instead of
    /// drop+fade — the source's single motion.div does the same.
    private var blocks: [BlockSpec] {
        var runs: [(lo: Int, hi: Int)] = []
        for i in checked.sorted() {
            if let last = runs.last, i == last.hi + 1 {
                runs[runs.count - 1].hi = i
            } else {
                runs.append((i, i))
            }
        }
        let members = runs.map { Array($0.lo...$0.hi) }
        return zip(runIds.ids(for: members), members).compactMap { id, ms in
            var union: CGRect?
            for i in ms {
                guard let r = hover.rects[i] else { continue }
                union = union?.union(r) ?? r
            }
            return union.map { BlockSpec(id: pinIds ? -1 : id, rect: $0) }
        }
    }

    /// Reconcile the on-screen list with the new run set: persisting ids
    /// take the new rect, fresh ids mount (their view fades in), dropped
    /// ids become ghosts that fade out then get reaped.
    private func sync(_ new: [BlockSpec]) {
        let live = Set(new.map(\.id))
        var next: [Block] = new.map { Block(id: $0.id, rect: $0.rect) }
        for b in shown where !live.contains(b.id) {
            guard exitFades else { continue }
            var ghost = b
            if !ghost.departing {
                ghost.departing = true
                let id = b.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    shown.removeAll { $0.id == id && $0.departing }
                }
            }
            next.append(ghost)
        }
        shown = next
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(shown, id: \.id) { b in
                SelectionBlock(rect: b.rect, radius: mergedRadius,
                               departing: b.departing, enterFades: enterFades)
            }
        }
        .animation(FluidSpring.moderate, value: shown)
        .onChange(of: blocks, initial: true) { _, new in sync(new) }
    }

    /// One block's opacity choreography — mount at 0 and ease in over
    /// 80ms (or pop when the source renders initial={false}); a departed
    /// ghost eases out over 120ms. Geometry rides the parent's moderate
    /// spring.
    private struct SelectionBlock: View {
        let rect: CGRect
        let radius: CGFloat
        let departing: Bool
        let enterFades: Bool
        @State private var appeared = false

        var body: some View {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(FluidTone.active)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(appeared && !departing ? 1 : 0)
                .onAppear { appeared = true }
                .animation(.easeOut(duration: 0.08), value: appeared && enterFades)
                .animation(.easeOut(duration: 0.12), value: departing)
        }
    }
}

// MARK: - Row label

/// The two-span label: invisible semibold sizer + visible label that
/// emboldens when selected — selection never changes the row's width.
struct FluidRowLabel: View {
    let label: String
    let selected: Bool
    var lit: Bool = false
    var size: FluidSize = .default

    var body: some View {
        ZStack {
            Text(label)
                .font(.system(size: size.text, weight: .semibold))
                .hidden()
            Text(label)
                .font(.system(size: size.text, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected || lit ? FluidTone.foreground : FluidTone.mutedForeground)
        }
        // transition-[color,font-variation-settings] duration-80 — every
        // state swap (selected, lit) eases the tint, not just selected.
        .animation(.easeOut(duration: 0.08), value: selected)
        .animation(.easeOut(duration: 0.08), value: lit)
    }
}

// MARK: - Group keyboard wiring

/// Per-row disabled flags — arrow nav and the hover pick skip these rows.
private struct FluidCheckDisabledKey: PreferenceKey {
    static var defaultValue: [Int: Bool] { [:] }
    static func reduce(value: inout [Int: Bool], nextValue: () -> [Int: Bool]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// Per-row self-declared selection — the source's third radio mode where
/// an item carries `selected` outside the group binding
/// (radio-group.tsx:284-285). Those rows are roving stops too.
private struct FluidCheckSelectedKey: PreferenceKey {
    static var defaultValue: [Int: Bool] { [:] }
    static func reduce(value: inout [Int: Bool], nextValue: () -> [Int: Bool]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// index → onSelect, so arrow/Home/End nav can click the target row —
/// the source's items[next].click() (radio-group.tsx:132), which runs
/// the row's own select path rather than writing the binding directly.
/// Rows register while visible (the FluidCardActivations idiom).
private final class FluidCheckSelects {
    private var map: [Int: () -> Void] = [:]
    func register(_ i: Int, _ a: @escaping () -> Void) { map[i] = a }
    func unregister(_ i: Int) { map[i] = nil }
    /// Returns false when the row isn't registered (fallback writes the
    /// binding directly).
    @discardableResult func call(_ i: Int) -> Bool {
        guard let a = map[i] else { return false }
        a(); return true
    }
}

/// What a row needs from its enclosing group — the port of the React
/// group context: the shared focus binding, the enabled-row nav list, the
/// radio group's select-on-nav, and the pointer-modality latch writes.
private struct FluidCheckGroupCtx {
    /// The group's @FocusState — rows bind `.focused(equals:)` to it.
    var focused: FocusState<Int?>.Binding
    /// Enabled item indices in row order — the list arrows/Home/End walk.
    var navIndices: () -> [Int]
    /// Radio only: the roving tab-stop test — selected row, or first
    /// enabled when nothing is selected. nil = every enabled row is a
    /// stop (checkbox's tabIndex=0).
    var isTabStop: ((Int) -> Bool)? = nil
    /// Radio only: arrows/Home/End also click the target
    /// (radio-group.tsx:132) — writes the group's selection binding and
    /// lands focus once the new tab stop renders. nil = arrows move focus
    /// only (checkbox — checkbox-group.tsx:146-158).
    var navSelect: ((Int) -> Void)? = nil
    /// Radio only: left/right arrows navigate too (radio-group.tsx:126).
    var horizontalNav = false
    /// Row pointer-down: latches pointer modality and moves focus to the
    /// pressed row (the source's onMouseDown → row.focus()).
    var pressFocus: (Int) -> Void = { _ in }
    /// Row pointer-up.
    var endPress: () -> Void = {}
    /// A handled nav/activation key is keyboard modality: arms the group's
    /// ring+fill and clears the pointer latch (:focus-visible). Focus alone
    /// never arms it — AppKit's auto-assigned initial first responder
    /// would otherwise light row 0 at window open without input.
    var armNav: () -> Void = {}
    /// Radio only: the rows' select registry nav clicks through.
    var selects: FluidCheckSelects? = nil
}

private struct FluidCheckGroupKey: EnvironmentKey {
    static let defaultValue: FluidCheckGroupCtx? = nil
}

extension EnvironmentValues {
    fileprivate var fluidCheckGroup: FluidCheckGroupCtx? {
        get { self[FluidCheckGroupKey.self] }
        set { self[FluidCheckGroupKey.self] = newValue }
    }
}

/// Pins \.fluidSize only when the group actually got one — omitted follows
/// the ambient provider (the source's `size ? <SizeProvider> : node`).
private struct FluidCheckSizePin: ViewModifier {
    let size: FluidSize?
    func body(content: Content) -> some View {
        if let size { content.environment(\.fluidSize, size) } else { content }
    }
}

/// role="group" / role="radiogroup" — a containment element, with the
/// accessible name when the caller supplies one (the source's aria-label
/// pass-through).
private struct FluidGroupA11y: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(label))
        } else {
            content.accessibilityElement(children: .contain)
        }
    }
}

/// The focus-visible ring around a row — the source's focusRect border
/// div: a bare 1px --focus-ring border on a box inset −2px (its painted
/// band sits 1–2px outside the row with a transparent gap, not an opaque
/// background-colored offset band — checkbox-group.tsx:181-189).
private struct FluidCheckFocusRing: View {
    @Environment(\.fluidShape) private var shape
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: shape.focusRing, style: .continuous)
            .strokeBorder(FluidTone.focusRing, lineWidth: 1)
            .padding(-2)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

/// A row's keyboard/pointer wiring: the shared @FocusState binding, wrap-
/// around arrow nav, Home/End, Return activation (Space rides the row
/// Button's native activation), and the press-focus latch.
private struct FluidCheckRowFocus: ViewModifier {
    let index: Int
    let enabled: Bool
    /// Whether the row currently holds the group's tab stop — always true
    /// for checkbox rows (tabIndex=0); radio rows rove.
    let tabStop: Bool
    let group: FluidCheckGroupCtx?
    /// Return-key activation — the row's onToggle/onSelect.
    var activate: () -> Void = {}

    /// Radix wraps: past the last row lands back on the first.
    private func move(_ dir: Int, in group: FluidCheckGroupCtx) {
        let idxs = group.navIndices()
        guard let pos = idxs.firstIndex(of: index), !idxs.isEmpty else { return }
        let next = idxs[(pos + dir + idxs.count) % idxs.count]
        group.armNav()
        if let navSelect = group.navSelect { navSelect(next) }
        else { group.focused.wrappedValue = next }
    }

    private func edge(first: Bool, in group: FluidCheckGroupCtx) {
        let idxs = group.navIndices()
        guard let next = first ? idxs.first : idxs.last else { return }
        group.armNav()
        if let navSelect = group.navSelect { navSelect(next) }
        else { group.focused.wrappedValue = next }
    }

    func body(content: Content) -> some View {
        if let group {
            content
                // A focused row stays focusable even once it loses the
                // roving stop — focus writes never get yanked mid-flight.
                .focusable(enabled && (tabStop || group.focused.wrappedValue == index))
                .focused(group.focused, equals: index)
                .focusEffectDisabled()
                // The press: latch pointer modality and land focus on the
                // row — the source's onMouseDown preventDefault + focus().
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in group.pressFocus(index) }
                        .onEnded { _ in group.endPress() }
                )
                // The source's keydown repeats while held — .down+.repeat.
                // Each handled nav/activation also arms keyboard modality.
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
                    move(-1, in: group); return .handled
                }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
                    move(1, in: group); return .handled
                }
                .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
                    guard group.horizontalNav else { return .ignored }
                    move(-1, in: group); return .handled
                }
                .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in
                    guard group.horizontalNav else { return .ignored }
                    move(1, in: group); return .handled
                }
                .onKeyPress(.home, phases: [.down, .repeat]) { _ in
                    edge(first: true, in: group); return .handled
                }
                .onKeyPress(.end, phases: [.down, .repeat]) { _ in
                    edge(first: false, in: group); return .handled
                }
                // Space rides the row Button's native activation — observe
                // it only to arm keyboard modality; .ignored keeps the
                // activation intact.
                .onKeyPress(.space, phases: [.down, .repeat]) { _ in
                    group.armNav(); return .ignored
                }
                .onKeyPress(.return, phases: [.down, .repeat]) { _ in
                    group.armNav(); activate(); return .handled
                }
        } else {
            content.focusable(enabled)
        }
    }
}

// MARK: - Checkbox group

/// `CheckboxGroup`: fluid-hover rows with merged checked blocks.
struct FluidCheckboxGroup<Content: View>: View {
    @Binding var checked: Set<Int>
    /// Pins every row to one ladder step; omitted follows the ambient
    /// \.fluidSize (the source's optional SizeProvider wrap).
    var size: FluidSize? = nil
    /// The group's accessible name — role="group" + an aria-label analog.
    var label: String? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidShape) private var shape
    @State private var hover = FluidHover(axis: .y)
    @State private var disabledIndices: Set<Int> = []
    @FocusState private var focusedIndex: Int?
    @State private var pointerFocus = false
    @State private var pointerDown = false
    /// Keyboard modality: only a handled nav/activation key arms the ring
    /// (and focus-lit hover). AppKit auto-assigns an initial first
    /// responder at window open — focus alone must not light the row.
    @State private var navArmed = false

    /// Enabled rows in row order — the arrow/Home/End nav list.
    private var navIndices: [Int] {
        hover.rects.keys.sorted().filter { !disabledIndices.contains($0) }
    }

    /// The ring's target — nil until a keypress arms keyboard modality,
    /// and nil while the pointer owns it.
    private var focusRect: CGRect? {
        guard navArmed, !pointerFocus else { return nil }
        return focusedIndex.flatMap { hover.rects[$0] }
    }

    var body: some View {
        FluidContainer(hover: hover, radius: shape.bg) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .background(alignment: .topLeading) {
            FluidSelectionBlocks(hover: hover, checked: checked, mergedRadius: shape.merged)
        }
        .overlay(alignment: .topLeading) {
            if let r = focusRect { FluidCheckFocusRing(rect: r) }
        }
        // Row-to-row moves glide on the fast tier; mount/unmount fade.
        .animation(FluidSpring.fast, value: focusRect)
        .modifier(FluidCheckSizePin(size: size))
        // w-72 max-w-full — the group's 288px column, shrinking only
        // under a narrower container.
        .frame(idealWidth: 288, maxWidth: 288, alignment: .leading)
        .modifier(FluidGroupA11y(label: label))
        .environment(\.fluidCheckGroup, FluidCheckGroupCtx(
            focused: $focusedIndex,
            navIndices: { navIndices },
            pressFocus: pressFocus,
            endPress: { pointerDown = false },
            armNav: { navArmed = true; pointerFocus = false }
        ))
        .onPreferenceChange(FluidCheckDisabledKey.self) { flags in
            let set = Set(flags.filter { $0.value }.map(\.key))
            disabledIndices = set
            hover.isItemDisabled = { i in set.contains(i) }
        }
        .onChange(of: focusedIndex) { _, f in
            // :focus-visible — a focus that arrives while no press is down
            // is keyboard modality and clears the latch; blur resets.
            if f == nil || !pointerDown { pointerFocus = false }
            // A focus arriving under a keyDown (Tab entry, anything the
            // row didn't handle) is keyboard modality too — AppKit's
            // auto-assigned first responder isn't, so it stays dark.
            if f != nil, !pointerDown, NSApp.currentEvent?.type == .keyDown {
                navArmed = true
                pointerFocus = false
            }
            // The group's onFocus/onBlur lights the row — but only once
            // real key input (or an in-flight press) proves user intent;
            // the auto-assigned first responder must not paint at open.
            hover.activeIndex = (navArmed || pointerDown) ? f : nil
        }
    }

    /// Row pointer-down: latch the ring off and focus the pressed row —
    /// the source's onMouseDown → row.focus(). Every enabled row is a
    /// stop, so the write lands right away.
    private func pressFocus(_ i: Int) {
        guard !disabledIndices.contains(i) else { return }
        pointerFocus = true
        pointerDown = true
        // A press reasserts pointer modality — the arming drops so a
        // blur→refocus can't paint a ring from stale keyboard state.
        navArmed = false
        focusedIndex = i
    }
}

/// `CheckboxItem` — toggles on click; Space/Return toggle, arrows/Home/End
/// move focus (checkbox-group.tsx:136-159, 263-268).
struct FluidCheckboxItem: View {
    let index: Int
    let label: String
    let checked: Bool
    var size: FluidSize? = nil
    var isDisabled = false
    var onToggle: () -> Void = {}

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidCheckGroup) private var group
    @Environment(\.fluidSize) private var envSize
    @Environment(\.isEnabled) private var envEnabled

    private var resolvedSize: FluidSize { size ?? envSize }
    private var enabled: Bool { envEnabled && !isDisabled }
    private var isActive: Bool { hover?.activeIndex == index }

    var body: some View {
        let size = resolvedSize
        Button(action: onToggle) {
            HStack(spacing: size.gap) {
                FluidCheckSquare(checked: checked, hovered: isActive, compact: size == .compact)
                FluidRowLabel(label: label, selected: checked, lit: isActive, size: size)
            }
            .padding(.horizontal, size.px)
            .frame(height: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .fluidItem(index)
        .modifier(FluidCheckRowFocus(
            index: index, enabled: enabled, tabStop: true, group: group,
            activate: onToggle
        ))
        .preference(key: FluidCheckDisabledKey.self, value: [index: !enabled])
        // role="checkbox" + aria-checked — the row is a togglable button
        // named by its label (the invisible semibold twin would otherwise
        // double-speak the name).
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits([.isButton, .isToggle])
        .accessibilityValue(Text(checked ? "On" : "Off"))
    }
}

/// The 16px box: 1.5px border (border → neutral-400 hover → transparent
/// when checked), 5px radius, check draws in on selection.
struct FluidCheckSquare: View {
    let checked: Bool
    var hovered = false
    var compact = false

    private var side: CGFloat { compact ? 14 : 16 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
                .strokeBorder(
                    checked ? .clear : (hovered ? FluidTone.borderStrong : FluidTone.border),
                    lineWidth: 1.5
                )
                // The border swap always eases 80ms (transition-all) —
                // scoped here so it doesn't ride the check trim's 40ms
                // uncheck reversal.
                .animation(.easeOut(duration: 0.08), value: checked)
            // M6 12L10 16L18 8 in a 24-unit viewBox, rendered at 18px
            // (compact 16) centered on the box — the svg overhangs the
            // square and strokeWidth 2 lands at 1.5px effective. pathLength
            // draws in 80ms easeOut, out 40ms easeIn (checked-driven trim
            // so the uncheck reverses the draw).
            CheckArm()
                .trim(from: 0, to: checked ? 1 : 0)
                .stroke(
                    style: StrokeStyle(lineWidth: glyph / 12, lineCap: .round, lineJoin: .round)
                )
                .foregroundStyle(FluidTone.foreground)
                .frame(width: glyph, height: glyph)
        }
        .frame(width: side, height: side)
        .animation(checked ? .easeOut(duration: 0.08) : .easeIn(duration: 0.04), value: checked)
        // transition-all duration-80 — the border → neutral-400 hover
        // swap eases too (checkbox-group.tsx:292-299).
        .animation(.easeOut(duration: 0.08), value: hovered)
    }

    /// The svg the source renders at 18px (compact 16) over the box.
    private var glyph: CGFloat { compact ? 16 : 18 }

    private struct CheckArm: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 24
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + 6 * s, y: rect.minY + 12 * s))
            p.addLine(to: CGPoint(x: rect.minX + 10 * s, y: rect.minY + 16 * s))
            p.addLine(to: CGPoint(x: rect.minX + 18 * s, y: rect.minY + 8 * s))
            return p
        }
    }
}

// MARK: - Radio group

/// `RadioGroup`: same rows as the checkbox group, one selection — plus
/// roving tabindex: only the selected row is a stop (first enabled row
/// when nothing is selected), and arrow/Home/End nav selects its target.
struct FluidRadioGroup<Content: View>: View {
    @Binding var selection: Int?
    /// Pins every row to one ladder step; omitted follows the ambient
    /// \.fluidSize (the source's optional SizeProvider wrap).
    var size: FluidSize? = nil
    /// The group's accessible name — role="radiogroup" + an aria-label
    /// analog.
    var label: String? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidShape) private var shape
    @State private var hover = FluidHover(axis: .y)
    @State private var disabledIndices: Set<Int> = []
    /// index → the row's onSelect — nav clicks through it (the source's
    /// items[next].click()).
    @State private var selects = FluidCheckSelects()
    @FocusState private var focusedIndex: Int?
    @State private var pointerFocus = false
    @State private var pointerDown = false
    /// Rows carrying their own `selected` — the source's uncontrolled
    /// third mode (radio-group.tsx:284-285).
    @State private var selectedIndices: Set<Int> = []
    /// Keyboard modality: only a handled nav/activation key arms the ring
    /// (and focus-lit hover); the auto-assigned first responder at window
    /// open must not paint ring+fill without input.
    @State private var navArmed = false
    /// Focus to land once a selection change renders — a row isn't a tab
    /// stop (focusable) until the selection that makes it one is drawn.
    @State private var deferredFocus: Int? = nil
    /// The deferred landing's index when a press drove it — it keeps the
    /// pointer latch (a click-focus is not focus-visible).
    @State private var pressFocusTarget: Int? = nil

    /// Enabled rows in row order — the arrow/Home/End nav list.
    private var navIndices: [Int] {
        hover.rects.keys.sorted().filter { !disabledIndices.contains($0) }
    }

    /// The ring's target — nil until a keypress arms keyboard modality,
    /// and nil while the pointer owns it.
    private var focusRect: CGRect? {
        guard navArmed, !pointerFocus else { return nil }
        return focusedIndex.flatMap { hover.rects[$0] }
    }

    /// The roving tab stop: the selected row — the binding's or a row's
    /// own `selected` prop (radio-group.tsx:284-285) — else the first
    /// enabled row (the source's !hasSelection → index 0 fallback keeps
    /// the group keyboard-reachable).
    private func isTabStop(_ i: Int) -> Bool {
        if selectedIndices.contains(i) { return true }
        if let selection { return i == selection }
        return selectedIndices.isEmpty && i == navIndices.first
    }

    /// Arrow/Home/End nav — items[next].focus() + items[next].click() in
    /// the source (radio-group.tsx:131-141): the target row's own onSelect
    /// runs (which writes the binding), and focus defers until the new
    /// tab stop is focusable.
    private func navSelect(_ i: Int) {
        if i == selection {
            focusedIndex = i
            selects.call(i)
        } else {
            deferredFocus = i
            if !selects.call(i) { selection = i }
        }
    }

    /// Row pointer-down: latch the ring off and focus the pressed row —
    /// the source's onMouseDown → row.focus(). A row that isn't the stop
    /// yet defers until the click's selection renders it focusable.
    private func pressFocus(_ i: Int) {
        guard !disabledIndices.contains(i) else { return }
        pointerFocus = true
        pointerDown = true
        // Pointer modality — drop the arming so a blur→refocus can't
        // paint a ring from stale keyboard state.
        navArmed = false
        if isTabStop(i) {
            focusedIndex = i
        } else {
            deferredFocus = i
            pressFocusTarget = i
        }
    }

    /// Row pointer-up. A press whose click never moved the selection
    /// leaves deferredFocus armed — expire it after the click's write had
    /// its turn, or a later unrelated selection change lands focus on the
    /// stale target.
    private func endPress() {
        pointerDown = false
        let stale = deferredFocus
        DispatchQueue.main.async {
            if let stale, deferredFocus == stale, selection != stale {
                deferredFocus = nil
                pressFocusTarget = nil
            }
        }
    }

    var body: some View {
        FluidContainer(hover: hover, radius: shape.bg) {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .background(alignment: .topLeading) {
            FluidSelectionBlocks(
                // The radio's block rounds at shape.bg — the single-select
                // block isn't a merged run (radio-group.tsx:153), pops in
                // and drops instantly, and glides between rows on one id.
                hover: hover,
                checked: selectedIndices.union(selection.map { [$0] } ?? []),
                mergedRadius: shape.bg,
                exitFades: false,
                enterFades: false,
                pinIds: true
            )
        }
        .overlay(alignment: .topLeading) {
            if let r = focusRect { FluidCheckFocusRing(rect: r) }
        }
        .animation(FluidSpring.fast, value: focusRect)
        .modifier(FluidCheckSizePin(size: size))
        // w-72 max-w-full — the group's 288px column, shrinking only
        // under a narrower container.
        .frame(idealWidth: 288, maxWidth: 288, alignment: .leading)
        .modifier(FluidGroupA11y(label: label))
        .environment(\.fluidCheckGroup, FluidCheckGroupCtx(
            focused: $focusedIndex,
            navIndices: { navIndices },
            isTabStop: isTabStop,
            navSelect: navSelect,
            horizontalNav: true,
            pressFocus: pressFocus,
            endPress: endPress,
            armNav: { navArmed = true; pointerFocus = false },
            selects: selects
        ))
        .onPreferenceChange(FluidCheckDisabledKey.self) { flags in
            let set = Set(flags.filter { $0.value }.map(\.key))
            disabledIndices = set
            hover.isItemDisabled = { i in set.contains(i) }
        }
        .onPreferenceChange(FluidCheckSelectedKey.self) { flags in
            selectedIndices = Set(flags.filter { $0.value }.map(\.key))
            // Pure per-item mode: no binding write ever fires, so the
            // deferred focus is consumed here — the preference write is
            // what made the target a tab stop.
            if let target = deferredFocus, selectedIndices.contains(target) {
                deferredFocus = nil
                pressFocusTarget = nil
                DispatchQueue.main.async { focusedIndex = target }
            }
        }
        .onChange(of: selection) { _, sel in
            // The deferred focus lands after the update that made the
            // target a tab stop — the focus write would be dropped earlier.
            // Only the aimed-at selection may consume it: an unrelated
            // write drops the stale target instead of focusing wrong.
            guard let target = deferredFocus else { return }
            deferredFocus = nil
            guard sel == target else { pressFocusTarget = nil; return }
            DispatchQueue.main.async { focusedIndex = target }
        }
        .onChange(of: focusedIndex) { _, f in
            // :focus-visible — a focus arriving while no press is down is
            // keyboard modality and clears the latch; the deferred landing
            // of a press-focus keeps it; blur always resets.
            let landedPress = f != nil && f == pressFocusTarget
            pressFocusTarget = nil
            if f == nil || (!pointerDown && !landedPress) { pointerFocus = false }
            // A focus arriving under a keyDown (Tab entry) is keyboard
            // modality — the auto-assigned first responder isn't.
            if f != nil, !pointerDown, !landedPress,
               NSApp.currentEvent?.type == .keyDown {
                navArmed = true
                pointerFocus = false
            }
            // Focus lights the row (the group's onFocus/onBlur) — but only
            // once real key input or a press proves user intent, so the
            // auto-assigned first responder doesn't paint at open.
            hover.activeIndex = (navArmed || pointerDown || landedPress) ? f : nil
        }
    }
}

/// `RadioItem` — selects on click; Space/Return select, arrows/Home/End
/// move focus AND select (radio-group.tsx:116-141, 323-328).
struct FluidRadioItem: View {
    let index: Int
    let label: String
    let selected: Bool
    var size: FluidSize? = nil
    var isDisabled = false
    var onSelect: () -> Void = {}

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidCheckGroup) private var group
    @Environment(\.fluidSize) private var envSize
    @Environment(\.isEnabled) private var envEnabled

    private var resolvedSize: FluidSize { size ?? envSize }
    private var enabled: Bool { envEnabled && !isDisabled }
    private var isActive: Bool { hover?.activeIndex == index }
    /// The group's roving stop — nil context (standalone) = always a stop.
    private var tabStop: Bool {
        group.flatMap { $0.isTabStop?(index) } ?? true
    }

    var body: some View {
        let size = resolvedSize
        Button(action: onSelect) {
            HStack(spacing: size.gap) {
                FluidRadioDot(selected: selected, hovered: isActive, compact: size == .compact)
                FluidRowLabel(label: label, selected: selected, lit: isActive, size: size)
            }
            .padding(.horizontal, size.px)
            .frame(height: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .fluidItem(index)
        .modifier(FluidCheckRowFocus(
            index: index, enabled: enabled, tabStop: tabStop, group: group,
            activate: onSelect
        ))
        .preference(key: FluidCheckDisabledKey.self, value: [index: !enabled])
        .preference(key: FluidCheckSelectedKey.self, value: [index: selected])
        // role="radio" + aria-checked — a button that is .isSelected when
        // checked, named by its label.
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityValue(Text(selected ? "On" : "Off"))
        // Publish the row's select path — arrow/Home/End nav clicks it
        // (items[next].click() — radio-group.tsx:132).
        .onAppear { registerSelect() }
        .onDisappear { group?.selects?.unregister(index) }
        // The stored closure is a struct snapshot — re-register on any
        // input that could stale it.
        .onChange(of: enabled) { _, _ in registerSelect() }
        .onChange(of: index) { old, _ in
            group?.selects?.unregister(old)
            registerSelect()
        }
    }

    /// items[next].click() routing — the group's nav calls the registered
    /// closure so the row's own onSelect runs.
    private func registerSelect() {
        guard let selects = group?.selects else { return }
        selects.unregister(index)
        guard enabled else { return }
        selects.register(index) { [self] in
            if enabled { onSelect() }
        }
    }
}

/// The 16px circle: border like the checkbox's; selected swaps it for an
/// 8px fg dot that scales in (scale 0.3→1, spring.fast).
struct FluidRadioDot: View {
    let selected: Bool
    var hovered = false
    var compact = false

    private var side: CGFloat { compact ? 14 : 16 }

    var body: some View {
        ZStack {
            // The ring stays mounted — selection eases it to transparent
            // over 80ms like the source's transition-all, not pop off.
            Circle()
                .strokeBorder(
                    selected ? .clear
                        : (hovered ? FluidTone.borderStrong : FluidTone.border),
                    lineWidth: 1.5
                )
                .animation(.easeOut(duration: 0.08), value: selected)
            if selected {
                Circle()
                    .fill(FluidTone.foreground)
                    .frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: side, height: side)
        // In on the fast spring; out on the source's 40ms tween
        // (exit: { transition: { duration: 0.04 } } — framer's default ease).
        .animation(
            selected
                ? FluidSpring.fast
                : .timingCurve(0.25, 0.1, 0.35, 1, duration: 0.04),
            value: selected
        )
        // transition-all duration-80 — border → neutral-400 hover ease
        // (radio-group.tsx:347-353).
        .animation(.easeOut(duration: 0.08), value: hovered)
    }
}

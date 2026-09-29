import SwiftUI
import AppKit

// CommandMenu — fluid-demo/components/ui/command-menu.tsx.
// The palette: search field (h-12, icon muted→fg while focused), optional
// subtle-tab / filters rows, a filtered sectioned list where rows are
// fluid-hover items AND the keyboard highlight (one store in the source —
// one `activeIndex` here), Enter to select, ↑↓ wrapping among enabled
// rows, footer hints naming what Enter does to the lit row.

// MARK: - Shortcut engine (command-menu.tsx:118-301)

/// The parsed combo — "mod+k" → ⌘-or-⌃ + K. `mod` matches either platform
/// modifier (⌘ on a Mac, Ctrl elsewhere), so a Ctrl press still opens.
struct FluidParsedShortcut: Equatable {
    var mod = false
    var meta = false
    var ctrl = false
    var alt = false
    var shift = false
    /// Lowercase KeyboardEvent.key spelling — "k", "/", "escape", "enter".
    var key = ""
}

private let fluidModifierTokens: [String: WritableKeyPath<FluidParsedShortcut, Bool>] = [
    "mod": \.mod, "cmd": \.meta, "command": \.meta, "meta": \.meta,
    "win": \.meta, "super": \.meta,
    "ctrl": \.ctrl, "control": \.ctrl,
    "alt": \.alt, "option": \.alt, "opt": \.alt,
    "shift": \.shift,
]

/// Named keys, as KeyboardEvent.key spells them (lowercased).
private let fluidKeyAliases: [String: String] = [
    "esc": "escape", "return": "enter", "space": " ", "spacebar": " ",
    "up": "arrowup", "down": "arrowdown", "left": "arrowleft",
    "right": "arrowright", "del": "delete", "plus": "+",
]

/// Splits a combo on "+", keeping a trailing "+" as the key itself
/// ("mod++" → mod + "+").
func fluidShortcutTokens(_ shortcut: String) -> [String] {
    let trimmed = shortcut.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return [] }
    let tokens = trimmed.split(separator: "+", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    var out: [String] = []
    for (i, t) in tokens.enumerated() {
        if t.isEmpty && i > 0 {
            if out.last != "+" { out.append("+") }
            continue
        }
        if !t.isEmpty { out.append(t) }
    }
    return out
}

func fluidParseShortcut(_ shortcut: String) -> FluidParsedShortcut {
    var p = FluidParsedShortcut()
    for token in fluidShortcutTokens(shortcut) {
        let lower = token.lowercased()
        if let m = fluidModifierTokens[lower] { p[keyPath: m] = true }
        else { p.key = fluidKeyAliases[lower] ?? lower }
    }
    return p
}

/// ANSI keyCode → the name `e.code` reports ("keyk" → "k" minus prefix).
private let fluidANSIKeyCodes: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

/// Named keys are compared by keyCode — characters for arrows/Home are
/// control glyphs no spellcheck survives.
private let fluidNamedKeyCodes: [String: Set<UInt16>] = [
    "escape": [53], "enter": [36, 76], " ": [49], "tab": [48],
    "backspace": [51], "delete": [117],
    "arrowup": [126], "arrowdown": [125], "arrowleft": [123],
    "arrowright": [124], "home": [115], "end": [119],
]

/// Whether a keydown is the parsed combo — command-menu.tsx's
/// matchesShortcut. The physical key stands in only when `key` isn't a
/// Latin letter/digit: ⌥ combos (where `key` becomes a symbol) and
/// non-Latin layouts; a Latin letter is taken at face value so Dvorak's
/// "t" is never read as the physical K.
func fluidMatchesShortcut(_ e: NSEvent, _ p: FluidParsedShortcut) -> Bool {
    guard !p.key.isEmpty else { return false }
    let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let key = (e.charactersIgnoringModifiers ?? "").lowercased()
    let keyOk: Bool
    if let codes = fluidNamedKeyCodes[p.key] {
        keyOk = codes.contains(e.keyCode)
    } else {
        var byCode = false
        if p.key.count == 1, let c = p.key.first,
           c.isASCII, c.isLetter || c.isNumber {
            let typedPlain = key.count == 1
                && (key.first?.isASCII ?? false)
                && (key.first?.isLetter ?? false || key.first?.isNumber ?? false)
            if flags.contains(.option) || !typedPlain {
                byCode = fluidANSIKeyCodes[p.key] == e.keyCode
            }
        }
        keyOk = key == p.key || byCode
    }
    guard keyOk else { return false }
    if p.mod {
        if !flags.contains(.command) && !flags.contains(.control) { return false }
    } else if flags.contains(.command) != p.meta || flags.contains(.control) != p.ctrl {
        return false
    }
    if flags.contains(.option) != p.alt { return false }
    // Shift is implied by an uppercase letter or a shifted symbol, so it is
    // only checked when the combo names it.
    if p.shift && !flags.contains(.shift) { return false }
    return true
}

/// Whether the parsed combo holds any modifier — safe to fire while
/// typing in a field. A bare key stays out of inputs.
func fluidHasModifier(_ p: FluidParsedShortcut) -> Bool {
    p.mod || p.meta || p.ctrl || p.alt
}

private let fluidCapLabels: [String: String] = [
    "mod": "⌘", "meta": "⌘", "ctrl": "⌃", "alt": "⌥", "shift": "⇧",
    "enter": "↵", "escape": "esc", "backspace": "⌫", "delete": "⌦",
    "tab": "⇥", " ": "space", "arrowup": "↑", "arrowdown": "↓",
    "arrowleft": "←", "arrowright": "→",
]

/// A cap that is already glyphs ("⌘", "⌘⇧P") renders as-is, one cap per
/// glyph — the source's PREFORMATTED check.
private func fluidIsPreformatted(_ token: String) -> Bool {
    let glyphs: Set<Character> = ["⌘", "⌃", "⌥", "⇧", "↵", "⌫", "⌦", "⇥", "↑", "↓", "←", "→"]
    let chars = Array(token)
    guard !chars.isEmpty else { return false }
    var i = 0
    while i < chars.count, glyphs.contains(chars[i]) { i += 1 }
    // glyph+ then an optional single ASCII alnum (the source's regex).
    if i == chars.count { return true }
    return i == chars.count - 1 && chars[i].isASCII
        && (chars[i].isLetter || chars[i].isNumber)
}

/// The caps a shortcut displays, in order (Mac always: ⌘ ⌃ ⌥ ⇧ glyphs,
/// letters upper-cased, named keys spelled out).
func fluidShortcutCaps(_ keys: String) -> [String] {
    fluidShortcutTokens(keys).flatMap { token -> [String] in
        if fluidIsPreformatted(token) { return token.map(String.init) }
        let lower = token.lowercased()
        let name = fluidModifierTokens[lower] != nil
            ? tokenKeyName(lower)
            : (fluidKeyAliases[lower] ?? lower)
        if let cap = fluidCapLabels[name] { return [cap] }
        if name.count == 1 { return [name.uppercased()] }
        return [name.prefix(1).uppercased() + name.dropFirst()]
    }
}

/// The caps a list of shortcut strings displays — the source's
/// `keys: string | readonly string[]` flatMap.
func fluidShortcutCaps(_ keys: [String]) -> [String] {
    keys.flatMap { fluidShortcutCaps($0) }
}

/// Modifier token → its ParsedShortcut key name ("mod" → "mod").
private func tokenKeyName(_ lower: String) -> String {
    switch lower {
    case "cmd", "command", "meta", "win", "super": return "meta"
    case "ctrl", "control": return "ctrl"
    case "alt", "option", "opt": return "alt"
    default: return lower
    }
}

// MARK: - Item + filter + sections

struct FluidCommandItem {
    var value: String
    var label: String
    /// What the footer names Enter while the row is highlighted, e.g.
    /// "Open Showcase" for a row labelled "Showcase". Defaults to label.
    var action: String? = nil
    var description: String? = nil
    var icon: String? = nil
    /// Caps in trigger syntax ("mod+p") or pre-formatted ("⌘P"); a list
    /// entry renders one cap per token.
    var shortcut: String? = nil
    var keywords: [String] = []
    var disabled = false
    var group: String? = nil
    var onSelect: (() -> Void)? = nil

    init(_ value: String, label: String? = nil, action: String? = nil,
         description: String? = nil, icon: String? = nil, shortcut: String? = nil,
         keywords: [String] = [], disabled: Bool = false, group: String? = nil,
         onSelect: (() -> Void)? = nil) {
        self.value = value
        self.label = label ?? value
        self.action = action
        self.description = description
        self.icon = icon
        self.shortcut = shortcut
        self.keywords = keywords
        self.disabled = disabled
        self.group = group
        self.onSelect = onSelect
    }
}

struct CommandSection {
    var heading: String?
    var items: [FluidCommandItem]
    var start: Int
}

/// Every whitespace-separated word must appear in
/// label+description+keywords — defaultCommandMenuFilter verbatim.
/// Order is kept: rows never re-sort under the cursor as the query grows.
func fluidCommandMenuDefaultFilter(_ item: FluidCommandItem, _ query: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if words.isEmpty { return true }
    let haystack = ([item.label, item.description ?? ""] + item.keywords)
        .joined(separator: " ").lowercased()
    return words.allSatisfy { haystack.contains($0) }
}

/// Suggested rows lead under their own heading while the query is empty —
/// sectionRows verbatim. Groups keep the order their first item appears
/// in; ungrouped items form an unlabelled section.
private func commandSections(
    visible: [FluidCommandItem], suggestions: [String]?, suggestionsLabel: String, query: String
) -> [CommandSection] {
    var sections: [CommandSection] = []
    var byHeading: [String?: Int] = [:]
    let suggested = Set(query.isEmpty ? suggestions ?? [] : [])

    func push(_ heading: String?, _ item: FluidCommandItem) {
        if let s = byHeading[heading] {
            sections[s].items.append(item)
        } else {
            byHeading[heading] = sections.count
            sections.append(CommandSection(heading: heading, items: [item], start: 0))
        }
    }

    if !suggested.isEmpty {
        let pool = Dictionary(uniqueKeysWithValues: visible.map { ($0.value, $0) })
        for value in suggestions ?? [] {
            if let item = pool[value] { push(suggestionsLabel, item) }
        }
    }
    for item in visible where !suggested.contains(item.value) {
        push(item.group, item)
    }
    var index = 0
    for i in sections.indices {
        sections[i].start = index
        index += sections[i].items.count
    }
    return sections
}

/// A monitor in a box — a View can't assign to its own `@State` from a
/// plain method, so the monitor lives on a class the struct keeps.
final class FluidMonitorBox {
    var monitor: Any? = nil
    func clear() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

/// Optional `size` pin — the source's SizeProvider: an explicit `size`
/// overrides `\.fluidSize` for the subtree; nil leaves the ambient value.
private struct FluidOptionalSizePin: ViewModifier {
    let size: FluidSize?
    @Environment(\.fluidSize) private var ambient
    func body(content: Content) -> some View {
        content.environment(\.fluidSize, size ?? ambient)
    }
}

// MARK: - Model

/// One tab on the strip under the field — value is state the caller owns;
/// derive `items` from it so the list follows.
struct FluidCommandMenuTab {
    var value: String
    var label: String
    var icon: String? = nil

    init(_ value: String, _ label: String, icon: String? = nil) {
        self.value = value
        self.label = label
        self.icon = icon
    }
}

/// One footer hint — a label and the caps that trigger it.
struct FluidCommandHint {
    var label: String
    /// A combo in trigger syntax, or a list of separate caps.
    var keys: [String]

    init(_ label: String, keys: [String]) {
        self.label = label
        self.keys = keys
    }
    init(_ label: String, keys: String) {
        self.label = label
        self.keys = [keys]
    }
}

/// The shared context — the source's CommandMenuContext. Rows, the field,
/// the tabs strip, and the footer all subscribe off the one model; the
/// highlight lives in the fluid hover hook so pointer and keys agree.
@Observable
final class FluidCommandMenuModel {
    var items: [FluidCommandItem]
    /// Controlled query — the root's `query`/`onQueryChange` binding.
    var queryBinding: Binding<String>
    var filter: ((FluidCommandItem, String) -> Bool)? = nil
    var suggestions: [String]? = nil
    var suggestionsLabel = "Suggestions"
    /// Inside a dialog, picking a row closes it (default true).
    var closeOnSelect = true
    var onSelect: ((FluidCommandItem) -> Void)? = nil
    /// Escape defers here when the query is empty — a dialog's shell owns
    /// the key (or the call site's onEscape).
    var onEscape: (() -> Void)? = nil
    /// The close() a containing FluidCommandMenuDialog supplies.
    var dialogClose: (() -> Void)? = nil

    /// The fluid hover store — pointer and keyboard share activeIndex.
    let hover = FluidHover(axis: .y)
    /// Scroll proxy captured by the list — moves scroll the row's
    /// CENTER into view on the fast spring (the source's scrollToRow).
    var listProxy: ScrollViewProxy? = nil
    /// The highlight's last non-nil value — pointer exit restores it so
    /// Enter keeps a target (the list's handleMouseLeave).
    var lastActive: Int? = nil
    /// The mounted tabs, so ← and → in the field switch them.
    var tabsHandle: (tabs: [FluidCommandMenuTab], value: String,
                     onValueChange: (String) -> Void)? = nil
    var tabsMounted = false
    /// The list's natural content height — scroll content measures at its
    /// ideal even while the viewport clamps it, so the column can spring
    /// to a size (the source's ResizeObserver on the column).
    var contentHeight: CGFloat = 0

    init(items: [FluidCommandItem], query: Binding<String>) {
        self.items = items
        self.queryBinding = query
    }

    var query: String {
        get { queryBinding.wrappedValue }
        set { queryBinding.wrappedValue = newValue }
    }

    private var visible: [FluidCommandItem] {
        let f = filter ?? fluidCommandMenuDefaultFilter
        return query.isEmpty ? items : items.filter { f($0, query) }
    }
    var sections: [CommandSection] {
        commandSections(visible: visible, suggestions: suggestions,
                        suggestionsLabel: suggestionsLabel, query: query)
    }
    var rows: [FluidCommandItem] { sections.flatMap(\.items) }
    /// What the rows ARE, not the array's identity — a real change resets
    /// the highlight (rowsKey, joined on NUL so values can't collide).
    var rowsKey: String { rows.map(\.value).joined(separator: "\u{0}") }
    var activeIndex: Int? { hover.activeIndex }

    /// The first enabled row is highlighted whenever the row set changes,
    /// so Enter always has a target and it follows the query as it
    /// filters. Also snaps the viewport back to the top.
    func highlightFirstEnabled() {
        let first = rows.firstIndex(where: { !$0.disabled })
        hover.activeIndex = first
        lastActive = first
        scrollToTop()
    }

    /// move(to:) — a step wraps among enabled rows at both ends (the list
    /// is the whole keyboard space — no field to stop at); first/last
    /// jump to the ends. Every move centers the row on the fast spring.
    func move(_ to: FluidCommandMove) {
        let enabled = rows.indices.filter { !rows[$0].disabled }
        guard !enabled.isEmpty else { return }
        let next: Int
        switch to {
        case .first: next = enabled.first!
        case .last: next = enabled.last!
        case .step(let dir):
            let pos = activeIndex.flatMap { enabled.firstIndex(of: $0) }
            next = pos == nil
                ? (dir > 0 ? enabled.first! : enabled.last!)
                : enabled[(pos! + dir + enabled.count) % enabled.count]
        }
        hover.activeIndex = next
        lastActive = next
        scrollToRow(next)
    }

    /// mode "center": the row lands mid-viewport on the fast spring.
    /// Index 0 snaps the viewport to the top (the source's `top` mode —
    /// no animation on a query reset).
    func scrollToRow(_ i: Int) {
        if i == 0 { scrollToTop(); return }
        withAnimation(FluidSpring.fast) {
            listProxy?.scrollTo("cmd-\(i)", anchor: .center)
        }
    }
    private func scrollToTop() {
        listProxy?.scrollTo("cmd-0", anchor: .top)
    }

    /// Row's own onSelect first, then the root's — then the dialog close.
    func select(_ item: FluidCommandItem) {
        guard !item.disabled else { return }
        item.onSelect?()
        onSelect?(item)
        if closeOnSelect { dialogClose?() }
    }
}

enum FluidCommandMove { case step(Int), first, last }

// MARK: - Environment

private struct FluidCommandDialogCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var fluidCommandDialogClose: (() -> Void)? {
        get { self[FluidCommandDialogCloseKey.self] }
        set { self[FluidCommandDialogCloseKey.self] = newValue }
    }
}

// MARK: - Root

/// The one-piece palette — composes Input, Tabs (optional), List and
/// Footer inside the measured-height shell. The compound pieces below are
/// the same parts for custom arrangements.
struct FluidCommandMenu: View {
    let model: FluidCommandMenuModel
    var placeholder = "Type a command or search…"
    /// Pins field and rows to one step of the size ladder — the source's
    /// `size` prop (compact: h-10 field, 28px rows, h-8 footer).
    var size: FluidSize? = nil
    var showFooter = true
    /// Replaces the default footer hints entirely.
    var hints: [FluidCommandHint]? = nil
    /// Tabs strip under the field — ←/→ in the field switches them.
    var tabs: [FluidCommandMenuTab]? = nil
    var tabSelection: Binding<String>? = nil
    /// The empty-state row (CommandMenuEmpty's children).
    var emptyText = "No results."
    /// The list scrolls past this — the shell's max-h in the source.
    var listMaxHeight: CGFloat? = nil

    @State private var tabsHeight: CGFloat = 0
    @Environment(\.fluidSize) private var ambientSize
    /// Set by a containing FluidCommandMenuDialog — selecting a row then
    /// closes the shell (closeOnSelect) and the footer hints at Esc.
    @Environment(\.fluidCommandDialogClose) private var dialogClose

    private var tabsMountedHeight: CGFloat { (tabs != nil && tabSelection != nil) ? tabsHeight : 0 }

    init(items: [FluidCommandItem], query: Binding<String>,
         placeholder: String = "Type a command or search…",
         suggestions: [String]? = nil, suggestionsLabel: String = "Suggestions",
         size: FluidSize? = nil, showFooter: Bool = true,
         hints: [FluidCommandHint]? = nil,
         tabs: [FluidCommandMenuTab]? = nil,
         tabSelection: Binding<String>? = nil,
         filter: ((FluidCommandItem, String) -> Bool)? = nil,
         closeOnSelect: Bool = true,
         emptyText: String = "No results.",
         listMaxHeight: CGFloat? = nil,
         onSelect: ((FluidCommandItem) -> Void)? = nil,
         onEscape: (() -> Void)? = nil) {
        let m = FluidCommandMenuModel(items: items, query: query)
        m.filter = filter
        m.suggestions = suggestions
        m.suggestionsLabel = suggestionsLabel
        m.closeOnSelect = closeOnSelect
        m.onSelect = onSelect
        m.onEscape = onEscape
        self.model = m
        self.placeholder = placeholder
        self.size = size
        self.showFooter = showFooter
        self.hints = hints
        self.tabs = tabs
        self.tabSelection = tabSelection
        self.emptyText = emptyText
        self.listMaxHeight = listMaxHeight
    }

    var body: some View {
        // The panel follows its rows: animate={height} on the shell in the
        // source. The scroll CONTENT reports its natural height even while
        // the viewport clamps it; the column's height is the fixed parts
        // (field/tabs/footer have known per-tier heights) plus the list —
        // measured directly would pin the compressible ScrollView at the
        // clamp and the panel could never grow again.
        let compact = (size ?? ambientSize) == .compact
        let columnH = (compact ? 40 : 48)
            + tabsMountedHeight
            + min(model.contentHeight, listMaxHeight ?? .infinity)
            + (showFooter ? (compact ? 32 : 40) : 0)
        VStack(alignment: .leading, spacing: 0) {
            FluidCommandMenuInput(model: model, placeholder: placeholder)
            if let tabs, let tabSelection {
                FluidCommandMenuTabs(model: model, tabs: tabs,
                                     selection: tabSelection)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                    action: { tabsHeight = $0 }
            }
            FluidCommandMenuList(model: model, emptyText: emptyText,
                                 maxHeight: listMaxHeight)
            if showFooter { FluidCommandMenuFooter(model: model, hints: hints) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: columnH > 0 ? columnH : nil, alignment: .top)
        .clipped()
        .animation(FluidSpring.moderate, value: columnH)
        .modifier(FluidOptionalSizePin(size: size))
        .environment(\.fluidCommandDialogClose, model.dialogClose)
        .onAppear {
            model.hover.isItemDisabled = { i in
                let rs = model.rows
                return i < 0 || i >= rs.count || rs[i].disabled
            }
            model.dialogClose = dialogClose
        }
        // The first enabled row is lit whenever the row set changes —
        // Enter always has a target and it follows the query as it
        // filters; the viewport snaps to the top with the reset.
        .onChange(of: model.rowsKey, initial: true) { _, _ in
            model.highlightFirstEnabled()
        }
    }
}

// MARK: - Input

/// The search field: h-12 gap-2.5 px-4 (compact h-10 gap-2 px-3), leading
/// icon muted→fg while focused, one notch above the rows' text size —
/// the palette's title line. Keeps focus; arrows/Home/End/Enter act on
/// the list through the model; ←/→ switch mounted tabs.
struct FluidCommandMenuInput: View {
    @Bindable var model: FluidCommandMenuModel
    var placeholder = "Type a command or search…"
    /// Leading icon — defaults to the search glyph; nil hides it.
    var icon: String? = "magnifyingglass"

    @Environment(\.fluidSize) private var size
    @FocusState private var inputFocused: Bool
    @State private var monitorBox = FluidMonitorBox()

    private var compact: Bool { size == .compact }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            if let icon {
                FluidIcon(icon, size: size.icon, bold: inputFocused)
                    .foregroundStyle(inputFocused ? FluidTone.foreground : FluidTone.mutedForeground)
                    .animation(.easeOut(duration: 0.08), value: inputFocused)
            }
            TextField(placeholder, text: model.queryBinding)
                .textFieldStyle(.plain)
                // One notch above the rows' body size; the line box keeps
                // the caret in proportion (text-[14px] leading-6).
                .font(.system(size: compact ? 13 : 14))
                .foregroundStyle(FluidTone.foreground)
                .focused($inputFocused)
        }
        .padding(.horizontal, compact ? 12 : 16)
        .frame(height: compact ? 40 : 48)
        .onAppear {
            installKeyMonitor()
            // The palette opens keyboard-first — without focus the field's
            // keys die until a click. One hop so the field exists first.
            DispatchQueue.main.async { inputFocused = true }
        }
        .onDisappear { monitorBox.clear() }
    }

    /// The field's keydown — command-menu.tsx:764-820. ↑↓ move (wrapping),
    /// Home/End move while the query is empty (else the caret owns them),
    /// Enter selects the lit row, Escape clears what was typed or defers
    /// to the shell, ←→ switch mounted tabs. Keys inside an IME
    /// composition belong to the composer (the source's isComposing/229).
    private func installKeyMonitor() {
        let focus = $inputFocused
        monitorBox.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, focus.wrappedValue else { return event }
            // A keydown mid-IME-composition is the composer's — Return
            // commits a candidate, arrows pick one. The field editor
            // carries marked text while a composition is live.
            if let tv = event.window?.firstResponder as? NSTextView,
               tv.hasMarkedText() { return event }
            if event.isARepeat && (event.keyCode == 36 || event.keyCode == 76) {
                return event   // held Return doesn't repeat-select
            }
            switch event.keyCode {
            case 123, 124: // ← →
                guard let tabs = model.tabsHandle, !tabs.tabs.isEmpty,
                      !event.modifierFlags.contains(.option),
                      !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.control)
                else { return event }
                let count = tabs.tabs.count
                let current = tabs.tabs.firstIndex { $0.value == tabs.value } ?? -1
                let step = event.keyCode == 124 ? 1 : -1
                let next = ((current == -1 ? 0 : current) + step + count) % count
                tabs.onValueChange(tabs.tabs[next].value)
                return nil
            case 125: model.move(.step(1)); return nil    // ↓
            case 126: model.move(.step(-1)); return nil   // ↑
            case 115:                                     // Home
                guard model.query.isEmpty else { return event }
                model.move(.first); return nil
            case 119:                                     // End
                guard model.query.isEmpty else { return event }
                model.move(.last); return nil
            case 36, 76:                                  // return
                if let i = model.activeIndex, i < model.rows.count {
                    model.select(model.rows[i])
                }
                return nil
            case 53:                                      // escape
                // In a dialog the shell closes on Escape. Inline, Escape
                // clears what was typed.
                if model.dialogClose != nil || model.query.isEmpty {
                    model.onEscape?()
                } else {
                    model.query = ""
                }
                return nil
            default: return event
            }
        }
    }
}

// MARK: - Tabs

/// Subtle tabs under the field. The tabs are state you own — derive
/// `items` from the value so the list follows. ← and → in the field
/// switch tabs (wrapping); the strip registers itself on the model so
/// the field knows and the footer can hint at it.
struct FluidCommandMenuTabs: View {
    @Bindable var model: FluidCommandMenuModel
    let tabs: [FluidCommandMenuTab]
    @Binding var selection: String
    /// Trailing slot — a CommandMenuFilters, a Button. The tabs take the
    /// room that is left.
    var trailing: AnyView? = nil

    @Environment(\.fluidSize) private var size
    private var compact: Bool { size == .compact }

    init(model: FluidCommandMenuModel, tabs: [FluidCommandMenuTab],
         selection: Binding<String>) {
        self.model = model
        self.tabs = tabs
        self._selection = selection
    }

    init<Trailing: View>(model: FluidCommandMenuModel, tabs: [FluidCommandMenuTab],
                       selection: Binding<String>,
                       @ViewBuilder trailing: @escaping () -> Trailing) {
        self.model = model
        self.tabs = tabs
        self._selection = selection
        self.trailing = AnyView(trailing())
    }

    /// FluidTabsSubtle is index-driven — map value ↔ index.
    private var indexBinding: Binding<Int> {
        Binding(
            get: { max(0, tabs.firstIndex { $0.value == selection } ?? 0) },
            set: { i in if tabs.indices.contains(i) { selection = tabs[i].value } }
        )
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            // The strip's mousedown is preventDefault'd in the source so a
            // pick can't take focus from the field — SwiftUI buttons don't
            // join the key-view loop on click, so focus stays put already.
            FluidTabsSubtle(
                items: tabs.map { ($0.icon, $0.label) },
                selection: indexBinding,
                size: .compact
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let trailing {
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.bottom, compact ? 6 : 8)
        .onAppear { registerTabs() }
        .onDisappear {
            model.tabsHandle = nil
            model.tabsMounted = false
        }
        // Keep the handle fresh — a re-render with new tabs/value must not
        // leave the field's ←→ switching on stale state.
        .onChange(of: tabs.map(\.value)) { _, _ in registerTabs() }
        .onChange(of: selection) { _, _ in registerTabs() }
    }

    private func registerTabs() {
        let sel = $selection
        model.tabsHandle = (tabs: tabs, value: selection,
                            onValueChange: { v in sel.wrappedValue = v })
        model.tabsMounted = true
    }
}

// MARK: - Filters

/// A borderless bar under the field for compact controls (borderless
/// Selects, ghost Buttons). On its own it is a row of the header with the
/// header's inset and wrapping room; inside a tab row it hugs its
/// controls. Everything inside renders one size step down.
struct FluidCommandMenuFilters<Content: View>: View {
    var inTabsRow = false
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidSize) private var size
    private var compact: Bool { size == .compact }

    init(inTabsRow: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.inTabsRow = inTabsRow
        self.content = content
    }

    var body: some View {
        HStack(spacing: 4) { content() }
            .modifier(FluidOptionalSizePin(size: .compact))
            .padding(.horizontal, inTabsRow ? 0 : (compact ? 8 : 10))
            .padding(.bottom, inTabsRow ? 0 : (compact ? 6 : 8))
    }
}

// MARK: - List

/// The scrolling rows under a divider, grouped by heading, with the fluid
/// hover fill. scroll-divider draws the edges; the fill scrolls with the
/// rows (the list is its coordinate space).
struct FluidCommandMenuList: View {
    @Bindable var model: FluidCommandMenuModel
    var emptyText = "No results."
    /// The list scrolls past this — the shell's max-h in the source.
    var maxHeight: CGFloat? = nil

    @Environment(\.fluidSize) private var size
    @State private var fade = FluidScrollFadeState()

    private var compact: Bool { size == .compact }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).onAppear { model.listProxy = proxy }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.sections.enumerated()), id: \.offset) { _, section in
                        if let heading = section.heading {
                            // text-caption muted — h-7 px-2 (compact h-6 px-1.5).
                            Text(heading)
                                .font(.system(size: 12))
                                .foregroundStyle(FluidTone.mutedForeground)
                                .padding(.horizontal, compact ? 6 : 8)
                                .frame(height: compact ? 24 : 28, alignment: .leading)
                        }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { i, item in
                            row(item, index: section.start + i)
                        }
                    }
                    // CommandMenuEmpty — role=status live region inside the
                    // scrollable list, only while nothing matches.
                    if model.rows.isEmpty {
                        Text(emptyText)
                            .font(.system(size: size.text))
                            .foregroundStyle(FluidTone.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 24)
                    }
                }
                // Padding collapses when the list is empty (data-[empty]:p-0).
                .padding(model.rows.isEmpty ? 0 : 4)
                .fluidFadeContent(fade)
                // The item rects and the hover points must share ONE named
                // space — .fluidItem measures in hover.space, so this list
                // declares the same.
                .coordinateSpace(name: model.hover.space)
                .background(alignment: .topLeading) {
                    if let i = model.activeIndex, let r = model.hover.rects[i] {
                        CommandFill(rect: r, radius: FluidShape.rounded.bg)
                            .id(model.hover.session)
                            .transition(.opacity)
                    }
                }
                .onContinuousHover(coordinateSpace: .named(model.hover.space)) { phase in
                    switch phase {
                    case .active(let point): model.hover.moved(to: point)
                    case .ended:
                        model.hover.exited()
                        // Pointer exit keeps the highlight where it was —
                        // Enter still has a target, and the fill stays on
                        // the row the field points at (lastActiveRef).
                        model.hover.activeIndex = model.lastActive
                    }
                }
                .environment(\.fluidHover, model.hover)
                .frame(maxWidth: .infinity)
                // Scroll content reports its natural height even while the
                // viewport clamps it — that is what the column springs to.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    model.contentHeight = $0
                }
            }
            .scrollIndicators(.hidden)
            // The palette is sized by its rows up to the shell's max —
            // the source's flex min-h-0 column with scroll past the cap.
            .frame(maxHeight: maxHeight)
            // scroll-divider edges + the 32px scroll-fade.
            .fluidScrollFade(32, state: fade, dividers: true)
            .overlay(alignment: .top) {
                Rectangle().fill(FluidTone.border.opacity(0.6)).frame(height: 1)
            }
        }
    }

    /// One row — CommandMenuItem: icon (bold while lit), label, optional
    /// description one contrast step lower, shortcut caps at the trailing
    /// edge. aria-selected = the lit row.
    private func row(_ item: FluidCommandItem, index: Int) -> some View {
        let isActive = model.activeIndex == index
        return Button {
            model.select(item)
        } label: {
            HStack(spacing: size.gap) {
                if let icon = item.icon {
                    FluidIcon(icon, size: size.icon, bold: isActive)
                        .frame(width: size.icon, height: size.icon)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.label).lineLimit(1)
                    if let description = item.description {
                        // Same size, one contrast step below the label, on
                        // both states of the row.
                        Text(description)
                            .foregroundStyle(isActive
                                ? FluidTone.mutedForeground
                                : FluidTone.mutedForeground.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut = item.shortcut {
                    FluidCommandMenuShortcut(shortcut)
                }
            }
            .font(.system(size: size.text))
            .foregroundStyle(isActive ? FluidTone.foreground : FluidTone.mutedForeground)
            .padding(.horizontal, size.itemPx)
            .frame(height: size.controlHeight)
            .contentShape(Rectangle())
            .opacity(item.disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(item.disabled)
        .id("cmd-\(index)")
        .fluidItem(index)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .animation(.easeOut(duration: 0.08), value: isActive)
    }
}

// MARK: - Shortcut caps

/// The caps at a row's trailing edge — one cap per token; a list draws
/// each entry's caps in order (the source's `keys: string | string[]`).
struct FluidCommandMenuShortcut: View {
    let caps: [String]

    init(_ keys: String) { caps = fluidShortcutCaps(keys) }
    init(_ keys: [String]) { caps = fluidShortcutCaps(keys) }

    @Environment(\.fluidSize) private var size
    private var compact: Bool { size == .compact }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(caps, id: \.self) { cap in
                Text(cap)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .frame(minWidth: compact ? 16 : 20, minHeight: compact ? 16 : 20)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(FluidTone.hover)
                    )
            }
        }
        .fixedSize()
    }
}

// MARK: - Footer

/// The hint strip under the list: what the keys do here. Default hints
/// follow the menu — tabs add ← →, a dialog adds Esc. The Enter hint
/// names the highlighted row (its `action`, else label) and sits at the
/// trailing edge so its changing width never moves the other hints.
struct FluidCommandMenuFooter: View {
    @Bindable var model: FluidCommandMenuModel
    /// Replaces the default hints. nil → Select/Tabs/Close by context.
    var hints: [FluidCommandHint]? = nil

    @Environment(\.fluidSize) private var size
    private var compact: Bool { size == .compact }

    var body: some View {
        let resolved: [FluidCommandHint] = hints ?? [
            FluidCommandHint("Select", keys: ["up", "down"]),
        ] + (model.tabsMounted ? [FluidCommandHint("Tabs", keys: ["left", "right"])] : [])
          + (model.dialogClose != nil ? [FluidCommandHint("Close", keys: "esc")] : [])
        HStack(spacing: compact ? 12 : 16) {
            ForEach(Array(resolved.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 6) {
                    Text(hint.label).fixedSize()
                    FluidCommandMenuShortcut(hint.keys)
                }
            }
            Spacer(minLength: 0)
            // "Open Showcase ↵" — names what Enter does to the lit row.
            if let i = model.activeIndex, i < model.rows.count {
                let row = model.rows[i]
                HStack(spacing: 6) {
                    Text(row.action ?? row.label)
                        .foregroundStyle(FluidTone.foreground)
                        .lineLimit(1)
                    FluidCommandMenuShortcut("enter")
                }
                .fixedSize()
            }
        }
        .font(.system(size: compact ? 11 : 12))
        .foregroundStyle(FluidTone.mutedForeground)
        .padding(.horizontal, compact ? 12 : 16)
        .frame(height: compact ? 32 : 40)
    }
}

// MARK: - Dialog

/// Every mounted command dialog listens for its own combo; one of them
/// answers a press. An open dialog answers first (the press closes it).
/// Otherwise the most recently mounted one with that combo whose scope
/// holds the focus answers — a scopeless dialog is in scope everywhere.
private struct FluidMountedCommandDialog {
    let id: UUID
    let combo: String
    let isOpen: () -> Bool
    let inScope: () -> Bool
}

private var fluidMountedCommandDialogs: [FluidMountedCommandDialog] = []

private func fluidComboKey(_ p: FluidParsedShortcut) -> String {
    [
        p.mod ? "mod" : nil, p.meta ? "meta" : nil, p.ctrl ? "ctrl" : nil,
        p.alt ? "alt" : nil, p.shift ? "shift" : nil,
        p.key.isEmpty ? nil : p.key,
    ].compactMap { $0 }.joined(separator: "+")
}

/// The modal palette — command-menu.tsx's CommandMenuDialog. Opens on a
/// global shortcut (default ⌘K): a bare key stays out of text fields, a
/// modifier combo fires anywhere; an open dialog's press closes it; among
/// peers sharing a combo the most recently mounted in-scope one answers.
/// The panel is the top-positioned lg dialog capped at min(440, 76dvh) so
/// the field stays put while the rows under it filter down.
struct FluidCommandMenuDialog<Content: View>: View {
    @Binding var isPresented: Bool
    /// The combo that toggles the dialog, in shortcut syntax. nil binds
    /// nothing.
    var shortcut: String? = "mod+k"
    /// Focus must be inside this view for the combo to open the dialog —
    /// a scoped palette must not take an app-wide combo. Closing works
    /// from anywhere.
    var shortcutScope: NSView? = nil
    var content: () -> Content

    @State private var probe = FluidCommandDialogProbe()

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { install() }
            .onDisappear { probe.uninstall() }
            .fluidDialog(isPresented: $isPresented, size: .lg,
                         position: .top, showCloseButton: false) {
                // Any FluidCommandMenu inside picks up the shell's close —
                // closeOnSelect then dismisses and Esc hints appear.
                content()
                    .environment(\.fluidCommandDialogClose, {
                        isPresented = false
                    })
            }
    }

    private func install() {
        guard let shortcut else { return }
        let parsed = fluidParseShortcut(shortcut)
        guard !parsed.key.isEmpty else { return }
        probe.install(
            combo: fluidComboKey(parsed),
            parsed: parsed,
            isOpen: { isPresented },
            inScope: { [weak shortcutScope] in
                guard let scope = shortcutScope else { return true }
                guard let w = scope.window,
                      let responder = w.firstResponder as? NSView
                else { return false }
                return responder === scope || responder.isDescendant(of: scope)
            },
            toggle: { isPresented.toggle() }
        )
    }
}

/// Owns the global key monitor and this dialog's entry in the peer
/// registry. Survives view churn because it lives in @State.
private final class FluidCommandDialogProbe {
    private var monitor: Any? = nil
    private var id: UUID? = nil

    func install(combo: String, parsed: FluidParsedShortcut,
                 isOpen: @escaping () -> Bool,
                 inScope: @escaping () -> Bool,
                 toggle: @escaping () -> Void) {
        uninstall()
        let id = UUID()
        self.id = id
        fluidMountedCommandDialogs.append(
            FluidMountedCommandDialog(id: id, combo: combo,
                                      isOpen: isOpen, inScope: inScope)
        )
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.isARepeat { return event }
            guard fluidMatchesShortcut(event, parsed) else { return event }
            // A bare key stays out of fields; a modifier combo fires
            // anywhere.
            if !fluidHasModifier(parsed),
               NSApp.keyWindow?.firstResponder is NSTextView { return event }
            // An open dialog answers first (the press closes it); else the
            // most recently mounted in-scope peer.
            let peers = fluidMountedCommandDialogs.filter { $0.combo == combo }
            guard let answers = peers.first(where: { $0.isOpen() })
                    ?? peers.reversed().first(where: { $0.inScope() }),
                  answers.id == id
            else { return event }
            toggle()
            return nil
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let id {
            fluidMountedCommandDialogs.removeAll { $0.id == id }
        }
        self.id = nil
    }
}

// MARK: - Fill

/// The lit row's fill — the standard fluid hover highlight (bg-hover),
/// sprung on the fast tier inside the scrolling list.
private struct CommandFill: View {
    let rect: CGRect
    let radius: CGFloat
    @State private var current: CGRect
    @State private var opacity = 0.0

    init(rect: CGRect, radius: CGFloat) {
        self.rect = rect; self.radius = radius
        _current = State(initialValue: rect)
    }

    var body: some View {
        // The list's highlight IS FluidHoverHighlight — bg-hover, sprung on
        // the fast tier, fading in on mount.
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(FluidTone.hover)
            .frame(width: current.width, height: current.height)
            .position(x: current.midX, y: current.midY)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.08)) { opacity = 1 }
                withAnimation(FluidSpring.fast) { current = rect }
            }
            .onChange(of: rect) { _, new in
                withAnimation(FluidSpring.fast) { current = new }
            }
    }
}

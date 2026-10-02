import SwiftUI

// The composer's model, effort, mode and status capsules — shared by the
// rail's AskPanel and the fullscreen AskPage, so they live at file scope
// here rather than nested inside either surface (design/fullscreen-features.md §2).

/// The brains on offer and the words they wear — the model menus' one
/// source of truth for both Ask surfaces.
enum AskChips {
    /// The brains on offer, grouped by the wire they ride — the selector's
    /// sections: a name the section reads, the provider's wire name, and
    /// each model as (title it is called by here, the wire's own name for
    /// it). Settings' free-text model still works — a pick from a section
    /// overwrites it, a custom one shows in its provider's section.
    static let providers: [(name: String, provider: String, models: [(title: String, model: String)])] = [
        ("OpenRouter", "openrouter", [
            ("z-ai/glm-5.3-flash", "z-ai/glm-5.3-flash"),
        ]),
        ("Codex", "codex", [
            ("gpt-6-luna", "gpt-6-luna"),
        ]),
        ("Devin", "devin", [
            ("Devin (REST)", "devin"),
        ]),
        ("Echo", "echo", [
            ("Echo", "echo"),
        ]),
    ]

    /// The flat list the retry menu wants — every provider's models in
    /// order, named the way the chip reads them.
    static let models: [(title: String, provider: String, model: String)] =
        providers.flatMap { group in
            group.models.map { item in
                (AskModel(provider: group.provider, model: item.model).readout, group.provider, item.model)
            }
        }

    /// One reasoning level the composer can offer. `value` nil is Auto:
    /// the request leaves the field off and the model uses its default.
    struct Effort: Equatable {
        var value: String?
        var title: String
    }

    /// Levels this model actually accepts, Auto first. A pick stored for
    /// another model is not offered here — `wireEffort` says what this
    /// model will be sent instead. harness.js `effortLevel` is the same map.
    static func efforts(provider: String, model: String) -> [Effort] {
        [Effort(value: nil, title: "Auto")] + nativeEfforts(provider: provider, model: model)
    }

    /// The `reasoning.effort` token to send, or nil to send nothing.
    /// "off" is the old stored word for switching reasoning off.
    static func wireEffort(_ stored: String?, provider: String, model: String) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        return effortMap(provider: provider, model: model)[stored]
    }

    /// Menu rows are the tokens the model takes unchanged. Aliases such
    /// as "off" resolve through `wireEffort` onto one of these.
    private static func nativeEfforts(provider: String, model: String) -> [Effort] {
        let map = effortMap(provider: provider, model: model)
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        let titles = [
            "none": "Off", "minimal": "Minimal", "low": "Low", "medium": "Medium",
            "high": "High", "xhigh": "Extra high", "max": "Max",
        ]
        return order.compactMap { token in
            guard map[token] == token, let title = titles[token] else { return nil }
            return Effort(value: token, title: title)
        }
    }

    /// Codex gpt-6-luna: none, low, medium (its default), high, xhigh, max.
    /// It has no "minimal" — that word 400s, and "off" is a real none.
    private static let codexLuna: [String: String] = [
        "off": "none", "none": "none", "minimal": "low",
        "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max",
    ]

    /// OpenRouter's own ladder, for a model without a tighter table.
    /// "off" is a real disable (`none`).
    private static let openrouter: [String: String] = [
        "off": "none", "none": "none", "minimal": "minimal",
        "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max",
    ]

    /// Z.ai GLM-5.3 Flash accepts only low, high, and max. Anything else
    /// errors, and thinking cannot be turned off, so the floor is low.
    /// medium folds up to high; xhigh folds up to max.
    private static let glmFlash: [String: String] = [
        "off": "low", "none": "low", "minimal": "low",
        "low": "low", "medium": "high", "high": "high", "xhigh": "max", "max": "max",
    ]

    private static let tables: [String: [String: String]] = [
        "codex/gpt-6-luna": codexLuna,
        "openrouter/z-ai/glm-5.3-flash": glmFlash,
    ]

    private static func effortMap(provider: String, model: String) -> [String: String] {
        if let table = tables["\(provider)/\(model)"] { return table }
        if provider == "codex" { return codexLuna }
        if provider == "openrouter" { return openrouter }
        return [:]
    }
}

/// The quiet handle every composer pick wears — a word and a chevron on
/// the floor, a wash under the pointer, a deeper one while its list is up.
struct AskPick: View {
    var icon: String? = nil
    var provider: String? = nil
    let text: String
    var open = false
    var trouble = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let provider {
                    ProviderLogo(provider: provider)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .medium))
                }
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(trouble ? FluidTone.destructive : (hovering || open ? Palette.ink : Palette.muted))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(open ? FluidTone.active : (hovering ? FluidTone.hover : .clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(AskMotion.pop, value: open)
    }
}

private struct AskPickRow {
    let index: Int
    let act: () -> Void
}

private extension View {
    func askPopup<Rows: View>(
        _ open: Binding<Bool>,
        checked: Int?,
        width: CGFloat = 230,
        rows: [AskPickRow],
        @ViewBuilder content: @escaping () -> Rows
    ) -> some View {
        fluidMenuPopup(
            isPresented: open,
            checkedIndex: checked,
            width: width,
            maxHeight: 380,
            side: .top,
            align: .start,
            sideOffset: 6,
            selectionAck: 0.16,
            onPick: { i in rows.first { $0.index == i }?.act() }
        ) {
            content().environment(\.fluidSize, .compact)
        }
    }
}

/// The brain, as a pick — the providers' sections in a Fluid list, a
/// check on the pair on duty, and the way to Settings under them.
struct ModelChip: View {
    var browser: Browser
    var short = false
    @ObservedObject private var mind = Mind.shared
    @State private var open = false

    private struct Section {
        let index: Int
        let name: String
        let provider: String
        let models: [(title: String, model: String)]
    }

    private var sections: [Section] {
        AskChips.providers.enumerated().map { i, group in
            var models = group.models
            if mind.model.provider == group.provider,
               !models.contains(where: { $0.model == mind.model.model }) {
                models.append((title: mind.model.label, model: mind.model.model))
            }
            return Section(index: i, name: group.name, provider: group.provider, models: models.map { (AskModel(provider: group.provider, model: $0.model).label, $0.model) })
        }
    }

    private var settingsIndex: Int { AskChips.providers.count }

    private var checked: Int? {
        sections.first { $0.provider == mind.model.provider }?.index
    }

    private var rows: [AskPickRow] {
        [AskPickRow(index: settingsIndex) { browser.openInternal(.settings, section: "ask") }]
    }

    private func current(_ section: Section) -> Int? {
        guard section.provider == mind.model.provider else { return nil }
        return section.models.firstIndex { $0.model == mind.model.model }
    }

    private func pick(_ section: Section, _ i: Int) {
        guard section.models.indices.contains(i) else { return }
        mind.model = AskModel(provider: section.provider, model: section.models[i].model)
    }

    var body: some View {
        AskPick(provider: mind.model.provider, text: mind.model.label, open: open, trouble: mind.engine == nil) {
            open.toggle()
        }
        .askPopup($open, checked: checked, width: 200, rows: rows) {
            FluidMenuLabel("Provider", size: .compact)
            ForEach(sections, id: \.index) { section in
                FluidSubmenu(
                    index: section.index,
                    label: section.name,
                    detail: current(section).map { section.models[$0].title },
                    checked: section.provider == mind.model.provider,
                    width: 230,
                    checkedIndex: current(section),
                    onPick: { pick(section, $0) }
                ) {
                    ForEach(Array(section.models.enumerated()), id: \.offset) { i, item in
                        FluidMenuItem(index: i, label: item.title, checked: i == current(section)) {
                            pick(section, i)
                        }
                    }
                }
            }
            FluidMenuSeparator()
            FluidMenuItem(index: settingsIndex, icon: "gearshape", label: "Settings…") {
                browser.openInternal(.settings, section: "ask")
            }
        }
        .fixedSize()
        .help(mind.engine == nil
              ? "No engine is up — sends will land in a dead chat"
              : "The model the next turn runs on")
    }
}

typealias ModelSelector = ModelChip

/// How hard the brain thinks — only drawn while the wire in play can.
struct EffortChip: View {
    @ObservedObject private var mind = Mind.shared
    @State private var open = false

    private var effort: String? {
        mind.current?.effort ?? Store.settings.string(forKey: "ask.effort")
    }

    private var canReason: Bool {
        mind.model.canReason || (mind.current?.canReason ?? false)
    }

    /// The brain the next turn actually asks. A custom model id keeps its
    /// provider and its own name, slashes and all.
    private var brain: (provider: String, model: String) {
        if mind.model.canReason { return (mind.model.provider, mind.model.model) }
        let id = mind.current?.model ?? ""
        if let slash = id.firstIndex(of: "/") {
            return (String(id[..<slash]), String(id[id.index(after: slash)...]))
        }
        return (mind.model.provider, mind.model.model)
    }

    private var ladder: [AskChips.Effort] {
        AskChips.efforts(provider: brain.provider, model: brain.model)
    }

    /// What this model will be sent for the stored pick, so a level it
    /// does not accept shows as the one that goes out.
    private var resolved: String? {
        AskChips.wireEffort(effort, provider: brain.provider, model: brain.model)
    }

    private var checked: Int? {
        ladder.firstIndex { $0.value == resolved }
    }

    private var rows: [AskPickRow] {
        ladder.enumerated().map { i, item in
            AskPickRow(index: i) { mind.setEffort(item.value) }
        }
    }

    var body: some View {
        if canReason {
            AskPick(icon: "brain", text: ladder.first { $0.value == resolved }?.title ?? "Auto", open: open) {
                open.toggle()
            }
            .askPopup($open, checked: checked, width: 190, rows: rows) {
                FluidMenuLabel("Reasoning", size: .compact)
                ForEach(Array(ladder.enumerated()), id: \.offset) { i, item in
                    FluidMenuItem(index: i, label: item.title, checked: i == checked) {
                        mind.setEffort(item.value)
                    }
                }
            }
            .fixedSize()
            .help("How hard this model reasons — only the levels it accepts")
            .transition(.opacity)
        }
    }
}

/// The leash the next turn runs under (design/permissions.md §1), drawn
/// whether or not a chat is open: with none, it edits the default a chat
/// is born with.
struct ModeMenu: View {
    @ObservedObject private var mind = Mind.shared
    @State private var open = false

    private static let modes: [AskMode] = [.guard, .full]

    private var mode: AskMode {
        mind.current?.mode
            ?? AskMode(rawValue: Store.settings.string(forKey: "ask.mode") ?? "") ?? .guard
    }

    private static func detail(_ mode: AskMode) -> String {
        switch mode {
        case .guard: return "Asks before it acts"
        case .full: return "Acts on its own"
        }
    }

    private var rows: [AskPickRow] {
        Self.modes.enumerated().map { i, item in AskPickRow(index: i) { mind.setMode(item) } }
    }

    var body: some View {
        AskPick(icon: mode.icon, text: mode.label, open: open) { open.toggle() }
            .askPopup($open, checked: Self.modes.firstIndex(of: mode), width: 210, rows: rows) {
                ForEach(Array(Self.modes.enumerated()), id: \.offset) { i, item in
                    FluidMenuItem(index: i, icon: item.icon, label: item.label, detail: Self.detail(item), checked: item == mode) {
                        mind.setMode(item)
                    }
                }
            }
            .fixedSize()
            .help("What the agent may do: Confirm or Full")
    }
}

/// The row under the composer: the leash, the brain and its effort.
struct AskComposerBar: View {
    var browser: Browser
    @ObservedObject private var mind = Mind.shared

    var body: some View {
        HStack(spacing: 0) {
            ModeMenu()
            ModelChip(browser: browser)
            EffortChip()
            Spacer(minLength: 0)
        }
        .animation(AskMotion.pop, value: mind.model.canReason)
    }
}

/// A status word with an optional mark — the chips' old capsule, kept for
/// the places that only show a state.
struct StatusChip: View {
    var icon: String? = nil
    let text: String
    var trouble = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .medium))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170)
        }
        .foregroundStyle(trouble ? FluidTone.destructive : Palette.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .contentShape(Capsule())
    }
}

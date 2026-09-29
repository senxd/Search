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

    /// The reasoning efforts a thinking wire takes — nil is "auto", the
    /// provider's own call; each with the word its menu reads and the
    /// short form the chip wears.
    static let efforts: [(value: String?, title: String, chip: String)] = [
        (nil, "Auto", "auto"),
        ("off", "Off", "off"),
        ("low", "Low", "low"),
        ("medium", "Medium", "med"),
        ("high", "High", "high"),
    ]
}

/// The model as a capsule — a menu of the providers' sections behind a
/// press, a check on the pair on duty. `short` is the header's, just
/// the model's name; the composer's wears the provider with it.
struct ModelSelector: View {
    var browser: Browser
    var short = false
    @ObservedObject private var mind = Mind.shared

    /// A provider's models — plus the current one when it isn't a
    /// listed name (a custom model typed in Settings), so the check
    /// still lands somewhere.
    private func items(in group: (name: String, provider: String, models: [(title: String, model: String)])) -> [(title: String, model: String)] {
        var items = group.models
        if mind.model.provider == group.provider,
           !items.contains(where: { $0.model == mind.model.model }) {
            items.append((title: mind.model.model, model: mind.model.model))
        }
        return items
    }

    var body: some View {
        Menu {
            ForEach(AskChips.providers, id: \.provider) { group in
                Section(group.name) {
                    ForEach(items(in: group), id: \.model) { item in
                        Button {
                            mind.model = AskModel(provider: group.provider, model: item.model)
                        } label: {
                            if mind.model == AskModel(provider: group.provider, model: item.model) {
                                Label(item.title, systemImage: "checkmark")
                            } else {
                                Text(item.title)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Settings…") {
                // The ask section of the settings page — the page hears the
                // section asked for even when it is already open.
                browser.openInternal(.settings, section: "ask")
            }
        } label: {
            StatusChip(text: short ? mind.model.label : mind.model.readout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The brain and how hard it thinks as one capsule — the mock's
/// "GPT-6 Luna · med ⌄". Its menu holds the providers' model sections
/// and, while the wire takes one, the effort rows beneath them —
/// effort is a property of a model that can use it, not a second menu.
struct ModelChip: View {
    var browser: Browser
    @ObservedObject private var mind = Mind.shared

    /// The current chat's effort; with no chat open, the Settings
    /// default the next chat is born with. nil reads "auto".
    private var effort: String? {
        mind.current?.effort ?? Store.settings.string(forKey: "ask.effort")
    }

    /// The chip's effort tail only counts while a reasoning wire is
    /// in play — the next turn's pick or the wire the open chat is on.
    private var canReason: Bool {
        mind.model.canReason || (mind.current?.canReason ?? false)
    }

    private var effortChip: String {
        AskChips.efforts.first { ($0.value ?? "auto") == (effort ?? "auto") }?.chip ?? "auto"
    }

    /// A provider's models — plus the current one when it isn't a
    /// listed name (a custom model typed in Settings), so the check
    /// still lands somewhere.
    private func items(in group: (name: String, provider: String, models: [(title: String, model: String)])) -> [(title: String, model: String)] {
        var items = group.models
        if mind.model.provider == group.provider,
           !items.contains(where: { $0.model == mind.model.model }) {
            items.append((title: mind.model.model, model: mind.model.model))
        }
        return items
    }

    var body: some View {
        Menu {
            ForEach(AskChips.providers, id: \.provider) { group in
                Section(group.name) {
                    ForEach(items(in: group), id: \.model) { item in
                        Button {
                            mind.model = AskModel(provider: group.provider, model: item.model)
                        } label: {
                            if mind.model == AskModel(provider: group.provider, model: item.model) {
                                Label(item.title, systemImage: "checkmark")
                            } else {
                                Text(item.title)
                            }
                        }
                    }
                }
            }
            if canReason {
                Divider()
                Section("Effort") {
                    ForEach(AskChips.efforts, id: \.title) { item in
                        Button {
                            mind.setEffort(item.value)
                        } label: {
                            if (effort ?? "auto") == (item.value ?? "auto") {
                                Label(item.title, systemImage: "checkmark")
                            } else {
                                Text(item.title)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Settings…") {
                browser.openInternal(.settings, section: "ask")
            }
        } label: {
            StatusChip(text: canReason
                       ? "\(mind.model.readout) · \(effortChip)"
                       : mind.model.readout,
                       trouble: mind.engine == nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mind.engine == nil
              ? "No engine is up — sends will land in a dead chat"
              : "The model and how hard it reasons")
    }
}

/// The mode as the same kind of capsule — the leash the next turn runs
/// under (design/permissions.md §1), drawn whether or not a chat is
/// open: with none, it edits the default a chat is born with.
struct ModeMenu: View {
    @ObservedObject private var mind = Mind.shared

    /// The current chat's leash; with no chat open, the Settings
    /// default the next chat is born with (the chip edits that).
    private var mode: AskMode {
        mind.current?.mode
            ?? AskMode(rawValue: Store.settings.string(forKey: "ask.mode") ?? "") ?? .guard
    }

    var body: some View {
        Menu {
            ForEach([AskMode.read, .guard, .full], id: \.self) { item in
                Button {
                    mind.setMode(item)
                } label: {
                    if mode == item {
                        Label(item.label, systemImage: "checkmark")
                    } else {
                        Label(item.label, systemImage: item.icon)
                    }
                }
            }
        } label: {
            StatusChip(icon: mode.icon, text: mode.label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What the agent may do — Read, Guard or Full")
    }
}

/// The capsule both composer menus wear — a status chip that is also
/// the menu's handle (design/chatux.md). Draws a word, an optional
/// mark and a hidden-indicator chevron; the chip knows no semantics.
struct StatusChip: View {
    var icon: String? = nil
    let text: String
    /// Red when the thing it names is broken — the model chip wears it
    /// while no engine is up, so a dead host reads on the send button's
    /// neighbour instead of failing silently (fullscreen-ux §7).
    var trouble = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                // A long model id shrinks to fit rather than growing
                // the composer (design/chatux.md — 170pt, mid-cut).
                .truncationMode(.middle)
                .frame(maxWidth: 170)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 6.5, weight: .bold))
        }
        .foregroundStyle(trouble ? FluidTone.destructive : Palette.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(trouble ? FluidTone.destructiveLight : Palette.ground.opacity(0.6),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(
            trouble ? FluidTone.destructive.opacity(0.4) : Palette.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }
}

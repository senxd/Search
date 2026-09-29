import AppKit
import SwiftUI

// Select — select.tsx. A bordered trigger (value or placeholder + chevron)
// that opens a menu panel anchored below. Rows are the same FluidMenuItem
// row as Dropdown; the selected row carries the bg-active block and the
// trailing check. The trigger follows the ambient shape; the popup is
// always rounded, like every FF popup.

private struct FluidSelectContext {
    var selection: String?
    var select: (String) -> Void
}

fileprivate struct FluidSelectContextKey: EnvironmentKey {
    static let defaultValue: FluidSelectContext? = nil
}

extension EnvironmentValues {
    fileprivate var fluidSelect: FluidSelectContext? {
        get { self[FluidSelectContextKey.self] }
        set { self[FluidSelectContextKey.self] = newValue }
    }
}

/// What a FluidSelectItem contributes to its parent select: enough to draw
/// the row and resolve the trigger's label when the popup is closed.
struct FluidSelectItemInfo: Equatable {
    var value: String
    var label: String
    var icon: String?
    var disabled: Bool
}

private struct FluidSelectItemsKey: PreferenceKey {
    static let defaultValue: [Int: FluidSelectItemInfo] = [:]
    static func reduce(value: inout [Int: FluidSelectItemInfo],
                       nextValue: () -> [Int: FluidSelectItemInfo]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// One row of the popup list — `SelectItem`. Register it with an explicit
/// index (fluid hover picks by index) and its `value`.
struct FluidSelectItem: View {
    let index: Int
    let value: String
    var icon: String? = nil
    let label: String
    var disabled = false
    /// Omitted follows the ambient `\.fluidSize` (the popup pins it to
    /// the trigger's ladder step).
    var size: FluidSize? = nil

    @Environment(\.fluidSelect) private var select
    @Environment(\.fluidMenuDismiss) private var menuDismiss

    var body: some View {
        FluidMenuItem(
            index: index, icon: icon, label: label,
            checked: select?.selection == value,
            disabled: disabled, size: size,
            onSelect: { select?.select(value) }
        )
        .preference(
            key: FluidSelectItemsKey.self,
            value: [index: FluidSelectItemInfo(
                value: value, label: label, icon: icon, disabled: disabled
            )]
        )
    }
}

/// The control: `Select` + `SelectTrigger` + `SelectContent` in one.
///
///     FluidSelect(selection: $mode, placeholder: "Choose a mode") {
///         FluidSelectItem(index: 0, value: "fast", label: "Fast")
///         FluidSelectItem(index: 1, value: "balanced", label: "Balanced")
///     }
///
/// Items render twice: once hidden so the trigger knows the selected
/// label before the popup first opens, once inside the popup.
struct FluidSelect<Content: View>: View {
    enum Variant { case bordered, borderless }

    @Binding var selection: String?
    var placeholder: String = "Select…"
    var variant: Variant = .bordered
    var icon: String? = nil
    var error: String? = nil
    var disabled = false
    /// `size` pins trigger and popup rows to one ladder step (the source's
    /// SizeProvider wrap around the whole compound).
    var size: FluidSize? = nil
    @ViewBuilder var content: () -> Content

    @State private var open = false
    @State private var items: [Int: FluidSelectItemInfo] = [:]
    @State private var hovered = false
    /// useKeyboardNavGate seed — whether the trigger held keyboard focus
    /// (:focus-visible approximation) when the popup opened.
    @State private var navSeed = false
    @FocusState private var focused: Bool
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var ambientSize

    private var resolvedSize: FluidSize { size ?? ambientSize }
    private var compact: Bool { resolvedSize == .compact }

    private var selectedIndex: Int? {
        items.first { $0.value.value == selection }?.key
    }

    private var selectedLabel: String? {
        guard let selection else { return nil }
        return items.values.first { $0.value == selection }?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                navSeed = focused
                open.toggle()
            } label: {
                HStack(spacing: resolvedSize.gap) {
                    if let icon {
                        FluidIcon(icon, size: resolvedSize.icon, bold: hovered)
                            .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
                            .frame(width: resolvedSize.icon, height: resolvedSize.icon)
                    }
                    Text(selectedLabel ?? placeholder)
                        .font(.system(size: resolvedSize.text))
                        .foregroundStyle(selectedLabel == nil ? FluidTone.mutedForeground : FluidTone.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FluidIcon("chevron.down", size: resolvedSize.icon)
                        .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
                }
                .padding(.horizontal, resolvedSize.px)
                .frame(height: resolvedSize.controlHeight)
                .frame(minWidth: compact ? 128 : 160)
                .background(
                    RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                        .fill(hovered ? FluidTone.hover : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                // focus-visible:ring-1 — the blue ring sits 1px proud of the
                // hairline border like the source's ring utility.
                .overlay(
                    RoundedRectangle(cornerRadius: shape.input + 1, style: .continuous)
                        .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                        .padding(-1)
                        .opacity(focused ? 1 : 0)
                )
            }
            .buttonStyle(.plain)
            .focused($focused)
            .disabled(disabled)
            // disabled:opacity-50 — plain style doesn't dim on its own.
            .opacity(disabled ? 0.5 : 1)
            .onHover { h in withAnimation(FluidSpring.fast) { hovered = h } }
            .fluidMenuPopup(
                isPresented: $open,
                checkedIndex: selectedIndex,
                disabledIndices: Set(items.filter { $0.value.disabled }.map(\.key)),
                width: nil,
                maxHeight: 300,
                // selectionAckMs — the pick holds the popup 300ms so the
                // checkmark draw + selected-bg spring land before closing.
                selectionAck: 0.3,
                navSeed: navSeed,
                onPick: { i in if let item = items[i], !item.disabled { selection = item.value } }
            ) {
                content()
                    .environment(\.fluidSelect, FluidSelectContext(
                        selection: selection,
                        select: { v in selection = v }
                    ))
                    // SizeProvider: the pin crosses into the popup tree.
                    .environment(\.fluidSize, resolvedSize)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .padding(.leading, 12)
            }
        }
        // Hidden twin: collects item info so the trigger can show the
        // selected label before the popup has ever opened. hidden() drops
        // the subtree's preferences, so it stays rendered at zero size.
        .background(
            content()
                .environment(\.fluidSelect, FluidSelectContext(
                    selection: selection, select: { _ in }
                ))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(0)
                .frame(height: 0)
                .clipped()
        )
        .onPreferenceChange(FluidSelectItemsKey.self) { items = $0 }
    }

    private var borderColor: Color {
        if error != nil { return Color.red.opacity(0.5) }
        return variant == .bordered ? FluidTone.border : .clear
    }
}

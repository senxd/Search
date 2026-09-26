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
    var size: FluidSize = .default

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
    var size: FluidSize = .default
    @ViewBuilder var content: () -> Content

    @State private var open = false
    @State private var items: [Int: FluidSelectItemInfo] = [:]
    @State private var hovered = false
    @Environment(\.fluidShape) private var shape

    private var compact: Bool { size == .compact }

    private var selectedIndex: Int? {
        items.first { $0.value.value == selection }?.key
    }

    private var selectedLabel: String? {
        guard let selection else { return nil }
        return items.values.first { $0.value == selection }?.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: size.gap) {
                    if let icon {
                        FluidIcon(icon, size: size.icon, bold: hovered)
                            .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
                    }
                    Text(selectedLabel ?? placeholder)
                        .font(.system(size: size.text))
                        .foregroundStyle(selectedLabel == nil ? FluidTone.mutedForeground : FluidTone.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FluidIcon("chevron.down", size: size.icon)
                        .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
                }
                .padding(.horizontal, size.px)
                .frame(height: size.controlHeight)
                .frame(minWidth: compact ? 128 : 160)
                .background(
                    RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                        .fill(hovered ? FluidTone.hover : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(FluidSpring.fast) { hovered = h } }
            .fluidMenuPopup(
                isPresented: $open,
                checkedIndex: selectedIndex,
                disabledIndices: Set(items.filter { $0.value.disabled }.map(\.key)),
                width: nil,
                onPick: { i in if let item = items[i], !item.disabled { selection = item.value } }
            ) {
                content()
                    .environment(\.fluidSelect, FluidSelectContext(
                        selection: selection,
                        select: { v in selection = v }
                    ))
            }
            .onPreferenceChange(FluidSelectItemsKey.self) { items = $0 }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .padding(.leading, 12)
            }
        }
        // Hidden twin: collects item info so the trigger can show the
        // selected label before the popup has ever opened.
        .background(
            content()
                .environment(\.fluidSelect, FluidSelectContext(
                    selection: selection, select: { _ in }
                ))
                .allowsHitTesting(false)
                .hidden()
        )
    }

    private var borderColor: Color {
        if error != nil { return Color.red.opacity(0.5) }
        return variant == .bordered ? FluidTone.border : .clear
    }
}

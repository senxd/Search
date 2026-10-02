import SwiftUI

// InputGroup / InputField — fluid-demo/components/ui/input-group.tsx.
// Fields register as fluid-hover items but draw no highlight: the active
// field swaps its own bg + ring instead (transparent/ring-transparent at
// rest → muted/50 + ring-border hovered → card + ring-border focused).

/// flex flex-col gap-3 w-72 — the field column, tracking the pick.
struct FluidInputGroup<Content: View>: View {
    var size: FluidSize? = nil
    @Environment(\.fluidSize) private var ambientSize
    @State private var hover = FluidHover(axis: .y)
    @ViewBuilder var content: () -> Content

    var body: some View {
        FluidContainer(hover: hover, showsHighlight: false) {
            VStack(alignment: .leading, spacing: 12) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // SizeProvider wraps only when `size` is set (input-group.tsx:79)
        // — an unset prop must not flatten an ambient .compact.
        .environment(\.fluidSize, size ?? ambientSize)
    }
}

/// One labeled field — label, the 36pt input container, an optional error.
struct FluidInput: View {
    var label: String? = nil
    @Binding var text: String
    var placeholder = ""
    var icon: String? = nil
    var error: String? = nil
    var disabled = false
    /// Fluid-hover index — set it when the field sits in a FluidInputGroup.
    var index: Int? = nil

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var size
    @FocusState private var focused: Bool
    @State private var selfHovered = false

    /// Grouped fields read the group's pick; standalone ones self-hover.
    private var isActive: Bool {
        index.map { hover?.activeIndex == $0 } ?? selfHovered
    }
    private var labelActive: Bool { isActive || focused }

    private var fieldBg: Color {
        if disabled { return .clear }
        if error != nil {
            if focused { return FluidTone.card }
            return isActive ? FluidTone.destructiveLight.opacity(0.6) : .clear
        }
        if focused { return FluidTone.card }
        return isActive ? FluidTone.muted.opacity(0.5) : .clear
    }

    private var ring: Color {
        if disabled { return FluidTone.border }
        if error != nil {
            return (focused || isActive) ? FluidTone.destructive.opacity(0.5) : .clear
        }
        return (focused || isActive) ? FluidTone.border : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                // Dual-layer label: an invisible semibold twin sizes the row
                // so the weight flip on activation never reflows it.
                ZStack(alignment: .leading) {
                    Text(label).fontWeight(.semibold).opacity(0)
                    Text(label)
                        .foregroundStyle(error != nil ? FluidTone.destructive : FluidTone.mutedForeground)
                }
                .font(.system(size: size.text))
                .padding(.leading, size == .compact ? 8 : 10)
            }

            HStack(spacing: size.gap) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: size.icon, weight: labelActive ? .semibold : .regular))
                        .foregroundStyle(labelActive ? FluidTone.foreground : FluidTone.mutedForeground)
                }
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: size.text))
                    .foregroundStyle(FluidTone.foreground)
                    .focused($focused)
            }
            .padding(.horizontal, size == .compact ? 8 : 10)
            .frame(height: size.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                    .fill(fieldBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                            .strokeBorder(ring, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: shape.input, style: .continuous))
            .onTapGesture { focused = true }
            .animation(FluidSpring.fast, value: isActive)
            .animation(FluidSpring.fast, value: focused)

            if let error {
                Text(error)
                    .font(.system(size: size == .compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(FluidTone.destructive)
                    .padding(.leading, size == .compact ? 8 : 10)
            }
        }
        .opacity(disabled ? 0.5 : 1)
        .modifier(FluidInputItem(index: index))
        .onHover { if index == nil { selfHovered = $0 } }
    }
}

/// `.fluidItem` can't be applied conditionally, so index-less fields
/// skip registration through this no-op-able modifier.
private struct FluidInputItem: ViewModifier {
    let index: Int?
    func body(content: Content) -> some View {
        if let index { content.fluidItem(index) } else { content }
    }
}

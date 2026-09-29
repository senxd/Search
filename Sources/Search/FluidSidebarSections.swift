import SwiftUI

// Sidebar regions — sidebar-core.tsx:1127-1604 (input, header/footer/
// separator, group actions) + sidebar.tsx:222-265 (SidebarContent).
// Slots keep the source's paddings: p-2 sections, an mx-2 hairline
// separator, and an InputGroup-flavored px-3 h-8 field.
//
// N/A on macOS: role/aria plumbing, and the source's child surgery that
// hoists actions into the header — here they arrive via the group's
// `actions:` parameter.

// MARK: - Header / Footer / Separator

/// `SidebarHeader` — `flex shrink-0 flex-col gap-2 p-2`
/// (sidebar-core.tsx:1163-1173).
struct FluidSidebarHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `SidebarFooter` — `mt-auto flex shrink-0 flex-col gap-2 p-2`. The
/// source's mt-auto needs a fixed-height flex column; in SwiftUI the
/// FluidSidebarContent sibling already flexes, so the footer simply hugs
/// its content. In a sidebar with no scroll region, add Spacer() before it
/// to pin it to the bottom (sidebar-core.tsx:1175-1185).
struct FluidSidebarFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `SidebarSeparator` — `mx-2 h-px shrink-0 bg-border`
/// (sidebar-core.tsx:1187-1199).
struct FluidSidebarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(FluidTone.border)
            .frame(height: 1)
            .padding(.horizontal, 8)
    }
}

// MARK: - Input

/// `SidebarInput` (sidebar-core.tsx:1131-1157) — the InputGroup field
/// ladder: transparent at rest, muted/50 fill + border ring on hover, card
/// fill when focused. h-8 / h-7 compact (one step under the 36pt ladder).
/// The focus-visible accent ring is dropped — the FluidInput port does the
/// same (a focused field rings border, not the accent).
struct FluidSidebarInput: View {
    @Binding var text: String
    var placeholder = ""
    var icon: String? = nil
    var disabled = false

    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var size
    @FocusState private var focused: Bool
    @State private var hovered = false

    init(text: Binding<String>, placeholder: String = "",
         icon: String? = nil, disabled: Bool = false) {
        self._text = text
        self.placeholder = placeholder
        self.icon = icon
        self.disabled = disabled
    }

    /// Placeholder-first convenience: `FluidSidebarInput("Search…", text: $q)`.
    init(_ placeholder: String, text: Binding<String>,
         icon: String? = nil, disabled: Bool = false) {
        self.init(text: text, placeholder: placeholder, icon: icon, disabled: disabled)
    }

    private var fieldBg: Color {
        if disabled { return .clear }
        if focused { return FluidTone.card }
        return hovered ? FluidTone.muted.opacity(0.5) : .clear
    }

    private var ring: Color {
        if disabled { return FluidTone.border }
        return (focused || hovered) ? FluidTone.border : .clear
    }

    var body: some View {
        HStack(spacing: size.gap) {
            if let icon {
                FluidIcon(icon, size: size.icon, bold: hovered || focused)
                    .foregroundStyle(hovered || focused
                        ? FluidTone.foreground : FluidTone.mutedForeground)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: size.text))
                .foregroundStyle(FluidTone.foreground)
                .focused($focused)
        }
        .padding(.horizontal, 12) // px-3
        .frame(height: size == .compact ? 28 : 32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                .fill(fieldBg)
                .overlay(
                    RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                        .strokeBorder(ring, lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: shape.input, style: .continuous))
        .onTapGesture { if !disabled { focused = true } }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovered = $0 }
        .animation(FluidSpring.fast, value: hovered)
        .animation(FluidSpring.fast, value: focused)
    }
}

// MARK: - Content

/// `SidebarContent` (sidebar.tsx:228-265): the scroll region — a
/// FluidScrollArea carrying the source's scroll-fade mask and the
/// scroll-divider hairlines that land on whichever edge has been scrolled
/// away from. `[&>div]:!min-w-0`: the document sizes to the clip's width,
/// so content can't force the sidebar wider — rows truncate, not push.
/// The inset variant's `--scroll-divider-inset:8px` (sidebar-core.tsx:678)
/// keeps the hairlines on the rows' gutter.
struct FluidSidebarContent<Content: View>: View {
    /// scroll-fade's --scroll-fade-size.
    var fadeSize: CGFloat = 48
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidSidebar) private var state

    init(fadeSize: CGFloat = 48, @ViewBuilder content: @escaping () -> Content) {
        self.fadeSize = fadeSize
        self.content = content
    }

    var body: some View {
        FluidScrollArea(
            content: {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            },
            fadeSize: fadeSize,
            dividers: true,
            dividerInset: state?.variant == .inset ? 8 : 0
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Group actions

/// `SidebarGroupAction` (sidebar-core.tsx:1522-1563) — a 24px ghost icon
/// control overlaid on the group header's trailing edge. `popupOpen` pins
/// the header's reveal while a popup the action opened is up (the source's
/// group-has-[data-popup-open] selector). The source draws group actions
/// unconditionally — `showOnHover` opts into the hover-revealed variant.
struct FluidSidebarGroupAction: View {
    let icon: String
    var popupOpen = false
    var showOnHover = false
    var action: () -> Void

    @Environment(\.fluidSidebarGroup) private var group
    @Environment(\.fluidSidebarGroupFocus) private var focus
    @Environment(\.fluidSidebarGroupRevealed) private var revealed
    @Environment(\.fluidInGroupCluster) private var inCluster
    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var size
    @State private var id = UUID()
    @State private var hovered = false

    init(_ icon: String, popupOpen: Bool = false, showOnHover: Bool = false,
         action: @escaping () -> Void = {}) {
        self.icon = icon
        self.popupOpen = popupOpen
        self.showOnHover = showOnHover
        self.action = action
    }

    private var focused: Bool { focus?.wrappedValue == id }
    private var visible: Bool { inCluster || !showOnHover || revealed }

    var body: some View {
        Button {
            focus?.wrappedValue = id
            action()
        } label: {
            // size-6 — the rows' action hit-box — hover:bg-hover +
            // text-foreground, icon thickening like a Button glyph.
            FluidIcon(icon, size: size.icon, bold: hovered)
                .foregroundStyle(hovered ? FluidTone.foreground : FluidTone.mutedForeground)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                        .fill(hovered ? FluidTone.hover : .clear)
                )
        }
        .buttonStyle(.plain)
        .overlay {
            // focus-visible:ring-1 (modality split noted on the group label).
            if focused {
                RoundedRectangle(cornerRadius: shape.item, style: .continuous)
                    .strokeBorder(FluidTone.focusRing, lineWidth: 1)
            }
        }
        .modifier(FluidGroupActionFocusable(id: id))
        // A standalone action sits one cluster-gap lower than clustered
        // ones (top-3 vs the cluster's h-8 at top-2 — both center on 24).
        .padding(.top, inCluster ? 0 : 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.08)) { hovered = h } }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.08), value: visible)
        .onAppear {
            group?.setPopupPin(id, popupOpen)
            if !inCluster { group?.actionsWidth = max(24, group?.actionsWidth ?? 0) }
        }
        .onDisappear {
            group?.setPopupPin(id, false)
            if !inCluster { group?.actionsWidth = 0 }
        }
        .onChange(of: popupOpen) { _, p in group?.setPopupPin(id, p) }
        .onChange(of: inCluster) { _, c in group?.actionsWidth = c ? group?.actionsWidth ?? 0 : 24 }
    }
}

/// Optional-focus binding — FluidMenuFocusable's pattern: the env binding
/// only exists inside a group, so plain actions stay unfocusable.
private struct FluidGroupActionFocusable: ViewModifier {
    let id: UUID
    @Environment(\.fluidSidebarGroupFocus) private var focus

    func body(content: Content) -> some View {
        if let focus {
            content.focusable().focused(focus, equals: id).focusEffectDisabled()
        } else {
            content
        }
    }
}

/// `SidebarGroupActions` (sidebar-core.tsx:1570-1592) — the cluster for
/// 1–3 header actions: h-8 row, gap-1, anchored right-3.5/top-2 by the
/// group's overlay so the last action lands on the rows' action axis.
/// `showOnHover` gates the cluster as a unit on the header reveal; it
/// self-reports its width so a collapsible label pads clear of it.
struct FluidSidebarGroupActions<Content: View>: View {
    var showOnHover = false
    @ViewBuilder var content: () -> Content

    @Environment(\.fluidSidebarGroup) private var group
    @Environment(\.fluidSidebarGroupRevealed) private var revealed

    init(showOnHover: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.showOnHover = showOnHover
        self.content = content
    }

    private var visible: Bool { !showOnHover || revealed }

    var body: some View {
        HStack(spacing: 4) { content() } // gap-1
            .frame(height: 32)           // h-8, centered on the label row
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                group?.actionsWidth = $0
            }
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.easeOut(duration: 0.08), value: visible)
            .environment(\.fluidInGroupCluster, true)
            .onDisappear { group?.actionsWidth = 0 }
    }
}

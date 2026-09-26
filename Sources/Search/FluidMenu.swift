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

extension EnvironmentValues {
    var fluidMenuDismiss: (() -> Void)? {
        get { self[FluidMenuDismissKey.self] }
        set { self[FluidMenuDismissKey.self] = newValue }
    }
}

// MARK: - Menu item

/// A menu row: icon (optional), label, trailing check slot. `checked`
/// nil = plain action item; a Bool makes it a radio/checkbox row.
struct FluidMenuItem: View {
    let index: Int
    var icon: String? = nil
    let label: String
    var checked: Bool? = nil
    var disabled = false
    var size: FluidSize = .default
    var onSelect: () -> Void = {}

    @Environment(\.fluidHover) private var hover
    @Environment(\.fluidMenuDismiss) private var menuDismiss

    private var isActive: Bool { hover?.activeIndex == index }
    private var lit: Bool { isActive || checked == true }

    var body: some View {
        Button(action: { onSelect(); menuDismiss?() }) {
            HStack(spacing: size.gap) {
                if let icon {
                    FluidIcon(icon, size: size.icon, bold: lit)
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                }
                Text(label)
                    .font(.system(
                        size: size.text,
                        weight: checked == true ? .semibold : .regular
                    ))
                    .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                Spacer(minLength: 0)
                // The fixed check slot — its presence never changes the
                // row's width.
                ZStack {
                    if checked == true {
                        FluidCheckmark(size: size.icon)
                            .foregroundStyle(FluidTone.foreground)
                    }
                }
                .frame(width: size.icon, height: size.icon)
            }
            .padding(.horizontal, size.itemPx)
            .frame(height: size.controlHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .fluidItem(index)
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

/// The check glyph: M4 12L9 17L20 6, drawing in on appear (80ms easeOut).
struct FluidCheckmark: View {
    var size: CGFloat = 16
    @State private var drawn: CGFloat = 0

    var body: some View {
        CheckPath()
            .trim(from: 0, to: drawn)
            .stroke(
                style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round)
            )
            .frame(width: size, height: size)
            .onAppear { withAnimation(.easeOut(duration: 0.08)) { drawn = 1 } }
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
struct FluidMenuPanel<Content: View>: View {
    var checkedIndex: Int? = nil
    /// Disabled rows — skipped by the pick, dimmed by the row itself.
    var disabledIndices: Set<Int> = []
    var size: FluidSize = .default
    var substrate: Int = 1
    /// Dropdown fixes the panel at w-72; Select fits rows to content
    /// (the popup window still enforces min-width = trigger width).
    var width: CGFloat? = 288
    /// Gap-click routing: a click between rows picks the lit one.
    var onPick: ((Int) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var hover = FluidHover(axis: .y)

    private var checkedRect: CGRect? {
        checkedIndex.flatMap { hover.rects[$0] }
    }

    var body: some View {
        FluidContainer(
            hover: hover,
            from: checkedRect,
            radius: menuShape.bg,
            onGapPick: onPick
        ) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(4)
        }
        .frame(width: width)
        .background(alignment: .topLeading) { checkedBackground }
        .onAppear { hover.isItemDisabled = { disabledIndices.contains($0) } }
        .fluidSurface(min(substrate + 2, 8), radius: menuShape.container)
    }

    /// bg-active behind the checked row — springs with the moderate tier.
    @ViewBuilder
    private var checkedBackground: some View {
        if let r = checkedRect {
            RoundedRectangle(cornerRadius: menuShape.bg, style: .continuous)
                .fill(FluidTone.active)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .animation(FluidSpring.moderate, value: r)
                .transition(.opacity)
        }
    }
}

// MARK: - Popup presentation

/// Radix positions popup content in a portal; on macOS the faithful
/// counterpart is a borderless, non-activating child panel — no system
/// chrome, no clipping at the window edge, and it never steals focus from
/// the field that opened it (which Combobox relies on).
@MainActor
final class FluidPopupController {
    /// Shared by the enter/exit wrapper inside the popup.
    final class OpenState: ObservableObject {
        @Published var shown = false
    }

    enum Edge: Equatable { case top, bottom, left, right }
    enum Align { case start, center }
    /// Enter/exit motion: menu popups scaleY + rise 4pt from the opening
    /// edge; tooltips slide 4pt toward the trigger with no scale.
    enum Motion: Equatable { case popup, tooltip(Edge) }

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var state = OpenState()
    private var motion: Motion = .popup
    var onDismissed: (() -> Void)?
    private var anchor: NSView?

    var isPresented: Bool { panel != nil }

    func setAnchor(_ view: NSView) { anchor = view }

    /// Current anchor frame in screen coordinates, for follow-cursor moves.
    func anchorScreenRect() -> CGRect? {
        guard let anchor, let window = anchor.window else { return nil }
        let r = anchor.convert(anchor.bounds, to: nil)
        let origin = window.convertPoint(toScreen: r.origin)
        return CGRect(x: origin.x, y: origin.y, width: r.width, height: r.height)
    }

    /// Slides the already-open panel to a new origin (followCursor).
    func move(to origin: CGPoint) {
        guard let panel else { return }
        panel.setFrameOrigin(origin)
    }

    func panelFrame() -> CGRect? { panel?.frame }

    func present<Content: View>(
        edge: Edge = .bottom,
        align: Align = .start,
        offset: CGFloat = 6,
        motion: Motion = .popup,
        clickDismiss: Bool = true,
        mouseTransparent: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        guard let anchor, let window = anchor.window else { return }
        dismiss(animated: false)
        self.motion = motion

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = mouseTransparent

        let host = NSHostingView(
            rootView: FluidPopupRoot(state: state, motion: motion, content: content)
        )
        panel.contentView = host

        let fitting = host.fittingSize
        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let screen = window.convertPoint(toScreen: anchorRect.origin)
        let width = edge == .bottom || edge == .top
            ? max(fitting.width, anchorRect.width)
            : fitting.width
        let x: CGFloat = {
            switch (edge, align) {
            case (.left, _): return screen.x - width - offset
            case (.right, _): return screen.x + anchorRect.width + offset
            case (_, .center): return screen.x + anchorRect.width / 2 - width / 2
            default: return screen.x
            }
        }()
        let y: CGFloat = {
            switch (edge, align) {
            case (.bottom, _): return screen.y - fitting.height - offset
            case (.top, _): return screen.y + anchorRect.height + offset
            case (_, .center): return screen.y + anchorRect.height / 2 - fitting.height / 2
            default: return screen.y
            }
        }()
        panel.setFrame(
            NSRect(x: x, y: y, width: width, height: fitting.height),
            display: false
        )
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel

        guard clickDismiss else { return }

        // Outside click (not on the anchor — the trigger toggles) and
        // Escape dismiss, like Radix's pointer-down-outside + Esc.
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            let inAnchor = anchor.window === event.window &&
                anchor.bounds.contains(
                    anchor.convert(event.locationInWindow, from: nil)
                )
            if event.window !== self.panel, !inAnchor { self.dismiss() }
            return event
        }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return nil }
            return event
        }!)
    }

    func dismiss(animated: Bool = true) {
        guard let panel else { return }
        if animated {
            withAnimation(FluidSpring.fast) { state.shown = false }
            // spring.fast exits in ~90ms; release the window after it lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.teardown(panel)
            }
        } else {
            teardown(panel)
        }
    }

    private func teardown(_ panel: NSPanel) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if self.panel === panel { self.panel = nil }
        state = OpenState()
        onDismissed?()
    }
}

/// The enter/exit motions shared by every FF popup (popup.ts): menus do
/// opacity + y −4→0 + scaleY 0.96→1 anchored to the opening edge; tooltips
/// slide 4pt toward their trigger. Both run spring.fast.
private struct FluidPopupRoot<Content: View>: View {
    @ObservedObject var state: FluidPopupController.OpenState
    var motion: FluidPopupController.Motion = .popup
    @ViewBuilder var content: () -> Content

    private var hiddenOffset: CGSize {
        switch motion {
        case .popup: return CGSize(width: 0, height: -4)
        case .tooltip(.top): return CGSize(width: 0, height: 4)
        case .tooltip(.bottom): return CGSize(width: 0, height: -4)
        case .tooltip(.left): return CGSize(width: 4, height: 0)
        case .tooltip(.right): return CGSize(width: -4, height: 0)
        }
    }

    var body: some View {
        content()
            .opacity(state.shown ? 1 : 0)
            .scaleEffect(
                x: 1,
                y: state.shown ? 1 : (motion == .popup ? 0.96 : 1),
                anchor: .top
            )
            .offset(state.shown ? .zero : hiddenOffset)
            .onAppear { withAnimation(FluidSpring.fast) { state.shown = true } }
    }
}

/// Reports the rendered NSView so the popup can anchor to it.
struct FluidAnchorResolver: NSViewRepresentable {
    let controller: FluidPopupController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { controller.setAnchor(view) }
        return view
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
    var onPick: ((Int) -> Void)? = nil
    @ViewBuilder var rows: () -> Rows

    @State private var controller = FluidPopupController()

    func body(content: Content) -> some View {
        content
            .background(FluidAnchorResolver(controller: controller))
            .onChange(of: isPresented) { _, open in
                if open {
                    controller.present {
                        FluidMenuPanel(
                            checkedIndex: checkedIndex,
                            disabledIndices: disabledIndices,
                            substrate: substrate,
                            width: width,
                            onPick: { i in onPick?(i); isPresented = false },
                            content: rows
                        )
                        .environment(\.fluidMenuDismiss, { isPresented = false })
                    }
                } else {
                    controller.dismiss()
                }
            }
            .onAppear {
                controller.onDismissed = { isPresented = false }
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
        onPick: ((Int) -> Void)? = nil,
        @ViewBuilder rows: @escaping () -> Rows
    ) -> some View {
        modifier(FluidMenuPopupModifier(
            isPresented: isPresented,
            checkedIndex: checkedIndex,
            disabledIndices: disabledIndices,
            substrate: substrate,
            width: width,
            onPick: onPick,
            rows: rows
        ))
    }
}

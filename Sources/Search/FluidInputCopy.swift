import AppKit
import SwiftUI

// InputCopy — fluid-demo/components/ui/input-copy.tsx.
// A read-only value row that copies on click: mono truncated value, a
// copy affordance (icon-only with a 500ms tooltip at sideOffset 2, or a
// labeled button), and a status swap — copy icon → drawn-in check → back
// after 2s. On hover the value picks up the focus-ring tint (#6B97FF/20)
// and the icon bolds. Disabled is 50% and inert.
//
// The icon variant's tooltip rides a three-state machine: idle (normal
// hover), copied (force-open "Copied" right after a copy while the
// pointer is on the button), suppressed (force-closed — set when the
// copy happened without the tooltip up, or on leave, so the "Copied"
// pill never pops late).

enum FluidInputCopyVariant { case icon, button }
enum FluidInputCopyAlign { case right, left }

struct FluidInputCopy: View {
    let value: String
    var label: String? = nil
    var onCopy: (() -> Void)? = nil
    var disabled = false
    var variant: FluidInputCopyVariant = .icon
    var align: FluidInputCopyAlign = .right
    /// `size` pins the field to one ladder step (input-copy.tsx:32);
    /// omitted, it follows the surrounding fluidSize.
    var size: FluidSize? = nil

    @Environment(\.fluidSize) private var ambientSize
    @Environment(\.fluidShape) private var shape
    @State private var status: Status = .idle
    @State private var copyCount = 0
    /// Row hover — the button's `group-hover` (visuals only).
    @State private var hovered = false
    /// idle = normal tooltip, copied = force open, suppressed = force closed.
    @State private var tipState: TipState = .idle
    /// Live tooltip visibility, reported through onOpenChange — the
    /// source's tooltipVisibleRef.
    @State private var tipVisible = false
    @State private var resetTask: Task<Void, Never>?
    /// :focus-visible latch — a pointer-originated focus paints no ring.
    @State private var pointerFocus = false

    private enum Status { case idle, copied, failed }
    private enum TipState { case idle, copied, suppressed }
    /// The ladder step — the prop pins it, else the ambient.
    private var resolvedSize: FluidSize { size ?? ambientSize }
    private var compact: Bool { resolvedSize == .compact }

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label)
                    .font(.system(size: resolvedSize.text))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .padding(.leading, align == .left ? 4 : 0)
            }
            Button(action: copy) {
                HStack(spacing: 0) {
                    if align == .left { action }
                    valueElement
                    if align == .right { action }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .onChange(of: focused) { _, f in
                // :focus-visible — the ring only paints when the focus
                // arrived under a keyDown (Tab in); a click-focus doesn't
                // (focus-visible:ring-1, input-copy.tsx:348).
                if f { pointerFocus = NSApp.currentEvent?.type != .keyDown }
            }
            // group-hover scope — the button alone, not the label above.
            .onHover { h in
                withAnimation(.easeOut(duration: 0.08)) { hovered = h }
            }
            .overlay(
                RoundedRectangle(cornerRadius: shape.input, style: .continuous)
                    .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                    .opacity(focused && !pointerFocus ? 1 : 0)
            )
            // The Tooltip wraps the button alone (input-copy.tsx:382-384)
            // — hovering the label doesn't trigger it.
            .fluidTooltipIf(
                variant == .icon,
                text: tipState == .idle ? "Copy to clipboard"
                    : status == .failed ? "Copy failed" : "Copied",
                sideOffset: 2,
                delay: 0.5,
                forceOpen: tipState == .copied ? true
                    : tipState == .suppressed ? false : nil,
                onOpenChange: { tipVisible = $0 }
            )
        }
        .environment(\.fluidSize, resolvedSize)
        .opacity(disabled ? 0.5 : 1)
        .allowsHitTesting(!disabled)
        // The OUTER box's hover drives the tooltip machine (the source's
        // onMouseEnter/Leave on the root div): a fresh entry clears a
        // suppressed pill, leaving hides a stuck "Copied".
        .onHover { h in
            if h {
                if tipState == .suppressed { tipState = .idle }
            } else if tipState == .copied {
                tipState = .suppressed
            }
        }
    }

    /// The value — mono, truncated, and mark-highlighted on hover. The
    /// tint sits on the text run itself (the source's <mark>,
    /// input-copy.tsx:317), not the full-width flex span — the tint ends
    /// where the glyphs do.
    private var valueElement: some View {
        Text(value)
            .font(.system(size: resolvedSize.text, design: .monospaced))
            .foregroundStyle(FluidTone.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
            .background(
                Rectangle().fill(
                    hovered ? FluidTone.focusRing.opacity(0.2) : .clear
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, compact ? 4 : 8)
            .padding(.leading, align == .left ? 4 : 0)
    }

    private var action: some View {
        HStack(spacing: 6) {
            statusIcon
            if variant == .button {
                // Fixed-width label slot — "Copied" reserves the width.
                ZStack(alignment: .leading) {
                    Text("Copied").opacity(0)
                    Text(status == .idle ? "Copy" : status == .copied ? "Copied" : "Failed")
                        .id("\(status)-\(copyCount)")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                .font(.system(size: resolvedSize.text))
            }
        }
        .foregroundStyle(status == .failed ? FluidTone.destructive
                         : hovered ? FluidTone.foreground : FluidTone.mutedForeground)
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 4 : 8)
    }

    /// Copy → check draws in (80ms); failure shows the ✕ in destructive.
    /// Re-keyed on copyCount so a re-copy while still "Copied" replays.
    /// The button variant's glyph is stroke-2; the icon variant rests at
    /// 1.5 and picks up 2 on group-hover ([&_svg]:stroke-[1.5] → 2).
    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            switch status {
            case .idle:
                FluidIcon("doc.on.doc", size: 14, bold: hovered)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .copied:
                DrawnGlyph(check: true, weight: variant == .button ? 2 : (hovered ? 2 : 1.5))
                    .id("check-\(copyCount)")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .failed:
                DrawnGlyph(check: false, weight: variant == .button ? 2 : (hovered ? 2 : 1.5))
                    .id("error-\(copyCount)")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(FluidSpring.fast, value: status)
        .animation(FluidSpring.fast, value: copyCount)
        .frame(width: 14, height: 14)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(value, forType: .string)
        withAnimation(FluidSpring.fast) { status = ok ? .copied : .failed }
        copyCount += 1
        // The source reads the pre-click tooltip visibility — our tooltip
        // stays open through the click, so the live flag is the same read.
        tipState = tipVisible ? .copied : .suppressed
        if ok { onCopy?() }
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(FluidSpring.fast) { status = .idle }
                tipState = .suppressed
            }
        }
    }
}

/// The check (M6 12L10 16L18 8) or ✕ (M9 9L15 15M15 9L9 15) glyph,
/// drawing in over 80ms — the source's pathLength animation.
private struct DrawnGlyph: View {
    let check: Bool
    var weight: CGFloat = 2
    @State private var drawn: CGFloat = 0

    var body: some View {
        GlyphPath(check: check)
            .trim(from: 0, to: drawn)
            .stroke(style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
            .onAppear { withAnimation(.easeOut(duration: 0.08)) { drawn = 1 } }
    }

    private struct GlyphPath: Shape {
        let check: Bool
        func path(in rect: CGRect) -> Path {
            // Source viewBox="2 4 20 16" — x runs 2–22, y runs 4–20.
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(
                    x: rect.minX + (x - 2) / 20 * rect.width,
                    y: rect.minY + (y - 4) / 16 * rect.height
                )
            }
            var p = Path()
            if check {
                p.move(to: pt(6, 12)); p.addLine(to: pt(10, 16)); p.addLine(to: pt(18, 8))
            } else {
                p.move(to: pt(9, 9)); p.addLine(to: pt(15, 15))
                p.move(to: pt(15, 9)); p.addLine(to: pt(9, 15))
            }
            return p
        }
    }
}

private extension View {
    /// fluidTooltip only when asked — the button variant carries no tooltip.
    @ViewBuilder
    func fluidTooltipIf(
        _ enabled: Bool, text: String, sideOffset: CGFloat,
        delay: TimeInterval, forceOpen: Bool?, onOpenChange: ((Bool) -> Void)?
    ) -> some View {
        if enabled {
            self.fluidTooltip(
                text, side: .top, sideOffset: sideOffset, delay: delay,
                forceOpen: forceOpen, onOpenChange: onOpenChange
            )
        } else { self }
    }
}

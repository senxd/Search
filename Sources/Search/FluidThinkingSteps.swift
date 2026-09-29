import AppKit
import SwiftUI

// ThinkingSteps — fluid-demo/components/ui/thinking-steps.tsx.
// A single collapsible section: a compact trigger row (hover bg fade,
// dual-layer label that emboldens on open, chevron right→90° on the fast
// tier) over a measured-height panel (moderate spring, bounce: 0). Steps
// mount by springing their height open (slow tier) then fading in —
// each with an icon column and a hairline connector to the next step.

// MARK: - Root

/// `ThinkingSteps` — one collapsible, w-80 (320px, `max-w-full` shrink-
/// safe). Controlled or uncontrolled (`open:` omitted → internal state,
/// `defaultOpen` starts it like the source's prop).
struct FluidThinkingSteps<Content: View>: View {
    private var bound: Binding<Bool>?
    /// `size` pins every row to one ladder step; omitted, rows follow the
    /// surrounding fluidSize (the source's optional SizeProvider wrap).
    var size: FluidSize? = nil
    @ViewBuilder var content: () -> Content
    @State private var fallback: Bool
    @Environment(\.fluidSize) private var ambientSize

    private var open: Binding<Bool> { bound ?? $fallback }

    init(open: Binding<Bool>, size: FluidSize? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.bound = open; self.size = size; self.content = content
        _fallback = State(initialValue: true)
    }

    /// Uncontrolled — `defaultOpen` seeds the state (source default true).
    init(defaultOpen: Bool = true, size: FluidSize? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.bound = nil; self.size = size; self.content = content
        _fallback = State(initialValue: defaultOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            // w-80 max-w-full — 320 unless the box is narrower.
            .frame(minWidth: 0, idealWidth: 320, maxWidth: 320, alignment: .leading)
            .environment(\.fluidStepsOpen, open)
            .environment(\.fluidSize, size ?? ambientSize)
    }
}

private struct FluidStepsOpenKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}
extension EnvironmentValues {
    var fluidStepsOpen: Binding<Bool>? {
        get { self[FluidStepsOpenKey.self] }
        set { self[FluidStepsOpenKey.self] = newValue }
    }
}

// MARK: - Trigger row

/// The shared trigger: hover bg fade, dual-layer label, chevron 0→90°,
/// and the source's focus-visible ring-1.
struct FluidStepsTrigger<Label: View>: View {
    @Binding var open: Bool
    var paddingless = false
    @ViewBuilder var label: () -> Label

    @Environment(\.fluidSize) private var size
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var compact: Bool { size == .compact }
    private var lit: Bool { open || hovered }

    var body: some View {
        Button { withAnimation(FluidSpring.fast) { open.toggle() } } label: {
            HStack(spacing: paddingless ? 6 : 10) {
                // Invisible semibold sizer — emboldening never reflows.
                ZStack(alignment: .leading) {
                    label().font(.system(size: size.text, weight: .semibold)).hidden()
                    label()
                        .font(.system(size: size.text, weight: open ? .semibold : .regular))
                        .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                }
                FluidIcon("chevron.right", size: size.icon, bold: lit)
                    .foregroundStyle(lit ? FluidTone.foreground : FluidTone.mutedForeground)
                    .frame(width: size.icon, height: size.icon)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, paddingless ? 12 : size.px)
            .padding(.vertical, paddingless ? 4 : compact ? 6 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .background(
            RoundedRectangle(cornerRadius: FluidShape.rounded.bg, style: .continuous)
                .fill(FluidTone.hover)
                .opacity(hovered ? 1 : 0)
        )
        // focus-visible:ring-1 — the ring hugs the row's item radius.
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.item, style: .continuous)
                .strokeBorder(FluidTone.focusRing, lineWidth: 1)
                .opacity(focused ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.08), value: hovered)
        .onHover { hovered = $0 }
    }
}

/// `ThinkingStepsHeader` — the root's trigger ("Thinking" by default).
/// Takes any label view; the String init keeps the common case short.
struct FluidThinkingStepsHeader<Label: View>: View {
    @ViewBuilder var label: () -> Label
    @Environment(\.fluidStepsOpen) private var open

    init(@ViewBuilder label: @escaping () -> Label) {
        self.label = label
    }

    var body: some View {
        if let open {
            FluidStepsTrigger(open: open, label: label)
        }
    }
}

extension FluidThinkingStepsHeader where Label == Text {
    init(_ text: String = "Thinking") {
        self.init { Text(text) }
    }
}

// MARK: - Panel

/// The measured-height collapse: the content renders at ideal size,
/// reports its height, and the visible frame clamps to it (or 0).
struct FluidStepsPanel<Content: View>: View {
    @Binding var open: Bool
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0
    @Environment(\.fluidSize) private var size

    private var compact: Bool { size == .compact }

    var body: some View {
        content()
            // CollapsePanel's inner box: px-3 pb-3 pt-1, muted, 13/12px.
            .font(.system(size: compact ? 12 : 13))
            .foregroundStyle(FluidTone.mutedForeground)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { height = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in height = h }
                }
            )
            .frame(height: open ? height : 0, alignment: .top)
            .clipped()
            .animation(FluidSpring.moderate, value: open)
    }
}

/// `ThinkingStepsContent` — the root's collapse panel.
struct FluidThinkingStepsContent<Content: View>: View {
    @Environment(\.fluidStepsOpen) private var open
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let open {
            FluidStepsPanel(open: open) {
                VStack(alignment: .leading, spacing: 0) { content() }
            }
        }
    }
}

// MARK: - Step

enum FluidStepStatus { case complete, active, pending }

/// A step row: 14pt icon column with a hairline connector continuing to
/// the next step, label (medium, shimmered + "…" while active), and an
/// optional description.
struct FluidThinkingStep<Extra: View>: View {
    var icon: String? = nil
    var showIcon = true
    let label: String
    var description: String? = nil
    var status: FluidStepStatus = .complete
    /// Content fade-in delay — the source's `delay` prop (0.08s default).
    var delay: Double = 0.08
    var isLast = false
    @ViewBuilder var extra: () -> Extra

    @Environment(\.fluidSize) private var size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 0
    @State private var appeared = false

    private var compact: Bool { size == .compact }

    init(label: String, icon: String? = nil, description: String? = nil,
         status: FluidStepStatus = .complete, delay: Double = 0.08,
         isLast: Bool = false,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.label = label; self.icon = icon; self.description = description
        self.status = status; self.delay = delay; self.isLast = isLast
        self.extra = extra
    }

    var body: some View {
        // status === "pending" returns null upstream — nothing renders.
        if status != .pending {
            row
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { height = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in height = h }
                    }
                )
                .frame(height: appeared ? height : 0, alignment: .top)
                .clipped()
                .onAppear {
                    withAnimation(FluidSpring.slow) { appeared = true }
                }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            // Icon column + connector to the next step.
            VStack(spacing: 0) {
                Group {
                    if showIcon, let icon {
                        FluidIcon(icon, size: compact ? 12 : 14)
                            .foregroundStyle(FluidTone.mutedForeground)
                    } else {
                        Circle()
                            .fill(FluidTone.mutedForeground.opacity(0.6))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 14, height: compact ? 12 : 14)
                .padding(.top, 2)
                if !isLast {
                    Rectangle()
                        .fill(FluidTone.border.opacity(0.6))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 4)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(label + (status == .active ? "…" : ""))
                    .font(.system(size: size.text, weight: .medium))
                    // Active steps shimmer — shimmer-text's literal ramp:
                    // #a3a3a3 base, #525252 sweep (globals.css), NOT the
                    // foreground token.
                    .foregroundStyle(status == .active ? shimmerBase : FluidTone.foreground)
                    .fluidShimmerSweep(shimmerTint, active: status == .active)
                if let description {
                    Text(description)
                        .font(.system(size: size.text))
                        .foregroundStyle(FluidTone.mutedForeground)
                }
                extra()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.24).delay(delay), value: appeared)
    }

}

/// shimmer-text's literal colors (globals.css:272) — verbatim like the
/// ThinkingIndicator's, since the CSS uses the same hexes in both schemes.
private let shimmerBase = Color(red: 0xA3/255, green: 0xA3/255, blue: 0xA3/255)
private let shimmerTint = Color(red: 0x52/255, green: 0x52/255, blue: 0x52/255)

// MARK: - Nested details

/// `ThinkingStepDetails` — a nested collapsible inside a step: smaller
/// trigger, muted detail lines underneath.
struct FluidThinkingStepDetails: View {
    let summary: String
    var details: [String] = []
    @State private var open: Bool
    @Environment(\.fluidSize) private var size

    init(summary: String, details: [String] = [], defaultOpen: Bool = false) {
        self.summary = summary
        self.details = details
        _open = State(initialValue: defaultOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FluidStepsTrigger(open: $open, paddingless: true) {
                Text(summary).font(.system(size: size.text - 1))
            }
            FluidStepsPanel(open: $open) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(details, id: \.self) { d in
                        Text(d)
                            .font(.system(size: size == .compact ? 11 : 12))
                            .foregroundStyle(FluidTone.mutedForeground)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.leading, -12)
        .padding(.top, 4)
    }
}

// MARK: - Sources

/// `ThinkingStepSource` — one source chip: the registry's solid sm Badge
/// popping in (opacity + 0.85 scale on the moderate tier, a 120ms blur
/// unwrap), with the source's per-chip `delay`.
struct FluidThinkingStepSource: View {
    let text: String
    var color: FluidBadgeColor = .gray
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var sharp = false

    init(_ text: String, color: FluidBadgeColor = .gray, delay: Double = 0) {
        self.text = text; self.color = color; self.delay = delay
    }

    var body: some View {
        FluidBadge(text, variant: .solid, color: color, size: .compact)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.85)
            .blur(radius: sharp || reduceMotion ? 0 : 4)
            .onAppear {
                // framer: { ...spring.moderate, delay,
                //         filter: { duration: 0.12, delay } }
                withAnimation(FluidSpring.moderate.delay(delay)) { appeared = true }
                withAnimation(.easeOut(duration: 0.12).delay(delay)) { sharp = true }
            }
    }
}

/// The array convenience — every entry a chip at the same `delay`.
struct FluidSourceChipGroup: View {
    var sources: [(text: String, color: FluidChipColor)]
    var delay: Double = 0

    var body: some View {
        ForEach(Array(sources.enumerated()), id: \.offset) { _, s in
            FluidThinkingStepSource(
                s.text,
                color: FluidBadgeColor(rawValue: s.color.rawValue) ?? .gray,
                delay: delay
            )
        }
    }
}

/// `ThinkingStepSources` — the wrap row of chips (flex flex-wrap
/// gap-1.5 mt-1). Compose `FluidThinkingStepSource` children directly for
/// per-chip delays, or pass the array for the common case.
struct FluidThinkingStepSources<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        FluidFlow(spacing: 6, rowSpacing: 6) { content() }
            .padding(.top, 6)
    }
}

extension FluidThinkingStepSources where Content == FluidSourceChipGroup {
    init(sources: [(text: String, color: FluidChipColor)], delay: Double = 0) {
        self.init { FluidSourceChipGroup(sources: sources, delay: delay) }
    }
}

// MARK: - Image

/// `ThinkingStepImage` — a screenshot/photo under a step: full-width up
/// to 200px (w-full max-w-[200px]), the container radius, an optional
/// caption (12/11px muted, mt-1). Fades in over 200ms while a 4px blur
/// unwraps over 150ms.
struct FluidThinkingStepImage: View {
    let image: Image
    var caption: String? = nil
    var delay: Double = 0

    @Environment(\.fluidSize) private var size
    @Environment(\.fluidShape) private var shape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var sharp = false

    init(image: Image, caption: String? = nil, delay: Double = 0) {
        self.image = image; self.caption = caption; self.delay = delay
    }

    init(nsImage: NSImage, caption: String? = nil, delay: Double = 0) {
        self.init(image: Image(nsImage: nsImage), caption: caption, delay: delay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 200, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: shape.container, style: .continuous))
            if let caption {
                Text(caption)
                    .font(.system(size: size == .compact ? 11 : 12))
                    .foregroundStyle(FluidTone.mutedForeground)
            }
        }
        .padding(.top, 6)
        .opacity(appeared ? 1 : 0)
        .blur(radius: sharp || reduceMotion ? 0 : 4)
        .onAppear {
            // framer: opacity { duration: 0.2, delay, easeOut },
            //         filter  { duration: 0.15, delay }
            withAnimation(.easeOut(duration: 0.2).delay(delay)) { appeared = true }
            withAnimation(.easeOut(duration: 0.15).delay(delay)) { sharp = true }
        }
    }
}

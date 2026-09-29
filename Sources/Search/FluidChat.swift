import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// ChatMessage + FileThumbnail — chat-message.tsx / file-thumbnail.tsx.
// User bubbles keep the chrome (accent-mix fill, rounded, accent-foreground
// text), assistant replies are flush-left plain text; the meta row (time +
// actions) stays mounted but invisible until the message is hovered. Entry:
// moderate spring, y+8, scale 0.96, anchored at the bubble's bottom corner.
// The whole column is capped at 80% of the row width (max-w-[80%]) and
// attachments wrap in a flex row hugging the message's edge. Image
// attachments preview object-cover; PDFs render their first page at 2x;
// anything else falls back to the registry's inline file glyph.

enum FluidChatSender { case user, assistant }

struct FluidChatMessage<Content: View, Actions: View>: View {
    var from: FluidChatSender = .assistant
    var time: String? = nil
    var files: [URL] = []
    var thumbnailSize: CGFloat = 64
    /// Pins the message to one step of the size ladder — the source's
    /// `size` prop (compact tightens bubble type and padding). Nil follows
    /// the surrounding fluidSize environment.
    var size: FluidSize? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    @Environment(\.fluidShape) private var shape
    @Environment(\.fluidSize) private var contextSize
    @State private var hovered = false
    @State private var appeared = false

    private var compact: Bool { (size ?? contextSize) == .compact }
    private var isUser: Bool { from == .user }

    var body: some View {
        FluidChatWidthCap(factor: 0.8) {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !files.isEmpty {
                    // flex flex-wrap gap-1.5 — rows wrap at the bubble cap
                    // and each row hugs the message's own edge
                    // (justify-end / justify-start).
                    FluidChatFileFlow(spacing: 6, rowSpacing: 6, trailing: isUser) {
                        // Index-keyed like the source's `-${i}` suffix, so
                        // attaching the same URL twice can't collide.
                        ForEach(Array(files.enumerated()), id: \.offset) { _, url in
                            FluidFileThumbnail(url: url, size: thumbnailSize)
                        }
                    }
                }

                // `children == null` drops the text bubble entirely —
                // attachment-only messages pass `EmptyView`.
                if Content.self != EmptyView.self {
                    content()
                        .font(.system(size: compact ? 13 : 14))
                        .foregroundStyle(isUser ? FluidChatTone.bubbleText : FluidTone.foreground)
                        .padding(.horizontal, isUser ? (compact ? 12 : 14) : 0)
                        // py-1.5/py-2 applies to the assistant's plain text
                        // too, not just the user bubble.
                        .padding(.vertical, compact ? 6 : 8)
                        .background {
                            if isUser {
                                RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                                    .fill(FluidTone.bubble)
                            }
                        }
                }

                // Meta row: timestamp (a user-message affordance) +
                // icon-only actions. Always laid out so it reserves its
                // height and the gap between bubbles never shifts; revealed
                // on hover. The source also reveals on focus-within, which
                // SwiftUI can't observe — hover covers the macOS case.
                if isUser && time != nil || Actions.self != EmptyView.self {
                    HStack(spacing: 8) {
                        if isUser, let time {
                            Text(time).monospacedDigit()
                        }
                        // The source wraps {actions} in flex gap-0.5.
                        HStack(spacing: 2) { actions() }
                    }
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(FluidTone.mutedForeground)
                    .padding(.horizontal, 4)
                    .opacity(hovered ? 1 : 0)
                    // pointer-events-none until the group is hovered.
                    .allowsHitTesting(hovered)
                    .animation(.easeOut(duration: 0.15), value: hovered)
                }
            }
            // Entrance on the message box (not the full row) so the scale
            // anchors at the bubble's bottom corner like transform-origin.
            .scaleEffect(appeared ? 1 : 0.96, anchor: isUser ? .bottomTrailing : .bottomLeading)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            // group-hover over the message's own bounds, not the whole row.
            .onHover { hovered = $0 }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onAppear {
            withAnimation(FluidSpring.moderate) { appeared = true }
        }
    }
}

extension FluidChatMessage where Actions == EmptyView {
    init(
        from: FluidChatSender = .assistant,
        time: String? = nil,
        files: [URL] = [],
        thumbnailSize: CGFloat = 64,
        size: FluidSize? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(from: from, time: time, files: files, thumbnailSize: thumbnailSize,
                  size: size, content: content, actions: { EmptyView() })
    }
}

/// --accent-foreground (oklch 0.205 / 0.985) — the user bubble's text tone.
/// Local because Fluid.swift's palette doesn't carry it; matches the
/// neutral-900/neutral-50 values the token resolves to.
private enum FluidChatTone {
    static let bubbleText = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.985, alpha: 1)
            : NSColor(srgbRed: 0x17/255, green: 0x17/255, blue: 0x17/255, alpha: 1)
    })
}

/// `max-w-[80%]` — the message column wraps at 80% of the offered row width
/// but hugs its content below that, so short bubbles keep their natural
/// size. A `Layout` (not measured state) so the cap applies in one pass.
private struct FluidChatWidthCap: Layout {
    var factor: CGFloat = 0.8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let cap = proposal.width.map { $0 * factor } ?? .infinity
        return child.sizeThatFits(ProposedViewSize(width: cap, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// `flex flex-wrap gap-1.5` + `justify-end`/`justify-start`: rows wrap at
/// the container width and hug the message's own edge. `FluidFlow`
/// (FluidCombobox.swift) wraps but always left-aligns rows, so the row
/// justification lives here where the transcript needs it.
private struct FluidChatFileFlow: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6
    var trailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > limit { x = 0; y += rowH + rowSpacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x - spacing)
        }
        // Report the content width (not the offered width) so the parent
        // aligns the block like a content-sized flex child.
        return CGSize(width: min(limit, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Split into rows first so each row's width is known — justify-*
        // needs the row's extent before placing its first item.
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var idx: [Int] = []; var w: CGFloat = 0; var h: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !idx.isEmpty, w + spacing + s.width > bounds.width {
                rows.append((idx, w, h)); idx = []; w = 0; h = 0
            }
            w += (idx.isEmpty ? 0 : spacing) + s.width
            idx.append(i); h = max(h, s.height)
        }
        if !idx.isEmpty { rows.append((idx, w, h)) }

        var y = bounds.minY
        for row in rows {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + rowSpacing
        }
    }
}

// MARK: - FileThumbnail

/// bg-accent tile, 1px border, shape radius. Images render a cover preview;
/// PDFs render their first page at 2x (the source's renderPdfFirstPage);
/// while either resolves a spinner shows. Failed PDFs and unsupported
/// types get the inline file glyph — the same icon, not an SF Symbol.
struct FluidFileThumbnail: View {
    let url: URL
    var size: CGFloat = 64

    @Environment(\.fluidShape) private var shape
    /// `imageUrl ?? pdfUrl` — the resolved preview, whichever kind loaded.
    @State private var image: NSImage?
    /// Load-invalidation ticket — the source's `cancelled` effect cleanup.
    /// An in-flight load for a swapped-out url can't land over the new one.
    @State private var ticket = 0
    /// pdfError — a failed first-page render drops to the generic glyph
    /// instead of spinning forever (corrupt or encrypted files).
    @State private var failed = false

    /// The source checks the File's MIME (`image/*`, `application/pdf`);
    /// with a URL on disk, the extension's UTType is the same answer.
    private var type: UTType? {
        UTType(filenameExtension: url.pathExtension.lowercased())
    }
    private var isImage: Bool { type?.conforms(to: .image) == true }
    private var isPDF: Bool { type?.conforms(to: .pdf) == true }
    /// Spinner only while a preview is genuinely pending; anything that
    /// can't produce one gets the generic icon instead.
    private var isPending: Bool {
        (isImage || isPDF) && image == nil && !failed
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isPending {
                // The ring spinner — w-6 h-6, border-2, one quadrant
                // accented — while a preview resolves.
                FluidRingSpinner(diameter: 24)
                    .accessibilityLabel("Loading preview")
            } else {
                // Generic document glyph for files with no renderable
                // preview — the source's inline SVG, drawn.
                let glyph = max(16, size * 0.35)
                FluidFileGlyph()
                    .stroke(FluidTone.mutedForeground, style: StrokeStyle(
                        lineWidth: 1.5 * glyph / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: glyph, height: glyph)
            }
        }
        .frame(width: size, height: size)
        .background(FluidTone.accent)
        .clipShape(RoundedRectangle(cornerRadius: shape.bg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: shape.bg, style: .continuous)
                .strokeBorder(FluidTone.border, lineWidth: 1)
        )
        .accessibilityLabel(url.lastPathComponent)
        .onAppear(perform: load)
        // Index-keyed ForEach + a swapped file keeps the view — reload on
        // identity change like the source's effect deps (url AND size).
        .onChange(of: url) { _, _ in reload() }
        .onChange(of: size) { _, _ in reload() }
    }

    private func reload() {
        ticket += 1
        image = nil
        failed = false
        load()
    }

    private func load() {
        let t = ticket
        if isImage {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOf: url)
                DispatchQueue.main.async {
                    guard self.ticket == t else { return }
                    if let img { self.image = img } else { self.failed = true }
                }
            }
        } else if isPDF {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = Self.renderPDFPage(url: url, width: size)
                DispatchQueue.main.async {
                    guard self.ticket == t else { return }
                    if let img { self.image = img } else { self.failed = true }
                }
            }
        }
    }

    /// renderPdfFirstPage: first page rasterized at `width * 2` points wide
    /// (2x for retina), the same scale the source computes off pdfjs's
    /// scale-1 viewport. nil → the caller falls back to the glyph.
    private static func renderPDFPage(url: URL, width: CGFloat) -> NSImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let base = page.bounds(for: .mediaBox)
        guard base.width > 0 else { return nil }
        let scale = (width * 2) / base.width
        return page.thumbnail(
            of: NSSize(width: base.width * scale, height: base.height * scale),
            for: .mediaBox
        )
    }
}

/// The registry's inline SVG — a document with a folded top-right corner
/// (Lucide `file`), 24-unit viewBox, 1.5-unit round stroke. Drawn as a path
/// so the glyph matches the source instead of borrowing `doc`'s unfurled
/// SF Symbol.
private struct FluidFileGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2
        let oy = rect.minY + (rect.height - 24 * s) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        // M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z —
        // the outline: rounded rect with the top-right corner cut by the
        // fold (the closeSubpath draws the diagonal back to 14,3).
        var p = Path()
        p.move(to: pt(14, 3))
        p.addLine(to: pt(7, 3))
        p.addArc(center: pt(7, 5), radius: 2 * s,
                 startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: pt(5, 19))
        p.addArc(center: pt(7, 19), radius: 2 * s,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: pt(17, 21))
        p.addArc(center: pt(17, 19), radius: 2 * s,
                 startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: pt(19, 8))
        p.closeSubpath()
        // M14 3v5h5 — the folded corner.
        p.move(to: pt(14, 3))
        p.addLine(to: pt(14, 8))
        p.addLine(to: pt(19, 8))
        return p
    }
}

/// The border-t spin: mostly `border` with one accented quadrant, rotating
/// at animate-spin (1s linear infinite).
struct FluidRingSpinner: View {
    var diameter: CGFloat = 24
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(FluidTone.border, lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(FluidTone.mutedForeground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !reduceMotion, !FluidPerf.quiet else { return }
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

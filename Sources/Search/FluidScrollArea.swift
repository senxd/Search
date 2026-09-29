import AppKit
import SwiftUI

// ScrollArea — fluid-demo/components/ui/scroll-area.tsx.
// Native overflow scrolling with a custom overlay scrollbar: a 10pt
// edge track hit-target, a 4pt thumb (shape.bg radius) resting 2pt off
// the edge that widens to 6pt on hover, tinted from the overlay ramp
// (8% → 12% hover → 16% pressed). The bar fades in on hover or scroll
// (160ms), lingers 600ms after the last scroll, and fades out on exit
// (120ms after a 160ms delay so the thumb visibly narrows first).
// `orientation` ports the source prop: "vertical" (default),
// "horizontal", or "both" — the touch-primary branch is N/A on macOS.

/// Which axes get scrollbars — scroll-area.tsx's `orientation`.
enum FluidScrollAxis {
    case vertical, horizontal, both
}

/// `FluidScrollArea { content }` — a ScrollView drop-in.
struct FluidScrollArea<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content
    /// scroll-fade's `--scroll-fade-size` (48px default).
    var fadeSize: CGFloat = 48
    /// scroll-divider's hairlines at scrolled-away edges.
    var dividers = false
    /// scroll-divider's `--scroll-divider-inset` — horizontal inset for the
    /// edge hairlines (the inset sidebar variant pins it to the rows'
    /// 8px gutter, sidebar-core.tsx:678).
    var dividerInset: CGFloat = 0
    /// The source's `orientation` — which axes get scrollbars.
    var orientation: FluidScrollAxis = .vertical

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FluidScrollView {
        let scroll = FluidScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        scroll.fadeSize = fadeSize
        scroll.dividerInset = dividerInset

        let host = NSHostingView(rootView: content())
        scroll.documentView = host
        context.coordinator.attach(
            scroll: scroll, host: host, dividers: dividers, orientation: orientation
        )
        return scroll
    }

    func updateNSView(_ scroll: FluidScrollView, context: Context) {
        context.coordinator.host?.rootView = content()
        scroll.fadeSize = fadeSize
        scroll.dividerInset = dividerInset
        context.coordinator.orientation = orientation
        context.coordinator.syncThumbs()
        context.coordinator.sizeDocument()
        context.coordinator.updateThumbs()
        context.coordinator.updateFades()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scroll: FluidScrollView?
        var host: NSHostingView<Content>?
        var orientation: FluidScrollAxis = .vertical
        private var thumbV: FluidScrollThumb?
        private var thumbH: FluidScrollThumb?
        private var observers: [NSObjectProtocol] = []
        private var linger: Task<Void, Never>?
        private var hovering = false { didSet { applyVisibility() } }
        private var trackHover = false { didSet { applyVisibility() } }
        private var scrolling = false { didSet { applyVisibility() } }
        private var dividerTop: CALayer?
        private var dividerBottom: CALayer?
        /// One gradient layer for the life of the scroll view — recreating
        /// and reattaching a mask every scroll tick shows up in samples.
        private var fadeMask: CAGradientLayer?

        private var showsV: Bool { orientation != .horizontal }
        private var showsH: Bool { orientation != .vertical }

        func attach(scroll: FluidScrollView, host: NSHostingView<Content>,
                    dividers: Bool, orientation: FluidScrollAxis) {
            self.scroll = scroll
            self.host = host
            self.orientation = orientation

            if showsV {
                let thumb = FluidScrollThumb(axis: .vertical)
                scroll.addSubview(thumb)
                thumbV = thumb
                wire(thumb)
            }
            if showsH {
                let thumb = FluidScrollThumb(axis: .horizontal)
                scroll.addSubview(thumb)
                thumbH = thumb
                wire(thumb)
            }
            scroll.hoverChanged = { [weak self] inside in
                self?.hovering = inside
            }
            if dividers {
                let top = CALayer(), bottom = CALayer()
                for layer in [top, bottom] {
                    layer.backgroundColor = NSColor(FluidTone.border).cgColor
                    layer.opacity = 0
                    layer.zPosition = 1
                    scroll.contentView.superview?.layer?.addSublayer(layer)
                }
                dividerTop = top; dividerBottom = bottom
            }

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.didScroll() }
            })
            observers.append(nc.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scroll, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sizeDocument(); self?.updateThumbs(); self?.updateFades()
                }
            })
            sizeDocument()
            updateThumbs()
            updateFades()
        }

        /// Keeps the mounted thumbs in step with `orientation` (a live
        /// change through updateNSView adds or drops a bar).
        func syncThumbs() {
            guard let scroll else { return }
            if showsV, thumbV == nil {
                let thumb = FluidScrollThumb(axis: .vertical)
                scroll.addSubview(thumb)
                thumbV = thumb
                wire(thumb)
            } else if !showsV, let t = thumbV {
                t.removeFromSuperview()
                thumbV = nil
            }
            if showsH, thumbH == nil {
                let thumb = FluidScrollThumb(axis: .horizontal)
                scroll.addSubview(thumb)
                thumbH = thumb
                wire(thumb)
            } else if !showsH, let t = thumbH {
                t.removeFromSuperview()
                thumbH = nil
            }
        }

        private func wire(_ thumb: FluidScrollThumb) {
            thumb.onDrag = { [weak self] f, axis in self?.scrollTo(f, axis: axis) }
            thumb.onHover = { [weak self] inside in
                self?.trackHover = inside
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        /// The document sizes to its content on each scrolling axis and
        /// stays pinned to the clip on the rest — Radix's `size-full`
        /// viewport. Vertical keeps the clip width; horizontal the clip
        /// height; both releases both.
        func sizeDocument() {
            guard let scroll, let host else { return }
            let clip = scroll.contentView.bounds
            let fit = host.fittingSize
            let w = showsH ? max(fit.width, clip.width) : clip.width
            let h = showsV ? max(fit.height, clip.height) : clip.height
            if host.frame.size != NSSize(width: w, height: h) {
                host.frame = NSRect(x: 0, y: 0, width: w, height: h)
            }
        }

        func updateThumbs() {
            guard let scroll, let doc = scroll.documentView else { return }
            let corner = orientation == .both
            thumbV?.update(scroll: scroll, doc: doc, corner: corner)
            thumbH?.update(scroll: scroll, doc: doc, corner: corner)
        }

        private func applyVisibility() {
            let v = hovering || scrolling || trackHover
            thumbV?.setVisible(v)
            thumbH?.setVisible(v)
        }

        private func didScroll() {
            updateThumbs()
            updateFades()
            scrolling = true
            linger?.cancel()
            linger = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                self?.scrolling = false
            }
        }

        /// The scroll-fade mask + scroll-divider hairlines — progressive
        /// like the CSS scroll-timeline variant: at an edge, that edge's
        /// fade is fully opaque (no fade); it opens up over the first
        /// `fadeSize` points of travel. Symmetric at the far edge. The mask
        /// runs along the scroll axis (`.scroll-fade` down, `.scroll-fade-x`
        /// across); `.both` fades vertically, matching `.scroll-fade`.
        func updateFades() {
            guard let scroll, let doc = scroll.documentView else { return }
            let clip = scroll.contentView
            let size = scroll.fadeSize

            let offY = clip.bounds.origin.y
            let travelY = doc.bounds.height - clip.bounds.height
            let offX = clip.bounds.origin.x
            let travelX = doc.bounds.width - clip.bounds.width

            let mask: CAGradientLayer
            if let existing = fadeMask {
                mask = existing
            } else {
                mask = CAGradientLayer()
                fadeMask = mask
            }
            mask.frame = clip.bounds

            if orientation == .horizontal {
                let clipW = clip.bounds.width
                guard clipW > 0 else { return }
                let overflowing = travelX > 0
                let leadK = overflowing ? min(1, max(0, offX) / size) : 0
                let tailK = overflowing ? min(1, max(0, travelX - offX) / size) : 0
                let leadA = 1 - leadK, tailA = 1 - tailK
                let p1 = min(size / clipW, 0.5), p2 = max(1 - size / clipW, 0.5)
                mask.startPoint = CGPoint(x: 0, y: 0.5)
                mask.endPoint = CGPoint(x: 1, y: 0.5)
                mask.colors = [
                    NSColor.black.withAlphaComponent(leadA).cgColor,
                    NSColor.black.cgColor,
                    NSColor.black.cgColor,
                    NSColor.black.withAlphaComponent(tailA).cgColor,
                ]
                mask.locations = [0, p1 as NSNumber, p2 as NSNumber, 1]
            } else {
                let clipH = clip.bounds.height
                guard clipH > 0 else { return }
                let overflowing = travelY > 0
                let topK = overflowing ? min(1, max(0, offY) / size) : 0
                let botK = overflowing ? min(1, max(0, travelY - offY) / size) : 0
                let topA = 1 - topK, botA = 1 - botK
                let p1 = min(size / clipH, 0.5), p2 = max(1 - size / clipH, 0.5)
                mask.startPoint = CGPoint(x: 0.5, y: 0)
                mask.endPoint = CGPoint(x: 0.5, y: 1)
                mask.colors = [
                    NSColor.black.withAlphaComponent(topA).cgColor,
                    NSColor.black.cgColor,
                    NSColor.black.cgColor,
                    NSColor.black.withAlphaComponent(botA).cgColor,
                ]
                mask.locations = [0, p1 as NSNumber, p2 as NSNumber, 1]
            }
            clip.wantsLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if clip.layer?.mask !== mask { clip.layer?.mask = mask }
            if let top = dividerTop, let bottom = dividerBottom {
                let overflowing = travelY > 0
                let w = scroll.bounds.width, inset = scroll.dividerInset
                top.frame = CGRect(x: inset, y: 0, width: w - inset * 2, height: 1)
                bottom.frame = CGRect(x: inset, y: scroll.bounds.height - 1, width: w - inset * 2, height: 1)
                top.opacity = overflowing && offY > 0 ? 1 : 0
                bottom.opacity = overflowing && travelY - offY > 0 ? 1 : 0
            }
            CATransaction.commit()
        }

        private func scrollTo(_ fraction: Double, axis: Axis) {
            guard let scroll, let doc = scroll.documentView else { return }
            let clip = scroll.contentView.bounds
            var p = clip.origin
            if axis == .vertical {
                let travel = doc.bounds.height - clip.height
                guard travel > 0 else { return }
                p.y = fraction * travel
            } else {
                let travel = doc.bounds.width - clip.width
                guard travel > 0 else { return }
                p.x = fraction * travel
            }
            scroll.contentView.scroll(to: p)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

// MARK: - Scroll view

/// The NSScrollView underneath — owns the area-hover tracking so the bar
/// reveals when the pointer enters anywhere in the region.
final class FluidScrollView: NSScrollView {
    var hoverChanged: ((Bool) -> Void)?
    /// scroll-fade size — the mask ramps over this much travel at each edge.
    var fadeSize: CGFloat = 48
    /// --scroll-divider-inset — horizontal inset on the edge hairlines.
    var dividerInset: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea(_:))
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

// MARK: - Thumb

/// The overlay scrollbar: a 10pt edge strip owning a draggable 4pt thumb.
/// `axis` picks the edge — vertical rides the right edge, horizontal the
/// bottom (the source's `flex-col` flip).
final class FluidScrollThumb: NSView {
    let axis: Axis
    /// (fraction, axis) — the coordinator scrolls the matching dimension.
    var onDrag: ((Double, Axis) -> Void)?
    var onHover: ((Bool) -> Void)?

    private let thumb = CALayer()
    private var hovered = false
    private var dragging = false
    private var shown = false
    private var thumbLength: CGFloat = 0
    private var thumbTravel: CGFloat = 0
    private var thumbPos: CGFloat = 0
    private var hideTask: Task<Void, Never>?

    /// Track width — a comfortable 10pt hit target (the React w-2.5).
    private let trackW: CGFloat = 10
    /// 4pt resting, 6pt under hover or while dragging.
    private var thumbW: CGFloat { (hovered || dragging) ? 6 : 4 }

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(thumb)
        alphaValue = 0
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea(_:))
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    func setVisible(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        hideTask?.cancel()
        if visible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16; ctx.timingFunction = .init(name: .easeOut)
                self.animator().alphaValue = 1
            }
        } else {
            // Wait out the thumb's 150ms shrink before fading, so the thumb
            // visibly narrows back first instead of the fade masking it.
            hovered = false
            layoutThumb()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 160_000_000)
                guard !Task.isCancelled else { return }
                await NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12; ctx.timingFunction = .init(name: .easeOut)
                    self?.animator().alphaValue = 0
                }
            }
        }
    }

    /// Flush against the edge; `corner` shortens the track 10pt so a
    /// perpendicular bar gets the junction (Radix's Corner). 4pt caps each
    /// end — my-1 for vertical, mx-1 for horizontal.
    func update(scroll: NSScrollView, doc: NSView, corner: Bool) {
        let clip = scroll.contentView.bounds
        let cap: CGFloat = 4
        if axis == .vertical {
            frame = NSRect(
                x: scroll.bounds.width - trackW, y: 0,
                width: trackW,
                height: scroll.bounds.height - (corner ? trackW : 0)
            )
            let trackLength = bounds.height - cap * 2
            let clipH = clip.height, docH = doc.bounds.height
            guard docH > 0, docH > clipH else {
                thumb.isHidden = true
                return
            }
            thumb.isHidden = false
            thumbLength = max(24, clipH / docH * trackLength)
            thumbTravel = trackLength - thumbLength
            let travel = docH - clipH
            thumbPos = travel > 0 ? clip.origin.y / travel * thumbTravel : 0
        } else {
            frame = NSRect(
                x: 0, y: 0,
                width: scroll.bounds.width - (corner ? trackW : 0),
                height: trackW
            )
            let trackLength = bounds.width - cap * 2
            let clipW = clip.width, docW = doc.bounds.width
            guard docW > 0, docW > clipW else {
                thumb.isHidden = true
                return
            }
            thumb.isHidden = false
            thumbLength = max(24, clipW / docW * trackLength)
            thumbTravel = trackLength - thumbLength
            let travel = docW - clipW
            thumbPos = travel > 0 ? clip.origin.x / travel * thumbTravel : 0
        }
        layoutThumb()
    }

    private func layoutThumb() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 2pt off the container edge — the -translate nudge.
        if axis == .vertical {
            thumb.frame = CGRect(
                x: trackW - thumbW - 2, y: 4 + thumbPos,
                width: thumbW, height: thumbLength
            )
        } else {
            thumb.frame = CGRect(
                x: 4 + thumbPos, y: trackW - thumbW - 2,
                width: thumbLength, height: thumbW
            )
        }
        thumb.cornerRadius = thumbW / 2
        thumb.backgroundColor = thumbColor.cgColor
        CATransaction.commit()
    }

    /// Fixed overlay ramp: 8% → 12% hover → 16% while dragging.
    private var thumbColor: NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let k: CGFloat = dragging ? 0.16 : hovered ? 0.12 : 0.08
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(k)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true; layoutThumb(); onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; layoutThumb(); onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        layoutThumb()
        let start = convert(event.locationInWindow, from: nil)
        let startPos = thumbPos
        // Modal drag — the thumb follows the pointer 1:1 along its travel.
        while true {
            guard let ev = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if ev.type == .leftMouseUp { break }
            let p = convert(ev.locationInWindow, from: nil)
            let delta = axis == .vertical ? p.y - start.y : p.x - start.x
            thumbPos = min(thumbTravel, max(0, startPos + delta))
            layoutThumb()
            onDrag?(Double(thumbPos / max(1, thumbTravel)), axis)
        }
        dragging = false
        layoutThumb()
    }
}

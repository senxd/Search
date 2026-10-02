import AppKit
import SwiftUI

enum FluidTone { static let border = Color.gray }

@main
struct ScrollCheck {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let scroll = FluidScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        scroll.hasVerticalScroller = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.fadeSize = 48
        let host = NSHostingView(rootView: Color.clear.frame(width: 240, height: 10000))
        scroll.documentView = host
        // The concrete hosting type avoids a second UI just for this test.
        let area = FluidScrollArea(content: { Color.clear.frame(width: 240, height: 10000) })
        let keeper = area.makeCoordinator()
        keeper.attach(scroll: scroll, host: host, dividers: true, orientation: .vertical)
        precondition(host.frame.height >= 10000)
        let start = Date()
        for i in 0..<2000 {
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: i % 9000))
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(10))
        fputs(String(format: "2000 scroll updates: %.2f ms\n", Date().timeIntervalSince(start) * 1000), stderr)
        precondition(scroll.contentView.layer?.mask != nil)
        precondition(scroll.subviews.contains { $0 is FluidScrollThumb })
        scroll.fadeSize = 0
        keeper.updateFades()
        precondition(scroll.contentView.layer?.mask == nil)
        print("Native scrolling, scrollbar and fade checks passed")
    }
}

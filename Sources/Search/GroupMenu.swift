import AppKit
import SwiftUI

// The menu a group's header or chip answers a right-click with, and the view
// that catches the click for it. SwiftUI's contextMenu can't hold the colour
// dots and the icon grid this menu shows, so — like SpaceMenu — it is a real
// NSMenu popped where the pointer is.

/// A right-click over a group's header or chip opens the menu. Asks for the
/// right button and nothing else, the way MiddleClick asks for the middle
/// one: a left click, a drag, or a release elsewhere isn't answered here.
struct GroupMenuCatch: NSViewRepresentable {
    let browser: Browser
    let group: TabGroup

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.browser = browser
        (view as? Catch)?.group = group
    }

    private final class Catch: NSView {
        var browser: Browser?
        var group: TabGroup?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown
            else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let browser, let group else { return }
            GroupMenu.show(for: browser, group: group)
        }
    }
}

/// The group's name, typed into its header or chip itself — a field of its
/// own rather than SwiftUI's, for the same reason as the address in a tab:
/// the system paints selected text as a solid block of accent colour, which
/// over a tinted chip this size is the loudest thing in the row.
struct GroupNameField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    let group: TabGroup

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, group: group) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = group.name ?? ""
        context.coordinator.watch(field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.group = group
        if !coordinator.editing, field.stringValue != group.name ?? "" {
            field.stringValue = group.name ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var group: TabGroup
        var claimed = false
        /// True while the field editor is attached — a publish from anywhere
        /// else in the browser mustn't overwrite what is being typed.
        var editing = false

        init(browser: Browser, group: TabGroup) {
            self.browser = browser
            self.group = group
        }

        func controlTextDidBeginEditing(_ note: Notification) { editing = true }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                guard let field = control as? NSTextField else { return true }
                browser.renameGroup(group.id, to: field.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.endGroupRename()
                return true
            default:
                return false
            }
        }

        /// Keeping what was typed — Return, focus lost, a click elsewhere —
        /// is one answer, and it lands only while this group's field is
        /// still up. Escape lowers `renamingGroup` before the field comes
        /// down, so the end-editing the removal raises commits nothing:
        /// without the guard a discarded name would be applied after all.
        private func commit(_ text: String) {
            let browser = browser
            let id = group.id
            DispatchQueue.main.async {
                guard browser.renamingGroup == id else { return }
                browser.renameGroup(id, to: text)
            }
        }

        /// Focus moving on keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            editing = false
            guard let field = note.object as? NSTextField else { return }
            commit(field.stringValue)
        }

        /// A press on something that takes no focus — another tab, the
        /// strip's empty stretch — would leave the field editing while the
        /// row has moved on, so presses are watched for while it is there:
        /// one anywhere but in the field ends the edit the way focus lost
        /// does. The press itself goes on to what it was for.
        private var watcher: Any?

        func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                self.commit(field.stringValue)
                return event
            }
        }

        func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

@MainActor
enum GroupMenu {
    /// Menu items call back into Swift through this.
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    /// The menu most recently built. A right-click pops it and lets it go;
    /// a bench probe can send the click but has no hand to take a menu down
    /// with, so a test run is answered from here with what it would have
    /// shown instead.
    private(set) static var shown: NSMenu?

    private static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        // `target` is weak, so the item holds its own action on as its
        // represented object — kept for exactly the item's life, where a
        // list beside the menu would either dead-target one still open or
        // outlive every one that had closed.
        item.representedObject = action
        return item
    }

    /// An item that is all view — the row of dots, the icon grid. Enabled by
    /// hand: with the menu's autoenabling off (see `make`) an item with no
    /// action of its own would grey out, view and all, and take no clicks.
    private static func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        item.isEnabled = true
        return item
    }

    /// What the menu's two hand-made views share: which cell a point falls
    /// in is the subclass's to say, as is what a click on it does — the
    /// hovering, the tracking area and the letting the menu go are one way
    /// for both. A menu item's own highlight is the whole row, which is the
    /// wrong shape for eight dots or forty-nine symbols.
    private class Cells: NSView {
        /// The cell the pointer is over — the subclasses only draw it.
        var over: Int? { didSet { needsDisplay = true } }
        private var tracking: NSTrackingArea?

        /// Which cell a point in the view's own coordinates falls in, if any.
        func index(at point: NSPoint) -> Int? { nil }

        /// What a click on a cell does.
        func pick(_ index: Int) {}

        /// What a cell is called, for the tooltip under the pointer.
        func name(at index: Int) -> String? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            // activeAlways because a menu's window answers the pointer
            // without ever being key, and its views want the same.
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
            // One tooltip rect covers the whole view and `name(at:)` answers
            // for the point inside it — re-added here, where a change of
            // bounds lands, rather than once at a guessed width.
            removeAllToolTips()
            addToolTip(bounds, owner: self, userData: nil)
        }

        /// The tooltip owner answers for the point under the pointer — an
        /// informal-protocol method on any NSObject, not an override.
        func view(
            _ view: NSView,
            stringForToolTip tag: NSView.ToolTipTag,
            point: NSPoint,
            userData data: UnsafeMutableRawPointer?
        ) -> String {
            guard let index = index(at: point) else { return "" }
            return name(at: index) ?? ""
        }

        override func mouseMoved(with event: NSEvent) {
            over = index(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            over = index(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) { over = nil }

        /// The release answers, as on any menu item — a press slid onto a
        /// cell and let go there is a pick wherever it started. Choosing
        /// ends the whole menu, root and all, not just the submenu a grid
        /// may be sitting in.
        override func mouseUp(with event: NSEvent) {
            guard let at = index(at: convert(event.locationInWindow, from: nil)) else { return }
            pick(at)
            var menu = enclosingMenuItem?.menu
            while let up = menu?.supermenu { menu = up }
            menu?.cancelTracking()
        }
    }

    /// The palette as a row of swatches, the dots spread evenly across the
    /// row's width — an item's width is the menu's, which nobody knows until
    /// every item is measured, so the spacing is worked out from the bounds
    /// each time rather than fixed ahead of it.
    private final class DotRow: Cells {
        private let colours = Groups.colours.map { NSColor($0) }
        private let current: Int
        private let run: (Int) -> Void

        private let margin: CGFloat = 15
        private let dot: CGFloat = 12

        init(current: Int, run: @escaping (Int) -> Void) {
            // `tint` reads a colour the palette doesn't hold as grey, so the
            // ring marks the grey dot the chip is wearing rather than nothing.
            self.current = colours.indices.contains(current) ? current : 0
            self.run = run
            super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 26))
            autoresizingMask = [.width]
        }

        required init?(coder: NSCoder) { nil }

        /// A dot's stretch of the row — the whole height, so near misses
        /// still count; the dot drawn in it is much smaller.
        private func slot(_ index: Int) -> NSRect {
            let width = (bounds.width - 2 * margin) / CGFloat(colours.count)
            return NSRect(x: margin + width * CGFloat(index), y: 0, width: width, height: bounds.height)
        }

        override func index(at point: NSPoint) -> Int? {
            colours.indices.first { slot($0).contains(point) }
        }

        override func pick(_ index: Int) { run(index) }

        override func name(at index: Int) -> String? {
            Groups.colourNames.indices.contains(index) ? Groups.colourNames[index] : nil
        }

        override func draw(_: NSRect) {
            for index in colours.indices {
                let rect = NSRect(
                    x: slot(index).midX - dot / 2, y: bounds.midY - dot / 2,
                    width: dot, height: dot
                )
                colours[index].setFill()
                NSBezierPath(ovalIn: rect).fill()
                // What the group wears keeps a ring of ink, the pointer's dot
                // a fainter one — the same circle, so hovering moves nothing.
                guard index == current || index == over else { continue }
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 1.5
                (index == current ? Palette.NS.ink : Palette.NS.ink.withAlphaComponent(0.35)).setStroke()
                ring.stroke()
            }
        }
    }

    /// Every symbol a group can wear, as a grid under "Change Icon" — a flat
    /// submenu would run longer than the window is tall, and a grid is the
    /// quicker read beside the dots anyway. Seven columns is the square the
    /// count happens to want; nothing here depends on the count staying so.
    private final class IconGrid: Cells {
        private static let columns = 7
        private let cell: CGFloat = 28
        private let inset: CGFloat = 8
        private let current: String
        private let run: (String) -> Void
        /// The symbols drawn once each and kept — fifty draws of the same
        /// configuration every repaint would be work done for nothing.
        private let images: [NSImage?]

        init(current: String, run: @escaping (String) -> Void) {
            self.current = current
            self.run = run
            let style = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
                .applying(.init(paletteColors: [Palette.NS.ink]))
            images = Groups.icons.map {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(style)
            }
            let rows = (Groups.icons.count + IconGrid.columns - 1) / IconGrid.columns
            super.init(frame: NSRect(
                x: 0, y: 0,
                width: 2 * inset + cell * CGFloat(IconGrid.columns),
                height: 2 * inset + cell * CGFloat(rows)
            ))
        }

        required init?(coder: NSCoder) { nil }

        /// Cells read the way the list does: left to right, top to bottom.
        override var isFlipped: Bool { true }

        /// Where the first cell starts — inset, plus half of whatever width
        /// a wider menu hands the view, so the grid sits centred in it.
        private var x0: CGFloat {
            inset + max(0, (bounds.width - 2 * inset - cell * CGFloat(IconGrid.columns)) / 2)
        }

        private func cellRect(_ index: Int) -> NSRect {
            NSRect(
                x: x0 + cell * CGFloat(index % IconGrid.columns),
                y: inset + cell * CGFloat(index / IconGrid.columns),
                width: cell, height: cell
            )
        }

        override func index(at point: NSPoint) -> Int? {
            Groups.icons.indices.first { cellRect($0).contains(point) }
        }

        override func pick(_ index: Int) { run(Groups.icons[index]) }

        override func name(at index: Int) -> String? {
            Groups.iconNames.indices.contains(index) ? Groups.iconNames[index] : Groups.icons[index]
        }

        override func draw(_: NSRect) {
            for index in Groups.icons.indices {
                let rect = cellRect(index)
                if index == over || Groups.icons[index] == current {
                    // The pointer's cell sits a touch heavier than the mark
                    // the group's own icon keeps — intent outranks state.
                    Palette.NS.ink.withAlphaComponent(index == over ? 0.16 : 0.09).setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7).fill()
                }
                if let image = images[index] {
                    let size = image.size
                    image.draw(in: NSRect(
                        x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                        width: size.width, height: size.height
                    ))
                }
            }
        }
    }

    /// The menu, built. The identity of the group first — its name kept
    /// grey, then the dots — then what can be done to it, ending in the
    /// three that take it apart.
    @discardableResult
    static func make(for browser: Browser, group: TabGroup) -> NSMenu {
        let menu = NSMenu()
        // Enablement set by hand: autoenabling would grey the view items for
        // having no action, and argue with the title's being off on purpose.
        menu.autoenablesItems = false

        let title = item(browser.groupTitle(group)) {}
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(viewItem(DotRow(current: group.colour) { browser.colourGroup(group.id, with: $0) }))
        menu.addItem(.separator())

        let icons = NSMenuItem(title: "Change Icon", action: nil, keyEquivalent: "")
        let grid = NSMenu()
        grid.autoenablesItems = false
        grid.addItem(viewItem(IconGrid(current: group.symbol) { browser.iconGroup(group.id, to: $0) }))
        icons.submenu = grid
        menu.addItem(icons)

        menu.addItem(item("Rename Tab Group") { browser.beginGroupRename(group.id) })
        menu.addItem(item("New Tab in Group") { browser.newTabInGroup(group.id) })
        // There is no group-into-an-existing-space to offer: a group becomes
        // a space whole, or stays where it is.
        menu.addItem(item("Move Group to New Space") { browser.moveGroupToNewSpace(group.id) })
        menu.addItem(.separator())
        menu.addItem(item("Ungroup") { browser.ungroup(group.id) })
        menu.addItem(item("Convert Group to Bookmark…") {
            Ask.name("Bookmark Group", placeholder: browser.groupTitle(group), initial: browser.groupTitle(group), confirm: "Save") { name in
                browser.bookmarkGroup(group.id, named: name)
            }
        })
        menu.addItem(item("Delete Group") { browser.closeGroup(group.id) })
        return menu
    }

    static func show(for browser: Browser, group: TabGroup) {
        shown = make(for: browser, group: group)
        // A bench-driven right-click can't take a popped menu down again,
        // and it would open beside the real pointer rather than the chip —
        // so a test run builds it, remembers it, and leaves it unpopped.
        guard !Store.testing else { return }
        shown?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

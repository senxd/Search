import SwiftUI

/// The tabs, down the left instead of across the top.
///
/// The same pieces as the strip — the grey that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The traffic lights keep their corner; the column starts under
/// them and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @Namespace private var pill

    @State private var dragging: Tab.ID?
    /// The edge the picked-up row left — kept, not an index, so the hand
    /// stays glued to it however the rows beneath change places.
    @State private var anchor: CGFloat = 0
    @State private var travel: CGFloat = 0
    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false

    /// A pin, picked up out of the grid — a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var before
    @Namespace private var after

    @State private var pinDragging: Tab.ID?
    @State private var pinFrom = 0
    @State private var pinTravel: CGSize = .zero

    /// A whole group carried by its header — the same drag as a row's,
    /// landed with `moveGroup` so the members follow it.
    @State private var groupDragging: TabGroup.ID?
    @State private var groupAnchor: CGFloat = 0
    @State private var groupTravel: CGFloat = 0
    /// The header under the pointer — one for the column, as the edge's is.
    @State private var overHead: TabGroup.ID?

    private static let row: CGFloat = 28
    private static let gap: CGFloat = 2
    private static let square: CGFloat = 34
    private static let pinGap: CGFloat = 4
    /// The air a group block keeps around its rows, so two blocks never
    /// touch and a block never sits flush against a plain row.
    private static let blockPad: CGFloat = 4

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd)

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            HStack(spacing: 0) {
                DragStrip()
                    .frame(width: 10 + Metrics.sideLights)
                Color.clear
                    .frame(width: Metrics.helm)
                    .allowsHitTesting(false)
                DragStrip()
            }
            .frame(height: Metrics.strip)

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                HStack(spacing: 0) {
                    Color.clear.frame(width: Metrics.sideLights)
                    Helm(browser: browser)
                    Spacer(minLength: 0)
                }
                .frame(height: Metrics.strip)

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the column's bottom edge.
            .padding(.bottom, SideBar.footHeight)

            VStack {
                Spacer()
                foot
            }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background(landing ? Palette.hover : Palette.ground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .overlay(alignment: .trailing) { edge }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The hairline darkens under the pointer
    /// so the edge says it can be taken before it is.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        let wanted = (grabbed ?? prefs.sideWidth) + value.translation.width
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var pages: some View {
        let width = prefs.sideWidth
        let swipe = browser.spaceSwipe
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at, pill: pill)
                .offset(x: swipe)
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1, pill: before)
                    .offset(x: swipe - width)
            }
            if swipe < 0, at < browser.spaces.count {
                page(at + 1, pill: after)
                    .offset(x: swipe + width)
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int, pill: Namespace.ID) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == browser.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    if browser.pinnedCount > 0 {
                        pinned
                            .padding(.bottom, 10)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits it stays a
                    // plain stack, and the space under it is still the
                    // window's to be dragged by. Inside the page: the swipe
                    // between spaces moves the page, scroll and all.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) { rows }
                                // The tab you go to is the tab you see — ⌘1–⌘9,
                                // ⇧⌘], a link opening beside the one on screen.
                                // Rows are named by their item, so a tab in a
                                // folded group reveals the header standing for
                                // it rather than a row it doesn't have.
                                .onChange(of: browser.activeID) { _, id in
                                    guard let tab = browser.tabs.first(where: { $0.id == id }) else { return }
                                    withAnimation(Motion.glide) {
                                        proxy.scrollTo(browser.visibleID(for: tab))
                                    }
                                }
                                .onAppear {
                                    if let tab = browser.active {
                                        proxy.scrollTo(browser.visibleID(for: tab), anchor: .center)
                                    }
                                }
                        }
                    }
                }
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil), pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: prefs.sideWidth, alignment: .topLeading)
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen. Groups parked with it keep their blocks: a
    /// folded run goes by as its header, an open one as the whole card.
    private func preview(_ row: Parked, pill: Namespace.ID) -> some View {
        let pins = row.tabs.filter { $0.pin != nil }
        let cols = SideBar.pinColumns(pins.count)
        let width = pinWidth(for: pins.count)
        let height = min(SideBar.square, width)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    PinGrid(columns: cols, width: width, height: height, spacing: SideBar.pinGap) {
                        ForEach(pins) { tab in
                            PinSquare(browser: browser, tab: tab, live: tab.id == row.active,
                                      pill: pill, width: width, height: height)
                        }
                    }
                }
                // The same shared card the live column's pins sit on — a
                // space going by keeps its pieces exactly as it left them.
                .padding(SideBar.blockPad)
                .background { pinCard }
                .padding(.horizontal, -SideBar.blockPad)
                .padding(.bottom, 10)
            }
            VStack(spacing: SideBar.gap) {
                ForEach(Self.pieces(from: Self.items(in: row))) { piece in
                    switch piece {
                    case .row(let tab):
                        SideRow(browser: browser, prefs: prefs, tab: tab,
                                live: tab.id == row.active, pill: pill, close: {})
                    case .block(let group, let members):
                        VStack(spacing: SideBar.gap) {
                            head(group, title: Self.title(of: group, in: row),
                                 count: row.tabs.reduce(0) { $0 + ($1.groupID == group.id ? 1 : 0) },
                                 interactive: false)
                            ForEach(members) { tab in
                                SideRow(browser: browser, prefs: prefs, tab: tab,
                                        live: tab.id == row.active, pill: pill, tint: group.tint, close: {})
                            }
                        }
                        .background { card(group.tint) }
                        .padding(.vertical, SideBar.blockPad)
                    }
                }
            }
            newTab
        }
        .allowsHitTesting(false)
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        let pins = browser.pinnedCount
        let cols = SideBar.pinColumns(pins)
        let pinRows = pins == 0 ? 0 : (pins + cols - 1) / cols
        // The pin block is its rows of cells plus the air the shared card
        // keeps above and below them, then the gap under the block itself.
        let pinBlock = pinRows == 0 ? 0
            : CGFloat(pinRows) * pinHeight + CGFloat(pinRows - 1) * SideBar.pinGap
                + 2 * SideBar.blockPad + 10
        // The loose column as it is actually drawn: a block is its rows plus
        // the air it keeps around them, a tab on its own is a row — and a
        // folded group's members draw nothing at all.
        var loose: CGFloat = 0
        var first = true
        for piece in pieces {
            if !first { loose += SideBar.gap }
            first = false
            switch piece {
            case .row:
                loose += SideBar.row
            case .block(_, let members):
                loose += CGFloat(members.count + 1) * SideBar.row
                    + CGFloat(members.count) * SideBar.gap
                    + 2 * SideBar.blockPad
            }
        }
        return Metrics.strip + pinBlock + loose + SideBar.gap + SideBar.row + 8
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.tabs.filter { $0.pin != nil } }

    /// Three columns is the block's own shape — up to six pins, that's two
    /// full rows, and one or two is just those same three places with a
    /// couple of them empty rather than a lonely row of its own width. Only
    /// past six does the block widen, one column at a time, to stay at two
    /// rows for as long as that's a reasonable shape at all.
    private static func pinColumns(_ count: Int) -> Int {
        max(3, (count + 1) / 2)
    }

    /// However many columns the count calls for, they split the row's own
    /// width between them — the row is what fills edge to edge, not each
    /// cell on its own, so this grows past 34 just as readily as it shrinks
    /// below it.
    private var pinWidth: CGFloat { pinWidth(for: browser.pinnedCount) }

    private func pinWidth(for count: Int) -> CGFloat {
        let cols = SideBar.pinColumns(count)
        guard cols > 0 else { return SideBar.square }
        let available = prefs.sideWidth - 20 - CGFloat(cols - 1) * SideBar.pinGap
        return max(20, available / CGFloat(cols))
    }

    /// The one dimension that doesn't chase the sidebar's width: past three
    /// columns' worth of room a cell would otherwise turn into a big square
    /// rather than the wide, short button pinned tabs actually look like
    /// everywhere else in this app. It only shrinks below 34 alongside the
    /// width, once a narrow column leaves no other choice.
    private var pinHeight: CGFloat {
        min(SideBar.square, pinWidth)
    }

    /// The card the whole pin block sits on. The squares used to draw this
    /// same wash a faint apiece; worn once by the block it reads as one
    /// piece rather than a row of tiles — and stays dimmer than the live
    /// square's full wash, so the picked tab still stands out on it.
    private var pinCard: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.wash.opacity(0.55))
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cols = SideBar.pinColumns(tabs.count)
        let width = pinWidth
        let height = pinHeight
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(columns: cols, width: width, height: height, spacing: SideBar.pinGap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let held = pinDragging == tab.id
                PinSquare(
                    browser: browser,
                    tab: tab,
                    live: tab.id == browser.activeID,
                    pill: pill,
                    width: width,
                    height: height
                )
                .offset(pinOffset(held: held, index: index, columns: cols))
                // Under the hand exactly, as a row is (see the rows below).
                .transaction { if held { $0.animation = nil } }
                .zIndex(held ? 1 : 0)
                .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
                .gesture(pinReorder(tab: tab, index: index, columns: cols, width: width, height: height))
            }
        } }
        // One shared card under the grid, its air kept as padding so every
        // cell sits inside it — reaching a touch wider than the cells the
        // way a group's card reaches past its rows, which leaves the cells
        // their size and their pitch, and everything the reorder measures
        // exactly where it was. The block just grows a sliver top and
        // bottom, which `rowsEnd` counts.
        .padding(SideBar.blockPad)
        .background { pinCard }
        .padding(.horizontal, -SideBar.blockPad)
        .coordinateSpace(name: "pins")
    }

    /// The one square actually held stays glued to the fingers; every other
    /// square is already exactly where it belongs, because `browser.move`
    /// put it there — this only cancels out the bit of that same movement
    /// the held square already got for free by changing index underneath
    /// its own drag.
    private func pinOffset(held: Bool, index: Int, columns: Int) -> CGSize {
        guard held else { return .zero }
        let stepX = pinWidth + SideBar.pinGap
        let stepY = pinHeight + SideBar.pinGap
        let from = (row: pinFrom / columns, col: pinFrom % columns)
        let now = (row: index / columns, col: index % columns)
        return CGSize(
            width: pinTravel.width - CGFloat(now.col - from.col) * stepX,
            height: pinTravel.height - CGFloat(now.row - from.row) * stepY
        )
    }

    /// How many cells the drag has moved, in the grid's own row-major order
    /// — a straight line through the array a column-major offset would get
    /// wrong the moment it crossed a row. Row and column travel each measure
    /// themselves against that axis's own step now that a cell's width and
    /// height aren't the same number.
    private func pinDelta(columns: Int, stepX: CGFloat, stepY: CGFloat) -> Int {
        let col = Int((pinTravel.width / stepX).rounded())
        let row = Int((pinTravel.height / stepY).rounded())
        return row * columns + col
    }

    private func pinTarget(from: Int, moved: Int) -> Int {
        min(max(0, from + moved), max(0, pinnedTabs.count - 1))
    }

    /// Pick a square up and the others make way — across a row, and down
    /// into the next, exactly as far as the fingers actually moved.
    private func pinReorder(tab: Tab, index: Int, columns: Int, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                }
                pinTravel = value.translation
                let stepX = width + SideBar.pinGap
                let stepY = height + SideBar.pinGap
                let target = pinTarget(from: pinFrom, moved: pinDelta(columns: columns, stepX: stepX, stepY: stepY))
                if target != index {
                    withAnimation(Motion.settle) {
                        browser.move(tab, to: target)
                    }
                }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    pinDragging = nil
                    pinTravel = .zero
                }
            }
    }

    // MARK: - the rows

    /// One thing the loose column draws: a tab standing alone, or a group —
    /// its header and, while it is open, the members it wraps — as a block.
    private enum Piece: Identifiable {
        case row(Tab)
        case block(TabGroup, [Tab])

        var id: String {
            switch self {
            case .row(let tab): return TabItem.tab(tab).id
            case .block(let group, _): return TabItem.group(group).id
            }
        }
    }

    /// `visibleItems` without the pins — they stand in the grid above, and a
    /// pin is never in a group, so a `.group` item can only ever be loose.
    private var looseItems: [TabItem] {
        browser.visibleItems.filter { $0.tab?.pin == nil }
    }

    /// The items folded into draw order: a group's header gathers the
    /// members that follow it into one block; a loose tab is a row alone.
    private static func pieces(from items: [TabItem]) -> [Piece] {
        var out: [Piece] = []
        var at = 0
        while at < items.count {
            switch items[at] {
            case .group(let group):
                var members: [Tab] = []
                var next = at + 1
                while next < items.count,
                      case .tab(let tab) = items[next],
                      tab.groupID == group.id {
                    members.append(tab)
                    next += 1
                }
                out.append(.block(group, members))
                at = next
            case .tab(let tab):
                out.append(.row(tab))
                at += 1
            }
        }
        return out
    }

    private var pieces: [Piece] { Self.pieces(from: looseItems) }

    /// `visibleItems` for a parked row — it keeps its own groups for exactly
    /// this, so a space passing by shows the blocks it left behind.
    private static func items(in row: Parked) -> [TabItem] {
        var out: [TabItem] = []
        var headed: Set<UUID> = []
        for tab in row.tabs where tab.pin == nil {
            guard let id = tab.groupID,
                  let group = row.groups.first(where: { $0.id == id })
            else {
                out.append(.tab(tab))
                continue
            }
            if headed.insert(id).inserted { out.append(.group(group)) }
            if group.expanded { out.append(.tab(tab)) }
        }
        return out
    }

    /// What a parked group is called — `groupTitle` numbers the unnamed by
    /// the row on screen; a parked one is numbered among its own.
    private static func title(of group: TabGroup, in row: Parked) -> String {
        if let name = group.name, !name.isEmpty { return name }
        var order: [UUID] = []
        for tab in row.tabs {
            guard let id = tab.groupID, !order.contains(id) else { continue }
            order.append(id)
        }
        let unnamed = order.filter { id in
            row.groups.first { $0.id == id }?.name?.isEmpty != false
        }
        guard let at = unnamed.firstIndex(of: group.id) else { return "Group" }
        return "Group \(at + 1)"
    }

    private var loose: some View {
        let origins = drawnOrigins
        return VStack(spacing: SideBar.gap) {
            // See the grid: the drag is measured in the column's space, not
            // the row's, so a row that has just moved keeps its bearings.
            ForEach(pieces) { piece in
                switch piece {
                case .row(let tab):
                    row(tab, tint: nil, origins: origins)
                case .block(let group, let members):
                    block(group, members: members, origins: origins)
                }
            }
        }
        .coordinateSpace(name: "rows")
        .animation(Motion.settle, value: browser.groups)
    }

    /// The top edge of every drawn row, in the loose column's own space — a
    /// folded run contributes just its header. Computed rather than measured,
    /// the way `rowsEnd` is, so a drag can ask before layout answers; a
    /// block's padding is why the edges aren't one even stride apart.
    private var drawnOrigins: [CGFloat] {
        var out: [CGFloat] = []
        var y: CGFloat = 0
        for piece in pieces {
            switch piece {
            case .row:
                out.append(y)
                y += SideBar.row + SideBar.gap
            case .block(_, let members):
                y += SideBar.blockPad
                for _ in 0...members.count {
                    out.append(y)
                    y += SideBar.row + SideBar.gap
                }
                y += SideBar.blockPad
            }
        }
        return out
    }

    /// One loose row — standing on the ground, or a member inside a group's
    /// block where `tint` blends its washes into the card under it.
    private func row(_ tab: Tab, tint: Color?, origins: [CGFloat]) -> some View {
        // The drag's index is the row's place among the drawn items, not the
        // tabs' — a folded group's members hold tabs but draw no rows.
        let index = looseItems.firstIndex { $0.id == TabItem.tab(tab).id } ?? 0
        let held = dragging == tab.id
        return SideRow(
            browser: browser,
            prefs: prefs,
            tab: tab,
            live: tab.id == browser.activeID,
            pill: pill,
            tint: tint,
            close: { browser.close(tab) }
        )
        .offset(y: held && origins.indices.contains(index)
                ? anchor + travel - origins[index] : 0)
        // Under the hand exactly. Its place in the column springs when it
        // passes another row, and the offset springs back the same way —
        // until the next move of the hand cuts the offset's spring short
        // and leaves the place's running: the row jumped a whole slot and
        // drifted back each time it passed one. Only the others glide.
        .transaction { if held { $0.animation = nil } }
        .zIndex(held ? 1 : 0)
        .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
        .gesture(reorder(tab: tab, index: index, origins: origins))
    }

    /// A group's run: the header over its member rows, all of it on one
    /// tinted card that reaches a little past them so the block reads as a
    /// piece apart — and so the rows keep their own pitch and the drag math
    /// never has to know a block is there.
    private func block(_ group: TabGroup, members: [Tab], origins: [CGFloat]) -> some View {
        let held = groupDragging == group.id
        // The slot the block sits in: its header's place among the loose
        // items, since everything drawn above a header belongs to others.
        let now = looseItems.firstIndex { $0.id == TabItem.group(group).id } ?? 0
        return VStack(spacing: SideBar.gap) {
            head(group, title: browser.groupTitle(group),
                 count: browser.groupCount(group), interactive: true,
                 index: now, origins: origins)
            ForEach(members) { tab in
                row(tab, tint: group.tint, origins: origins)
                    // Named the way the scroll reveal asks — ForEach's own
                    // tag is the tab's UUID, but `visibleID` answers the
                    // item's, and the two never matched.
                    .id(TabItem.tab(tab).id)
            }
        }
        .background { card(group.tint) }
        .padding(.vertical, SideBar.blockPad)
        .offset(y: held && origins.indices.contains(now)
                ? groupAnchor + groupTravel - origins[now] : 0)
        // Glued to the hand like a row: the block's place springs as it
        // passes another, the offset under it does not — see the rows' own.
        .transaction { if held { $0.animation = nil } }
        // A member picked up inside the block lifts it whole — it will be
        // leaving, and the rows it crosses are the card's own.
        .zIndex(held || members.contains { $0.id == dragging } ? 1 : 0)
        .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
    }

    /// The card a group sits on: its colour as a wash over the column's
    /// ground, rounded a little past the rows' own corners and reaching a
    /// touch wider than them so the run reads as one piece.
    private func card(_ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(0.12))
            .padding(.horizontal, -4)
            .padding(.vertical, -2)
    }

    /// The colour a group's name and symbol wear — the group's own pulled
    /// toward the window's ink far enough to read over its wash: deepened on
    /// a light window, lifted a little on a dark one.
    private static func ink(_ tint: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor(tint).usingColorSpace(.deviceRGB) ?? .gray
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return NSColor(hue: h,
                           saturation: min(1, s * 1.05),
                           brightness: dim ? min(1, b * 1.12) : b * 0.72,
                           alpha: 1)
        })
    }

    /// A group's header: its symbol and name in the group's colour, a count
    /// of what a folded run is keeping out of sight, the chevron at the far
    /// end saying which way the fold sits. Parked rows draw it too, with
    /// nothing answering — `interactive` is the difference, and the drag's
    /// index and edges come with it.
    private func head(_ group: TabGroup, title: String, count: Int, interactive: Bool,
                      index: Int = 0, origins: [CGFloat] = []) -> some View {
        let tint = group.tint
        let renaming = interactive && browser.renamingGroup == group.id
        let hovering = interactive && overHead == group.id
        return HStack(spacing: 8) {
            Image(systemName: group.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.ink(tint))
                .frame(width: 15)
            if renaming {
                GroupNameField(browser: browser, group: group)
                    .frame(height: 16)
            } else {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Self.ink(tint))
            }
            Spacer(minLength: 2)
            if !group.expanded, count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Self.ink(tint).opacity(0.55))
            }
            Image(systemName: group.expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Self.ink(tint).opacity(0.55))
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(hovering ? 0.16 : 0))
        }
        .contentShape(Rectangle())
        .onHover { over in
            overHead = over ? group.id : (overHead == group.id ? nil : overHead)
        }
        .onTapGesture {
            guard interactive, browser.renamingGroup != group.id else { return }
            withAnimation(Motion.settle) { browser.toggleGroup(group.id) }
        }
        // High priority so the whole block lifts on a drag while a plain
        // click still folds — the same pact the rows' own gestures keep.
        .highPriorityGesture(groupMove(group, index: index, origins: origins),
                             isEnabled: interactive)
        .overlay { if interactive { GroupMenuCatch(browser: browser, group: group) } }
        .animation(Motion.quick, value: hovering)
    }

    /// The boundary a point in the column is nearest, as a drawn-row index —
    /// "before this one" — with one more answer, the count of them, for the
    /// stretch past the last row that means "at the end". The edges are
    /// measured one by one rather than divided out of a pitch, because a
    /// block's padding bends the spacing.
    private func edge(near y: CGFloat, in origins: [CGFloat]) -> Int {
        var best = origins.count
        var dist = CGFloat.greatestFiniteMagnitude
        if let last = origins.last {
            dist = abs(y - (last + SideBar.row))
        }
        for at in origins.indices {
            let gap = abs(y - origins[at])
            if gap < dist { (dist, best) = (gap, at) }
        }
        return best
    }

    /// The index into `tabs` a drop before drawn row `at` lands at — a plain
    /// row's own place, a header's first member's (the header stands at the
    /// run's head, so the drop is just before the run), the row's last place
    /// past the end.
    private func tabIndex(forItem at: Int) -> Int? {
        guard at < looseItems.count else {
            return browser.tabs.isEmpty ? nil : browser.tabs.count - 1
        }
        switch looseItems[at] {
        case .tab(let tab): return browser.tabs.firstIndex { $0.id == tab.id }
        case .group(let group): return browser.tabs.firstIndex { $0.groupID == group.id }
        }
    }

    /// The index `moveGroup` wants for a block dropped before drawn row `at`:
    /// the same place, but counted over the row with the group's own members
    /// lifted out — a member standing before it leaves with it, and doesn't
    /// count toward where it lands.
    private func groupIndex(forItem at: Int, lifting group: TabGroup) -> Int {
        let members = browser.tabs.reduce(0) { $0 + ($1.groupID == group.id ? 1 : 0) }
        let rest = browser.tabs.count - members
        guard at < looseItems.count else { return rest }
        let pos = tabIndex(forItem: at) ?? browser.tabs.count
        let lifted = browser.tabs[..<pos].reduce(0) { $0 + ($1.groupID == group.id ? 1 : 0) }
        return min(pos - lifted, rest)
    }

    /// A header picked up carries its whole run: the same gesture as a row's,
    /// landed with `moveGroup` rather than `move` so the members follow it
    /// instead of being picked off one by one.
    private func groupMove(_ group: TabGroup, index: Int, origins: [CGFloat]) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("rows"))
            .onChanged { value in
                guard origins.indices.contains(index) else { return }
                if groupDragging != group.id {
                    groupDragging = group.id
                    groupAnchor = origins[index]
                }
                groupTravel = value.translation.height
                let target = edge(near: groupAnchor + groupTravel, in: origins)
                let to = groupIndex(forItem: target, lifting: group)
                // Aimed at where it already stands — inside its own run
                // included — nothing moves.
                guard to != groupIndex(forItem: index, lifting: group) else { return }
                withAnimation(Motion.settle) {
                    browser.moveGroup(group.id, toTabIndex: to)
                }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    groupDragging = nil
                    groupTravel = 0
                }
            }
    }

    /// A tab dropped on a group's header joins the run, at its end — the one
    /// place it can land without the run breaking. `add` opens a folded run
    /// to show where the tab went; a drop asks the opposite, so the fold the
    /// header was holding is handed back to it — aiming at a shut group is
    /// how you file a tab away.
    private func join(_ tab: Tab, _ group: TabGroup) {
        let folded = !group.expanded
        withAnimation(Motion.settle) { browser.add(tab, to: group.id) }
        if folded, tab.groupID == group.id,
           browser.groups.first(where: { $0.id == group.id })?.expanded == true {
            browser.toggleGroup(group.id)
        }
    }

    /// Pick a row up and the others make way as it passes them.
    private func reorder(tab: Tab, index: Int, origins: [CGFloat]) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("rows"))
            .onChanged { value in
                guard origins.indices.contains(index) else { return }
                if dragging != tab.id {
                    dragging = tab.id
                    anchor = origins[index]
                }
                travel = value.translation.height
                let y = anchor + travel
                // On a header row — anywhere in the stretch of column it is
                // drawn over, not just past its top edge — the drop joins the
                // run instead of standing ahead of it: `add` lands the tab at
                // the run's end, and a block holding its run folded keeps it
                // folded. The span runs to the next row's top, so the air
                // between header and first member — inside the run's card —
                // joins as well; the air *above* a header stays outside it.
                // The header's own drag is `groupMove`; this only ever fires
                // for a row's.
                for at in origins.indices {
                    guard at < looseItems.count,
                          case .group(let group) = looseItems[at],
                          y >= origins[at],
                          y < origins[at] + SideBar.row + SideBar.gap
                    else { continue }
                    join(tab, group)
                    return
                }
                // The edge the row's top is nearest. An even row pitch used
                // to divide the travel; folded runs and block padding broke
                // that — a chip is one drawn row but a whole run of tabs —
                // so the drawn edges are measured, then mapped: before a
                // header is before the run, past one is past it, and only a
                // member's own row is inside.
                let target = edge(near: y, in: origins)
                guard target != index, var to = tabIndex(forItem: target) else { return }
                // A header stands at its run's head, so a drop short of it
                // lands before the run — which, coming down, is one place
                // lower: the dragged row lifting out shifts the run a place
                // left, and asking for its old head index puts the drop
                // inside it.
                if target < looseItems.count, case .group = looseItems[target],
                   let here = browser.tabs.firstIndex(where: { $0.id == tab.id }),
                   here < to {
                    to -= 1
                }
                withAnimation(Motion.settle) { browser.move(tab, to: to) }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                }
            }
    }

    /// The loose tabs and the row that makes another, which scroll as one.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            loose
            newTab
        }
    }

    /// The foot's door and its margin beneath.
    private static let footHeight: CGFloat = 26 + 10

    private var newTab: some View {
        Quiet(icon: "plus", title: "New tab", height: SideBar.row) { browser.newTab() }
            .padding(.top, SideBar.gap)
    }

    /// One small door at the bottom: the settings.
    private var foot: some View {
        HStack(spacing: 2) {
            if browser.prefs.usesSpaces { SpaceDot(browser: browser) }
            ExtensionSlot(edge: .trailing)
            Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .trailing) {
                    BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

}

/// The pinned squares' grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness.
private struct PinGrid: Layout {
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(
            width: CGFloat(columns) * width + CGFloat(max(0, columns - 1)) * spacing,
            height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                    y: bounds.minY + CGFloat(index / columns) * (height + spacing)
                ),
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var width: CGFloat = 34
    var height: CGFloat = 34

    @State private var hovering = false

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        Group {
            if browser.editingPin == tab.id {
                PinField(browser: browser, tab: tab)
            } else if tab.loading {
                // The ring spins in the glyph's slot while the page is
                // coming — Chrome's way over a pinned tab's icon —
                // whichever glyph the square would otherwise wear.
                Ring(size: scale * 11 / 34)
                    .transition(.opacity)
            } else if let icon = tab.icon {
                // A pin has no title to speak for it, so the site's mark
                // stands for it whenever there is one — the letters/icons
                // choice is for the rows, where a title does the naming.
                // A site that never gave an icon keeps the letter.
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * 16 / 34, dim: tab.asleep)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            if live {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(Palette.wash)
                    .matchedGeometryEffect(id: "live", in: pill)
            } else if hovering {
                // Nothing at rest — the card under the block is the fill a
                // square used to draw for itself; only the pointer still
                // lights one.
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(Palette.hover)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(OneClick(double: live) {
            if live { browser.editLetter(tab) } else { browser.select(tab) }
        })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: tab.loading)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// One tab, as a line in the column.
private struct SideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    /// The group's colour while the row sits inside a block — the wash the
    /// live row wears and the ground the hover draws over are the card's
    /// own, so a live member reads as picked rather than as grey on colour.
    var tint: Color? = nil
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: 16)
            } else {
                if prefs.glyph == .icons, !tab.isBlank {
                    // The ring takes the mark's slot while the page is
                    // coming — Chrome's spinner where the site icon sits —
                    // leaving the button at the far end to the cross.
                    ZStack {
                        if tab.loading {
                            Ring().transition(.opacity)
                        } else {
                            Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                        }
                    }
                    .frame(width: 15, height: 15)
                    .animation(Motion.quick, value: tab.loading)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            Spacer(minLength: 2)

            ZStack {
                if hovering, !editing {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 15, height: 15)
                        .background(Palette.ink.opacity(0.07), in: Circle())
                        .transition(.opacity)
                } else if tab.loading, prefs.glyph == .letters {
                    // With letters there is no mark's slot to lend the
                    // ring, so the button's does as it always has.
                    Ring().transition(.opacity)
                } else if tab.noisy {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.muted)
                        .transition(.opacity)
                }
            }
            .frame(width: editing ? 0 : 15, height: 15)
            .opacity(editing ? 0 : 1)
            .overlay {
                if !editing {
                    Color.clear
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { close() } }
                }
            }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: tab.loading)
            .animation(Motion.quick, value: tab.noisy)
        }
        .padding(.leading, 10)
        .padding(.trailing, editing ? 10 : 7)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                Rectangle().fill(tint.map { $0.opacity(0.30) } ?? Palette.wash)
                GeometryReader { geo in
                    Rectangle()
                        .fill(Palette.ink.opacity(0.055))
                        .frame(width: geo.size.width * tab.reading)
                        .animation(.easeOut(duration: 0.15), value: tab.reading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: "live", in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.map { $0.opacity(0.16) } ?? Palette.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.faint)
            .padding(.leading, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}

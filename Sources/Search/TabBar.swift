import SwiftUI

/// The only chrome there is. Titles, one of them in a grey pill, and the pill
/// slides from the tab you left to the tab you picked rather than blinking out
/// of one and into the other. A group's run sits inside one bar of its
/// colour — the chip at its head, the tabs bare within it, the colour going
/// deeper only where the pointer is or the page is on screen — and folded
/// away the chip is all that is left of it.
struct TabBar: View {
    @ObservedObject var browser: Browser

    @Namespace private var pill
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var above
    @Namespace private var below

    /// Which tab — or which group's chip — is under the hand, where in the run
    /// it was picked up, and how far it has come. The start is kept as a
    /// place rather than a slot: with chips in the row the places are no
    /// longer a fixed stride apiece.
    @State private var dragging: Tab.ID?
    @State private var draggingGroup: TabGroup.ID?
    @State private var anchor: CGFloat = 0
    @State private var travel: CGFloat = 0
    @State private var landing = false
    /// The plus only comes out when the pointer is in the row.
    @State private var nearby = false
    @State private var plussed = false
    /// How wide the doors at the far end are, extension buttons included.
    @State private var doors: CGFloat = 0

    var body: some View {
        // A GeometryReader is only here to measure the width. Its content is
        // put in a stack of its own and told to fill it: left to itself a
        // reader pins whatever it holds to the top corner, which is the row
        // riding at the very top of the strip while the traffic lights centre
        // themselves halfway down it.
        GeometryReader { geo in
            // The row flattened to what is actually drawn — a pin or a loose
            // tab as a pill, a group as its chip then each member, a folded
            // group as the chip alone — and where each thing in it starts.
            // Both are counted here rather than asked of the layout: a chip's
            // width is measured off its name (see chipWidth), so the run's
            // arithmetic — its length, a drag's aim — is settled before a
            // single view exists.
            let items = browser.visibleItems
            let strides = strides(in: geo.size.width)
            let origins = origins(of: strides)
            ZStack(alignment: .leading) {
                // The empty half of the strip is what you grab to move the
                // window; the tabs keep the run they sit on.
                DragStrip(reserved: Metrics.lights + dot + (making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width)) + Metrics.tabGap + Metrics.plusWidth, trailing: Metrics.helm + 26 + 24 + (browser.prefs.ask ? AskButton.width : 0))
                // And the corner the lights sit in, which is title bar too —
                // the one stretch left to take hold of when tabs fill the row.
                DragStrip()
                    .frame(width: Metrics.lights)

                HStack(spacing: Metrics.tabGap) {
                    // The space on screen, first, when there are spaces.
                    if browser.prefs.usesSpaces { SpaceDot(browser: browser) }

                    // The tabs, in a run of their own. While they fit, it is
                    // exactly as wide as they are and nothing about the row
                    // changes. Past what the window holds at their narrowest
                    // it takes the room there is and scrolls inside its own
                    // edges — never under the lights, never over the doors —
                    // keeping the tab you are on in view.
                    // The spaces, one above the other: up or down over the bar
                    // and the next one's tabs come in as these go, with nothing
                    // between them (see SpaceSwipe). Past the last, a new one.
                    ZStack(alignment: .leading) {
                        if making {
                            NewSpaceCard(browser: browser, inline: true)
                                .fixedSize()
                                .offset(y: browser.spaceSwipe)
                        } else {
                            ScrollViewReader { reader in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: Metrics.tabGap) {
                                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                            if let group = item.group {
                                                // The chip stands at the head of its run; while the
                                                // group is folded it is all the run there is.
                                                let held = draggingGroup == group.id
                                                GroupChip(browser: browser, group: group, width: chipWidth(group))
                                                    // The same keeping up with the hand the pills do.
                                                    .offset(x: held ? anchor + travel - origins[index] : 0)
                                                    .transaction { if held { $0.animation = nil } }
                                                    .zIndex(held ? 1 : 0)
                                                    .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
                                                    .gesture(reorder(group: group, index: index, strides: strides, origins: origins))
                                                    .id(item.id)
                                            } else if let tab = item.tab {
                                                let held = dragging == tab.id
                                                TabPill(
                                                    browser: browser,
                                                    prefs: browser.prefs,
                                                    tab: tab,
                                                    live: tab.id == browser.activeID,
                                                    tint: browser.group(for: tab)?.tint,
                                                    width: width(in: geo.size.width),
                                                    room: geo.size.width - Metrics.lights - 12,
                                                    pill: pill,
                                                    close: { browser.close(tab) }
                                                )
                                                // The row reflows around it while the pill itself keeps
                                                // up with the hand: where it was picked up plus what it
                                                // has travelled, less the ground its new place has
                                                // already given it.
                                                .offset(x: held ? anchor + travel - origins[index] : 0)
                                                // Under the hand exactly. Its place in the row springs when it
                                                // passes another tab, and the offset springs back the same way —
                                                // until the next move of the hand cuts the offset's spring short
                                                // and leaves the place's running: the tab jumped a whole slot and
                                                // drifted back each time it passed one. Only the others glide.
                                                .transaction { if held { $0.animation = nil } }
                                                .zIndex(held ? 1 : 0)
                                                .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
                                                .gesture(reorder(tab: tab, index: index, strides: strides, origins: origins))
                                                .id(item.id)
                                            }
                                        }
                                    }
                                    .frame(height: Metrics.strip)
                                    // Each open group's colour as one bar beneath its
                                    // whole run — chip and members together — reaching
                                    // a little into the gaps either side, so the run
                                    // reads as a thing the tabs are inside rather than
                                    // neighbours sharing a paint. Pure ground: the
                                    // run's arithmetic already placed everything it
                                    // wraps, and nothing here takes a click.
                                    .background {
                                        ZStack {
                                            // The pins' ground, drawn once around
                                            // the whole run rather than a faint
                                            // square apiece — a letter with nothing
                                            // behind it reads as debris, and the
                                            // block of them is one thing. The same
                                            // quiet grey the squares used to wear,
                                            // kept a step under the live tab's so
                                            // the run reads as a tray its icons sit
                                            // inside. Pure ground like the bars:
                                            // everything it wraps is already
                                            // placed, and it takes no click.
                                            if let pins = pinRun(of: items, origins: origins, strides: strides) {
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .fill(Palette.wash.opacity(0.55))
                                                    .frame(width: pins.width, height: TabBar.barHeight)
                                                    .position(x: pins.minX + pins.width / 2, y: Metrics.strip / 2)
                                                    .transition(.opacity)
                                            }
                                            ForEach(bars(of: items, origins: origins, strides: strides)) { bar in
                                                // The pills' own radius on the pills'
                                                // own height, centred where they are:
                                                // the bar is their run's ground, and
                                                // an end rounder than theirs would
                                                // read as taller rather than wider.
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .fill(bar.tint.opacity(0.14))
                                                    .frame(width: bar.width, height: TabBar.barHeight)
                                                    .position(x: bar.minX + bar.width / 2, y: Metrics.strip / 2)
                                                    .transition(.opacity)
                                            }
                                        }
                                        .allowsHitTesting(false)
                                    }
                                }
                                .scrollDisabled(!overflowing(in: geo.size.width))
                                .frame(width: run(in: geo.size.width))
                                .onAppear { reveal(reader, in: geo.size.width) }
                                .onChange(of: overflowing(in: geo.size.width)) { _, _ in reveal(reader, in: geo.size.width) }
                                .onChange(of: browser.activeID) { _, _ in reveal(reader, in: geo.size.width, gliding: true) }
                                // A fold moves what a tab in it shows as — its chip —
                                // without the row's overflow answering for it.
                                .onChange(of: items.map(\.id)) { _, _ in reveal(reader, in: geo.size.width) }
                            }
                            .offset(y: browser.spaceSwipe)
                        }
                        if browser.spaceSwipe > 0, spaceAt > 0 {
                            page(spaceAt - 1, in: geo.size.width, pill: above)
                                .offset(y: browser.spaceSwipe - Metrics.strip)
                        }
                        if browser.spaceSwipe < 0, spaceAt < browser.spaces.count {
                            page(spaceAt + 1, in: geo.size.width, pill: below)
                                .offset(y: browser.spaceSwipe + Metrics.strip)
                        }
                    }
                    .frame(width: making ? min(540, room(in: geo.size.width)) : run(in: geo.size.width), height: Metrics.strip, alignment: .leading)
                    // Only up and down: a neighbour's row may run wider than this one.
                    .mask(Rectangle().frame(width: 4000, height: Metrics.strip))

                    // The way to a new page, right after the tabs rather than
                    // at the end of their run, so it is there however far the
                    // run has scrolled. Out of sight until the pointer is up here.
                    Button { browser.newTab() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(plussed ? Palette.hover : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { plussed = $0 }
                    .opacity(nearby ? 1 : 0)
                    .scaleEffect(nearby ? 1 : 0.7, anchor: .leading)
                    .allowsHitTesting(nearby)
                    .animation(Motion.settle, value: nearby)

                    Spacer(minLength: 0)

                    // Back, forward, reload, and the bookmarks, at the far end
                    // of the row. The dropdown hangs from the last one.
                    HStack(spacing: Metrics.tabGap) {
                        AgentTabsButton(browser: browser)
                        ExtensionSlot()
                        Helm(browser: browser)
                            .padding(.trailing, 8)
                        Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                            .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .bottom) {
                                BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                            }
                        // Ask gets a word where the doors wear symbols: it is
                        // a feature arriving, not another tool.
                        if browser.prefs.ask {
                            AskButton(browser: browser)
                        }
                    }
                    .background {
                        GeometryReader { box in
                            Color.clear
                                .onAppear { doors = box.size.width }
                                .onChange(of: box.size.width) { _, width in doors = width }
                        }
                    }
                }
                // The traffic lights are the system's. The row starts after
                // them and stays there — nothing here moves to get out of
                // their way, because nothing here was ever in it.
                .padding(.leading, Metrics.lights)
                .padding(.trailing, 12)
                .coordinateSpace(name: "strip")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Metrics.strip)
        .onHover { nearby = $0 }
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        // A link dragged onto the row opens there.
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .background(landing ? Palette.hover : .clear)
        .animation(Motion.quick, value: landing)
        .animation(Motion.glide, value: browser.activeID)
        // The row makes room for the field on the same spring as everything
        // else. Without this the widths changed between one frame and the next
        // and the tabs appeared to jump aside.
        .animation(Motion.glide, value: browser.editingTab)
        // The drawn row rather than the tab list, so a group folding or
        // opening springs the same way a tab arriving or leaving does.
        .animation(Motion.settle, value: browser.visibleItems.map(\.id))
    }

    // MARK: - the spaces, one above the other

    private var making: Bool { browser.prefs.usesSpaces && browser.makingSpace }

    /// Where the space on screen sits among them: one past the last while
    /// the row for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    /// Another space's row, drawn with the same pills as this one's so the
    /// two read as one bar while they pass — nothing to press until it is
    /// the one on screen. Past the last, the row for a new space.
    @ViewBuilder
    private func page(_ index: Int, in strip: CGFloat, pill: Namespace.ID) -> some View {
        if index == browser.spaces.count {
            NewSpaceCard(browser: browser, inline: true)
                .fixedSize()
                .allowsHitTesting(false)
        } else {
            let space = browser.spaces[index]
            let live = space.id == browser.spaceID
            let row = live
                ? Parked(tabs: browser.tabs, active: browser.activeID)
                : browser.parked[space.id] ?? Parked(tabs: [], active: nil)
            // The row's groups, so a member's pill wears its colour here too.
            let rowGroups = live ? browser.groups : row.groups
            let tabs = row.tabs.filter { !$0.bench }
            let each = width(in: strip, pinned: tabs.filter { $0.pin != nil }.count, count: tabs.count)
            HStack(spacing: Metrics.tabGap) {
                ForEach(tabs) { tab in
                    TabPill(
                        browser: browser,
                        prefs: browser.prefs,
                        tab: tab,
                        live: tab.id == row.active,
                        tint: rowGroups.first { $0.id == tab.groupID }?.tint,
                        width: each,
                        room: strip - Metrics.lights - 12,
                        pill: pill,
                        close: {}
                    )
                }
            }
            .frame(height: Metrics.strip)
            .allowsHitTesting(false)
        }
    }

    /// Pick a tab up and the others get out of its way as it passes them.
    private func reorder(tab: Tab, index: Int, strides: [CGFloat], origins: [CGFloat]) -> some Gesture {
        // In the row's space, not the pill's — see the sidebar's grid for why.
        DragGesture(minimumDistance: 5, coordinateSpace: .named("strip"))
            .onChanged { value in
                guard origins.indices.contains(index) else { return }
                if dragging != tab.id {
                    dragging = tab.id
                    anchor = origins[index]
                }
                travel = value.translation.width
                let x = anchor + travel
                // On a chip — anywhere in the stretch of row it is drawn
                // over, not just past its leading edge — the drop joins the
                // run instead of standing ahead of it: `add` lands the tab at
                // the run's end, and a chip holding its run folded keeps it
                // folded. The span runs to the next item's start, so the air
                // between chip and first member — inside the run's bar —
                // joins as well; the gap *before* a chip stays outside it.
                for at in origins.indices {
                    guard at < browser.visibleItems.count,
                          case .group(let group) = browser.visibleItems[at],
                          x >= origins[at], x < origins[at] + strides[at]
                    else { continue }
                    join(tab, group)
                    return
                }
                // The edge the pill's leading edge is nearest. A fixed stride
                // used to divide the travel evenly; chips broke that, so the
                // places are measured one by one — and a drop short of a chip
                // lands before the run, strictly inside one joins it.
                let target = edge(near: x, in: origins, strides: strides)
                guard target != index, var to = tabIndex(forItem: target) else { return }
                // A chip stands at its run's head, so a drop short of it lands
                // before the run — which, coming from before the run, is one
                // index lower: the dragged tab lifting out shifts the run
                // left, and asking for its old head index drops inside it.
                if target < browser.visibleItems.count,
                   case .group = browser.visibleItems[target],
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

    /// A chip picked up carries its whole run: the same gesture, landed with
    /// `moveGroup` rather than `move` so the members follow it instead of
    /// being picked off one by one.
    private func reorder(group: TabGroup, index: Int, strides: [CGFloat], origins: [CGFloat]) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("strip"))
            .onChanged { value in
                guard origins.indices.contains(index) else { return }
                if draggingGroup != group.id {
                    draggingGroup = group.id
                    anchor = origins[index]
                }
                travel = value.translation.width
                let target = edge(near: anchor + travel, in: origins, strides: strides)
                let to = groupIndex(forItem: target, lifting: group)
                // Aimed at where it already stands — inside its own run
                // included — nothing moves.
                guard to != groupIndex(forItem: index, lifting: group) else { return }
                withAnimation(Motion.settle) { browser.moveGroup(group.id, toTabIndex: to) }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    draggingGroup = nil
                    travel = 0
                }
            }
    }

    /// The boundary a point in the run is nearest, as an item index —
    /// "before this one" — with one more answer, the count of them, for the
    /// stretch past the last item that means "at the end". The edges stand
    /// a stride apart and the strides differ item to item, so they are
    /// measured rather than divided out of one.
    private func edge(near x: CGFloat, in origins: [CGFloat], strides: [CGFloat]) -> Int {
        var best = origins.count
        var dist = CGFloat.greatestFiniteMagnitude
        if let last = origins.indices.last {
            dist = abs(x - (origins[last] + strides[last]))
        }
        for at in origins.indices {
            let gap = abs(x - origins[at])
            if gap < dist { (dist, best) = (gap, at) }
        }
        return best
    }

    /// A tab dropped on a group's chip joins the run, at its end — the one
    /// place it can land without the run breaking. `add` opens a folded run
    /// to show where the tab went; a drop asks the opposite, so the fold the
    /// chip was holding is handed back to it — aiming at a shut group is how
    /// you file a tab away.
    private func join(_ tab: Tab, _ group: TabGroup) {
        let folded = !group.expanded
        withAnimation(Motion.settle) { browser.add(tab, to: group.id) }
        if folded, tab.groupID == group.id,
           browser.groups.first(where: { $0.id == group.id })?.expanded == true {
            browser.toggleGroup(group.id)
        }
    }

    /// The index into `tabs` a drop before item `at` lands at — a pill's own
    /// place, a chip's first member's (the chip stands at the run's head, so
    /// the drop is just before the run), the row's last place past the end.
    private func tabIndex(forItem at: Int) -> Int? {
        let items = browser.visibleItems
        guard at < items.count else { return browser.tabs.isEmpty ? nil : browser.tabs.count - 1 }
        switch items[at] {
        case .tab(let tab): return browser.tabs.firstIndex { $0.id == tab.id }
        case .group(let group): return browser.tabs.firstIndex { $0.groupID == group.id }
        }
    }

    /// The index `moveGroup` wants for a chip dropped before item `at`: the
    /// same place, but counted over the row with the group's own members
    /// lifted out — a member standing before it leaves with it, and doesn't
    /// count toward where it lands.
    private func groupIndex(forItem at: Int, lifting group: TabGroup) -> Int {
        let members = browser.tabs.reduce(0) { $0 + ($1.groupID == group.id ? 1 : 0) }
        let rest = browser.tabs.count - members
        guard at < browser.visibleItems.count else { return rest }
        let pos = tabIndex(forItem: at) ?? browser.tabs.count
        let lifted = browser.tabs[..<pos].reduce(0) { $0 + ($1.groupID == group.id ? 1 : 0) }
        return min(pos - lifted, rest)
    }

    /// Brings the tab you are on into view once the run scrolls: at once
    /// when the window first shows it, on the strip's spring when you pick
    /// another. A turn of the run loop later, so the run has been laid out.
    private func reveal(_ reader: ScrollViewProxy, in strip: CGFloat, gliding: Bool = false) {
        guard overflowing(in: strip), let tab = browser.active else { return }
        // The tab's own id — or while its group is folded, the chip's, which
        // is the only place it has.
        let id = browser.visibleID(for: tab)
        DispatchQueue.main.async {
            if gliding {
                withAnimation(Motion.glide) { reader.scrollTo(id) }
            } else {
                reader.scrollTo(id)
            }
        }
    }

    /// How wide the run of tabs is: as wide as the tabs while they fit, as
    /// wide as the room there is once they don't.
    private func run(in strip: CGFloat) -> CGFloat {
        min(content(in: strip), room(in: strip))
    }

    private func overflowing(in strip: CGFloat) -> Bool {
        content(in: strip) > room(in: strip) + 0.5
    }

    /// Everything in the run at the width the items get — chips measured off
    /// their names, a tab being edited grown to the field — less the gap
    /// after the last, which the strides count and a row doesn't.
    private func content(in strip: CGFloat) -> CGFloat {
        max(0, strides(in: strip).reduce(0, +) - Metrics.tabGap)
    }

    /// The strip, less the lights, the plus, the doors at the far end and
    /// the air around them. The doors are measured; until they have been,
    /// the three of the helm and the bookmarks stand in for them.
    private func room(in strip: CGFloat) -> CGFloat {
        let far = doors > 0 ? doors : Metrics.helm + 26
        return max(0, strip - Metrics.lights - dot - 12 - Metrics.plusWidth - far - 3 * Metrics.tabGap)
    }

    /// What the space's dot takes before the tabs, when there are spaces.
    private var dot: CGFloat { browser.prefs.usesSpaces ? SpaceDot.width + Metrics.tabGap : 0 }

    /// Each item's stride — its width and the gap after it, the last one's
    /// included where it marks the edge a drop can still mean. A chip takes
    /// its measured width, a pin its square, a loose pill the shared width.
    /// A tab being edited draws the field whatever it was — a pinned square
    /// spends the field's stride too, not the square's, or the run's
    /// arithmetic and the drawn row would disagree by the difference.
    private func strides(in strip: CGFloat) -> [CGFloat] {
        let each = width(in: strip)
        let field = min(340, strip - Metrics.lights - 12)
        return browser.visibleItems.map { item in
            switch item {
            case .group(let group):
                return chipWidth(group) + Metrics.tabGap
            case .tab(let tab):
                if tab.id == browser.editingTab { return field + Metrics.tabGap }
                if tab.pin != nil { return Metrics.pinWidth + Metrics.tabGap }
                return each + Metrics.tabGap
            }
        }
    }

    /// Where each item starts — the running total of the strides before it.
    private func origins(of strides: [CGFloat]) -> [CGFloat] {
        var out: [CGFloat] = []
        out.reserveCapacity(strides.count)
        var x: CGFloat = 0
        for stride in strides {
            out.append(x)
            x += stride
        }
        return out
    }

    /// The bar's height — the pills' own and no more: a sixteen-point line
    /// plus the six of air either side of it that every pill draws by
    /// padding rather than by name. The container and the tabs beside it
    /// are one height in the row, so a run reads as a folder its tabs sit
    /// inside — flush top and bottom with them, not a band standing proud.
    private static let barHeight: CGFloat = 28
    /// The air a bar keeps past the ends of its run, borrowed from the gap
    /// either side. A gap is two points and both neighbours may borrow, so
    /// a quarter apiece: a sliver of ground always shows between two bars,
    /// however like-coloured they are, and nothing ever slides under the
    /// next item.
    private static let barBleed: CGFloat = Metrics.tabGap / 4
    /// The air the pins' block keeps past the end of its run — the bars'
    /// trick of borrowing from the gap, taken a little deeper, so the last
    /// square sits inside the container rather than on its edge. What it
    /// reaches beyond the two-point gap lands under the next item's empty
    /// padding, where a resting tab paints nothing; where there is no
    /// neighbour there is nothing to borrow, and the block keeps its
    /// rounded corner rather than painting off the content's edge.
    private static let pinBleed: CGFloat = 3

    /// One open group's bar, drawn behind the run: where it starts, how far
    /// it reaches, what it wears.
    private struct GroupBar: Identifiable {
        let id: String
        let tint: Color
        let minX: CGFloat
        let width: CGFloat
    }

    /// The open groups as spans of the row — each from just before its chip
    /// to just past its last member, counted from the same origins and
    /// strides the pills were placed by, so a bar can never disagree with
    /// what it wraps. A folded group draws no members and no bar: its chip
    /// keeps a pill of its own because it is the whole run.
    private func bars(of items: [TabItem], origins: [CGFloat], strides: [CGFloat]) -> [GroupBar] {
        var out: [GroupBar] = []
        for (at, item) in items.enumerated() {
            guard case .group(let group) = item, group.expanded else { continue }
            var last = at
            while last + 1 < items.count,
                  case .tab(let tab) = items[last + 1],
                  tab.groupID == group.id {
                last += 1
            }
            // An open group's members always follow its chip; the guard is
            // for the file saying otherwise, not for a state the row holds.
            guard last > at, strides.indices.contains(last) else { continue }
            // The bleed borrows a quarter of the gap on a side — only where
            // there is a gap. At the row's ends there is none to borrow, so
            // a first or last run's bar keeps its rounded corner rather than
            // painting off the content's edge.
            let bleedL: CGFloat = at > 0 ? TabBar.barBleed : 0
            let bleedR: CGFloat = last + 1 < items.count ? TabBar.barBleed : 0
            let minX = origins[at] - bleedL
            let end = origins[last] + strides[last] - Metrics.tabGap + bleedR
            out.append(GroupBar(
                id: item.id,
                tint: group.tint,
                minX: minX,
                width: end - minX
            ))
        }
        return out
    }

    /// The pinned run as one span of the row, for the block drawn beneath
    /// it — the run's start and how far it reaches, counted from the same
    /// origins and strides the pills were placed by, so the block can never
    /// disagree with what it wraps. Pins are always the row's leading
    /// prefix — `move` refuses to leave one standing among loose tabs — so
    /// the run is simply the leading stretch of letters, a pinned tab grown
    /// to its field included: being edited doesn't unpin it.
    private func pinRun(of items: [TabItem], origins: [CGFloat], strides: [CGFloat]) -> (minX: CGFloat, width: CGFloat)? {
        var last = -1
        for (at, item) in items.enumerated() {
            guard case .tab(let tab) = item, tab.pin != nil else { break }
            last = at
        }
        guard last >= 0, strides.indices.contains(last) else { return nil }
        // Leading the row, the run's start is the content's own edge —
        // nothing to borrow there. Past its end it stands a few points
        // proud where a neighbour leaves a gap; last in the row it keeps
        // its rounded corner instead.
        let bleed: CGFloat = last + 1 < items.count ? TabBar.pinBleed : 0
        let end = origins[last] + strides[last] - Metrics.tabGap + bleed
        return (0, end)
    }

    /// A chip's width is needed before anything is laid out — the run's
    /// arithmetic, the drag's map — so it is measured rather than asked of a
    /// view: the name set in the chip's own font, then the icon's slot and
    /// the padding, and capped so one group's name never swallows the row.
    private static let chipFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    private func chipWidth(_ group: TabGroup) -> CGFloat {
        let name = NSAttributedString(
            string: browser.groupTitle(group),
            attributes: [.font: TabBar.chipFont]
        ).size().width
        // The icon's slot, its distance from the name, the padding either side.
        return min(110, max(46, ceil(name) + 14 + 5 + 18))
    }

    /// Every loose pill is the same width, so the cross is always in the same
    /// place. Chips and pinned squares are fixed-width: the loose pills —
    /// grouped or not — share what is left once those and the gaps are spent.
    /// Past a dozen or so they start giving ground; too narrow for a title
    /// they show their mark alone (Metrics.tabTitled), down to the mark and
    /// its air. Past that, the run scrolls.
    private func width(in strip: CGFloat) -> CGFloat {
        var loose = 0
        var spent: CGFloat = 0
        var items = 0
        // The same order as `strides`: the field is what a tab costs while it
        // is being edited — a pinned one included — so what the loose pills
        // share is what is genuinely left.
        let field = min(340, strip - Metrics.lights - 12)
        for item in browser.visibleItems {
            items += 1
            switch item {
            case .group(let group):
                spent += chipWidth(group)
            case .tab(let tab):
                if tab.id == browser.editingTab {
                    spent += field
                } else if tab.pin != nil {
                    spent += Metrics.pinWidth
                } else {
                    loose += 1
                }
            }
        }
        guard loose > 0 else { return Metrics.tabWidth }
        spent += CGFloat(max(0, items - 1)) * Metrics.tabGap
        return max(Metrics.tabMinWidth, min(Metrics.tabWidth, (room(in: strip) - spent) / CGFloat(loose)))
    }

    /// The same, for a space previewing its row beside this one: it has no
    /// chips to measure, so its pills share what the pins leave.
    private func width(in strip: CGFloat, pinned pins: Int, count: Int) -> CGFloat {
        let pinned = CGFloat(pins)
        let loose = CGFloat(count) - pinned
        guard loose > 0 else { return Metrics.tabWidth }
        let spent = pinned * Metrics.pinWidth
            + CGFloat(max(0, count - 1)) * Metrics.tabGap
        return max(Metrics.tabMinWidth, min(Metrics.tabWidth, (room(in: strip) - spent) / loose))
    }
}

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Used here and, beside the traffic lights instead of at the
/// far end of the row, in the sidebar.
struct Helm: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Wheel(browser: browser, tab: tab)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // greyed, so the row doesn't shift when a tab arrives.
            HStack(spacing: 4) {
                Door(icon: "chevron.left") {}
                Door(icon: "chevron.right") {}
                Door(icon: "arrow.clockwise") {}
            }
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    private struct Wheel: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            HStack(spacing: 4) {
                Door(icon: "chevron.left", help: "Back   ⌘[") { browser.back() }
                    .disabled(!back)
                    .opacity(back ? 1 : 0.3)
                Door(icon: "chevron.right", help: "Forward   ⌘]") { browser.forward() }
                    .disabled(!forward)
                    .opacity(forward ? 1 : 0.3)
                // Reload, or stop while it is still coming.
                Door(
                    icon: tab.loading ? "xmark" : "arrow.clockwise",
                    help: tab.loading ? "Stop   ⌘." : "Reload   ⌘R"
                ) {
                    if tab.loading { tab.stop() } else { browser.reload() }
                }
                .disabled(tab.isBlank)
                .opacity(tab.isBlank ? 0.3 : 1)
            }
            .animation(Motion.quick, value: back)
            .animation(Motion.quick, value: forward)
            .animation(Motion.quick, value: tab.loading)
        }
    }
}

private struct TabPill: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    /// The group's colour a member pill sits on — nil for a tab that is no
    /// group's, which keeps the row's quiet greys.
    let tint: Color?
    let width: CGFloat
    /// How much of the strip there is, for the field that grows over it.
    let room: CGFloat
    let pill: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    private var editing: Bool { browser.editingTab == tab.id }
    private var pinned: Bool { tab.pin != nil && !editing }
    /// Too narrow for a title: the site's mark alone, the title in the
    /// tooltip, and ⌘W or the menu to close it — a cross on something this
    /// small would be what a click to pick the tab lands on.
    private var compact: Bool { !editing && !pinned && width < Metrics.tabTitled }
    /// A speaker to press at the end of the pill: the page plays sound, or
    /// was muted. The ring, while the page is still coming, goes first.
    private var speaker: Bool { !editing && !tab.loading && (tab.noisy || tab.muted) }

    /// A pinned tab is a square, an edited one is a field, everything else is
    /// its share of what is left.
    private var span: CGFloat {
        if editing { return min(340, room) }
        return pinned ? Metrics.pinWidth : width
    }

    var body: some View {
        Group {
            if pinned {
                Group {
                    if browser.editingPin == tab.id {
                        PinField(browser: browser, tab: tab)
                    } else if tab.loading {
                        // A pinned tab spins over its glyph, icon or letter
                        // alike — the same standing in for the mark that a
                        // compact tab's ring does. The letter field above
                        // still wins.
                        Ring()
                            .transition(.opacity)
                    } else if let icon = tab.icon {
                        // The site's own mark, whatever letters are doing
                        // elsewhere — it is what you would know the page by
                        // at a glance. The letter keeps the square only
                        // until the mark arrives.
                        Mark(icon: icon, letter: tab.pin ?? "", size: 16, dim: tab.asleep)
                    } else {
                        Text(tab.pin ?? "")
                            .font(.system(size: 12, weight: .medium))
                            // A pin holding no page is still there and still
                            // yours; it just isn't costing anything.
                            .foregroundStyle(colour.opacity(tab.asleep ? 0.45 : 1))
                            .transition(.opacity)
                    }
                }
                .frame(width: 16, height: 16)
                .animation(Motion.quick, value: tab.loading)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(width: span)
            } else {
                loose
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if tab.surfaced && (pinned || compact) { AgentTabIndicator().padding(3) }
        }
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // Never both at once.
        //
        // A view carrying a single tap *and* a double tap has to wait out the
        // system's double-click delay before it can conclude that a click was
        // single — and that delay is a preference, adjustable up to a second.
        // Which is exactly how long a tab took to come forward.
        //
        // So each tab carries one gesture. The pinned square you are already
        // on has nothing to do on a single click, so it takes the double one
        // and edits its letter; everything else answers the first click at
        // once. Change Letter in the menu covers the rest.
        .modifier(OneClick(double: live && pinned) {
            if live && pinned {
                browser.editLetter(tab)
            } else if live && !pinned {
                browser.beginTabEdit(tab)
            } else {
                browser.select(tab)
            }
        })
        .overlay { MiddleClick(act: close) }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .help(pinned || compact ? tab.label : "")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .animation(Motion.glide, value: tab.pin)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        // Arriving and leaving from the strip rather than from nowhere.
        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private var loose: some View {
        if compact {
            ZStack {
                if tab.loading {
                    Ring()
                } else {
                    Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 15, dim: tab.asleep)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.vertical, 6)
            .frame(width: span)
        } else {
            titled
        }
    }

    private var titled: some View {
        HStack(spacing: 6) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: 16)
            } else {
                if prefs.glyph == .icons, tab.loading || !tab.isBlank {
                    // While the page is coming the ring takes the mark's own
                    // slot — where Chrome's spinner stands — whether the icon
                    // has arrived or not; a blank tab keeps the slot shut.
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
                if tab.surfaced {
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                        .help("Kept from an agent")
                        .accessibilityLabel("Kept from an agent")
                }
                if tab.shy {
                    // Quiet, and only on the tabs that keep nothing.
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

            // The speaker, which can be pressed, is at the end of the pill on
            // its own, and one place in under the pointer, beside the cross
            // and clear of its reach.
            HStack(spacing: 0) {
                if speaker {
                    Speaker(tab: tab)
                        .padding(.trailing, hovering ? 8 : 0)
                        .transition(.opacity)
                }

                // Pinned to the right-hand end of the pill, not trailing the title.
                // One slot doing two jobs: the cross when the pointer is here, the
                // ring while the page is still coming, never both.
                ZStack {
                    if hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    } else if tab.loading {
                        Ring().transition(.opacity)
                    }
                }
                .frame(width: editing || (speaker && !hovering) ? 0 : 15, height: 15)
                .opacity(editing ? 0 : 1)
                // The cross is 15 points across because that is how big it should
                // look. What you have to hit is the whole right-hand end of the
                // tab: an overlay is not laid out, so it can reach past its own
                // frame without moving anything that is.
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
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, editing ? 11 : 7)
        .padding(.vertical, 6)
        .frame(width: span, alignment: .leading)
        .animation(Motion.quick, value: speaker)
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            // The grey fills from the left as you read down the page. It is
            // the one thing in the window that says how far in you are, and
            // it says it without adding anything to the window. In a group
            // the same thing is said in the group's colour, deeper — a
            // segment of the bar rather than a pill inside it, and the
            // strongest thing in the run.
            ZStack(alignment: .leading) {
                Rectangle().fill(tint?.opacity(0.30) ?? Palette.wash)
                // Not on a pinned square, nor a tab down to its mark. Thirty
                // points of grey filling from the left behind a single letter
                // says nothing about anything — it needs the width of a title
                // to read as progress at all.
                if !pinned && !compact && prefs.showsReading {
                    Rectangle()
                        .fill(tint?.opacity(0.16) ?? Palette.ink.opacity(0.055))
                        .frame(width: span * tab.reading)
                        .animation(.easeOut(duration: 0.15), value: tab.reading)
                }
            }
            // A member's is a segment of its bar, corners a touch squarer
            // than a pill's — the same modest turn the bar's own ends take,
            // so it reads as part of the container it is drawn inside.
            .clipShape(RoundedRectangle(cornerRadius: tint == nil ? 9 : 6.5, style: .continuous))
            .matchedGeometryEffect(id: "live", in: pill)
        } else if hovering {
            // A member under the pointer is a segment of its bar too — the
            // run's colour a step deeper at the bar's full height — not a
            // pill floating inside one. A loose tab keeps the row's grey.
            RoundedRectangle(cornerRadius: tint == nil ? 9 : 6.5, style: .continuous)
                .fill(tint?.opacity(0.25) ?? Palette.hover)
        } else if tint != nil {
            // A member rests on the run's bar itself — the container's
            // colour is the ground, and mark and title sit in it directly.
            // Nothing to draw until the pointer, or being the tab on screen,
            // asks for a deeper share of the colour.
            Color.clear
        }
        // A resting pin draws nothing of its own here: the block painted
        // behind the whole leading run, in the row's background, is the
        // ground it sits on now.
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// The address, inside its own tab.
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent colour, which over a pale grey pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
/// A tab picked up and carried along its row, the others making way as it
/// passes them — across the top or down the column alike.
///
/// The hand's travel is the tab's own: every move of the pointer redraws the
/// one tab being carried, not the whole column or bar around it (with the
/// neighbouring spaces drawn beside it, that was every row and every square
/// of three spaces, each frame, and the tab trailed behind the hand). The row
/// only redraws when the tab actually changes place.
struct Carried: ViewModifier {
    let index: Int
    let count: Int
    /// One place in the row: the tab's length and the gap after it.
    let step: CGFloat
    let vertical: Bool
    /// The row's coordinate space, not the tab's: a tab that has just moved
    /// keeps its bearings (see the sidebar's grid).
    let space: String
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    @State private var travel: CGFloat = 0

    func body(content: Content) -> some View {
        // What it has travelled, less the ground its new place has already
        // given it.
        let shift = held ? travel - CGFloat(index - from) * step : 0
        return content
            .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
            // Under the hand exactly. Its place in the row springs when it
            // passes another tab, and the offset springs back the same way —
            // until the next move of the hand cuts the offset's spring short
            // and leaves the place's running: the tab jumped a whole slot and
            // drifted back each time it passed one. Only the others glide.
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .onChanged { value in
                        if !held {
                            held = true
                            from = index
                        }
                        travel = vertical ? value.translation.height : value.translation.width
                        let target = min(max(0, from + Int((travel / step).rounded())), count - 1)
                        if target != index {
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(Motion.settle) {
                            held = false
                            travel = 0
                        }
                    }
            )
    }
}

struct TabAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = browser.tabDraft
        context.coordinator.watch(field)
        // The site card stands under whichever field the address is in.
        SiteCardPanel.follow(browser, anchor: field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
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
        var claimed = false
        var typing = false

        init(browser: Browser) { self.browser = browser }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.tabDraft = field.stringValue
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                // Returning true keeps the field editing, which is what lets a
                // refused address stay on screen instead of being thrown away.
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.finishTabEdit() }
        }

        /// A press on something that takes no focus — the strip's empty
        /// stretch, the column below the rows — leaves the field focused and
        /// editing, so presses are watched for while it is there: one anywhere
        /// but in the field ends the edit the same way. The press itself goes
        /// on to what it was for.
        private var watcher: Any?

        @MainActor func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let browser = self.browser
                DispatchQueue.main.async { browser.finishTabEdit() }
                return event
            }
        }

        @MainActor func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn.
struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    var body: some View {
        if tab.pin == nil {
            Button("Pin") { browser.pin(tab) }
                .disabled(tab.isBlank)
        } else {
            Button("Change Letter") { browser.editLetter(tab) }
            Button("Unpin") { browser.unpin(tab) }
        }
        Divider()
        Button("Rename") { browser.beginTabRename(tab) }
        Button("Duplicate") {
            browser.select(tab)
            browser.duplicate()
        }
        .disabled(tab.isBlank || tab.native != nil)
        // The card a click on the tab you are on shows under its address.
        Button("Site Information…") {
            if browser.activeID != tab.id { browser.select(tab) }
            browser.beginTabEdit(tab)
        }
        .disabled(tab.isBlank || tab.address == nil || tab.pin != nil || tab.native != nil)
        Button("Copy Address") {
            browser.select(tab)
            browser.copyAddress()
        }
        .disabled(tab.isBlank)
        Button("Copy as Markdown Link") {
            browser.select(tab)
            browser.copyMarkdownLink()
        }
        .disabled(tab.isBlank)
        Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
            .disabled(tab.native != nil)
        // A pin is already a place kept for a page, which is all a group is —
        // for a pinned tab the group offers simply aren't there.
        if tab.pin == nil {
            Divider()
            if browser.group(for: tab) != nil {
                Button("Remove from Group") { browser.removeFromGroup(tab) }
            } else {
                Button("New Tab Group") { browser.createGroup(from: tab) }
            }
            // Every group but this tab's own — moving within a run is a no-op
            // that would only look like it did something.
            let movable = browser.orderedGroups.filter { $0.id != tab.groupID }
            if !movable.isEmpty {
                Menu("Move to Group") {
                    ForEach(movable) { group in
                        Button {
                            browser.add(tab, to: group.id)
                        } label: {
                            Label(browser.groupTitle(group), systemImage: group.symbol)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Close Tab", action: close)
        Button("Close Other Tabs") { browser.closeOthers(but: tab) }
            .disabled(browser.tabs.count < 2)
        // ⌘⇧T, and the History menu's Recently Closed, where few think to
        // look for it: here too, where tabs are closed.
        Button("Reopen Closed Tab") { browser.reopen() }
            .disabled(browser.ghosts.isEmpty)
    }
}

/// One gesture or the other, never the two together.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    func body(content: Content) -> some View {
        if double {
            content.onTapGesture(count: 2, perform: act)
        } else {
            content.onTapGesture(perform: act)
        }
    }
}

/// The middle button on a tab closes it, as it does in every other browser.
///
/// SwiftUI has no gesture for that button, so this is a real view laid over
/// the tab — and a real view is asked first (see DragStrip). It says yes for
/// the middle button and nothing else: to a left click, a drag or a right
/// click it isn't there, and the tab's own gestures and menu go on as before.
struct MiddleClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.act = act
    }

    private final class Catch: NSView {
        var act: () -> Void = {}
        private var pressed = false

        /// Asked about every event that lands on the tab, the pointer moving
        /// over it included; the one being delivered is the one to judge by.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, not the press, and only if it is still over the
        /// tab: a middle button pressed by mistake can be taken back the way
        /// a click on the cross can, by moving off before letting go.
        override func otherMouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// An almost-closed ring, turning — the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
struct Ring: View {
    var size: CGFloat = 10
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.78)
            .stroke(
                Palette.muted.opacity(0.7),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}


/// The letter of a pinned tab, typed in the square itself.
///
/// A field of its own rather than SwiftUI's, for the same reason as the address
/// in a tab: the system paints selected text as a solid block of accent colour,
/// and over a thirty-point grey square that is the loudest thing on screen.
struct PinField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, tab: tab) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = tab.pin ?? ""
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab
        if !coordinator.typing, field.stringValue != tab.pin ?? "" {
            field.stringValue = tab.pin ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // The guessed letter arrives selected, so one keystroke replaces it
            // and doing nothing keeps it.
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab
        var claimed = false
        var typing = false

        init(browser: Browser, tab: Tab) {
            self.browser = browser
            self.tab = tab
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.letter(field.stringValue, for: tab)
            // One character only, and shown as it will be worn.
            field.stringValue = tab.pin ?? ""
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endPinEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endPinEdit() }
        }
    }
}

/// A group's chip: the run's icon and name on a wash of its colour, standing
/// where the first member sits — and, while the group is folded, all the run
/// there is. A click folds the run away into the chip or brings it back; a
/// right-click answers with the group's menu. While the name is being edited
/// the field sits in the chip itself.
private struct GroupChip: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    /// Settled before layout — the same number `TabBar.chipWidth` counts, so
    /// the run's arithmetic and what is drawn can never disagree.
    let width: CGFloat

    @State private var hovering = false

    private var renaming: Bool { browser.renamingGroup == group.id }
    /// The tab on screen is one of the group's — which once the run is
    /// folded shut on it only the chip can still say, so it says it louder.
    private var live: Bool { !group.expanded && browser.groupHasActiveTab(group) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: group.symbol)
                .font(.system(size: 11, weight: .medium))
                // The slot `chipWidth` allowed for, so a wide symbol can't
                // push the chip past what the run counted.
                .frame(width: 14)
            if renaming {
                GroupNameField(browser: browser, group: group)
                    .frame(height: 16)
                    .frame(maxWidth: .infinity)
            } else {
                Text(browser.groupTitle(group))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(group.tint.strengthened)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background {
            // Folded, the chip is the whole run and keeps its pill. Open, the
            // run's bar is already beneath it — the name and icon sit on it
            // directly, and a pill of their own would only paint the colour
            // twice. The pointer still gets a breath of the colour, so the
            // label says it can be pressed.
            if !group.expanded {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(group.tint.opacity(live ? 0.38 : hovering ? 0.32 : 0.25))
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(group.tint.opacity(0.12))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // Folding is a click; while the name's field is up its presses are
        // the field's, and the padding's are nobody's.
        .onTapGesture { if !renaming { browser.toggleGroup(group.id) } }
        .overlay { GroupMenuCatch(browser: browser, group: group) }
        .onHover { hovering = $0 }
        .help("\(browser.groupTitle(group)) — \(browser.groupCount(group)) \(browser.groupCount(group) == 1 ? "tab" : "tabs")")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: live)
        // A name that changed the chip's measure takes the row's own spring,
        // the way the address field does — never a snap between one frame and
        // the next.
        .animation(Motion.glide, value: width)
        // Arriving and leaving from the strip rather than from nowhere, the
        // way the pills do.
        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
    }
}

private extension Color {
    /// The colour pressed toward ink — lowered in a light window, lifted in
    /// a dark one — far enough to read as text on a wash of itself, not so
    /// far it stops being the colour it was. The palette's entries are
    /// mid-weight so their wash reads on the window's ground; the same
    /// colour as *writing* on that wash wants more of itself.
    var strengthened: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let base = NSColor(self).usingColorSpace(.sRGB) ?? .labelColor
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let by: CGFloat = dim ? 1.35 : 0.62
            return NSColor(
                red: min(1, base.redComponent * by),
                green: min(1, base.greenComponent * by),
                blue: min(1, base.blueComponent * by),
                alpha: 1
            )
        })
    }
}

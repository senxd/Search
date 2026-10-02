import AppKit
import SwiftUI

// The Fluid Functionalism port's proving ground — mirrors the React demo
// (fluid-demo/app/page.tsx) section for section so the two galleries can
// be compared side by side. Open it from View › Fluid Gallery.

struct FluidGallery: View {
    @State private var listY = FluidHover(axis: .y)
    @State private var listX = FluidHover(axis: .x)
    @State private var listXY = FluidHover(axis: .xy)

    @State private var dialogOpen = false

    static let menu = ["Inbox", "Drafts", "Sent", "Archive", "Trash"]
    static let strip = ["Library", "Recents", "Favorites", "Settings"]
    static let grid = ["Inbox", "Drafts", "Sent", "Archive", "Trash", "Spam"]
    static let scrollRows = grid + menu + strip + [
        "Apple", "Apricot", "Banana", "Cherry", "Dragonfruit", "Fig", "Grape", "Mango",
    ]
    static let channels = ["Email", "Slack", "Calendar", "Docs"]
    static let fruits = [
        "Apple", "Apricot", "Banana", "Cherry",
        "Dragonfruit", "Fig", "Grape", "Mango",
    ]

    /// The catalog in declaration order — two cells per visual row
    /// (EmptyView pads rows with a single section). Collected once so the
    /// body can pick its container: eager `Grid` for FLUID_SHOT captures
    /// (off-screen cells must exist to be rendered), `LazyVGrid`
    /// interactively — otherwise every forever-animation in the whole
    /// 10k-pt page re-lays out the shared grid per frame.
    private var cells: [AnyView] {
        func s<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> AnyView {
            AnyView(section(title, content: content))
        }
        let all: [AnyView] = [
            s("Button — variants") { buttons },
            s("Chip — leger design") { chips },
            s("Badge — palette") { badges },
            s("Switch") { GallerySwitches() },
            s("Slider — pips") { GallerySliderSection() },
            s("Tabs") { GalleryTabs() },
            s("Tabs subtle") { GalleryTabsSubtle() },
            s("Dropdown") { GalleryDropdown() },
            s("Dialog") {
                FluidButton("Open dialog", variant: .secondary) { dialogOpen = true }
            },
            s("Combobox — single") { GalleryComboboxSingle() },
            s("Combobox — chips") { GalleryComboboxChips() },
            s("Select") { GallerySelect() },
            s("Tooltip") { GalleryTooltip() },
            s("Accordion") { GalleryAccordion() },
            s("Input group") { inputGroup },
            s("Card") { card },
            s("Card group") { cardGroup },
            s("Card — parts") { cardParts },
            s("Table") { table },
            s("Chat") { chat },
            s("Command menu") { GalleryCommandMenu() },
            s("Color picker") { GalleryColorPicker() },
            s("Thinking") {
                VStack(alignment: .leading) {
                    FluidThinkingIndicator()
                    FluidThinkingIndicator(showIcon: false)
                }
            },
            AnyView(EmptyView()),
            s("Checkbox group") { GalleryChecks() },
            s("Radio group") { GalleryRadios() },
            s("Input message") { GalleryComposer() },
            AnyView(EmptyView()),
            s("Ask user questions") {
                FluidAskUserQuestions(questions: [
                    FluidAskQuestion(
                        title: "Which tabs should I close?",
                        options: [
                            FluidAskOption(title: "Duplicates",
                                           description: "Same URL open twice"),
                            FluidAskOption(title: "Oldest",
                                           description: "Not touched in a week"),
                            FluidAskOption(title: "Reading queue",
                                           description: "Already saved"),
                        ],
                        allowOther: true
                    ),
                    FluidAskQuestion(
                        title: "Then what?",
                        options: [
                            FluidAskOption(title: "Summarize"),
                            FluidAskOption(title: "Bookmark"),
                            FluidAskOption(title: "Snooze"),
                        ],
                        multiSelect: true
                    ),
                ], embedded: true,
                   onComplete: { answers in
                       FileHandle.standardError.write(
                           "FLUID_ASK complete: \(answers.mapValues { "\($0.selectedIds)|\($0.otherText ?? "-")" })\n"
                               .data(using: .utf8)!)
                   })
                .frame(width: 420)
            },
            AnyView(EmptyView()),
            s("Sidebar") { GallerySidebar() },
            AnyView(EmptyView()),
            s("Scroll area") { scrollArea },
            s("Input copy") {
                VStack(alignment: .leading) {
                    FluidInputCopy(value: "sk-fluid-a1b2c3d4e5f6a7b8c9d0", label: "API key")
                    FluidInputCopy(
                        value: "https://officecommun.com/search",
                        variant: .button
                    )
                }
                .frame(width: 288)
            },
            s("Dropdown search") { GalleryDropdownSearch() },
            s("Thinking steps") { thinkingSteps },
            s("Fluid hover — axis y") { hoverY },
            s("Fluid hover — axis x") { hoverX },
            s("Fluid hover — axis xy") { hoverXY },
            AnyView(EmptyView()),
        ]
        return all
    }

    var body: some View {
        let env = ProcessInfo.processInfo.environment
        // FLUID_CELL=94 — bypass the whole shell: measures the bare window.
        if env["FLUID_CELL"] == "94" {
            return AnyView(Text("probe").padding(40))
        }
        // FLUID_ASK=1 — just the embedded AskUser cell, on-screen for the
        // askprobe event drive. (cells[28] — keep in step with `cells`.)
        var cells = env["FLUID_ASK"] == "1" ? [cells[28]] : cells
        // FLUID_CELL=20,33 — keep just the listed cell indexes (profiling
        // bisect). FLUID_CELL=99 — a bare Text, to measure shell cost
        // with no component content.
        if let filter = env["FLUID_CELL"] {
            if filter == "99" {
                cells = [AnyView(Text("probe"))]
            } else if filter == "98" {
                cells = [AnyView(Text("probe").padding(20).fluidSurface(2, radius: 12))]
            } else if filter == "97" {
                cells = [AnyView(FluidCard { Text("probe").padding(12) })]
            } else if filter == "96" {
                cells = [AnyView(FluidCard(dismissible: true, onDismiss: {}) { Text("probe").padding(12) })]
            } else {
                let keep = Set(filter.split(separator: ",").compactMap { Int($0) })
                cells = cells.enumerated().filter { keep.contains($0.offset) }.map(\.element)
            }
        }
        return AnyView(ScrollView {
            // Eager Grid for both shot and interactive — LazyVGrid used to
            // dodge per-frame re-layout from the animating cells, but those
            // are Core Animation now; the lazy variant popped cells in while
            // scrolling, unlike the reference page's plain render.
            Grid(alignment: .topLeading, horizontalSpacing: 40, verticalSpacing: 40) {
                ForEach(0..<(cells.count + 1) / 2, id: \.self) { r in
                    GridRow {
                        cells[2 * r]
                        if 2 * r + 1 < cells.count { cells[2 * r + 1] }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
            .background(FluidTone.background)
        }
        .frame(minWidth: 1080, minHeight: 620)
        .background(FluidTone.background)
        .foregroundStyle(FluidTone.foreground)
        .fluidDialog(isPresented: $dialogOpen, size: .sm) {
            VStack(alignment: .leading, spacing: 0) {
                FluidDialogHeader {
                    FluidDialogTitle("Delete draft?")
                    FluidDialogDescription("This removes the draft permanently. There is no undo.")
                }
                FluidDialogFooter {
                    FluidButton("Cancel", variant: .tertiary) { dialogOpen = false }
                    FluidButton("Delete") { dialogOpen = false }
                }
            }
        }
        .onAppear(perform: probe)
        .background(FluidGalleryWindowHook())
        )
    }

    // MARK: - Sections

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FluidButton("Primary") {}
                FluidButton("Secondary", variant: .secondary) {}
                FluidButton("Tertiary", variant: .tertiary) {}
                FluidButton("Ghost", variant: .ghost) {}
            }
            HStack(spacing: 8) {
                FluidButton("Compact", size: .compact) {}
                FluidButton("With icon", leadingIcon: "plus") {}
                FluidButton(size: .icon, action: {}) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .light))
                }
                FluidButton("Loading", loading: true) {}
                FluidButton("Disabled", variant: .tertiary) {}.disabled(true)
            }
        }
    }

    private var badges: some View {
        // The registry badge's full 17-hue palette in both variants —
        // wraps in the cell; chip stays the leger-web design above.
        FlowLayoutBadges()
    }

/// Badge palette cell — 17 hues × solid + dot, split into fixed rows.
private struct FlowLayoutBadges: View {
    private let cols = Array(FluidBadgeColor.allCases.enumerated())
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(cols.prefix(9), id: \.element) { _, c in
                    FluidBadge(c.rawValue.capitalized, color: c)
                }
            }
            HStack(spacing: 6) {
                ForEach(cols.dropFirst(9), id: \.element) { _, c in
                    FluidBadge(c.rawValue.capitalized, color: c)
                }
            }
            HStack(spacing: 6) {
                ForEach(cols.prefix(9), id: \.element) { _, c in
                    FluidBadge(c.rawValue.capitalized, variant: .dot, color: c)
                }
            }
            HStack(spacing: 6) {
                ForEach(cols.dropFirst(9), id: \.element) { _, c in
                    FluidBadge(c.rawValue.capitalized, variant: .dot, color: c)
                }
            }
        }
    }
}

    private var chips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FluidChip("Neutral")
                FluidChip("Blue", color: .blue)
                FluidChip("Green", color: .green)
                FluidChip("Amber", color: .amber)
                FluidChip("Violet", color: .violet)
                FluidChip("Red", color: .red)
            }
            HStack(spacing: 8) {
                FluidChip("Small", color: .blue, size: .sm)
                FluidChip("Large", color: .green, size: .lg)
            }
        }
    }

    @State private var cardDismissed = false

    private var card: some View {
        Group {
            if !cardDismissed {
                FluidCard(dismissible: true, onDismiss: { cardDismissed = true }) {
                    FluidCardHeader {
                        FluidCardTitle("Quarterly report")
                        FluidCardDescription("Revenue grew 12% in Q3.")
                    }
                    FluidCardContent {
                        Text("Card body content sits here.")
                            .font(.system(size: 13))
                            .foregroundStyle(FluidTone.mutedForeground)
                    }
                }
            }
        }
        .frame(width: 288, alignment: .topLeading)
        .frame(minHeight: 96, alignment: .topLeading)
    }

    private var cardGroup: some View {
        FluidCardGroup(orientation: .inline, outlined: true, count: 3) {
            ForEach(0..<3, id: \.self) { i in
                FluidCard(index: i, onClick: {}) {
                    FluidCardHeader {
                        FluidCardTitle(Self.menu[i])
                        FluidCardDescription(["12 files", "3 unread", "Updated today"][i])
                    }
                }
            }
        }
        .frame(width: 288)
    }

    /// Exercises the newer card parts: eyebrow/media/feature/footer/
    /// buttons/action slot on a stacked card, plus an inline card with a
    /// leading image (the media-bleed rewrap) and a wrapped footer.
    private var cardParts: some View {
        VStack(alignment: .leading, spacing: 12) {
            FluidCard {
                FluidCardMedia(icon: "chart.bar.fill")
                FluidCardHeader(action: {
                    FluidCardAction {
                        FluidCardButton(variant: .ghost, icon: "ellipsis") {}
                    }
                }) {
                    FluidCardEyebrow("Analytics")
                    FluidCardTitle("Quarterly report")
                    FluidCardDescription("Revenue grew 12% in Q3.")
                }
                FluidCardContent {
                    FluidCardFeature(icon: "arrow.up.right",
                                     title: "Renewals",
                                     description: "Drove most of the growth")
                }
                FluidCardFooter {
                    FluidCardButton("Open", variant: .secondary) {}
                    FluidCardButton("Share", variant: .link,
                                    icon: "arrow.up.right", external: true) {}
                }
            }
            FluidCardGroup(orientation: .inline, outlined: true, count: 1) {
                FluidCard(index: 0, onClick: {}) {
                    FluidCardImage(Self.demoImage())
                    FluidCardHeader {
                        FluidCardTitle("Design review")
                        FluidCardDescription("2pm with the team")
                    }
                    FluidCardFooter {
                        FluidCardButton("Join", variant: .primary) {}
                    }
                }
            }
        }
        .frame(width: 288, alignment: .topLeading)
    }

    /// A small generated gradient so the inline-image path has real
    /// pixels to rewrap around (160² tile).
    private static func demoImage() -> Image {
        let img = NSImage(size: NSSize(width: 160, height: 90))
        img.lockFocus()
        NSGradient(colors: [
            NSColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1),
            NSColor(red: 0.60, green: 0.30, blue: 0.90, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: img.size), angle: -35)
        img.unlockFocus()
        return Image(nsImage: img)
    }

    private var chat: some View {
        VStack(spacing: 12) {
            FluidChatMessage(from: .user, time: "2:41 PM") {
                Text("Summarize the quarterly report")
            }
            FluidChatMessage(from: .assistant) {
                Text("Revenue grew 12% in Q3, driven mostly by renewals.")
            }
            FluidChatMessage(from: .user, time: "2:44 PM",
                             files: [URL(fileURLWithPath: "/tmp/quarterly-report.pdf")]) {
                Text("Here's the source file")
            }
        }
        .frame(width: 288)
    }

    private var table: some View {
        FluidTable {
            FluidTableRow {
                FluidTableCell("Name")
                FluidTableCell("Status", width: 80)
            }
            ForEach(0..<3, id: \.self) { i in
                FluidTableRow(index: i) {
                    FluidTableCell(["Report.pdf", "Notes.md", "Archive.zip"][i])
                    FluidTableCell(["Synced", "Draft", "Synced"][i], width: 80)
                }
            }
        }
        .frame(width: 288)
    }

    private var inputGroup: some View {
        FluidInputGroup {
            FluidInput(label: "Name", text: .constant("Ada Lovelace"), index: 0)
            FluidInput(label: "Search", text: .constant(""), placeholder: "Search…", icon: "magnifyingglass", index: 1)
            FluidInput(label: "API key", text: .constant("sk-deadbeef"), error: "Key rejected", index: 2)
        }
        .frame(width: 288)
    }

    private var scrollArea: some View {
        FluidScrollArea {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.scrollRows.enumerated()), id: \.offset) { i, label in
                    row(label).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(4)
        }
        .frame(width: 288, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FluidShape.rounded.container, style: .continuous)
                .strokeBorder(FluidTone.border, lineWidth: 1)
        )
    }

    private var thinkingSteps: some View {
        FluidThinkingSteps {
            FluidThinkingStepsHeader("Thinking")
            FluidThinkingStepsContent {
                FluidThinkingStep(
                    label: "Read the registry docs", icon: "book",
                    description: "Tokens, springs, and the hover model",
                    status: .complete
                )
                FluidThinkingStep(
                    label: "Draft the SwiftUI port", icon: "pencil",
                    description: "Components land one at a time",
                    status: .active
                )
                FluidThinkingStep(
                    label: "Verify side by side", status: .complete, isLast: true
                ) {
                    FluidThinkingStepSources(sources: [
                        ("fluidfunctionalism.com", .blue),
                        ("leger.-web", .gray),
                    ])
                }
            }
        }
    }

    private var hoverY: some View {
        FluidContainer(hover: listY, radius: FluidShape.rounded.bg) {
            VStack(spacing: 0) {
                ForEach(Array(Self.menu.enumerated()), id: \.offset) { i, label in
                    row(label).frame(maxWidth: .infinity, alignment: .leading).fluidItem(i)
                }
            }
            .frame(width: 224)
            .padding(4)
        }
    }

    private var hoverX: some View {
        FluidContainer(hover: listX, radius: FluidShape.rounded.bg) {
            HStack(spacing: 0) {
                ForEach(Array(Self.strip.enumerated()), id: \.offset) { i, label in
                    row(label).fixedSize().fluidItem(i)
                }
            }
            .padding(4)
        }
    }

    private var hoverXY: some View {
        FluidContainer(hover: listXY, radius: FluidShape.rounded.bg) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        ForEach(0..<2, id: \.self) { c in
                            row(Self.grid[r * 2 + c])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fluidItem(r * 2 + c)
                        }
                    }
                }
            }
            .frame(width: 340)
            .padding(4)
        }
    }

    // MARK: - headless verification
    //
    // FLUID_SHOT=/tmp/x.png  — the window renders its own content to PNG once
    //                          laid out (no Screen Recording needed: it's our
    //                          own view).
    // FLUID_HOVER=y:40,80    — before the shot, feed the point to that axis's
    //                          container as if the cursor had arrived: pick,
    //                          highlight, and spring all run for real.
    private func probe() {
        let env = ProcessInfo.processInfo.environment
        let shot = env["FLUID_SHOT"]
        guard shot != nil || env["FLUID_ASKPROBE"] == "1" || env["FLUID_PICKPROBE"] == "1"
            || env["FLUID_DROPPROBE"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            // FLUID_DARK is applied in App.swift before the window opens —
            // appearance changes after first render don't reach baked colors
            // in off-screen doc captures.
            if let h = env["FLUID_H"], let height = Double(h),
               let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }) {
                var f = window.frame
                f.size.height = height
                f.origin.y -= height - window.frame.height
                window.setFrame(f, display: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if let typeString = env["FLUID_TYPE"],
               let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }),
               let tv = Self.findTextView(in: window.contentView) {
                // Route real text entry through the text view — insertText
                // runs the same textDidChange → binding → updateNSView
                // path as typed keys.
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(tv)
                FileHandle.standardError.write("FLUID_TYPE focus: fr=\(type(of: window.firstResponder))\n".data(using: .utf8)!)
                for ch in typeString {
                    tv.insertText(String(ch))
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    FileHandle.standardError.write("FLUID_TYPE '\(ch)': fr=\(type(of: window.firstResponder)) sel=\(tv.selectedRange()) str=\(tv.string.debugDescription)\n".data(using: .utf8)!)
                }
            }
            if env["FLUID_DIALOG"] == "1", let shot {
                dialogOpen = true
                try? await Task.sleep(nanoseconds: 700_000_000)
                // The dialog overlays the window view, not the scroll doc —
                // capture the window's own bounds for this one.
                Self.snapshotGallery(to: shot, windowOnly: true)
                return
            }
            if env["FLUID_ASKPROBE"] == "1" {
                await askProbe()
                return
            }
            if env["FLUID_PICKPROBE"] == "1" {
                await pickProbe()
                return
            }
            if env["FLUID_DROPPROBE"] == "1" {
                await dropProbe()
                return
            }
            // FLUID_ANIMPROBE — read the CA presentation values of the
            // layer-hosted animators twice: moving values prove the loops
            // run render-server-side (snapshots only see model state).
            if env["FLUID_ANIMPROBE"] == "1",
               let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }),
               let cv = window.contentView {
                func layers(_ v: NSView) -> [CALayer] {
                    var out: [CALayer] = []
                    if let l = v.layer { out.append(l) }
                    out += v.subviews.flatMap(layers)
                    return out
                }
                func sublayers(_ l: CALayer) -> [CALayer] {
                    [l] + (l.sublayers ?? []).flatMap(sublayers)
                }
                let all = layers(cv).flatMap(sublayers)
                func read() -> String {
                    var parts: [String] = []
                    for l in all {
                        if l is CAShapeLayer {
                            let p = l.presentation() as? CAShapeLayer
                            parts.append("shape start=\(p?.strokeStart ?? -1) end=\(p?.strokeEnd ?? -1)")
                        }
                        if l is CAGradientLayer {
                            let tx = l.presentation()?.affineTransform().tx ?? 0
                            parts.append("grad tx=\(tx)")
                        }
                    }
                    return parts.joined(separator: " | ")
                }
                FileHandle.standardError.write("ANIM t0: \(read())\n".data(using: .utf8)!)
                try? await Task.sleep(nanoseconds: 400_000_000)
                FileHandle.standardError.write("ANIM t1: \(read())\n".data(using: .utf8)!)
                try? await Task.sleep(nanoseconds: 400_000_000)
                FileHandle.standardError.write("ANIM t2: \(read())\n".data(using: .utf8)!)
            }
            if let probe = env["FLUID_HOVER"] {
                let parts = probe.split(separator: ":")
                let xy = parts.count > 1
                    ? parts[1].split(separator: ",").compactMap { Double($0) }
                    : []
                if xy.count == 2 {
                    let p = CGPoint(x: xy[0], y: xy[1])
                    switch parts[0] {
                    case "x": listX.moved(to: p)
                    case "xy": listXY.moved(to: p)
                    default: listY.moved(to: p)
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if let shot { Self.snapshotGallery(to: shot) }
        }
    }

    /// FLUID_ASKPROBE=1 — drive the embedded AskUser with real events posted
    /// to our own pid (HID posting needs no permissions): click the title
    /// band to arm the card, digit '2' selects Q1's "Oldest" and advances,
    /// '2' toggles Q2's "Bookmark", ⌘↵ completes. Snapshots each step.
    private func askProbe() async {
        guard let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }),
              let cv = window.contentView,
              let probe = Self.findProbeView(in: cv) else {
            FileHandle.standardError.write("FLUID_ASKPROBE: no card\n".data(using: .utf8)!)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        var card = probe.superview ?? probe
        while card.bounds.size == .zero, let next = card.superview { card = next }
        let wr = card.convert(card.bounds, to: nil)
        // Synthetic events through sendEvent — local monitors see these on
        // the same dispatch path as real input.
        let top = cv.isFlipped ? wr.minY + 18 : wr.maxY - 18
        let title = CGPoint(x: wr.midX, y: top)
        func click(_ pt: CGPoint) {
            let t = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: pt,
                        modifierFlags: [], timestamp: t,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(e)
                }
            }
        }
        func key(_ code: UInt16, _ ch: String, _ flags: NSEvent.ModifierFlags = []) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: ch, charactersIgnoringModifiers: ch,
                    isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
        FileHandle.standardError.write(
            "FLUID_ASKPROBE card rect \(wr) flipped=\(cv.isFlipped)\n".data(using: .utf8)!)
        click(title)
        try? await Task.sleep(nanoseconds: 300_000_000)
        key(0x1D, "2")                                  // '2' → Oldest → advance
        try? await Task.sleep(nanoseconds: 500_000_000)
        Self.snapshotGallery(to: "/tmp/ask-a.png")

        // Editor path — click the composer's text view directly, then '3'
        // must type into it (fieldFocused), not toggle the third option.
        if let tv = Self.findTextView(in: cv) {
            let tr = tv.convert(tv.bounds, to: nil)
            // A real mouseDown on a non-key window activates it first —
            // synthetic sendEvent skips that. Activate, let it post, then
            // click; if first responder still isn't the text view, do the
            // responder move the real click would have done.
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 150_000_000)
            window.makeKeyAndOrderFront(nil)
            click(CGPoint(x: tr.midX, y: tr.midY))
            if window.firstResponder !== tv { window.makeFirstResponder(tv) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        key(0x1E, "3")
        try? await Task.sleep(nanoseconds: 300_000_000)
        Self.snapshotGallery(to: "/tmp/ask-b.png")

        // Outside click disarms — a following '2' must not toggle.
        click(CGPoint(x: wr.maxX + 200, y: wr.midY))
        try? await Task.sleep(nanoseconds: 300_000_000)
        key(0x1D, "2")
        try? await Task.sleep(nanoseconds: 300_000_000)
        Self.snapshotGallery(to: "/tmp/ask-c.png")

        // Re-arm on the title, '2' toggles Bookmark, ⌘↵ completes.
        click(title)
        try? await Task.sleep(nanoseconds: 300_000_000)
        key(0x1D, "2")
        try? await Task.sleep(nanoseconds: 400_000_000)
        Self.snapshotGallery(to: "/tmp/ask-d.png")
        key(0x24, "\r", .command)                       // ⌘↵ → complete
        try? await Task.sleep(nanoseconds: 400_000_000)
        Self.snapshotGallery(to: "/tmp/ask-e.png")
        FileHandle.standardError.write("FLUID_ASKPROBE done\n".data(using: .utf8)!)
    }

    /// FLUID_DROPPROBE=1 — click the first popup anchor ("Actions" in the
    /// Dropdown cell) and log every window's frame at key intervals, so a
    /// mis-placed or late-corrected panel is visible in the numbers.
    private func dropProbe() async {
        guard let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }),
              let cv = window.contentView else {
            FileHandle.standardError.write("FLUID_DROPPROBE: no window\n".data(using: .utf8)!)
            return
        }
        window.makeKeyAndOrderFront(nil)
        // Plain activate() doesn't key the window when the binary was
        // launched from a shell — the app has to actually take focus.
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        window.makeKeyAndOrderFront(nil)
        func findAnchor(_ v: NSView) -> NSView? {
            if v is FluidAnchorResolver.AnchorView { return v }
            for s in v.subviews { if let f = findAnchor(s) { return f } }
            return nil
        }
        guard let anchor = findAnchor(cv) else {
            FileHandle.standardError.write("FLUID_DROPPROBE: no anchor\n".data(using: .utf8)!)
            return
        }
        let ar = anchor.convert(anchor.bounds, to: nil)
        FileHandle.standardError.write(
            "DROP anchor winrect=\(ar) winframe=\(window.frame)\n".data(using: .utf8)!)
        func dump(_ tag: String) {
            for w in NSApp.windows {
                FileHandle.standardError.write(
                    "DROP \(tag) win[\(w.windowNumber)] \(w.isKeyWindow ? "key " : "")\(w.title.prefix(20)) frame=\(w.frame)\n".data(using: .utf8)!)
            }
        }
        dump("pre")
        let t = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: ar.midX, y: ar.midY),
                    modifierFlags: [], timestamp: t,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.sendEvent(e)
            }
        }
        for ms in [60, 200, 500] {
            try? await Task.sleep(nanoseconds: UInt64(ms == 60 ? 60 : ms - 200) * 1_000_000)
            dump("t+\(ms)ms")
            if let panel = window.childWindows?.first, let cvp = panel.contentView {
                Self.shotWindowContent(cvp, to: "/tmp/drop-t\(ms).png")
                func walk(_ v: NSView, _ d: Int) {
                    FileHandle.standardError.write(
                        "DROPVIEW t\(ms) \(String(repeating: " ", count: d))\(type(of: v)) f=\(v.frame)\n".data(using: .utf8)!)
                    v.subviews.forEach { walk($0, d + 1) }
                }
                if ms == 60 || ms == 200 { walk(cvp, 0) }
            }
        }
        Self.snapshotGallery(to: "/tmp/drop-open.png", windowOnly: true)

        // FLUID_SUBPROBE=1 — keyboard-drive into the first submenu row:
        // ↓ through the rows to "Export", then → opens the sub (Radix
        // SUB_OPEN_KEYS). Dumps + captures the sub panel — the audit
        // found subs pinned screen-tall; this verifies the fix.
        if ProcessInfo.processInfo.environment["FLUID_SUBPROBE"] == "1" {
            // Wait for the env-seeded popup to actually present (the
            // modifier opens it ~1.5s in, post-layout).
            var waited = 0
            while waited < 40,
                  !(window.childWindows ?? []).contains(where: {
                      String(describing: type(of: $0)).contains("PopupPanel")
                          && $0.frame.width > 0
                  }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            dump("open")
            // Keys must not be headed for a text field — navKey yields
            // to NSTextView responders (field parity). Take it back.
            window.makeFirstResponder(window.contentView)
            func key(_ code: UInt16) {
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(e)
                }
            }
            // Focus seeds at the checked row (index 1); navOrder is
            // [0,1,2,3,7,4,6] (5 disabled) — ↓×3 lands on "Export" (7).
            for _ in 0..<3 {
                key(125) // ↓
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            key(124) // → opens the submenu row
            try? await Task.sleep(nanoseconds: 400_000_000)
            dump("sub")
            if let sub = window.childWindows?.last,
               let subPanel = sub.childWindows?.first ?? (sub != window.childWindows?.first ? sub : nil) {
                Self.shotWindowContent(subPanel.contentView!, to: "/tmp/drop-sub.png")
            }
            // ↑ inside the sub must move within it, not the parent.
            key(126)
            try? await Task.sleep(nanoseconds: 150_000_000)
            dump("sub-up")
            // Return on a sub row must run the row's own onSelect path —
            // the menu dismiss env closes the panels (visible in dumps).
            key(36)
            try? await Task.sleep(nanoseconds: 500_000_000)
            dump("ret")
            Self.snapshotGallery(to: "/tmp/drop-subopen.png", windowOnly: true)
        }
        FileHandle.standardError.write("FLUID_DROPPROBE done\n".data(using: .utf8)!)
    }

    /// FLUID_PICKPROBE=1 — drag inside the saturation square (FLUID_CELL=19)
    /// with real events; GalleryColorPicker logs each emitted hex so the
    /// drag's tracking is visible on stderr.
    private func pickProbe() async {
        guard let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }),
              let cv = window.contentView else {
            FileHandle.standardError.write("FLUID_PICKPROBE: no window\n".data(using: .utf8)!)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Did the posted events reach our event queue at all?
        let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { e in
            FileHandle.standardError.write("PP evt \(e.type.rawValue) win=\(e.locationInWindow)\n".data(using: .utf8)!)
            return e
        }
        // Locate the square view directly — no layout guessing.
        func findSquare(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)).contains("FluidSaturationView") { return v }
            for s in v.subviews { if let f = findSquare(s) { return f } }
            return nil
        }
        guard let sq = findSquare(cv) else {
            FileHandle.standardError.write("FLUID_PICKPROBE: no square view\n".data(using: .utf8)!)
            return
        }
        let sr = sq.convert(sq.bounds, to: nil)  // window coords
        FileHandle.standardError.write(
            "PP winframe=\(window.frame) square=\(sr)\n".data(using: .utf8)!)
        // postEvent enqueues without dispatching — the square's modal drag
        // loop dequeues them via nextEvent. sendEvent would deadlock (the
        // loop owns the main thread until mouseUp).
        func send(_ type: NSEvent.EventType, _ pt: CGPoint) {
            if let e = NSEvent.mouseEvent(with: type, location: pt,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        let cx = sr.midX, cy = sr.midY
        // All queued up front — once the down dispatches, the modal loop
        // owns the main thread and a sleeping Task would never wake to
        // post the drags.
        send(.leftMouseDown, CGPoint(x: cx, y: cy))
        for pt in [CGPoint(x: cx - 30, y: cy + 25), CGPoint(x: cx - 60, y: cy + 45),
                   CGPoint(x: sr.maxX - 10, y: sr.minY + 20), CGPoint(x: cx + 30, y: cy - 15)] {
            send(.leftMouseDragged, pt)
        }
        send(.leftMouseUp, CGPoint(x: cx + 30, y: cy - 15))
        try? await Task.sleep(nanoseconds: 300_000_000)
        Self.snapshotGallery(to: "/tmp/pick-after.png")
        if let monitor { NSEvent.removeMonitor(monitor) }
        FileHandle.standardError.write("FLUID_PICKPROBE done\n".data(using: .utf8)!)
    }

    private static func findProbeView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("FluidKeyProbeView") { return view }
        for sub in view.subviews { if let v = findProbeView(in: sub) { return v } }
        return nil
    }

    /// The gallery's own window contents, as a PNG — no permission prompts.
    static func snapshotGallery(to path: String, windowOnly: Bool = false) {
        guard let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }),
              let view = window.contentView else {
            FileHandle.standardError.write("FLUID_SHOT: no gallery window\n".data(using: .utf8)!)
            return
        }
        // If the content scrolls past the window, capture the whole
        // document — cacheDisplay renders off-screen bounds too.
        var target = view
        if !windowOnly, let scroll = findScrollView(in: view),
           let doc = scroll.documentView, doc.bounds.height > view.bounds.height {
            target = doc
        }
        shotWindowContent(target, to: path)

        // Popups render in child panels — capture each beside the main shot.
        shotChildWindows(of: window, stem: (path as NSString).deletingPathExtension)
    }

    /// The live window's own view tree, cacheDisplay'd — for overlays like
    /// the dialog that only exist in the running window.
    private static func shotWindowContent(_ view: NSView, to path: String) {
        let bounds = view.bounds
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    private static func shotChildWindows(of window: NSWindow, stem: String) {
        for (i, child) in (window.childWindows ?? []).enumerated() {
            guard let cv = child.contentView else { continue }
            cv.layoutSubtreeIfNeeded()
            guard let cr = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { continue }
            cr.size = cv.bounds.size
            cv.cacheDisplay(in: cv.bounds, to: cr)
            try? cr.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(stem)-popup\(i).png"))
        }
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    static func findTextView(in view: NSView?) -> FluidTextView? {
        guard let view else { return nil }
        if let tv = view as? FluidTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    private func row(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13))
            .foregroundStyle(FluidTone.foreground)
            .frame(height: 36, alignment: .leading)
            .padding(.horizontal, 12)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FluidTone.mutedForeground)
                .tracking(0.6)
            content()
        }
    }
}

// MARK: - Section children
//
// Every interactive section owns its @State so a keystroke, drag, or pick
// only re-renders that child — the root body never reads these bindings,
// which keeps pointer-rate updates off the 10k-pt Grid.

private struct GallerySwitches: View {
    @State private var checked = true
    @State private var checked2 = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FluidSwitch(isOn: $checked, label: "Wi-Fi")
            FluidSwitch(isOn: $checked2, label: "Bluetooth")
            FluidSwitch(isOn: .constant(true), label: "Disabled", isDisabled: true)
        }
    }
}

private struct GallerySliderSection: View {
    @State private var slider = 40.0
    @State private var scrub = 35.0
    @State private var rangePair = (20.0, 70.0)
    @State private var stepped = 2.0
    @State private var tipped = 55.0
    @State private var dotted = 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FluidSlider(value: $slider, label: "Volume")
            FluidSlider(value: $scrub, label: "Scrub", variant: .scrubber)
            FluidSlider(value: $rangePair, label: "Range", showValue: true)
            FluidSlider(value: $stepped, steps: [0, 1, 2, 3, 4], label: "Steps",
                        showValue: true, valuePosition: .right)
            FluidSlider(value: $tipped, label: "Tooltip",
                        showValue: true, valuePosition: .tooltip)
            FluidSlider(value: $dotted, label: "Marked", showSteps: true,
                        showValue: true, valuePosition: .bottom)
        }
        .frame(width: 288)
    }
}

private struct GalleryTabs: View {
    @State private var tab = 0

    var body: some View {
        FluidTabs(items: FluidGallery.strip, selection: $tab)
        Text("\(FluidGallery.strip[tab]) panel.")
            .font(.system(size: 13))
            .foregroundStyle(FluidTone.mutedForeground)
    }
}

private struct GalleryTabsSubtle: View {
    @State private var subtleTab = 0

    var body: some View {
        FluidTabsSubtle(
            items: [(icon: "person", label: "Profile"), (icon: "gearshape", label: "Settings")],
            selection: $subtleTab
        )
    }
}

private struct GalleryDropdown: View {
    @State private var menuChecked = 1
    /// FLUID_MENUOPEN=1 opens the popup shortly after launch so headless
    /// probes can drive it with synthetic key events (the click path
    /// can't toggle a binding, and the off-screen cell can't take
    /// pointer events). Deferred — present-at-init lands before the
    /// window has a screen and parks off-frame.
    @State private var menuOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FluidButton("Actions", variant: .secondary) { menuOpen.toggle() }
                .fluidMenuPopup(isPresented: $menuOpen, disabledIndices: [5]) {
                    menuRows
                }
                .task {
                    guard ProcessInfo.processInfo.environment["FLUID_MENUOPEN"] == "1"
                    else { return }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    menuOpen = true
                }
            FluidMenuPanel(
                disabledIndices: [5],
                onPick: { i in if i == 2 || i == 3 { menuChecked = i } }
            ) {
                menuRows
            }
        }
    }

    @ViewBuilder
    private var menuRows: some View {
        FluidMenuLabel("File")
        FluidMenuItem(index: 0, icon: "pencil", label: "Rename")
        FluidMenuItem(index: 1, icon: "doc.on.doc", label: "Duplicate")
        FluidMenuSeparator()
        FluidMenuLabel("View")
        FluidMenuItem(index: 2, label: "Compact", checked: menuChecked == 2) {
            menuChecked = 2
        }
        FluidMenuItem(index: 3, label: "Comfortable", checked: menuChecked == 3) {
            menuChecked = 3
        }
        FluidMenuSeparator()
        FluidSubmenu(index: 7, icon: "square.and.arrow.up", label: "Export") {
            FluidMenuItem(index: 0, icon: "doc", label: "PDF")
            FluidMenuItem(index: 1, icon: "doc.plaintext", label: "Markdown")
            FluidMenuItem(index: 2, icon: "photo", label: "PNG")
        }
        FluidMenuItem(index: 4, icon: "gearshape", label: "Settings")
        FluidMenuItem(index: 5, icon: "trash", label: "Delete", disabled: true)
        FluidMenuItem(index: 6, icon: "rectangle.portrait.and.arrow.right", label: "Log out")
    }

}

private struct GalleryComboboxSingle: View {
    @State private var fruit: FluidComboboxModel
    @FocusState private var fruitFocus: Bool

    init() {
        let m = FluidComboboxModel(items: FluidGallery.fruits)
        // FLUID_OPEN mounts the list for screenshots/probes.
        if ProcessInfo.processInfo.environment["FLUID_OPEN"] != nil {
            m.open = true
        }
        _fruit = State(initialValue: m)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FluidComboboxField(
                model: fruit, icon: "magnifyingglass",
                placeholder: "Pick a fruit", clearable: true,
                focused: $fruitFocus
            )
            FluidComboboxList(model: fruit, emptyText: "No fruit found")
        }
        .frame(maxWidth: 400, alignment: .leading)
    }
}

private struct GalleryComboboxChips: View {
    @State private var picked: FluidComboboxModel
    @FocusState private var pickedFocus: Bool

    init() {
        let m = FluidComboboxModel(items: FluidGallery.fruits)
        m.hideSelected = true
        m.values = ["Apple", "Cherry"]
        if ProcessInfo.processInfo.environment["FLUID_OPEN"] != nil {
            m.open = true
        }
        _picked = State(initialValue: m)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FluidComboboxField(
                model: picked, multiple: true, icon: "magnifyingglass",
                placeholder: "Add fruits", clearable: true,
                focused: $pickedFocus
            )
            FluidComboboxList(model: picked, multiple: true, emptyText: "No fruit found")
        }
        .frame(maxWidth: 400, alignment: .leading)
    }
}

private struct GallerySelect: View {
    @State private var mode: String? = "balanced"

    var body: some View {
        FluidSelect(selection: $mode, placeholder: "Choose a mode") {
            FluidMenuLabel("Modes")
            FluidSelectItem(index: 0, value: "fast", label: "Fast")
            FluidSelectItem(index: 1, value: "balanced", label: "Balanced")
            FluidSelectItem(index: 2, value: "quiet", label: "Quiet")
        }
    }
}

private struct GalleryTooltip: View {
    var body: some View {
        HStack(spacing: 8) {
            FluidButton(variant: .secondary, size: .icon, action: {}) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .light))
            }
            .fluidTooltip("Copy to clipboard")
            FluidButton("Hover me", variant: .tertiary) {}
                .fluidTooltip("Open settings", side: .right)
        }
    }
}

private struct GalleryAccordion: View {
    @State private var accOpen: Set<String> = ["one"]

    var body: some View {
        FluidAccordion(open: $accOpen, single: true) {
            FluidAccordionItem(index: 0, value: "one") {
                Text("What is fluid hover?")
            } panel: {
                Text("A highlight that follows your cursor to the nearest item.")
            }
            FluidAccordionItem(index: 1, value: "two") {
                Text("Spring physics?")
            } panel: {
                Text("Every state change is a spring, not a tween.")
            }
        }
        .frame(width: 288)
    }
}

private struct GalleryCommandMenu: View {
    @State private var cmdQuery = ""

    private static let commands: [FluidCommandItem] = [
        .init("new-tab", label: "New Tab", icon: "plus.square", shortcut: "mod+t"),
        .init("new-window", label: "New Window", icon: "macwindow", shortcut: "mod+n"),
        .init("close-tab", label: "Close Tab", icon: "xmark.square", shortcut: "mod+w"),
        .init("history", label: "Show History", description: "All visited pages", icon: "clock", shortcut: "mod+y", group: "Go to"),
        .init("bookmarks", label: "Show Bookmarks", icon: "bookmark", shortcut: "mod+alt+b", group: "Go to"),
        .init("downloads", label: "Show Downloads", icon: "arrow.down.circle", group: "Go to"),
        .init("settings", label: "Open Settings", icon: "gearshape", shortcut: "mod+,", group: "App"),
        .init("quit", label: "Quit", icon: "power", shortcut: "mod+q", disabled: true, group: "App"),
    ]

    var body: some View {
        FluidCommandMenu(
            items: Self.commands,
            query: $cmdQuery,
            suggestions: ["new-tab", "settings"]
        )
        .frame(width: 288)
        .fluidSurface(5, radius: FluidShape.rounded.container)
    }
}

private struct GalleryColorPicker: View {
    @State private var pickedColor = "#6B97FF"

    var body: some View {
        FluidColorPicker(value: $pickedColor,
                         swatches: ["#6B97FF", "tomato", "seagreen", "gold",
                                    "rebeccapurple", "#0f172a"])
            .onChange(of: pickedColor) { _, v in
                if ProcessInfo.processInfo.environment["FLUID_PICKPROBE"] == "1" {
                    FileHandle.standardError.write("PICK \(v)\n".data(using: .utf8)!)
                }
            }
    }
}

private struct GalleryChecks: View {
    @State private var checks: Set<Int> = [0, 1]

    var body: some View {
        FluidCheckboxGroup(checked: $checks) {
            ForEach(Array(FluidGallery.channels.enumerated()), id: \.offset) { i, label in
                FluidCheckboxItem(
                    index: i, label: label, checked: checks.contains(i)
                ) { checks.formSymmetricDifference([i]) }
            }
        }
        .frame(width: 288)
    }
}

private struct GalleryRadios: View {
    @State private var radio: Int? = 0

    var body: some View {
        FluidRadioGroup(selection: $radio) {
            ForEach(Array(["System", "Light", "Dark"].enumerated()), id: \.offset) { i, label in
                FluidRadioItem(index: i, label: label, selected: radio == i) {
                    radio = i
                }
            }
        }
        .frame(width: 288)
    }
}

private struct GalleryComposer: View {
    @State private var draft = ""
    @State private var attachedFiles: [URL] = []
    @State private var queued: [FluidQueuedMessage] = []
    @State private var composerStatus = FluidComposerStatus.idle

    var body: some View {
        FluidInputMessage(
            text: $draft,
            placeholderSuggestion: "Summarize the open tabs",
            suggestions: [
                "Summarize the quarterly report",
                "Draft a follow-up email",
                "Compare the two proposals",
            ],
            history: ["What shipped this week?"],
            files: $attachedFiles,
            queue: $queued,
            status: composerStatus,
            onSend: { t, _ in draft = ""; composerStatus = .idle },
            onStop: { composerStatus = .idle }
        )
        .frame(width: 420)
        .onAppear(perform: probe)
    }

    private func probe() {
        guard let mode = ProcessInfo.processInfo.environment["FLUID_COMPOSER"] else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            switch mode {
            case "streaming":
                draft = "Follow up on this once the reply lands"
                composerStatus = .streaming
                queued = [
                    FluidQueuedMessage(text: "Compare against last week"),
                    FluidQueuedMessage(text: "Then draft the summary email"),
                ]
            case "queued":
                draft = "Follow up on this"
                queued = [FluidQueuedMessage(text: "Compare against last week")]
            case "text":
                draft = "A draft already typed into the composer"
            default: break
            }
        }
    }
}

private struct GallerySidebar: View {
    @State private var width: CGFloat = 220
    @State private var active: Int? = 2
    @State private var filter = ""

    var body: some View {
        FluidSidebarProvider(defaultOpen: true, persist: false,
                             shortcut: .disabled, peek: .hover,
                             width: 220) {
            HStack(spacing: 0) {
                FluidSidebar(width: $width) {
                    FluidSidebarHeader {
                        HStack(spacing: 8) {
                            FluidIcon("envelope.fill", size: 14)
                            Text("Mail").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            FluidSidebarTrigger()
                        }
                    }
                    FluidSidebarInput(text: $filter, placeholder: "Filter")
                    FluidSidebarContent {
                        FluidSidebarGroup("Mailboxes") {
                            FluidSidebarGroupAction("plus") {}
                        } content: {
                            FluidSidebarMenu(activeIndex: $active) {
                                FluidSidebarMenuItem(index: 0, label: "Inbox",
                                                     icon: "tray", badge: "4",
                                                     actionIcon: "ellipsis") { active = 0 }
                                FluidSidebarMenuItem(index: 1, label: "Drafts",
                                                     icon: "doc.text") { active = 1 }
                                FluidSidebarMenuItem(index: 2, label: "Sent",
                                                     icon: "paperplane") { active = 2 }
                                FluidSidebarMenuItem(index: 3, label: "Archive",
                                                     icon: "archivebox", badge: "12") { active = 3 }
                                FluidSidebarSubMenu {
                                    FluidSidebarSubItem(index: 4, label: "2024") { active = 4 }
                                    FluidSidebarSubItem(index: 5, label: "2025") { active = 5 }
                                }
                                FluidSidebarMenuItem(index: 6, label: "Trash",
                                                     icon: "trash") { active = 6 }
                            }
                        }
                        FluidSidebarGroup("Smart", collapsible: true) {
                            FluidSidebarGroupActions {
                                FluidSidebarGroupAction("plus") {}
                                FluidSidebarGroupAction("arrow.up.arrow.down") {}
                            }
                        } content: {
                            FluidSidebarMenu {
                                FluidSidebarMenuItem(index: 7, label: "Unread",
                                                     status: .unread, badge: "9",
                                                     isActive: true,
                                                     actions: [FluidSidebarMenuAction("bell", showOnHover: true) {}])
                                FluidSidebarMenuItem(index: 8, label: "Flagged",
                                                     status: .idle)
                                FluidSidebarMenuItem(index: 9, label: "VIP",
                                                     status: .idle, disabled: true)
                            }
                        }
                    }
                    FluidSidebarSeparator()
                    FluidSidebarFooter {
                        HStack(spacing: 8) {
                            FluidSidebarMenuSkeleton()
                            Spacer()
                            Text("3.2 GB").font(.system(size: 11))
                                .foregroundStyle(FluidTone.mutedForeground)
                        }
                    }
                }
                FluidSidebarInset {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            FluidSidebarTrigger()
                            Text("Inbox").font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        Text("Stateful pane — drag the rail to resize, past the slop to collapse. Collapsed: hover the edge or trigger to peek.")
                            .font(.system(size: 12))
                            .foregroundStyle(FluidTone.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(16)
                }
            }
        }
        .frame(height: 400)
        .background(FluidTone.background)
    }
}
private struct GalleryDropdownSearch: View {
    @State private var menuQuery = ""

    private static let actions: [(icon: String?, label: String)] = [
        ("pencil", "Rename"), ("doc.on.doc", "Duplicate"), ("square.and.arrow.up", "Share"),
        ("folder", "Move to folder"), ("trash", "Delete"),
    ]

    var body: some View {
        let filtered = Self.actions.enumerated().filter { _, a in
            menuQuery.isEmpty || a.label.localizedCaseInsensitiveContains(menuQuery)
        }
        return FluidMenuPanel(width: 288) {
            FluidMenuSearch(query: $menuQuery, indices: filtered.map(\.offset)) { _ in }
            ForEach(filtered, id: \.offset) { i, a in
                FluidMenuItem(index: i, icon: a.icon, label: a.label)
            }
            if filtered.isEmpty { FluidMenuEmpty() }
        }
    }
}

/// Opts the gallery window out of restorable-state snapshots — perpetual
/// animations keep invalidating the window's restorable state, and
/// NSPersistentUI re-encodes a full-window image on a background XPC queue
/// each time. A dev gallery has nothing worth restoring.
private struct FluidGalleryWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Hook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}

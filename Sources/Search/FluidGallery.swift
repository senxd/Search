import SwiftUI

// The Fluid Functionalism port's proving ground — mirrors the React demo
// (fluid-demo/app/page.tsx) section for section so the two galleries can
// be compared side by side. Open it from View › Fluid Gallery.

struct FluidGallery: View {
    @State private var listY = FluidHover(axis: .y)
    @State private var listX = FluidHover(axis: .x)
    @State private var listXY = FluidHover(axis: .xy)

    @State private var checked = true
    @State private var slider = 40.0
    @State private var tab = 0
    @State private var menuChecked = 1
    @State private var menuOpen = false
    @State private var mode: String? = "balanced"
    @State private var checks: Set<Int> = [0, 1]
    @State private var radio: Int? = 0
    @State private var fruit = FluidComboboxModel(items: Self.fruits)
    @State private var picked = FluidComboboxModel(items: Self.fruits)
    @FocusState private var fruitFocus: Bool
    @FocusState private var pickedFocus: Bool

    private static let menu = ["Inbox", "Drafts", "Sent", "Archive", "Trash"]
    private static let strip = ["Library", "Recents", "Favorites", "Settings"]
    private static let grid = ["Inbox", "Drafts", "Sent", "Archive", "Trash", "Spam"]
    private static let channels = ["Email", "Slack", "Calendar", "Docs"]
    private static let fruits = [
        "Apple", "Apricot", "Banana", "Cherry",
        "Dragonfruit", "Fig", "Grape", "Mango",
    ]

    init() {
        let m = FluidComboboxModel(items: Self.fruits)
        m.hideSelected = true
        m.values = ["Apple", "Cherry"]
        _picked = State(initialValue: m)
    }

    var body: some View {
        ScrollView {
            // Eager Grid, not LazyVGrid — lazy cells never materialize
            // off-screen, which would leave them out of FLUID_SHOT captures.
            Grid(alignment: .topLeading, horizontalSpacing: 40, verticalSpacing: 40) {
                GridRow {
                    section("Button — variants") { buttons }
                    section("Chip — leger design") { chips }
                }
                GridRow {
                    section("Switch") { switches }
                    section("Slider — pips") {
                        FluidSlider(value: $slider, label: "Volume")
                            .frame(width: 288)
                    }
                }
                GridRow {
                    section("Tabs") {
                        FluidTabs(items: Self.strip, selection: $tab)
                    }
                    section("Dropdown") { dropdown }
                }
                GridRow {
                    section("Combobox — single") { comboboxSingle }
                    section("Combobox — chips") { comboboxChips }
                }
                GridRow {
                    section("Select") {
                        FluidSelect(selection: $mode, placeholder: "Choose a mode") {
                            FluidMenuLabel("Modes")
                            FluidSelectItem(index: 0, value: "fast", label: "Fast")
                            FluidSelectItem(index: 1, value: "balanced", label: "Balanced")
                            FluidSelectItem(index: 2, value: "quiet", label: "Quiet")
                        }
                    }
                    section("Tooltip") { tooltip }
                }
                GridRow {
                    section("Checkbox group") {
                        FluidCheckboxGroup(checked: $checks) {
                            ForEach(Array(Self.channels.enumerated()), id: \.offset) { i, label in
                                FluidCheckboxItem(
                                    index: i, label: label, checked: checks.contains(i)
                                ) { checks.formSymmetricDifference([i]) }
                            }
                        }
                        .frame(width: 288)
                    }
                    section("Radio group") {
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
                GridRow {
                    section("Fluid hover — axis y") { hoverY }
                    section("Fluid hover — axis x") { hoverX }
                }
                GridRow {
                    section("Fluid hover — axis xy") { hoverXY }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
        .frame(minWidth: 1080, minHeight: 620)
        .background(FluidTone.background)
        .foregroundStyle(FluidTone.foreground)
        .onAppear(perform: probe)
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

    private var switches: some View {
        VStack(alignment: .leading, spacing: 2) {
            FluidSwitch(isOn: $checked, label: "Wi-Fi")
            FluidSwitch(isOn: .constant(false), label: "Bluetooth")
            FluidSwitch(isOn: .constant(true), label: "Disabled", isDisabled: true)
        }
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            FluidButton("Actions", variant: .secondary) { menuOpen.toggle() }
                .fluidMenuPopup(isPresented: $menuOpen, disabledIndices: [5]) {
                    menuRows
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
        FluidMenuItem(index: 4, icon: "gearshape", label: "Settings")
        FluidMenuItem(index: 5, icon: "trash", label: "Delete", disabled: true)
        FluidMenuItem(index: 6, icon: "rectangle.portrait.and.arrow.right", label: "Log out")
    }

    private var comboboxSingle: some View {
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

    private var comboboxChips: some View {
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

    private var tooltip: some View {
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(Array(Self.grid.enumerated()), id: \.offset) { i, label in
                    row(label).frame(maxWidth: .infinity, alignment: .leading).fluidItem(i)
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
        guard let shot = env["FLUID_SHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if env["FLUID_DARK"] == "1" {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            if let h = env["FLUID_H"], let height = Double(h),
               let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }) {
                var f = window.frame
                f.size.height = height
                f.origin.y -= height - window.frame.height
                window.setFrame(f, display: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if env["FLUID_MENU"] == "1" {
                menuOpen = true
                try? await Task.sleep(nanoseconds: 500_000_000)
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
            Self.snapshotGallery(to: shot)
        }
    }

    /// The gallery's own window contents, as a PNG — no permission prompts.
    static func snapshotGallery(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.title == "Fluid Gallery" }),
              let view = window.contentView else { return }
        // If the content scrolls past the window, capture the whole
        // document — cacheDisplay renders off-screen bounds too.
        var target = view
        var bounds = view.bounds
        if let scroll = findScrollView(in: view),
           let doc = scroll.documentView, doc.bounds.height > bounds.height {
            target = doc
            bounds = doc.bounds
        }
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        rep.size = bounds.size
        target.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))

        // Popups render in child panels — capture each beside the main shot.
        for (i, child) in (window.childWindows ?? []).enumerated() {
            guard let cv = child.contentView else { continue }
            cv.layoutSubtreeIfNeeded()
            guard let cr = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { continue }
            cr.size = cv.bounds.size
            cv.cacheDisplay(in: cv.bounds, to: cr)
            let stem = (path as NSString).deletingPathExtension
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

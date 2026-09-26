import SwiftUI

// The Fluid Functionalism port's proving ground — the same lists the React
// demo renders (fluid-demo/app/page.tsx), so a side-by-side comparison is
// apples to apples. Open it from View › Fluid Gallery.

struct FluidGallery: View {
    @State private var listY = FluidHover(axis: .y)
    @State private var listX = FluidHover(axis: .x)
    @State private var listXY = FluidHover(axis: .xy)

    private static let menu = ["Inbox", "Drafts", "Sent", "Archive", "Trash"]
    private static let strip = ["Library", "Recents", "Favorites", "Settings"]
    private static let grid = ["Inbox", "Drafts", "Sent", "Archive", "Trash", "Spam"]

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 48) {
                section("axis y") {
                    FluidContainer(hover: listY, radius: FluidShape.rounded.bg) {
                        VStack(spacing: 0) {
                            ForEach(Array(Self.menu.enumerated()), id: \.offset) { i, label in
                                row(label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fluidItem(i)
                            }
                        }
                        .frame(width: 224)
                        .padding(4)
                    }
                }

                section("axis x") {
                    FluidContainer(hover: listX, radius: FluidShape.rounded.bg) {
                        HStack(spacing: 0) {
                            ForEach(Array(Self.strip.enumerated()), id: \.offset) { i, label in
                                row(label)
                                    .fixedSize()
                                    .fluidItem(i)
                            }
                        }
                        .padding(4)
                    }
                }

                section("axis xy") {
                    FluidContainer(hover: listXY, radius: FluidShape.rounded.bg) {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 4
                        ) {
                            ForEach(Array(Self.grid.enumerated()), id: \.offset) { i, label in
                                row(label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fluidItem(i)
                            }
                        }
                        .frame(width: 340)
                        .padding(4)
                    }
                }
            }
            .padding(32)
        }
        .frame(minWidth: 1080, minHeight: 480)
        .background(Palette.ground)
        .onAppear(perform: probe)
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
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    private func row(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink)
            .frame(height: 36, alignment: .leading)
            .padding(.horizontal, 12)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .tracking(0.6)
            content()
        }
    }
}

// The radius-fluidItem ordering detail: `.fluidItem` reads the row's frame
// AFTER any outer .frame modifier, so call it last to measure the final box.

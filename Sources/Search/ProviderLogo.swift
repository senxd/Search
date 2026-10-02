import SwiftUI

/// Official website icons, loaded once and kept offline during rendering.
struct ProviderLogo: View {
    let provider: String
    private static let images: [String: NSImage] = {
        let folder = Bundle.main.url(forResource: "ProviderIcons", withExtension: nil)
            ?? Bundle.module.url(forResource: "ProviderIcons", withExtension: nil)
        guard let folder else { return [:] }
        return Dictionary(uniqueKeysWithValues: ["openrouter", "codex", "devin"].compactMap { name in
            NSImage(contentsOf: folder.appendingPathComponent(name + ".png")).map { (name, $0) }
        })
    }()

    var body: some View {
        Group {
            if let image = Self.images[provider] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: provider == "echo" ? "waveform" : "cpu")
                    .font(.system(size: 12))
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

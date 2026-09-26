import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Ask's typed attachments — the files, images and sites that ride beside
// the tab chips. The tab chip is consent (the agent may read and drive the
// page); these are payloads — the bytes that go, not access to where they
// came from. A pasted site is a reference, never a tab grant.
//
// The wire reads them out of AskJob.attachments; the .you message keeps
// them so history shows what the turn was handed.

/// One piece under the composer's chips row: an image the picker took, a
/// file of any kind, or a pasted web address.
struct AskAttach: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case image, file, site }
    var id = UUID()
    var kind: Kind
    /// What the chip reads — the file's name, the site's host.
    var label: String
    /// The file's or image's place on disk — the send-time fill reads it,
    /// and the wire falls back to it when `data`/`text` couldn't carry it.
    var path: String?
    /// The site's address, whole.
    var url: String?
    var mime: String?
    /// The file's text at send — UTF-8 only, capped — else nil and the
    /// wire degrades to "[file: name]".
    var text: String?
    /// The image's bytes, base64, while it's small enough to carry —
    /// else nil and the path has to do.
    var data: String?
}

extension AskAttach {
    /// The most text a file hands over — past it the path goes alone.
    static let textCap = 50_000
    /// The most an image base64's into the job — past it the path goes alone.
    static let imageCap = 2_000_000
    /// The most the picker will take for an image at all.
    static let pickCap = 3_000_000

    /// What the open panel picked — labelled and typed, its bytes left for
    /// the send-time fill to read.
    static func picked(_ url: URL, image: Bool) -> AskAttach {
        AskAttach(
            kind: image ? .image : .file,
            label: url.lastPathComponent,
            path: url.path,
            mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        )
    }

    /// A website pasted into the composer — a reference chip for the
    /// model to name, never a grant on a tab.
    static func site(_ url: URL) -> AskAttach {
        AskAttach(kind: .site, label: url.host() ?? url.absoluteString, url: url.absoluteString)
    }

    /// The send-time fill: a file reads as UTF-8 text inside its cap, an
    /// image base64's inside its own — anything bigger, binary or missing
    /// keeps its path and the wire says so.
    var filled: AskAttach {
        var piece = self
        guard let path, let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return piece }
        switch kind {
        case .file where raw.count <= AskAttach.textCap:
            piece.text = String(data: raw, encoding: .utf8)
        case .image where raw.count <= AskAttach.imageCap:
            piece.data = raw.base64EncodedString()
        default:
            break
        }
        return piece
    }
}

// MARK: - the chips

/// A typed attachment as a chip — the shape tells the kind before the name
/// does: an image wears its thumbnail in a rounded square, a file its
/// document glyph with its size beside it, a site its globe and host. The
/// cross is there while the composer can still take the piece back; a
/// message's chips keep only the mark.
struct AttachChip: View {
    let piece: AskAttach
    var remove: (() -> Void)? = nil

    @State private var thumb: NSImage?

    /// The name, kept to the row's etiquette the way Chip's is.
    private var trimmed: String {
        piece.label.count > 20 ? String(piece.label.prefix(20)) + "…" : piece.label
    }

    /// The little second reading: a file's size as the disk has it —
    /// nothing for the kinds that already say what they are.
    private var hint: String? {
        guard piece.kind == .file, let path = piece.path else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
        guard size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// The rounded rect the image kind asks for; the rest are capsules.
    /// Used for the wash; the hairline is stroked per-kind below —
    /// `strokeBorder` isn't on `AnyShape`.
    private var shape: AnyShape {
        piece.kind == .image
            ? AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            : AnyShape(Capsule())
    }

    /// The same edge stroked: a rounded rect for images, a capsule else.
    @ViewBuilder
    private var border: some View {
        if piece.kind == .image {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        } else {
            Capsule().strokeBorder(Palette.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch piece.kind {
        case .image:
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
            }
        case .file:
            Image(systemName: "doc")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 14, alignment: .center)
        case .site:
            Image(systemName: "globe")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 14, alignment: .center)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            mark
            Text(trimmed)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ink)
            if let hint {
                Text(hint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.faint)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, piece.kind == .image ? 4 : 6)
        .padding(.trailing, remove == nil ? 8 : 5)
        .padding(.vertical, 4)
        .background(Palette.wash, in: shape)
        .overlay(border)
        .help(help)
        .task(id: piece.path) {
            guard piece.kind == .image, let path = piece.path else { return }
            thumb = NSImage(contentsOfFile: path)
        }
    }

    /// The whole address or path behind the label, on hover.
    private var help: String {
        piece.url ?? piece.path ?? piece.label
    }
}

// MARK: - the menu

/// The composer's "+" — a quiet circle next to the field whose menu is the
/// way in for everything that isn't a tab: an image or a file off the
/// open panel, a site off the little field it raises.
struct AttachMenu: View {
    var browser: Browser
    /// Non-nil raises the composer's paste-a-URL row (its text when it is).
    @Binding var siteDraft: String?
    @ObservedObject private var mind = Mind.shared

    var body: some View {
        Menu {
            Button("Image…") { pick(image: true) }
            Button("File…") { pick(image: false) }
            Divider()
            Button("Website…") { siteDraft = "" }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: 20, height: 20)
                .background(Palette.ground, in: Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach an image, a file or a website")
    }

    /// The open panel — one answer per pick, images filtered and capped.
    private func pick(image: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if image {
            panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
            panel.message = "Images to hand the agent — up to 3 MB each."
        } else {
            panel.message = "Files to hand the agent."
        }
        guard panel.runModal() == .OK else { return }
        var skipped = 0
        for url in panel.urls {
            if image {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > AskAttach.pickCap { skipped += 1; continue }
            }
            mind.attachments.append(AskAttach.picked(url, image: image))
        }
        if skipped > 0 {
            browser.announce("\(skipped) image\(skipped == 1 ? " was" : "s were") over 3 MB — left off")
        }
    }
}

/// The little field "Website…" raises — a row inside the composer where a
/// URL is pasted, going away empty or turned into a site chip on Return.
struct SiteRow: View {
    /// The row's text while it is up; nil takes the row down.
    @Binding var text: String?
    /// The URL committed, already validated — the caller chips it.
    let commit: (URL) -> Void

    @FocusState private var typing: Bool

    private var url: URL? {
        (text ?? "").isEmpty ? nil : Address.url(from: text ?? "")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 14, alignment: .center)
            ZStack(alignment: .leading) {
                if (text ?? "").isEmpty {
                    Text("Paste a web address")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted.opacity(0.7))
                        .allowsHitTesting(false)
                }
                TextField("", text: Binding(get: { text ?? "" }, set: { text = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .onSubmit(send)
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(url == nil ? Palette.faint : Palette.ink)
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            Button {
                text = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { typing = true }
    }

    private func send() {
        guard let url else { return }
        commit(url)
        text = nil
    }
}

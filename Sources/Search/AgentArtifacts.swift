import Foundation
import WebKit

/// Files the asking session may read: PDFs it requested and downloads its
/// own tabs completed. They live in that session's world folder and vanish
/// when the session ends.
@MainActor
final class AgentArtifacts {
    private struct Entry {
        let id: String
        let kind: String
        let name: String
        let path: String
        let size: Int
        let tab: String
        let host: String
        let date: Date
        var json: [String: Any] {
            ["id": id, "kind": kind, "name": name, "mimeType": name.lowercased().hasSuffix(".pdf") ? "application/pdf" : "application/octet-stream",
             "byteLength": size, "tab": tab, "host": host,
             "createdAt": ISO8601DateFormatter().string(from: date)]
        }
    }
    private struct Download {
        let download: WKDownload
        let id: String
        let origin: DriveOrigin
        let tab: String
        let host: String
        let directory: URL
    }

    private let maximumCount = 64
    private let maximumBytes = 256 * 1024 * 1024
    private let maximumFileBytes = 16 * 1024 * 1024
    private var entries: [DriveOrigin: [Entry]] = [:]
    private var downloads: [ObjectIdentifier: Download] = [:]

    func directory(for origin: DriveOrigin) -> URL {
        Store.file("agent-artifacts").appendingPathComponent(origin.tag, isDirectory: true)
    }

    func savePDF(_ data: Data, tab: String, host: String, origin: DriveOrigin) throws -> [String: Any] {
        guard data.starts(with: Data("%PDF-".utf8)) else { throw Failure.invalidPDF }
        let id = UUID().uuidString.lowercased()
        let entry = Entry(id: id, kind: "pdf", name: "page-\(id.prefix(8)).pdf",
                          path: directory(for: origin).appendingPathComponent("page-\(id).pdf").path,
                          size: data.count, tab: tab, host: host, date: Date())
        try save(entry, data: data, origin: origin)
        return ["artifact": entry.json]
    }

    func startDownload(_ download: WKDownload, tab: String, host: String, origin: DriveOrigin) -> URL? {
        let directory = directory(for: origin).appendingPathComponent("downloads", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        downloads[ObjectIdentifier(download)] = Download(download: download, id: UUID().uuidString.lowercased(), origin: origin,
                                                           tab: tab, host: host, directory: directory)
        return directory
    }

    func owns(_ download: WKDownload) -> Bool { downloads[ObjectIdentifier(download)] != nil }

    func finish(_ download: WKDownload, file: URL) -> [String: Any]? {
        guard let pending = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= maximumFileBytes else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let entry = Entry(id: pending.id, kind: "download", name: file.lastPathComponent, path: file.path,
                          size: size, tab: pending.tab, host: pending.host, date: Date())
        do { try save(entry, origin: pending.origin) } catch { return nil }
        return ["origin": pending.origin.tag, "artifact": entry.json]
    }

    func fail(_ download: WKDownload) -> [String: Any]? {
        guard let pending = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        return ["origin": pending.origin.tag, "id": pending.id, "tab": pending.tab, "host": pending.host]
    }

    func list(for origin: DriveOrigin, tab: String? = nil) -> [[String: Any]] {
        (entries[origin] ?? []).filter { tab == nil || $0.tab == tab }.reversed().map(\.json)
    }

    func read(id: String, origin: DriveOrigin, offset: Any?, length: Any?) -> [String: Any] {
        guard let entry = entries[origin]?.first(where: { $0.id == id }) else {
            return ["error": "artifact is absent or belongs to another session", "code": "NOT_FOUND"]
        }
        func integer(_ value: Any?, _ fallback: Int) -> Int? {
            guard let number = value as? NSNumber else { return fallback }
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double, double >= 0, double <= Double(Int.max) else { return nil }
            return Int(double)
        }
        guard let start = integer(offset, 0), let count = integer(length, 48_000),
              start <= entry.size, count >= 1, count <= 48_000 else {
            return ["error": "offset must be within the file and length must be 1...48000", "code": "INVALID_ARGUMENT"]
        }
        do {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: entry.path))
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(start))
            let data = try file.read(upToCount: min(count, entry.size - start)) ?? Data()
            return ["id": id, "offset": start, "nextOffset": start + data.count,
                    "byteLength": entry.size, "eof": start + data.count >= entry.size,
                    "base64": data.base64EncodedString()]
        } catch { return ["error": error.localizedDescription, "code": "ARTIFACT_EXPIRED"] }
    }

    func remove(_ origin: DriveOrigin) -> [WKDownload] {
        let active = downloads.filter { $0.value.origin == origin }
        for key in active.keys { downloads.removeValue(forKey: key) }
        for entry in entries.removeValue(forKey: origin) ?? [] { try? FileManager.default.removeItem(atPath: entry.path) }
        try? FileManager.default.removeItem(at: directory(for: origin))
        return active.values.map(\.download)
    }

    private func save(_ entry: Entry, data: Data? = nil, origin: DriveOrigin) throws {
        guard entry.size <= maximumFileBytes else { throw Failure.tooLarge }
        var kept = entries[origin] ?? []
        var total = kept.reduce(0) { $0 + $1.size }
        while !kept.isEmpty && (kept.count >= maximumCount || total + entry.size > maximumBytes) {
            let old = kept.removeFirst()
            total -= old.size
            try? FileManager.default.removeItem(atPath: old.path)
        }
        let file = URL(fileURLWithPath: entry.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data { try data.write(to: file, options: .atomic) }
        kept.append(entry)
        entries[origin] = kept
    }

    private enum Failure: LocalizedError {
        case invalidPDF, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidPDF: return "WebKit returned an invalid PDF"
            case .tooLarge: return "artifact exceeds the 16 MiB limit"
            }
        }
    }
}

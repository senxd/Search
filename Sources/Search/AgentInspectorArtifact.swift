import Foundation

enum AgentInspectorArtifact {
    static func write(json: [String: Any], directory: URL) throws -> [String: Any] {
        let limit = 128 * 1024 * 1024
        let data = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        guard data.count <= limit else {
            throw NSError(domain: "SearchInspector", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Inspector artifact exceeds 128 MiB."])
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("inspector-\(UUID().uuidString).json")
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do {
            let files = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                .filter { $0.lastPathComponent.hasPrefix("inspector-") && $0.pathExtension == "json" }
                .compactMap { url -> (URL, Int, Date)? in
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true else { return nil }
                    return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
                }
                .sorted {
                    if $0.0 == file { return $1.0 != file }
                    if $1.0 == file { return false }
                    return $0.2 > $1.2
                }
            var bytes = 0
            var count = 0
            for (url, size, _) in files {
                if count < 32, bytes + size <= limit {
                    bytes += size
                    count += 1
                } else { try manager.removeItem(at: url) }
            }
        } catch {
            try? manager.removeItem(at: file)
            throw error
        }
        return ["artifact": ["path": file.path, "bytes": data.count, "format": "json"]]
    }
}

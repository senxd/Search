import WebKit

/// Native sheets are parked for opted-in agents and isolated benchmark seats.
@MainActor
final class AgentInteractions {
    static let shared = AgentInteractions()
    enum PendingWatch {
        case unavailable
        case alreadyPending
        case watching(UUID)
    }
    private struct Watcher {
        let session: DriveOrigin
        let requestToken: String?
        let found: () -> Void
        let cancelled: () -> Void
    }
    final class Pending {
        let id = UUID().uuidString
        let kind: String
        let message: String
        let multiple: Bool
        let directories: Bool
        let reply: (Bool, String?, [URL]?) -> Void
        var timer: DispatchSourceTimer?
        init(kind: String, message: String, multiple: Bool, directories: Bool,
             reply: @escaping (Bool, String?, [URL]?) -> Void) {
            self.kind = kind; self.message = message; self.multiple = multiple
            self.directories = directories; self.reply = reply
        }
        func finish(_ accept: Bool, _ text: String?, _ urls: [URL]?) {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            reply(accept, text, urls)
        }
        var description: [String: Any] {
            ["id": id, "kind": kind, "message": message,
             "multiple": multiple, "directories": directories]
        }
    }
    private struct Owner {
        let session: DriveOrigin
        let event: ([String: Any]) -> Void
        var pending: Pending?
    }
    private var owners: [ObjectIdentifier: Owner] = [:]
    private var watchers: [ObjectIdentifier: [UUID: Watcher]] = [:]

    func watchPending(_ web: WKWebView, session: DriveOrigin? = nil, requestToken: String? = nil, found: @escaping () -> Void,
                      cancelled: @escaping () -> Void) -> PendingWatch {
        let key = ObjectIdentifier(web)
        guard let owner = owners[key], session == nil || owner.session == session else { return .unavailable }
        guard owner.pending == nil else { return .alreadyPending }
        let id = UUID()
        watchers[key, default: [:]][id] = Watcher(session: owner.session, requestToken: requestToken,
                                                   found: found, cancelled: cancelled)
        return .watching(id)
    }

    func hasWatcher(_ web: WKWebView, requestToken: String) -> Bool {
        watchers[ObjectIdentifier(web)]?.values.contains { $0.requestToken == requestToken } ?? false
    }

    func stopWatching(_ key: ObjectIdentifier, id: UUID) {
        watchers[key]?.removeValue(forKey: id)
        if watchers[key]?.isEmpty == true { watchers[key] = nil }
    }

    func configure(_ web: WKWebView, session: DriveOrigin, enabled: Bool,
                   event: @escaping ([String: Any]) -> Void) -> [String: Any] {
        let key = ObjectIdentifier(web)
        if let owner = owners[key], owner.session != session {
            return ["error": "another session handles this tab's dialogs", "code": "BUSY"]
        }
        if enabled {
            if owners[key] == nil { owners[key] = Owner(session: session, event: event) }
        } else { clear(web, settleWatchers: false) }
        return status(web, session: session)
    }

    func status(_ web: WKWebView, session: DriveOrigin) -> [String: Any] {
        guard let owner = owners[ObjectIdentifier(web)], owner.session == session else {
            return ["enabled": false]
        }
        return ["enabled": true, "pending": owner.pending?.description ?? NSNull()]
    }

    func capture(_ web: WKWebView, kind: String, message: String = "",
                 multiple: Bool = false, directories: Bool = false,
                 reply: @escaping (Bool, String?, [URL]?) -> Void) -> Bool {
        let key = ObjectIdentifier(web)
        guard var owner = owners[key] else { return false }
        guard owner.pending == nil else { reply(false, nil, nil); return true }
        let pending = Pending(kind: kind, message: message, multiple: multiple,
                              directories: directories, reply: reply)
        owner.pending = pending
        owners[key] = owner
        owner.event(pending.description)
        let found = (watchers[key] ?? [:]).values.filter { $0.session == owner.session }
        watchers[key] = nil
        for watcher in found { watcher.found() }
        // A disconnected or idle agent must not strand a page indefinitely.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 120)
        timer.setEventHandler { [weak self, weak pending] in
            guard let self, let pending, self.owners[key]?.pending?.id == pending.id else { return }
            self.owners[key]?.pending = nil
            pending.finish(false, nil, nil)
        }
        pending.timer = timer
        timer.resume()
        return true
    }

    func answer(_ web: WKWebView, session: DriveOrigin, args: [String: Any], files: Bool) -> [String: Any] {
        let key = ObjectIdentifier(web)
        guard let owner = owners[key], owner.session == session, let pending = owner.pending else {
            return ["error": "no pending dialog for this session", "code": "NOT_FOUND"]
        }
        guard args["dialog"] as? String == pending.id else {
            return ["error": "dialog id is missing or stale", "code": "STALE_DIALOG"]
        }
        guard files == (pending.kind == "file") else {
            return ["error": "wrong dialog operation", "code": "WRONG_VERB"]
        }
        var urls: [URL]?
        if files {
            guard let paths = args["paths"] as? [String], pending.multiple || paths.count <= 1 else {
                return ["error": "paths must match the file chooser's selection limit"]
            }
            if paths.isEmpty {
                owners[key]?.pending = nil
                pending.finish(false, nil, nil)
                return ["ok": true]
            }
            urls = []
            for path in paths {
                let expanded = (path as NSString).expandingTildeInPath
                var directory: ObjCBool = false
                guard expanded.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: expanded, isDirectory: &directory),
                      FileManager.default.isReadableFile(atPath: expanded),
                      !directory.boolValue || pending.directories else {
                    return ["error": "file is not readable or permitted by the chooser: \(path)"]
                }
                urls?.append(URL(fileURLWithPath: expanded))
            }
        } else if !(args["accept"] is Bool) {
            return ["error": "accept must be a boolean"]
        }
        owners[key]?.pending = nil
        pending.finish(args["accept"] as? Bool ?? true, args["text"] as? String, urls)
        return ["ok": true]
    }

    func clear(_ web: WKWebView, settleWatchers: Bool = true) {
        let key = ObjectIdentifier(web)
        cancelWatchers(for: key, settle: settleWatchers)
        owners.removeValue(forKey: key)?.pending?.finish(false, nil, nil)
    }

    func release(_ web: WKWebView, session: DriveOrigin) {
        if owners[ObjectIdentifier(web)]?.session == session { clear(web) }
    }

    func release(_ session: DriveOrigin) {
        for key in Array(owners.keys) where owners[key]?.session == session {
            owners.removeValue(forKey: key)?.pending?.finish(false, nil, nil)
        }
        for key in Array(watchers.keys) { cancelWatchers(for: key, session: session, settle: true) }
    }

    private func cancelWatchers(for key: ObjectIdentifier, session: DriveOrigin? = nil, settle: Bool) {
        guard let current = watchers[key] else { return }
        let cancelled = current.filter { session == nil || $0.value.session == session }
        for id in cancelled.keys { watchers[key]?.removeValue(forKey: id) }
        if watchers[key]?.isEmpty == true { watchers[key] = nil }
        if settle { for watcher in cancelled.values { watcher.cancelled() } }
    }
}

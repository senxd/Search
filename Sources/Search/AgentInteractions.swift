import WebKit

/// Native sheets are parked only after an attached agent explicitly opts in.
@MainActor
final class AgentInteractions {
    static let shared = AgentInteractions()
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

    func configure(_ web: WKWebView, session: DriveOrigin, enabled: Bool,
                   event: @escaping ([String: Any]) -> Void) -> [String: Any] {
        let key = ObjectIdentifier(web)
        if let owner = owners[key], owner.session != session {
            return ["error": "another session handles this tab's dialogs", "code": "BUSY"]
        }
        if enabled {
            if owners[key] == nil { owners[key] = Owner(session: session, event: event) }
        } else { clear(web) }
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

    func clear(_ web: WKWebView) {
        owners.removeValue(forKey: ObjectIdentifier(web))?.pending?.finish(false, nil, nil)
    }

    func release(_ web: WKWebView, session: DriveOrigin) {
        if owners[ObjectIdentifier(web)]?.session == session { clear(web) }
    }

    func release(_ session: DriveOrigin) {
        for key in Array(owners.keys) where owners[key]?.session == session {
            owners.removeValue(forKey: key)?.pending?.finish(false, nil, nil)
        }
    }
}

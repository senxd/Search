import AppKit
import WebKit

// agent.sock — the protocol's other door. Where bench.sock is one request per
// connection for scripts that come and go, this is the session a thing that
// drives for a living keeps: connect once, ask as often as it likes, and get
// told what happens between answers.
//
// Same address family, same trust: a Unix socket in the app's own folder,
// chmod 600, the peer's uid checked before a word is read. Unlike the bench a
// connection stays open — each line in is `{"id":N,"op":"…","args":{…}}`, each
// line out `{"id":N,"result":{…}}` or `{"id":N,"error":"…"}`, requests may be
// in flight at once under their own ids, and `{"event":…,"data":{…}}` flows to
// sessions that said `subscribe`.
//
// The ops themselves are Drive's, `AskRuntime.drive` — the same object the
// in-app Ask panel talks through, so a socket agent and the panel's agent
// stand on exactly the same ground.

@MainActor
final class AgentSocket {
    static let shared = AgentSocket()
    private weak var browser: Browser?
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var sessions: [Int32: Session] = [:]
    /// Whether `onEvent` has been chained onto the driver yet.
    private var hooked = false
    private var activeRequests = 0

    /// Beside the bench socket, so a test run's agent is as separate from the
    /// real one's as everything else it keeps.
    static var socket: URL { Store.file("agent.sock") }

    private(set) var running = false

    func start(for browser: Browser) {
        guard !running else { return }
        self.browser = browser
        let path = AgentSocket.socket.path
        try? FileManager.default.createDirectory(
            at: AgentSocket.socket.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        running = true
    }

    func stop() {
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(AgentSocket.socket.path)
        sessions.values.forEach { $0.drop() }
        sessions = [:]
        running = false
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        guard sessions.count < 32 else { close(fd); return }
        // Only this user — the file mode says so already; this says it again,
        // for the day the folder's permissions are not what they were.
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        let session = Session(fd: fd) { [weak self] session, request in
            self?.serve(request, in: session)
        } gone: { [weak self] session in
            // Synchronous, before the fd is freed: the session's Drive state
            // — its tabs, its leases — dies with the connection that owned
            // it, not with a stray task that could land after the fd's next
            // owner has already registered.
            session.requests.cancelAll()
            self?.sessions[session.fd] = nil
            (AskRuntime.drive as? Drive)?.leave(.socket(session.token))
        }
        sessions[fd] = session
    }

    // MARK: - one request

    private func serve(_ request: [String: Any], in session: Session) {
        // The id echoes back in every reply and the args go on to drive.js
        // through JSONSerialization — where a non-finite number or a
        // non-JSON type is an uncatchable NSInvalidArgumentException, not a
        // throw. `-1e999` and `NaN` parse to exactly those. Both are checked
        // before either is trusted: a bad request earns an error, never the
        // app's life.
        let id = request["id"] ?? NSNull()
        let op = request["op"] as? String ?? ""
        let args = request["args"] as? [String: Any] ?? [:]
        let (registered, rejection) = session.requests.begin(id: id, op: op, control: op == "request.status" || op == "request.cancel")
        guard let receipt = registered else {
            var error: [String: Any] = ["id": AgentRequests.key(id) == nil ? NSNull() : id,
                                        "error": "request rejected", "code": rejection ?? "INVALID_REQUEST_ID"]
            if let existing = session.requests.lookup(id) { error["receipt"] = existing.json }
            session.say(error)
            return
        }
        var started = false
        let answer: ([String: Any]) -> Void = { [weak self] reply in
            guard receipt.state == "running" else { return }
            if started { self?.activeRequests -= 1 }
            let control = op == "request.status" || op == "request.cancel"
            session.requests.finish(receipt, reply: control && reply["error"] == nil ? ["ok": true] : reply)
            if !receipt.answered {
                receipt.answered = true
                var reply = reply
                reply["receipt"] = receipt.json
                session.answer(id: id, reply)
            } else if session.wants.contains("*") || session.wants.contains("request.finished") {
                session.say(["event": "request.finished", "data": receipt.json])
            }
        }
        guard Drive.jsonSafe(args) else {
            answer(["error": "args aren't JSON-safe", "code": "INVALID_ARGS"])
            return
        }

        switch op {
        case "ping":
            answer(["pong": true])
        case "subscribe":
            let mode: AskMode?
            if let value = args["mode"] {
                guard let raw = value as? String, let parsed = AskMode(rawValue: raw) else {
                    answer(["error": "subscribe mode needs guard|full"]); return
                }
                mode = parsed
            } else { mode = nil }
            let events = args["events"] as? [String] ?? ["*"]
            session.wants = Set(events)
            // A subscribe-only session still has to hear things, so the
            // fan-out — and with it the diff that feeds it — is armed on
            // subscribe itself, not held for some later op.
            if let drive = AskRuntime.drive {
                hook(drive)
                // `mode` sets this session's own leash as it signs on —
                // agent.mode in word form (permissions.md §1). Only the
                // session's own, never anyone else's.
                if let mode {
                    (drive as? Drive)?.setMode(mode, for: .socket(session.token))
                }
            }
            answer(["subscribed": true, "events": events])
        case "request.status", "request.cancel":
            guard let target = session.requests.lookup(args["requestId"]) else {
                answer(["error": "request receipt not found in this session", "code": "REQUEST_NOT_FOUND"])
                return
            }
            if op == "request.cancel", target.state == "running" {
                target.cancellation.cancel()
                if !target.answered {
                    target.answered = true
                    session.answer(id: target.id, ["error": "cancellation requested; outcome unknown",
                                                  "code": "CANCEL_REQUESTED", "receipt": target.json])
                }
            }
            answer(target.json)
        case "":
            answer(["error": "request needs an op"])
        default:
            guard let drive = AskRuntime.drive else {
                answer(["error": "no driver"])
                return
            }
            guard activeRequests < 256 else {
                answer(["error": "256 operations still running", "code": "TOO_MANY_REQUESTS"])
                return
            }
            activeRequests += 1
            started = true
            hook(drive)
            let requestedWait = (args["seconds"] as? NSNumber)?.doubleValue ?? 30
            let patience = op == "page.wait" ? min(max(requestedWait, 0), 3_600) + 5 : 30
            let timer = DispatchSource.makeTimerSource(queue: .main)
            receipt.timer = timer
            timer.schedule(deadline: .now() + patience)
            timer.setEventHandler { [weak session, weak receipt] in
                guard let session, let receipt else { return }
                guard receipt.state == "running", !receipt.answered else { return }
                receipt.answered = true
                receipt.timedOut = true
                var timedOut = receipt.json
                timedOut["cancelRequested"] = true
                session.answer(id: id, ["error": "no answer within \(Int(patience)) s; outcome unknown",
                                       "code": "TIMEOUT", "receipt": timedOut])
                receipt.cancellation.cancel()
            }
            timer.resume()
            if let native = drive as? Drive {
                native.perform(op, args, from: .socket(session.token), cancellation: receipt.cancellation, done: answer)
            } else {
                drive.perform(op, args, from: .socket(session.token), done: answer)
            }
        }
    }

    /// The driver's events go to every session that subscribed to them —
    /// installed on the first request or subscribe, whichever comes first.
    /// Anything already on `onEvent` (the in-app harness, say) keeps hearing
    /// too.
    private func hook(_ drive: any Driving) {
        guard !hooked else { return }
        hooked = true
        var drive = drive
        let prior = drive.onEvent
        drive.onEvent = { [weak self] event, data in
            prior?(event, data)
            self?.broadcast(event, data)
        }
    }

    private func broadcast(_ event: String, _ data: [String: Any]) {
        var data = data
        // `_session` is the driver's routing tag, never the client's
        // business: strip it and hand the event to the one session it names
        // — `done` and `lease.lost` are the asking session's own — while
        // `tab.*` carries no tag and broadcasts to everyone subscribed.
        let only = data.removeValue(forKey: "_session") as? String
        for session in sessions.values {
            if let only, session.tag != only { continue }
            guard session.wants.contains("*") || session.wants.contains(event) else { continue }
            session.say(["event": event, "data": data])
        }
    }

    // MARK: - one connection

    /// A persistent session: reads lines until the client goes away, each a
    /// complete request; writes whenever the socket will take them, on a queue
    /// of the connection's own so a slow reader never stalls the main one and
    /// a big screenshot never sits in a busy loop.
    private final class Session {
        let fd: Int32
        /// Who the session is to Drive — not the fd: a descriptor can be
        /// re-issued to the next connection the moment this one's closed,
        /// and the token is what keeps a dead session's leftovers from ever
        /// colliding with a live one.
        let token = UUID()
        /// The string Drive puts on an event's `_session` to route it here.
        var tag: String { DriveOrigin.socket(token).tag }
        /// The event names this session asked for — "*" or a list. Empty is
        /// unsubscribed: answers still come, events don't.
        var wants: Set<String> = []
        let requests: AgentRequests
        private let queue = DispatchQueue(label: "Search.agent.session")
        private var reader: DispatchSourceRead?
        private var writer: DispatchSourceWrite?
        private var incoming = Data()
        private var outgoing = Data()
        private var dead = false
        private var queuedRequests = 0
        private let line: (Session, [String: Any]) -> Void
        private let gone: (Session) -> Void

        @MainActor
        init(
            fd: Int32,
            line: @escaping (Session, [String: Any]) -> Void,
            gone: @escaping (Session) -> Void
        ) {
            self.requests = AgentRequests()
            self.fd = fd
            self.line = line
            self.gone = gone
            // Not blocking: reads land when there's something to read, writes
            // say EAGAIN rather than stalling, and the write source picks the
            // rest up when the socket has room again.
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.readSome() }
            // The descriptor's only close: on the session's own queue, after
            // whatever was queued ahead of it — never from under a write.
            reader.setCancelHandler { close(fd) }
            self.reader = reader
            reader.resume()
        }

        // Reads, writes and the close all live on this queue, so a descriptor
        // is never touched from two sides at once — and never reused by a new
        // connection while an old write still has it.

        private func readSome() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { fail() }
                return
            }
            incoming.append(contentsOf: chunk[0..<count])
            // A line that never ends is not a request; the session goes with it.
            if incoming.count > 4_000_000 {
                say(["error": "request too long"])
                queue.async { self.fail() }
                return
            }
            while let newline = incoming.firstIndex(of: 0x0A) {
                let data = Data(incoming[incoming.startIndex..<newline])
                incoming = Data(incoming[incoming.index(after: newline)...])
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    say(["id": NSNull(), "error": "not a JSON object"])
                    continue
                }
                guard queuedRequests < 128 else { fail(); return }
                queuedRequests += 1
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated { self.line(self, json) }
                    self.queue.async { self.queuedRequests -= 1 }
                }
            }
        }

        /// An op's reply, wrapped: `{"id":N,"result":{…}}`, or `{"id":N,
        /// "error":"…"}` with any extra keys the reply carried (a stale-ref's
        /// `code`, say) kept beside it.
        func answer(id: Any, _ reply: [String: Any]) {
            var out: [String: Any] = ["id": id]
            if let error = reply["error"] as? String {
                out["error"] = error
                for (key, value) in reply where key != "error" { out[key] = value }
            } else {
                out["result"] = reply
            }
            say(out)
        }

        func say(_ object: [String: Any]) {
            // A page can hand back a number JSON can't write — Infinity out
            // of the wrong arithmetic — and JSONSerialization repays it with
            // an uncatchable NSInvalidArgumentException, not a throw. The
            // answer degrades to an error line before it can take the app.
            var object = object
            if !Drive.jsonSafe(object) {
                let id = object["id"].map { Drive.jsonSafe($0) ? $0 : NSNull() } ?? NSNull()
                object = ["id": id, "error": "the answer wasn't JSON-safe"]
            }
            var data = (try? JSONSerialization.data(withJSONObject: object))
                ?? Data("{\"error\":\"unwritable answer\"}".utf8)
            // A single large result and a slow reader must not grow the queue forever.
            guard data.count <= 8_000_000 else { drop(); return }
            data.append(0x0A)
            queue.async { [weak self] in
                guard let self, !self.dead else { return }
                guard self.outgoing.count + data.count <= 8_000_000 else { self.fail(); return }
                self.outgoing.append(data)
                self.drain()
            }
        }

        /// Push what's queued into the socket until it won't take more; the
        /// write source — armed only while something is left — takes the rest.
        private func drain() {
            while !outgoing.isEmpty {
                let n = outgoing.withUnsafeBytes { raw in
                    send(fd, raw.baseAddress!, raw.count, Int32(MSG_NOSIGNAL))
                }
                if n > 0 {
                    outgoing = Data(outgoing.dropFirst(n))
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    if writer == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                        source.setEventHandler { [weak self] in self?.drain() }
                        source.resume()
                        writer = source
                    }
                    return
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    fail()
                    return
                }
            }
            writer?.cancel()
            writer = nil
        }

        /// The fd's quietus: tell the socket it's gone *first* — releasing
        /// the session's tabs and leases on Drive — and only then cancel the
        /// reader, whose handler does the close. The order is the whole
        /// point: a descriptor freed before the goodbye could be re-issued
        /// to a fresh connection, and the stale goodbye landing afterwards
        /// would strike the new session out of the socket's table. Running
        /// the goodbye synchronously rules that out; nothing on main ever
        /// waits on this queue, so the sync can't deadlock.
        private func fail() {
            guard !dead else { return }
            dead = true
            writer?.cancel()
            writer = nil
            if Thread.isMainThread {
                gone(self)
            } else {
                DispatchQueue.main.sync { self.gone(self) }
            }
            reader?.cancel()
            reader = nil
        }

        /// From the outside — the socket going down, a stop — same end.
        func drop() {
            queue.async { self.fail() }
        }
    }
}

import AppKit
import CoreGraphics
import ObjectiveC.runtime
import SwiftUI
import WebKit

/// Direct responder delivery keeps synthetic input inside the granted tab,
/// but AppKit's global pressed-button table only tracks events posted through
/// its event stream. WebKit's own test runner uses this scoped override for
/// the same case. Restore the class method before returning to the run loop.
private enum SyntheticMouseButtons {
    static func with(_ mask: UInt, dispatch: () -> Void) {
        let type: AnyClass = NSEvent.self
        let selector = #selector(getter: NSEvent.pressedMouseButtons)
        guard let method = class_getClassMethod(type, selector) else { dispatch(); return }
        let original = method_getImplementation(method)
        let originalCall = unsafeBitCast(original, to: (@convention(c) (AnyClass, Selector) -> UInt).self)
        let replacementBlock: @convention(block) (AnyObject) -> UInt = { object in
            originalCall(object as! AnyClass, selector) | mask
        }
        let replacement = imp_implementationWithBlock(replacementBlock)
        let installed = method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, installed)
            imp_removeBlock(replacement)
        }
        dispatch()
    }
}

// The ops layer behind Ask — the one implementation of Runtime/ask/PROTOCOL.md,
// reached two ways: the in-app harness's bridge and the persistent sessions on
// agent.sock. Both hand `perform` an op and an args object and get one JSON-able
// answer back; events raised in between — a tab navigating, a lease letting go
// — go to whoever set `onEvent`.
//
// The unit of permission is the tab: a tab opened through `tabs.open` is the
// agent's own (the bench kind — ⚗, out of your session and history); any other
// tab can be read or driven only after `tabs.attach` has found it consented —
// the composer's chips being where consent comes from, recorded in
// `grantedTabs` the one way that can ever happen: `tabs.grant`, the in-app
// door's own op, which no tool call may name and no socket may speak. Real
// input — the `event` tier of clicks and keys — is allowed on exactly those
// tabs.

/// Which session a `perform` is for. The in-app harness is one logical
/// session (`.app`) no matter how many turns it runs; each agent.sock
/// connection is its own, keyed by a token rather than the fd — a recycled
/// descriptor must never collide with a dead connection's leftovers.
enum DriveOrigin: Hashable {
    case app
    case socket(UUID)
    /// An unattended run (Routines.swift): the *routine's* id is the
    /// session — its tabs, leases and remembered always-rules outlive
    /// any single run of it.
    case routine(UUID)

    /// The routing tag an event's `_session` carries: who it is for. Never
    /// goes on the wire — the socket strips it while fanning out.
    var tag: String {
        switch self {
        case .app: return "app"
        case .socket(let id): return "sock-" + id.uuidString
        case .routine(let id): return "routine-" + id.uuidString.prefix(8)
        }
    }
}

extension Driving {
    /// The in-app door: a call without an origin is the app's own session.
    /// (A protocol requirement can't carry a default argument, so the
    /// three-argument shape the harness already calls lives here.)
    func perform(_ op: String, _ args: [String: Any], done: @escaping ([String: Any]) -> Void) {
        perform(op, args, from: .app, done: done)
    }
}

final class Drive: Driving {
    private static let agentWorld = WKContentWorld.world(name: "SearchAgent")
    /// The window's state, never owned: `AskRuntime.drive` is put up in
    /// Browser.init and the browser outlives everything that asks it things.
    unowned let browser: Browser

    /// Events between answers, for `tab.navigated`, `lease.lost` and friends.
    /// Set by whoever is listening — the socket once a session subscribes, the
    /// harness for its own sessions. Written on the main queue.
    var onEvent: ((String, [String: Any]) -> Void)? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.armDiff() }
            }
        }
    }

    /// One session's share of the driver's state: the tabs it attached, the
    /// tabs it opened, the foreground-action leases it holds, and how many
    /// of its ops are still in flight (which is what `done` counts down).
    /// Sessions must never see each other's — a second socket client used
    /// to be able to drive a tab the first had attached and to hear its
    /// lease.lost and done.
    @MainActor private struct Share {
        var attached = Set<UUID>()
        var mine = Set<UUID>()
        var leases = Set<UUID>()
        var pending = 0
    }

    /// The living sessions, by origin. `.app` is the in-app agent; each
    /// socket connection is a session of its own for as long as it lives.
    @MainActor private var sessions: [DriveOrigin: Share] = [:]

    /// Each session's leash (design/permissions.md §1) — what its ops may
    /// do once it holds a tab. Sockets default to `.full`: the same-uid,
    /// chmod-600 wire is already the app's trust level, and the mode is
    /// the agent's own. `.app` is pushed the current chat's mode by Mind
    /// (`setMode`), and defaults to the Settings pick meanwhile.
    @MainActor private var modes: [DriveOrigin: AskMode] = [:]

    /// A request the gate held for a card: the op and its `finish` parked
    /// together, so the verdict — or the session ending — can settle it.
    /// `Share.pending` stays up meanwhile, which is what keeps `done`
    /// honest. No timeout — a parked finish is first-class.
    @MainActor private struct PendingApproval {
        var origin: DriveOrigin
        var op: String
        var args: [String: Any]
        var summary: String
        var host: String
        var finish: ([String: Any]) -> Void
        var evidence: [String: Any]?
    }
    @MainActor private var guardChecks = Set<DriveOrigin>()
    @MainActor private var guardGeneration: [DriveOrigin: Int] = [:]
    @MainActor private var pendingApprovals: [UUID: PendingApproval] = [:]

    @MainActor
    private final class KeyResend {
        let event: NSEvent
        weak var view: PageView?
        let action: Selector
        let tabID: UUID
        let origin: DriveOrigin

        init(event: NSEvent, view: PageView, action: Selector, tabID: UUID, origin: DriveOrigin) {
            self.event = event
            self.view = view
            self.action = action
            self.tabID = tabID
            self.origin = origin
        }
    }
    @MainActor
    private final class MouseAck {
        weak var view: PageView?
        let key: ObjectIdentifier
        let origin: DriveOrigin
        private let done: (Bool, Bool) -> Void
        private var watcher: UUID?
        private(set) var finished = false
        private var waiting = false
        private(set) var dialogPending = false

        init(view: PageView, origin: DriveOrigin, done: @escaping (Bool, Bool) -> Void) {
            self.view = view
            self.key = ObjectIdentifier(view)
            self.origin = origin
            self.done = done
        }

        func watch() -> Bool {
            guard let view else { return false }
            switch AgentInteractions.shared.watchPending(view, session: origin,
                found: { [weak self] in self?.noticePendingDialog() },
                cancelled: { [weak self] in self?.finish(dialogPending: false, cancelled: true) }) {
            case .unavailable: return true
            case .alreadyPending: return false
            case .watching(let id): watcher = id; return true
            }
        }

        func afterPendingMouseEvents(_ completion: @escaping () -> Void) {
            guard !finished else { return }
            if dialogPending { finish(dialogPending: true); return }
            guard let view else { finish(dialogPending: false); return }
            waiting = true
            let ready: () -> Void = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    if self.dialogPending { self.finish(dialogPending: true); return }
                    completion()
                }
            }
            let selector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
            guard view.responds(to: selector) else {
                view.evaluateJavaScript("void 0") { _, _ in ready() }
                return
            }
            typealias Completion = @convention(block) () -> Void
            typealias Call = @convention(c) (AnyObject, Selector, Completion) -> Void
            let callback: Completion = { ready() }
            unsafeBitCast(view.method(for: selector), to: Call.self)(view, selector, callback)
        }

        func continueAfterWait(_ completion: () -> Void) {
            guard !finished else { return }
            if dialogPending { finish(dialogPending: true); return }
            waiting = false
            completion()
        }

        func wait() {
            afterPendingMouseEvents { self.finish(dialogPending: false) }
        }

        private func noticePendingDialog() {
            dialogPending = true
            if waiting { finish(dialogPending: true) }
        }

        func finish(dialogPending: Bool, cancelled: Bool = false) {
            guard !finished else { return }
            finished = true
            if let watcher { AgentInteractions.shared.stopWatching(key, id: watcher) }
            done(dialogPending, cancelled)
        }
    }
    @MainActor private var keyBounceMonitor: Any?
    @MainActor private var keyResends: [KeyResend] = []
    @MainActor private var nativeMouseEventNumber = 0

    /// The chat the `.app` session last sent into — learned in `ask`,
    /// the only door a turn comes through. parkApproval needs it when the
    /// panel's `currentID` has gone (a `new` chat landing mid-turn nils
    /// it under the op that was about to ask): minting a bare UUID would
    /// park a card no chat can show.
    @MainActor private var appChat: UUID?

    /// "Always" clicks remembered per session as (op, host) — the card's
    /// `Always: submit · acme.com`, not "always submit". Same lifetime as
    /// every other consent here: gone with the chat, the socket, the app.
    @MainActor private var remembered: [DriveOrigin: Set<Policy.AlwaysKey>] = [:]
    @MainActor private let artifacts = AgentArtifacts()
    @MainActor private var socketApprovalUI = Set<DriveOrigin>()

    /// The consent registry: tabs the user handed the agent layer through a
    /// composer chip — which arrives as `tabs.grant` on the in-app door
    /// alone, never as an argument `tabs.attach` would read — remembered by
    /// the 8-hex id the protocol speaks in. A socket session may attach a
    /// tab found here; the wire can never write it. Entries die on the tab
    /// closing, with the app, when the last session holding the tab lets
    /// go, and with the chat itself — consent is the chat's, so a new or
    /// deleted one clears them all (`tabs.ungrantAll`).
    @MainActor private var grantedTabs = Set<String>()

    /// What the last row-diff saw — url and title by tab — so a navigation or
    /// a rename between ops still lands as an event.
    @MainActor private var seen: [UUID: (String, String)] = [:]
    @MainActor private var primed = false
    @MainActor private var diffTimer: DispatchSourceTimer?
    /// `drive()` calls whose answer the page owes us, by tab — so a commit
    /// that tears the context down can settle them instead of leaving the
    /// request to die of old age. The flag marks the op a mutation — one
    /// that may legitimately have caused the navigation it dies of.
    @MainActor private var flying: [UUID: [Int: (mutating: Bool, cancellationToken: String?, settle: ([String: Any]) -> Void)]] = [:]
    @MainActor private var nextFlight = 0

    /// Bumped while a synthetic event is being handed to a view, so the
    /// user's-own-act lease check doesn't mistake ours for theirs.
    static var injecting = 0
    /// The synthetic events themselves, kept briefly: WebKit hands a key the
    /// page didn't use back up the responder chain — the same event a second
    /// time, possibly after `injecting` has settled — and it is still not the
    /// user's hand. The window is generous — 256, a long typing burst — so a
    /// bounced key can't have been evicted before it comes back through.
    static private var injected: [NSEvent] = []
    static func note(_ event: NSEvent) {
        injected.append(event)
        if injected.count > 256 { injected.removeFirst(injected.count - 256) }
    }

    init(browser: Browser) {
        self.browser = browser
    }

    // MARK: - the door

    /// `Driving`. The work is all main-queue — callers reach us there already
    /// (the socket's reader, the harness's bridge), but the protocol doesn't
    /// promise it, so a stray caller is hopped over rather than trusted.
    func perform(_ op: String, _ args: [String: Any], from origin: DriveOrigin = .app, done: @escaping ([String: Any]) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.serve(op, args, from: origin, done: done) }
        } else {
            Task { @MainActor in self.serve(op, args, from: origin, done: done) }
        }
    }

    /// A session ended — a socket closing, never the app: give back its
    /// leases and attaches and close the tabs it opened, so nothing a gone
    /// agent set up keeps running. The socket calls it while the descriptor
    /// is still its own, before the fd can be handed out again.
    @MainActor
    func leave(_ origin: DriveOrigin) {
        keyResends.removeAll { $0.origin == origin }
        clearHighlights(from: origin)
        AgentCursor.shared.sleep(origin)
        AgentInteractions.shared.release(origin)
        for id in Array(inspectorClients.keys) { releaseInspector(id, from: origin) }
        inspectorEvents[origin] = nil
        inspectorDropped[origin] = nil
        guard let share = sessions.removeValue(forKey: origin) else { return }
        for id in share.mine {
            if let tab = browser.allTabs.first(where: { $0.id == id }), tab.bench {
                browser.close(tab)
            }
        }
        // What the departed session was holding lapses the way a detach
        // would: a user tab nobody holds anymore loses its consent and its
        // place on the watched row.
        for id in share.attached {
            let held = sessions.values.contains { $0.attached.contains(id) || $0.mine.contains(id) }
            if !held, let tab = browser.allTabs.first(where: { $0.id == id }), !tab.bench {
                tab.built?.restoreRenderingAfterAgent()
                grantedTabs.remove(Bench.short(tab))
                seen.removeValue(forKey: id)
            }
        }
        // Its cards, its remembered always-rules and its mode die with it —
        // consent's whole lifetime is the session's.
        denyPending(for: origin, reason: "the session ended")
        for download in artifacts.remove(origin) { download.cancel(nil) }
        remembered[origin] = nil
        modes[origin] = nil
        socketApprovalUI.remove(origin)
        // The closed rows — if anyone subscribed — announce themselves in
        // the diff, which also sweeps whatever state of theirs remains.
        diff()
    }

    /// A run ended — the routine's tab work is done: its parked asks settle
    /// denied, its bench tabs close, its leases and attaches release. Unlike
    /// `leave` the session's remembered always-rules and mode SURVIVE —
    /// consent belongs to the routine, and the next run inherits it.
    @MainActor
    func endRun(_ origin: DriveOrigin) {
        keyResends.removeAll { $0.origin == origin }
        clearHighlights(from: origin)
        AgentCursor.shared.sleep(origin)
        denyPending(for: origin, reason: "the run ended")
        for download in artifacts.remove(origin) { download.cancel(nil) }
        AgentInteractions.shared.release(origin)
        for id in Array(inspectorClients.keys) { releaseInspector(id, from: origin) }
        inspectorEvents[origin] = nil
        inspectorDropped[origin] = nil
        guard let share = sessions.removeValue(forKey: origin) else { diff(); return }
        for id in share.mine {
            if let tab = browser.allTabs.first(where: { $0.id == id }), tab.bench {
                browser.close(tab)
            }
        }
        // Attached user tabs lapse the way a detach leaves them — a routine
        // only ever holds one while a live chat's chip covers it.
        for id in share.attached {
            let held = sessions.values.contains { $0.attached.contains(id) || $0.mine.contains(id) }
            if !held, let tab = browser.allTabs.first(where: { $0.id == id }), !tab.bench {
                tab.built?.restoreRenderingAfterAgent()
                grantedTabs.remove(Bench.short(tab))
                seen.removeValue(forKey: id)
            }
        }
        diff()
    }

    @MainActor private var inspectors: [UUID: AgentInspector] = [:]
    @MainActor private var inspectorClients: [UUID: Set<DriveOrigin>] = [:]
    @MainActor private var inspectorEvents: [DriveOrigin: [UUID: [[String: Any]]]] = [:]
    @MainActor private var inspectorDropped: [DriveOrigin: [UUID: Int]] = [:]
    @MainActor private var inspectorArtifacts: [UUID: Set<String>] = [:]

    @MainActor
    private func saveInspectorArtifact(_ value: [String: Any], tab: UUID) throws -> [String: Any] {
        let result = try AgentInspectorArtifact.write(json: value, directory: Store.file("inspector-artifacts"))
        if let artifact = result["artifact"] as? [String: Any], let path = artifact["path"] as? String {
            for id in Array(inspectorArtifacts.keys) {
                let kept = Set((inspectorArtifacts[id] ?? []).filter { FileManager.default.fileExists(atPath: $0) })
                inspectorArtifacts[id] = kept.isEmpty ? nil : kept
            }
            inspectorArtifacts[tab, default: []].insert(path)
        }
        return result
    }

    @MainActor
    private func releaseInspector(_ id: UUID, from origin: DriveOrigin) {
        inspectors[id]?.release(owner: origin.tag)
        inspectorClients[id]?.remove(origin)
        inspectorEvents[origin]?[id] = nil
        inspectorDropped[origin]?[id] = nil
        if inspectorClients[id]?.isEmpty == true {
            inspectors.removeValue(forKey: id)?.disconnect()
            inspectorClients[id] = nil
        }
    }

    @MainActor
    private func inspect(_ op: String, _ args: [String: Any], from origin: DriveOrigin,
                         done: @escaping ([String: Any]) -> Void) {
        guard let tab = own(args, done, origin), let web = view(of: tab, done) else { return }
        if op == "inspector.read" {
            guard let path = args["path"] as? String, inspectorArtifacts[tab.id]?.contains(path) == true else {
                done(["error": "artifact does not belong to this tab", "code": "NOT_FOUND"]); return
            }
            let offset = (args["offset"] as? NSNumber)?.doubleValue ?? 0
            let length = (args["length"] as? NSNumber)?.doubleValue ?? 16_384
            guard offset >= 0, offset <= Double(128 * 1024 * 1024), offset.rounded() == offset,
                  length >= 4, length <= 65_536, length.rounded() == length else {
                done(["error": "offset must be a nonnegative byte index; length must be 4...65536"]); return
            }
            do {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? file.close() }
                let size = try file.seekToEnd()
                try file.seek(toOffset: UInt64(offset))
                var data = try file.read(upToCount: Int(length)) ?? Data()
                var start = Int(offset)
                while let first = data.first, first & 0xC0 == 0x80 { data.removeFirst(); start += 1 }
                for _ in 0..<3 where String(data: data, encoding: .utf8) == nil { data.removeLast() }
                done(["text": String(decoding: data, as: UTF8.self), "offset": start,
                      "nextOffset": start + data.count, "eof": start + data.count >= size])
            } catch { done(["error": error.localizedDescription, "code": "ARTIFACT_EXPIRED"]) }
            return
        }
        if op == "inspector.detach" {
            releaseInspector(tab.id, from: origin)
            done(["detached": true]); return
        }
        if op == "inspector.events" {
            let pending = inspectorEvents[origin]?[tab.id] ?? []
            let events = pending.filter { event in
                guard let artifact = event["artifact"] as? [String: Any],
                      let path = artifact["path"] as? String else { return true }
                return FileManager.default.fileExists(atPath: path)
            }
            let dropped = (inspectorDropped[origin]?[tab.id] ?? 0) + pending.count - events.count
            inspectorEvents[origin]?[tab.id] = []
            inspectorDropped[origin]?[tab.id] = 0
            done(["events": events, "dropped": dropped]); return
        }
        if inspectors[tab.id] == nil {
            let inspector = AgentInspector(web: web)
            inspectors[tab.id] = inspector
            inspector.onEvent = { [weak self, weak tab] event in
                guard let self, let tab else { return }
                var event = event
                event["tab"] = Bench.short(tab)
                let bytes = (try? JSONSerialization.data(withJSONObject: event).count) ?? 0
                if bytes >= 65_536 {
                    do {
                        let artifact = try self.saveInspectorArtifact(event, tab: tab.id)
                        event = ["tab": Bench.short(tab), "method": event["method"] ?? "",
                                 "targetID": event["targetID"] ?? "", "artifact": artifact["artifact"]!]
                    } catch {
                        event = ["tab": Bench.short(tab), "method": "Search.artifactError", "error": error.localizedDescription]
                    }
                }
                for client in self.inspectorClients[tab.id] ?? [] where self.granted(tab, client) {
                    var history = self.inspectorEvents[client]?[tab.id] ?? []
                    if history.count >= 64 {
                        history.removeFirst()
                        self.inspectorDropped[client, default: [:]][tab.id, default: 0] += 1
                    }
                    history.append(event)
                    self.inspectorEvents[client, default: [:]][tab.id] = history
                    self.emit("inspector.event", event, to: client)
                }
            }
        }
        inspectorClients[tab.id, default: []].insert(origin)
        let finish: (Result<[String: Any], Error>) -> Void = { result in
            switch result {
            case .success(let reply):
                if args["save"] as? Bool == true || ((try? JSONSerialization.data(withJSONObject: reply).count) ?? 0) > 262_144 {
                    do { done(try self.saveInspectorArtifact(reply, tab: tab.id)) }
                    catch { done(["error": error.localizedDescription, "code": "ARTIFACT", "outcome": "unknown"]) }
                } else { done(reply) }
            case .failure(let error):
                var reply: [String: Any] = ["error": error.localizedDescription, "code": "INSPECTOR"]
                if let code = (error as? AgentInspector.Failure)?.code { reply["protocolCode"] = code }
                if error.localizedDescription.lowercased().contains("timed out") || error.localizedDescription.lowercased().contains("disconnect") {
                    reply["outcome"] = "unknown"
                }
                done(reply)
            }
        }
        if op == "inspector.attach" { inspectors[tab.id]?.capabilities(completion: finish) }
        else {
            guard let method = args["method"] as? String,
                  args["params"] == nil || args["params"] is [String: Any] else {
                done(["error": "inspector.send needs method and object params"]); return
            }
            inspectors[tab.id]?.perform(method: method, params: args["params"] as? [String: Any] ?? [:],
                targetID: args["targetId"] as? String, owner: origin.tag, completion: finish)
        }
    }

    @MainActor private var cancellations: [String: AgentCancellation] = [:]

    @MainActor
    func perform(_ op: String, _ args: [String: Any], from origin: DriveOrigin,
                 cancellation: AgentCancellation, tokenReady: ((String) -> Void)? = nil,
                 done: @escaping ([String: Any]) -> Void) {
        let token = UUID().uuidString
        tokenReady?(token)
        performCancellable(token: token, args: args, from: origin,
                           cancellation: cancellation, done: done) { args, finish in
            self.perform(op, args, from: origin) { result in finish(result) }
        }
    }

    /// The single cancellation door for native operations. The injected operation closure
    /// keeps its callback one-shot even when cancellation and a late native reply race.
    @MainActor
    private func performCancellable(
        token: String,
        args: [String: Any],
        from origin: DriveOrigin,
        cancellation: AgentCancellation,
        done: @escaping ([String: Any]) -> Void,
        operation: (_ args: [String: Any], _ finish: @escaping ([String: Any]) -> Void) -> Void
    ) {
        cancellations[token] = cancellation
        var finished = false
        let finish: ([String: Any]) -> Void = { [weak self] result in
            guard !finished else { return }
            finished = true
            cancellation.onCancel = nil
            self?.cancellations[token] = nil
            done(result)
        }
        cancellation.onCancel = { [weak self] in
            let approvals = self?.pendingApprovals.filter { $0.value.args["_cancelToken"] as? String == token }.map(\.key) ?? []
            // Latch the canonical reply before cleanup invokes synchronous callbacks.
            if approvals.isEmpty {
                finish(["error": "cancelled; outcome unknown", "code": "CANCELLED",
                        "guardStopped": true, "outcome": "unknown"])
            } else {
                finish(["error": "cancelled before approval", "code": "GUARD_CANCELLED",
                        "guardStopped": true, "outcome": "cancelled"])
            }
            if let self {
                if let view = self.tab(args)?.built {
                    if !self.cancelScriptFlights(token, in: view) {
                        self.drive(view, "function(d) { (d.__guardCancelled || (d.__guardCancelled = new Set())).add(\(self.json(token))); return {ok:true}; }") { _ in }
                    }
                }
                for id in approvals {
                    Mind.shared.removeApproval(id)
                    Routines.shared.removeApproval(id)
                    self.pendingApprovals.removeValue(forKey: id)?.finish([
                        "error": "cancelled before approval", "code": "GUARD_CANCELLED", "guardStopped": true])
                }
            }
        }
        var args = args
        args["_cancelToken"] = token
        operation(args) { result in finish(result) }
    }

    /// Exercises the exact production cancellation door without starting WebKit work.
    /// `check-queue` uses this to cover dropped native replies and pending approval cleanup.
    @MainActor
    func checkCancellationDoor() -> [String: Any] {
        let token = UUID().uuidString
        let cancellation = AgentCancellation()
        var rawReply: (([String: Any]) -> Void)?
        var replyCount = 0
        var result: [String: Any] = [:]
        performCancellable(token: token, args: [:], from: .socket(UUID()), cancellation: cancellation,
                           done: { result = $0; replyCount += 1 }) { _, finish in
            rawReply = finish
        }
        cancellation.cancel()
        let cancelledSynchronously = replyCount == 1 && result["code"] as? String == "CANCELLED"
            && result["outcome"] as? String == "unknown"
        rawReply?(["ok": true])
        rawReply?(["late": true])
        var lateStepReply: [String: Any]?
        let lateStepSuppressed = cancelled(["_cancelToken": token]) { lateStepReply = $0 }
        let activeOK = cancelledSynchronously && cancellations[token] == nil
            && replyCount == 1 && lateStepSuppressed
            && lateStepReply?["code"] as? String == "CANCELLED"

        let approvalToken = UUID().uuidString
        let approvalCancellation = AgentCancellation()
        let approvalID = UUID()
        var approvalReplyCount = 0
        var approvalResult: [String: Any] = [:]
        pendingApprovals[approvalID] = PendingApproval(
            origin: .socket(UUID()), op: "page.click", args: ["_cancelToken": approvalToken],
            summary: "test approval", host: "", finish: { _ in }, evidence: nil)
        performCancellable(token: approvalToken, args: [:], from: .socket(UUID()),
                           cancellation: approvalCancellation,
                           done: { approvalResult = $0; approvalReplyCount += 1 }) { _, _ in }
        approvalCancellation.cancel()
        let approvalOK = approvalReplyCount == 1 && approvalResult["code"] as? String == "GUARD_CANCELLED"
            && approvalResult["outcome"] as? String == "cancelled"
                && pendingApprovals[approvalID] == nil && cancellations[approvalToken] == nil
        return ["ok": activeOK && approvalOK, "active_cancel_replied_once": cancelledSynchronously,
                "active_token_removed": cancellations[token] == nil, "late_raw_reply_ignored": replyCount == 1,
                "late_native_step_suppressed": lateStepSuppressed, "approval_known_cancelled": approvalOK]
    }

    /// Internal state assertion used only by the bounded benchmark preflight.
    @MainActor
    func checkScriptState(_ view: WKWebView, requestToken: String) -> [String: Bool] {
        guard Store.testing, let tab = browser.allTabs.first(where: { $0.built === view }) else {
            return ["flight_present": false, "watcher_present": false,
                    "flight_removed": false, "watcher_removed": false]
        }
        let flightPresent = flying[tab.id]?.values.contains { $0.cancellationToken == requestToken } ?? false
        let watcherPresent = AgentInteractions.shared.hasWatcher(view, requestToken: requestToken)
        return ["flight_present": flightPresent, "watcher_present": watcherPresent,
                "flight_removed": !flightPresent, "watcher_removed": !watcherPresent]
    }

    @MainActor
    func checkScriptCancellationGate(_ view: PageView, origin: DriveOrigin, tab: String) -> Bool {
        let requestToken = UUID().uuidString
        let cancellation = AgentCancellation()
        var starts = 0, lateReplies = 0, replies = 0
        var result: [String: Any] = [:]
        performCancellable(token: requestToken, args: ["tab": tab], from: origin,
                           cancellation: cancellation, done: { result = $0; replies += 1 }) { _, finish in
            self.scriptCompletion(view, mutating: false, cancellationToken: requestToken, { _ in }) { _ in
                self.scriptCompletion(view, mutating: false, cancellationToken: requestToken,
                                      { _ in starts += 1 }, { _ in lateReplies += 1 })
                finish(["error": "translated internal cancellation error"])
            }
        }
        let active = checkScriptState(view, requestToken: requestToken)
        cancellation.cancel()
        let state = checkScriptState(view, requestToken: requestToken)
        return starts == 0 && lateReplies == 1 && replies == 1 && result["code"] as? String == "CANCELLED"
            && result["outcome"] as? String == "unknown"
            && active["flight_present"] == true && active["watcher_present"] == true
            && state["flight_removed"] == true && state["watcher_removed"] == true
    }

    @MainActor
    private func cancelled(_ args: [String: Any], _ done: ([String: Any]) -> Void) -> Bool {
        guard let token = args["_cancelToken"] as? String else { return false }
        guard let cancellation = cancellations[token] else {
            done(["error": "request already finished", "code": "CANCELLED", "guardStopped": true,
                  "outcome": "unknown"])
            return true
        }
        guard cancellation.isCancelled else { return false }
        done(["error": "cancelled before the next native action", "code": "GUARD_CANCELLED",
              "guardStopped": true, "outcome": "unknown"])
        return true
    }

    @MainActor
    func surfaceTab(_ tab: Tab) {
        for origin in Array(sessions.keys) {
            if sessions[origin]?.mine.remove(tab.id) != nil { sessions[origin]?.attached.insert(tab.id) }
        }
    }

    @MainActor
    private func configureBenchmarkDialogs(_ tab: Tab, origin: DriveOrigin) {
        guard Store.testing, ProcessInfo.processInfo.environment["SEARCH_BENCHMARK"] == "broad",
              tab.bench, sessions[origin]?.mine.contains(tab.id) == true,
              BenchmarkRuns.shared.websiteStore(for: origin) != nil else { return }
        _ = AgentInteractions.shared.configure(tab.web, session: origin, enabled: true) { [weak self, weak tab] data in
            guard let self, let tab, self.granted(tab, origin) else { return }
            var data = data
            data["tab"] = Bench.short(tab)
            self.emit("page.dialog", data, to: origin)
        }
    }

    @MainActor
    func adoptAgentTab(_ tab: Tab, from opener: Tab) {
        guard tab.bench else { return }
        for origin in Array(sessions.keys) where sessions[origin]?.mine.contains(opener.id) == true {
            sessions[origin]?.mine.insert(tab.id)
            configureBenchmarkDialogs(tab, origin: origin)
        }
    }

    @MainActor
    func replaceTab(_ old: Tab, with new: Tab) {
        if let web = old.built { AgentInteractions.shared.clear(web) }
        for origin in Array(sessions.keys) {
            if sessions[origin]?.mine.remove(old.id) != nil { sessions[origin]?.mine.insert(new.id) }
            if sessions[origin]?.attached.remove(old.id) != nil { sessions[origin]?.attached.insert(new.id) }
            if sessions[origin]?.leases.remove(old.id) != nil { sessions[origin]?.leases.insert(new.id) }
            configureBenchmarkDialogs(new, origin: origin)
        }
        let consented = grantedTabs.contains(Bench.short(old))
        drop(old.id)
        if consented { grantedTabs.insert(Bench.short(new)) }
    }

    // MARK: - modes

    /// The session's leash for the gate. A socket is `.full` unless it set
    /// its own (`agent.mode`, or `mode` on subscribe) — same-uid clients
    /// already hold the app's trust; a mode on a wire session is that
    /// agent's self-restraint or a test's probe. `.app` is whatever Mind
    /// last pushed — the current chat's mode — falling back to the global
    /// default in Settings ("ask.mode", guard out of the box).
    @MainActor
    func mode(for origin: DriveOrigin) -> AskMode {
        if let set = modes[origin] { return set }
        switch origin {
        case .app:
            return Store.settings.string(forKey: "ask.mode").flatMap(AskMode.init(rawValue:)) ?? .guard
        case .socket:
            return .full
        case .routine:
            // The routine's own pick, set at dispatch — and guard when a
            // run somehow outruns it: unattended defaults to asking.
            return .guard
        }
    }

    /// Mind pushes the current chat's mode here on send/select/newChat —
    /// the `.app` session's mode *is* the chat's. (Also how a socket's own
    /// `agent.mode` lands; the op refuses `.app` so the model can't lift
    /// its own leash.)
    @MainActor
    func setMode(_ mode: AskMode, for origin: DriveOrigin) {
        modes[origin] = mode
    }

    /// What a tab the session opens calls itself — the app's "Ask", a
    /// routine's own name, a socket's plain "Agent".
    @MainActor
    private func agentLabel(for origin: DriveOrigin) -> String {
        switch origin {
        case .app: return "Ask"
        case .routine(let id): return routineName?(id) ?? "Routine"
        case .socket: return "Agent"
        }
    }

    /// The session holding a tab, if one does — the download gate in
    /// Browser asks whose bench tab started a file on its way to disk.
    @MainActor
    func holder(of tab: Tab) -> DriveOrigin? {
        sessions.first(where: { $0.value.mine.contains(tab.id) || $0.value.attached.contains(tab.id) })?.key
    }

    @MainActor
    func sessionTabs(_ origin: DriveOrigin) -> [Tab] {
        browser.allTabs.filter { granted($0, origin) }
    }

    /// Agent-owned full-mode downloads go into the session's short-lived
    /// artifact world, never the user's Downloads folder.
    @MainActor
    func agentDownloadFolder(_ download: WKDownload, tab: Tab) -> URL? {
        guard tab.bench, let origin = holder(of: tab), mode(for: origin) == .full else { return nil }
        return artifacts.startDownload(download, tab: Bench.short(tab), host: tab.address?.host() ?? "", origin: origin)
    }

    @MainActor
    func agentDownloadFinished(_ download: WKDownload, file: URL) -> Bool {
        guard artifacts.owns(download) else { return false }
        guard let event = artifacts.finish(download, file: file),
              let tag = event["origin"] as? String,
              let origin = sessions.keys.first(where: { $0.tag == tag }) else { return true }
        emit("artifact.created", ["artifact": event["artifact"] ?? [:]], to: origin)
        return true
    }

    @MainActor
    func agentDownloadFailed(_ download: WKDownload) -> Bool {
        guard artifacts.owns(download) else { return false }
        guard let event = artifacts.fail(download) else { return false }
        if let tag = event["origin"] as? String,
           let origin = sessions.keys.first(where: { $0.tag == tag }) {
            emit("artifact.failed", ["id": event["id"] ?? "", "tab": event["tab"] ?? ""], to: origin)
        }
        return true
    }

    /// The card's answer. `allow` dispatches the original op fresh — a tab
    /// that went meanwhile errors the ordinary way through `own`/`view`;
    /// `always` remembers (op, host) for the session first; `deny` settles
    /// the parked call with the honest refusal.
    @MainActor
    func settleApproval(_ id: UUID, _ verdict: ApprovalVerdict) {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        if verdict == .deny {
            pending.finish(["error": "Action cancelled by you", "code": "GUARD_CANCELLED", "guardStopped": true])
            return
        }
        // Old persisted Always verdicts now approve this action once only.
        let generation = guardGeneration[pending.origin, default: 0]
        guardChecks.insert(pending.origin)
        inspectGuard(pending.op, pending.args, from: pending.origin) { [weak self] evidence in
            guard let self else { return }
            self.guardChecks.remove(pending.origin)
            if self.cancelled(pending.args, pending.finish) { return }
            guard self.guardGeneration[pending.origin, default: 0] == generation else {
                pending.finish(["error": "Approval cancelled", "code": "GUARD_CANCELLED", "guardStopped": true]); return
            }
            if let error = evidence["error"] {
                pending.finish(["error": error, "code": "GUARD_CHANGED", "guardStopped": true]); return
            }
            guard evidence["fingerprint"] as? String == pending.evidence?["fingerprint"] as? String else {
                if Store.testing,
                   let before = (pending.evidence?["fingerprint"] as? String)?.data(using: .utf8),
                   let after = (evidence["fingerprint"] as? String)?.data(using: .utf8),
                   let a = try? JSONSerialization.jsonObject(with: before) as? NSDictionary,
                   let b = try? JSONSerialization.jsonObject(with: after) as? NSDictionary {
                    let changed = a.allKeys.compactMap { $0 as? String }.filter { !NSDictionary(dictionary: ["v": a[$0] ?? NSNull()]).isEqual(to: ["v": b[$0] ?? NSNull()]) }
                    NSLog("[guard-test] changed evidence keys: %@", changed.joined(separator: ", "))
                }
                self.parkApproval(pending.op, pending.args, pending.finish, from: pending.origin,
                                  tab: self.tab(pending.args), evidence: evidence)
                return
            }
            var args = pending.args
            if pending.op.hasPrefix("act."), !["act.hover", "act.scroll"].contains(pending.op) {
                args["_guardFingerprint"] = evidence["fingerprint"]
                args["_guardOp"] = pending.op
            }
            self.dispatch(pending.op, args, pending.finish, from: pending.origin)
        }
        diff()
    }

    @MainActor
    func refreshApproval(_ id: UUID) {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        // Resolve the old UI card before recapturing; this never executes it.
        switch pending.origin {
        case .app, .socket: Mind.shared.removeApproval(id)
        case .routine: Routines.shared.removeApproval(id)
        }
        let generation = guardGeneration[pending.origin, default: 0]
        guardChecks.insert(pending.origin)
        inspectGuard(pending.op, pending.args, from: pending.origin) { [weak self] evidence in
            guard let self else { return }
            self.guardChecks.remove(pending.origin)
            if self.cancelled(pending.args, pending.finish) { return }
            guard self.guardGeneration[pending.origin, default: 0] == generation else {
                pending.finish(["error": "Action cancelled", "code": "GUARD_CANCELLED", "guardStopped": true]); return
            }
            if let error = evidence["error"] {
                pending.finish(["error": error, "code": "GUARD_UNAVAILABLE", "guardStopped": true]); return
            }
            self.parkApproval(pending.op, pending.args, pending.finish, from: pending.origin,
                              tab: self.tab(pending.args), evidence: evidence)
        }
    }

    /// Every ask one session still holds, settled denied — a stopped or
    /// replaced turn, a dead socket, a chat that ended. A `finish` that
    /// never fires is a pending that never ends and a JS promise that
    /// never resolves, so the seat has to be emptied, not waited out.
    @MainActor
    func denyPending(for origin: DriveOrigin, reason: String = "the turn ended") {
        guardGeneration[origin, default: 0] += 1
        guardChecks.remove(origin)
        let ids = pendingApprovals.filter { $0.value.origin == origin }.map(\.key)
        for id in ids {
            guard let pending = pendingApprovals.removeValue(forKey: id) else { continue }
            switch origin {
            case .app, .socket: Mind.shared.removeApproval(id)
            case .routine: Routines.shared.removeApproval(id)
            }
            pending.finish(["error": "Cancelled: \(reason)", "code": "GUARD_CANCELLED", "guardStopped": true])
        }
    }

    @MainActor
    private func serve(_ op: String, _ args: [String: Any], from origin: DriveOrigin, done: @escaping ([String: Any]) -> Void) {
        armDiff()
        let args = args.filter { !$0.key.hasPrefix("_guard") && $0.key != "says" && $0.key != "guardCheck" }
        // Check the args before they can reach JSONSerialization: a
        // non-finite number or a non-JSON type is an uncatchable
        // NSInvalidArgumentException there, not a throw — the request
        // bounces here instead of the app going down mid-op.
        guard Drive.jsonSafe(args) else {
            done(["error": "args aren't JSON-safe — a number ran off the end, or a non-JSON type came in"])
            return
        }
        sessions[origin, default: Share()].pending += 1
        var fired = false
        let finish: ([String: Any]) -> Void = { [weak self] reply in
            // One answer, and always one — bench's rule, and more load-bearing
            // here where an unanswered request just sits pending forever.
            guard !fired else { return }
            fired = true
            var reply = reply
            if reply["outcome"] as? String == "unknown" { reply["guardStopped"] = true }
            done(reply)
            MainActor.assumeIsolated {
                guard let self, var share = self.sessions[origin], share.pending > 0 else { return }
                share.pending -= 1
                self.sessions[origin] = share
                if share.pending == 0 { self.emit("done", [:], to: origin) }
            }
        }
        let subject = tab(args)
        let leash = mode(for: origin)
        let mutates = Policy.classify(op, args: args, tab: subject).rawValue > OpClass.read.rawValue
        if mutates && (guardChecks.contains(origin) || pendingApprovals.values.contains(where: { $0.origin == origin })) {
            finish(["error": "This run is waiting for approval", "code": "GUARD_WAITING", "guardStopped": true])
            return
        }
        if leash == .guard && mutates {
            guardChecks.insert(origin)
            let generation = guardGeneration[origin, default: 0]
            inspectGuard(op, args, from: origin) { [weak self] evidence in
                guard let self else { return }
                self.guardChecks.remove(origin)
                guard self.guardGeneration[origin, default: 0] == generation else {
                    finish(["error": "Action cancelled", "code": "GUARD_CANCELLED", "guardStopped": true]); return
                }
                if let error = evidence["error"] {
                    finish(["error": error, "code": "GUARD_UNAVAILABLE", "guardStopped": true]); return
                }
                if self.cancelled(args, finish) { return }
                let categories = (evidence["categories"] as? [String] ?? ["unverified"]).compactMap(GuardCategory.init(rawValue:))
                if categories.contains(where: { $0.enabled }) {
                    self.parkApproval(op, args, finish, from: origin, tab: subject, evidence: evidence)
                } else {
                    var checked = args
                    if op.hasPrefix("act."), !["act.hover", "act.scroll"].contains(op) {
                        checked["_guardFingerprint"] = evidence["fingerprint"]
                        checked["_guardOp"] = op
                    }
                    self.dispatch(op, checked, finish, from: origin)
                }
            }
        } else {
            switch Policy.check(op, args: args, mode: leash, tab: subject, remembered: []) {
            case .allow: dispatch(op, args, finish, from: origin)
            case .deny(let why): finish(["error": why, "code": "MODE"])
            case .ask: parkApproval(op, args, finish, from: origin, tab: subject)
            }
        }
        diff()
    }

    /// The op behind the finish line — split from `serve` so a card's
    /// verdict can run the very same dispatch the gate's `allow` would
    /// have. Re-runs `own`/`view` fresh: a tab that navigated or closed
    /// while its card was up errors the ordinary way.
    @MainActor
    private func dispatch(_ op: String, _ args: [String: Any], _ answer: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        if cancelled(args, answer) { return }
        var finish = answer
        if op.hasPrefix("page.") || op.hasPrefix("act."), let subject = tab(args), granted(subject, origin) {
            let id = subject.id
            AgentCursor.shared.wake(id, from: origin)
            finish = { reply in
                AgentCursor.shared.rest(id)
                answer(reply)
            }
        }
        let selects = op == "tabs.select"
            || (op == "tabs.open" && args["foreground"] as? Bool == true)
            || (op == "tabs.surface" && (args["foreground"] as? Bool ?? true))
        if selects && !browser.prefs.agentFocus {
            finish(["error": "Agent tab switching is disabled in Settings > Ask. Use foreground:false for background tabs.", "code": "ATTENTION_DISABLED"])
            return
        }
        if op == "page.highlight" && !browser.prefs.agentHighlights {
            finish(["error": "Agent highlights are disabled in Settings > Ask.", "code": "ATTENTION_DISABLED"])
            return
        }
        switch op {
        case "ping":
            finish(["pong": true])
        case "subscribe":
            // Subscribing is the socket's business — it decides which clients
            // hear events. In-app there's nothing to mark; AgentSocket owns
            // onEvent today. Either way the op answers. A `mode` arg sets the
            // session's leash along the way — a socket's own only: `.app`'s
            // is the chat's (pushed by Mind) and a routine's is the routine's
            // (set at dispatch) — a model must never lift its own leash.
            if case .socket = origin, let value = args["mode"] {
                guard let raw = value as? String, let mode = AskMode(rawValue: raw) else {
                    finish(["error": "subscribe mode needs guard|full"]); return
                }
                modes[origin] = mode
            }
            finish(["subscribed": true])
        case "tabs.list":
            finish(["tabs": browser.allTabs.map { Bench.shared.describe($0, in: browser) }])
        case "tabs.open":
            open(args, finish, from: origin)
        case "tabs.attach":
            attach(args, finish, from: origin)
        case "tabs.grant":
            grant(args, finish, from: origin)
        case "tabs.ungrantAll":
            ungrantAll(finish, from: origin)
        case "tabs.detach":
            detach(args, finish, from: origin)
        case "tabs.close":
            closeTab(args, finish, from: origin)
        case "tabs.select":
            selectTab(args, finish, from: origin)
        case "tabs.surface":
            guard let tab = own(args, finish, origin) else { return }
            guard browser.surfaceAgentTab(tab, select: args["foreground"] as? Bool ?? true) else {
                finish(["error": "tab is already a normal tab", "code": "NOT_AGENT_TAB"])
                return
            }
            emit("tab.surfaced", ["id": Bench.short(tab)], to: origin)
            finish(["id": Bench.short(tab), "surfaced": true])
        case "inspector.attach", "inspector.send", "inspector.events", "inspector.detach", "inspector.read":
            inspect(op, args, from: origin, done: finish)
        case "page.dialogs", "page.dialog", "page.files":
            guard let tab = own(args, finish, origin), let web = view(of: tab, finish) else { return }
            let interactions = AgentInteractions.shared
            if op == "page.dialogs" {
                if let enabled = args["enabled"] as? Bool {
                    finish(interactions.configure(web, session: origin, enabled: enabled) { [weak self] data in
                        guard let self, self.granted(tab, origin) else { return }
                        var data = data
                        data["tab"] = Bench.short(tab)
                        self.emit("page.dialog", data, to: origin)
                    })
                } else { finish(interactions.status(web, session: origin)) }
            } else {
                finish(interactions.answer(web, session: origin, args: args, files: op == "page.files"))
            }
        case "page.go":
            go(args, finish, from: origin)
        case "page.back", "page.forward", "page.reload":
            nav(op, args, finish, from: origin)
        case "page.wait":
            wait(args, finish, from: origin)
        case "page.text":
            text(args, finish, from: origin)
        case "page.snapshot":
            snapshot(args, finish, from: origin)
        case "page.screenshot":
            screenshot(args, finish, from: origin)
        case "page.pdf":
            pdf(args, finish, from: origin)
        case "artifact.list":
            finish(["artifacts": artifacts.list(for: origin, tab: args["tab"] as? String)])
        case "artifact.read":
            guard let id = args["id"] as? String else { finish(["error": "artifact.read needs id"]); return }
            finish(artifacts.read(id: id, origin: origin, offset: args["offset"], length: args["length"]))
        case "page.eval":
            eval(args, finish, from: origin)
        case "page.code":
            code(args, finish, from: origin)
        case "page.console":
            console(args, finish, from: origin)
        case "page.frames":
            frames(args, finish, from: origin)
        case "page.highlight", "page.clearHighlight":
            guard let tab = own(args, finish, origin) else { return }
            if op == "page.clearHighlight" {
                guard let web = tab.built else { finish(["cleared": false]); return }
                drive(web, "function(d) { return d.clearHighlight(\(json(origin.tag))); }",
                      cancellationToken: args["_cancelToken"] as? String) { finish($0) }
            } else {
                let target = query("highlight", args)
                let duration = args["duration"] as? NSNumber
                guard target.count == 1, target.values.allSatisfy({ ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }),
                      args["duration"] == nil || (duration != nil && CFGetTypeID(duration!) != CFBooleanGetTypeID() && (1...30).contains(duration!.doubleValue)),
                      args["scroll"] == nil || args["scroll"] is Bool else {
                    finish(["error": "highlight needs one target, duration 1..30 seconds, and optional boolean scroll", "code": "INVALID_ARGUMENT"])
                    return
                }
                guard let web = view(of: tab, finish) else { return }
                drive(web, "function(d) { return d.highlight(\(json(query("highlight", args))), \(json(args)), \(json(origin.tag))); }",
                      cancellationToken: args["_cancelToken"] as? String) { finish($0) }
            }
        case "act.click":
            click(args, finish, from: origin)
        case "act.type":
            type(args, finish, from: origin)
        case "act.press":
            press(args, finish, from: origin)
        case "act.clickAt":
            clickAt(args, finish, from: origin)
        case "act.drag":
            drag(args, finish, from: origin)
        case "act.fill", "act.hover", "act.scroll", "act.select", "act.check", "act.submit":
            actJS(op, args, finish, from: origin)
        case "agent.tabs":
            finish(["tabs": browser.allTabs.filter(\.bench).map { Bench.shared.describe($0, in: browser) }])
        case "agent.probe":
            finish(Bench.shared.probeReport(browser))
        case "agent.lease":
            lease(args, finish, from: origin)
        case "agent.mode":
            // A socket session sets its own leash. The app's session can't
            // move its — that's the chat's, pushed by Mind — and a routine's
            // is the routine's, set at dispatch — or the model would just
            // ask for "full" and step out from under the gate.
            guard case .socket = origin else {
                finish(["error": "this session's mode is set by its owner — sockets set their own only"])
                return
            }
            if args["to"] == nil {
                finish(["mode": mode(for: origin).rawValue, "uiApproval": socketApprovalUI.contains(origin)])
                return
            }
            guard let to = args["to"] as? String, let parsed = AskMode(rawValue: to) else {
                finish(["error": "agent.mode needs to: guard|full"])
                return
            }
            if parsed == .guard, args["uiApproval"] as? Bool == true, Mind.shared.currentID == nil {
                finish(["error": "open an Ask chat before opting into external Guard approvals", "code": "NEEDS_UI"])
                return
            }
            modes[origin] = parsed
            if parsed == .guard, args["uiApproval"] as? Bool == true { socketApprovalUI.insert(origin) }
            else { socketApprovalUI.remove(origin) }
            finish(["mode": parsed.rawValue, "uiApproval": socketApprovalUI.contains(origin)])
        case "ui.ask":
            // Posting/steering as the user is the interactive chat's door —
            // an unattended run reaching it is prompt injection into the
            // session that holds the grants, whatever its mode says.
            if case .routine = origin {
                finish(["error": "ui.ask is the app's door — a run can't speak for the user"])
            } else {
                ask(args, finish)
            }
        default:
            finish(["error": "unknown op “\(op)”"])
        }
        diff()
    }

    /// Resolve the actual page effect; tool-supplied labels never decide consent.
    @MainActor
    private func inspectGuard(_ op: String, _ args: [String: Any], from origin: DriveOrigin,
                              done: @escaping ([String: Any]) -> Void) {
        if op == "act.type", let text = args["text"] as? String, text.contains("\n") || text.contains("\r") {
            done(["error": "Use fill for multiline text, then a separate Enter action so submission can be reviewed.", "code": "GUARD_UNAVAILABLE"])
            return
        }
        if op.hasPrefix("act."), !["act.hover", "act.scroll"].contains(op) {
            guard let subject = own(args, done, origin), let view = view(of: subject, done) else { return }
            drive(view, "function(d) { return (\(GuardPage.inspect))(d, \(json(op)), \(json(actArgs(args)))); }",
                  cancellationToken: args["_cancelToken"] as? String) { out in
                MainActor.assumeIsolated { done(out) }
            }
            return
        }
        if args["tab"] != nil, own(args, done, origin) == nil { return }
        let subject = tab(args)
        let categories = Policy.categories(op, args: args, tab: subject)
        let material = ["op": op, "args": args.filter { !$0.key.hasPrefix("_") },
                        "url": subject?.address?.absoluteString ?? "", "tab": subject?.id.uuidString ?? ""] as [String: Any]
        let fingerprint = (try? JSONSerialization.data(withJSONObject: material, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var evidence: [String: Any] = ["categories": categories.map(\.rawValue),
              "summary": Policy.describe(op, args: args, tab: subject),
              "details": (categories.contains(.unverified) ? "This operation's effects cannot be verified. Review its full scope before allowing it.\n" : "") + (categories.isEmpty ? "" : json(args.filter { !$0.key.hasPrefix("_") && $0.key != "why" })),
              "actionLabel": categories.contains(.sharing) ? "Share files" : "Allow action",
              "fingerprint": fingerprint, "sensitive": true,
              "url": subject?.address?.absoluteString ?? ""]
        guard !categories.isEmpty, let view = subject?.built else { done(evidence); return }
        drive(view, "function(d) { return (\(GuardPage.inspect))(d, 'guard.context', {}); }",
              cancellationToken: args["_cancelToken"] as? String) { out in
            MainActor.assumeIsolated {
                guard out["error"] == nil, let page = out["fingerprint"] as? String else {
                    done(["error": "Cannot inspect the page for approval", "code": "GUARD_UNAVAILABLE"]); return
                }
                evidence["fingerprint"] = fingerprint + page
                evidence["sensitive"] = out["sensitive"]
                done(evidence)
            }
        }
    }

    /// Checked immediately before native input as well as when the card resolves.
    @MainActor
    private func validateGuard(_ view: PageView, _ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, at point: [Double]? = nil,
                               perform: @escaping () -> Void) {
        guard let expected = args["_guardFingerprint"] as? String,
              let op = args["_guardOp"] as? String else { perform(); return }
        let hitCheck: String
        if let point {
            hitCheck = """
            var target = d.resolve(\(json(query("click", args))));
            var hit = document.elementFromPoint(\(point[0]), \(point[1]));
            while (hit && hit.tagName === 'IFRAME' && hit.contentDocument && target.ownerDocument !== hit.ownerDocument) {
              var box = hit.getBoundingClientRect();
              hit = hit.contentDocument.elementFromPoint(\(point[0]) - box.left, \(point[1]) - box.top);
            }
            if (!hit || !(hit === target || target.contains(hit))) return {error:'Click target moved or is covered'};
            """
        } else { hitCheck = "" }
        drive(view, "function(d) { \(hitCheck) return (\(GuardPage.inspect))(d, \(json(op)), \(json(actArgs(args)))); }",
              cancellationToken: args["_cancelToken"] as? String) { out in
            MainActor.assumeIsolated {
                if self.cancelled(args, done) { return }
                guard out["error"] == nil, out["fingerprint"] as? String == expected else {
                    done(["error": "The action changed. Review it again before continuing.", "code": "GUARD_CHANGED", "guardStopped": true]); return
                }
                perform()
            }
        }
    }

    @MainActor
    private func guardCall(_ op: String, _ args: [String: Any], query: Any, verb: String) -> String {
        let plain = json(actArgs(args))
        guard let expected = args["_guardFingerprint"] as? String else {
            return "function(d) { return d.act(\(json(verb)), \(json(query)), \(plain)); }"
        }
        return """
        function(d) {
          var args = \(plain);
          args.guardCheck = function() {
            if (d.__guardCancelled && d.__guardCancelled.has(\(json(args["_cancelToken"] ?? "")))) return false;
            var fresh = (\(GuardPage.inspect))(d, \(json(op)), args);
            return !fresh.error && fresh.fingerprint === \(json(expected));
          };
          return d.act(\(json(verb)), \(json(query)), args);
        }
        """
    }

    /// One event out. `to` scopes it to a single session — a `done` or a
    /// `lease.lost` is the asking session's own business; nothing `to` is a
    /// broadcast, which `tab.*` is: every subscribed session watches the
    /// same tabs, so they all hear it. The tag travels as `_session` in the
    /// data and the socket strips it while fanning out.
    @MainActor
    private func emit(_ event: String, _ data: [String: Any], to origin: DriveOrigin? = nil) {
        var data = data
        if let origin { data["_session"] = origin.tag }
        onEvent?(event, data)
    }

    // MARK: - finding and permitting a tab

    /// A request's tab: `args["tab"]` (the protocol's name for it), with `id`
    /// taken as the same thing for callers that think in bench's spelling.
    @MainActor
    private func tab(_ args: [String: Any]) -> Tab? {
        let ref = ((args["tab"] ?? args["id"]) as? String)?.lowercased() ?? ""
        guard !ref.isEmpty else { return nil }
        return Bench.shared.find(ref, in: browser)
    }

    /// Read and driven alike: the tab is the asking session's own — opened
    /// by it or attached to it. An agent tab one session opened is nobody
    /// else's to drive; a loose one (bench.sock's, the ⚗ menu's) belongs to
    /// no session until attached.
    @MainActor
    private func granted(_ tab: Tab, _ origin: DriveOrigin) -> Bool {
        guard let share = sessions[origin] else { return false }
        return share.mine.contains(tab.id) || share.attached.contains(tab.id)
    }

    /// Resolve the request's tab and its permission, answering the error and
    /// returning nil when either fails.
    @MainActor
    private func own(_ args: [String: Any], _ done: ([String: Any]) -> Void, _ origin: DriveOrigin) -> Tab? {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return nil
        }
        guard granted(tab, origin) else {
            done(["error": "tab \(Bench.short(tab)) is not this session's — attach it first (its chip in Ask)"])
            return nil
        }
        return tab
    }

    /// The tab's page, painted or paintable. A sleeping or never-built tab is
    /// an error, never a reason to stand a view up — `tab.built` is the only
    /// one of the two that doesn't build.
    @MainActor
    private func view(of tab: Tab, _ done: ([String: Any]) -> Void) -> PageView? {
        guard let view = tab.built else {
            done(["error": tab.asleep
                  ? "tab \(Bench.short(tab)) is asleep — page.reload or tabs.select it first"
                  : "tab \(Bench.short(tab)) has no page yet"])
            return nil
        }
        // A page needs a window to lay out and paint in; one nobody is
        // looking at goes to the offscreen room, as bench tabs always have.
        Bench.shared.house(tab)
        return view
    }

    /// The ask path (design/permissions.md §3). The op's `finish` parks in
    /// `pendingApprovals` — `Share.pending` stays up, `done` never fires,
    /// the harness's promise just waits — while the card goes up through
    /// the same door `ui.ask` uses: `Mind.raise`. A socket reaches that door
    /// only after explicitly opting in through `agent.mode`.
    ///
    /// Who catches a parked card an unattended origin raises — the
    /// routines controller parks it on the live run's waitingApprovals.
    /// The sink owns the card's chat: it stamps the run's, never Mind's.
    /// Registered at start; nil means nothing out there can show a card
    /// and the op takes the honest NEEDS_UI the wire always got.
    @MainActor var approvalSink: ((AskApproval, DriveOrigin) -> Void)?
    /// The routine's name for a bench tab it opens — set by the
    /// controller so the tab reads "nightly report", not "Agent".
    @MainActor var routineName: ((UUID) -> String?)?

    @MainActor
    private func parkApproval(_ op: String, _ args: [String: Any], _ finish: @escaping ([String: Any]) -> Void,
                              from origin: DriveOrigin, tab subject: Tab?, evidence: [String: Any]? = nil) {
        // Where the card goes up: the app's chat rail, the opted-in socket's
        // current Ask chat, or the live run's parked list through the sink.
        let raise: ((AskApproval) -> Void)?
        switch origin {
        case .app:
            raise = { Mind.shared.raise($0) }
        case .routine:
            raise = approvalSink.map { sink in { sink($0, origin) } }
        case .socket:
            raise = socketApprovalUI.contains(origin) && Mind.shared.currentID != nil
                ? { Mind.shared.open = true; Mind.shared.raise($0) } : nil
        }
        guard let raise else {
            finish(["error": "\(op) needs approval — the wire can't be shown a card",
                    "code": "NEEDS_UI"])
            return
        }
        let id = UUID()
        // The chat the card lives in: for .app, the panel's current;
        // failing that, the chat this session last sent into (appChat —
        // kept for exactly this gap, currentID nil'd mid-turn); failing
        // that, the newest on record, checked so a deleted chat can't be
        // named. For a routine the sink stamps the run's chat — what
        // stands in here is only a placeholder that never leaves Drive.
        let chat: UUID?
        if case .routine = origin {
            chat = nil
        } else if case .socket = origin {
            chat = socketApprovalUI.contains(origin) ? Mind.shared.currentID : nil
        } else {
            chat = Mind.shared.runningChatID ?? Mind.shared.currentID
                ?? appChat.flatMap { id in Mind.shared.chats.contains(where: { $0.id == id }) ? id : nil }
                ?? Mind.shared.chats.first?.id
            if chat == nil {
                NSLog("[drive] approval for %@ found no chat to live in — raising anyway", op)
            }
        }
        var approval = AskApproval(
            id: id,
            chat: chat ?? UUID(),
            op: op,
            summary: evidence?["summary"] as? String ?? Policy.describe(op, args: args, tab: subject),
            why: (args["why"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            tabID: subject.map(Bench.short),
            host: (evidence?["url"] as? String).flatMap { URL(string: $0)?.host } ?? Policy.host(of: subject, args: args))
        approval.categories = (evidence?["categories"] as? [String])?.compactMap(GuardCategory.init(rawValue:))
        approval.details = evidence?["details"] as? String
        approval.actionLabel = evidence?["actionLabel"] as? String
        pendingApprovals[id] = PendingApproval(
            origin: origin, op: op, args: args,
            summary: approval.summary, host: approval.host ?? "", finish: finish, evidence: evidence)
        // Evidence: the tab as it stands. `built` only — the card is never
        // the reason a view exists. The shot lands on the card when it
        // can; the raise itself doesn't wait on paint.
        guard let view = subject?.built, evidence?["sensitive"] as? Bool == false else {
            approval.previewUnavailable = "Preview omitted because it may contain credentials or unverified content."
            raise(approval)
            return
        }
        let file = shotsFolder().appendingPathComponent("approval-\(id.uuidString).png")
        Bench.shared.shoot(view, to: file, width: 1000) { [weak self] out in
            // The ask may have settled while the shot painted — a stop or
            // denyPending answering it mid-flight. Raising now would post
            // a zombie card nobody can settle, so the seat's existence is
            // what the raise checks.
            MainActor.assumeIsolated {
                guard let self, self.pendingApprovals[id] != nil else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                self.drive(view, "function(d) { return (\(GuardPage.inspect))(d, 'guard.context', {}); }",
                           cancellationToken: args["_cancelToken"] as? String) { context in
                    MainActor.assumeIsolated {
                        guard self.pendingApprovals[id] != nil else {
                            try? FileManager.default.removeItem(at: file); return
                        }
                        if context["error"] != nil || context["sensitive"] as? Bool != false {
                            try? FileManager.default.removeItem(at: file)
                            approval.previewUnavailable = "Preview omitted because the page may contain credentials."
                        } else {
                            approval.shotPath = out["path"] as? String
                            if approval.shotPath == nil { approval.previewUnavailable = "Preview unavailable. Review the action details before continuing." }
                        }
                        raise(approval)
                    }
                }
            }
        }
    }

    // MARK: - tabs

    @MainActor
    private func open(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let url = (args["url"] as? String).flatMap(Address.url(from:)) else {
            done(["error": "tabs.open needs a url"])
            return
        }
        // Whose cookies the tab carries is a property fixed at open
        // (design/permissions.md §4): `fresh:true` asks for a tab signed in
        // as nobody — Tab(shy:) on a .nonPersistent store.
        let fresh = args["fresh"] as? Bool == true
        let store = Store.testing && ProcessInfo.processInfo.environment["SEARCH_BENCHMARK"] == "broad" && !fresh
            ? BenchmarkRuns.shared.websiteStore(for: origin) : nil
        let tab = browser.benchOpen(url, shy: fresh, store: store)
        tab.agentGroup = origin.tag
        tab.agentName = String((args["agentName"] as? String ?? agentLabel(for: origin)).prefix(80))
        sessions[origin, default: Share()].mine.insert(tab.id)
        configureBenchmarkDialogs(tab, origin: origin)
        Bench.shared.house(tab)
        // Selecting on the real window is deliberately allowed for a tab the
        // agent opened — the attention was asked for on purpose.
        if args["foreground"] as? Bool == true { browser.select(tab) }
        done(["id": Bench.short(tab)])
    }

    @MainActor
    private func attach(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        // Consent is never this op's argument, on any door: `granted:true`
        // here can only be a model or the wire reaching for a chip nobody
        // gave — the registry is written by `tabs.grant` alone. Refused
        // rather than read, so the flag is dead whoever sends it.
        if args["granted"] as? Bool == true {
            done(["error": "granted isn't an attach argument — grants come through the grant door (tabs.grant, in-app only)"])
            return
        }
        if tab.bench {
            // An agent tab another session opened is its own — not for
            // taking. A loose one attaches to whoever asks first.
            if let holder = sessions.first(where: { $0.value.mine.contains(tab.id) })?.key,
               holder != origin {
                done(["error": "tab \(Bench.short(tab)) is another session's own"])
                return
            }
            sessions[origin, default: Share()].attached.insert(tab.id)
            done(["id": Bench.short(tab), "attached": true])
            return
        }
        // One of the user's own. Consent is the composer's chip, recorded
        // by the grant door — a socket session may attach a tab the chip
        // granted, but the wire itself can never grant.
        guard grantedTabs.contains(Bench.short(tab)) else {
            done(["error": "tab \(Bench.short(tab)) needs its chip in Ask — " +
                  (origin == .app ? "consent isn't an attach argument" : "the wire can't grant it")])
            return
        }
        sessions[origin, default: Share()].attached.insert(tab.id)
        done(["id": Bench.short(tab), "attached": true])
    }

    /// The chip's own door — the one op that writes the consent registry,
    /// and the app's own session is the only caller it takes: the socket
    /// is refused outright, and the harness never routes a `tool` message
    /// here (kind:"grant" is the bridge shape for it, which attachTabs
    /// alone emits). Granting a user tab remembers it in `grantedTabs` and
    /// attaches it to the app's session in one step. A bench tab needs no
    /// consent — a grant on one is just an attach.
    @MainActor
    private func grant(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard origin == .app else {
            done(["error": "tabs.grant is the in-app door — the wire can't grant a tab"])
            return
        }
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        if tab.bench {
            // A grant on an agent tab is just an attach — hand it over
            // without the `granted` key, which attach refuses outright.
            var rest = args
            rest.removeValue(forKey: "granted")
            attach(rest, done, from: origin)
            return
        }
        grantedTabs.insert(Bench.short(tab))
        sessions[.app, default: Share()].attached.insert(tab.id)
        done(["id": Bench.short(tab), "attached": true])
    }

    /// The consent's other half: the chat it was made for is over — a fresh
    /// one started or this one deleted, which is the only way Mind calls
    /// this — so every grant ends at once. The registry empties and each
    /// session's attach on a granted user tab lets go with it, a held lease
    /// announcing its `lease.lost` as ever. The app's own door may say so,
    /// never the wire: the side that can't grant a tab can't ungrant one
    /// either. Tabs a session opened and bench tabs were never the
    /// registry's to give, and stay held.
    @MainActor
    private func ungrantAll(_ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard origin == .app else {
            done(["error": "tabs.ungrantAll is the in-app door — the wire can't end a grant"])
            return
        }
        // The registry speaks the 8-hex id; the sessions keep the tab's
        // UUID — resolve through the live tab list. A granted tab since
        // closed has already left all three by way of `drop`.
        let ended = grantedTabs
        grantedTabs.removeAll()
        var revoked = Set<UUID>()
        for who in Array(sessions.keys) {
            let attached = sessions[who]?.attached ?? []
            let ids = Set(browser.allTabs.filter {
                !$0.bench && (ended.contains(Bench.short($0)) || (who == .app && attached.contains($0.id)))
            }.map(\.id))
            revoked.formUnion(ids)
            sessions[who]?.attached.subtract(ids)
            for id in ids {
                if sessions[who]?.leases.remove(id) != nil {
                    emit("lease.lost", ["id": String(id.uuidString.prefix(8)).lowercased()], to: who)
                }
                releaseInspector(id, from: who)
                if let web = browser.allTabs.first(where: { $0.id == id })?.built {
                    AgentInteractions.shared.release(web, session: who)
                    clearHighlight(web, from: who)
                }
            }
        }
        for id in revoked where !sessions.values.contains(where: { $0.attached.contains(id) || $0.mine.contains(id) }) {
            browser.allTabs.first(where: { $0.id == id })?.built?.restoreRenderingAfterAgent()
            seen.removeValue(forKey: id)
        }
        // The chat's asks and its remembered always-rules die with its
        // consent — one lifetime.
        denyPending(for: .app, reason: "the chat's consent ended")
        remembered[.app] = nil
        done(["ungranted": ended.count])
    }

    @MainActor
    private func detach(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        // Releasing is the calling session's own business: its attach and
        // its leases on the tab go, and every other session's hold stands —
        // a session can't detach a tab out from under another. Consent
        // lapses only when the last holder lets go: while anyone still
        // holds the tab the chip's grant is in use, and a rider releasing
        // its own attach mustn't burn it. A tab the session opened stays
        // `mine` regardless — detaching isn't disowning.
        releaseInspector(tab.id, from: origin)
        AgentCursor.shared.sleep(tab: tab.id)
        if let web = tab.built {
            AgentInteractions.shared.release(web, session: origin)
            clearHighlight(web, from: origin)
        }
        sessions[origin]?.attached.remove(tab.id)
        sessions[origin]?.leases.remove(tab.id)
        let held = sessions.values.contains { $0.attached.contains(tab.id) || $0.mine.contains(tab.id) }
        if !held, !tab.bench {
            tab.built?.restoreRenderingAfterAgent()
            grantedTabs.remove(Bench.short(tab))
            // The tab leaves the watched row too: forget what the diff last
            // saw so its absence isn't announced as `tab.closed`. A tab
            // still held — and any bench tab — stays watched regardless.
            seen.removeValue(forKey: tab.id)
        }
        done(["id": Bench.short(tab), "attached": false])
    }

    /// Everything anyone held on a tab that's gone: its consent, every
    /// session's attach/open/lease, and any page call it still owes — which
    /// settles with an error rather than hanging the request that made it.
    /// `seen` is left for the row-diff: the tab's `tab.closed` is still owed
    /// to whoever is listening.
    @MainActor
    private func drop(_ id: UUID) {
        keyResends.removeAll { $0.tabID == id }
        AgentCursor.shared.forget(id)
        inspectorArtifacts[id] = nil
        for client in inspectorClients[id] ?? [] { releaseInspector(id, from: client) }
        grantedTabs.remove(String(id.uuidString.prefix(8)).lowercased())
        for origin in Array(sessions.keys) {
            sessions[origin]?.attached.remove(id)
            sessions[origin]?.mine.remove(id)
            sessions[origin]?.leases.remove(id)
        }
        if let owed = flying.removeValue(forKey: id) {
            for flight in owed.values { flight.settle(["error": "the tab is gone"]) }
        }
    }

    @MainActor
    private func closeTab(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = tab(args) else {
            done(["error": "no tab “\((args["tab"] ?? args["id"]) as? String ?? "")” — see tabs.list"])
            return
        }
        // Same rule as `bench close`, narrowed to what the session holds:
        // the agent's own tabs go; the user's and other sessions' never do.
        guard tab.bench else {
            done(["error": "not an agent tab — only tabs the agent opened can be closed from here"])
            return
        }
        guard granted(tab, origin) else {
            done(["error": "tab \(Bench.short(tab)) is not this session's — attach it first"])
            return
        }
        let id = Bench.short(tab)
        browser.close(tab)
        drop(tab.id)
        done(["id": id, "closed": true])
    }

    @MainActor
    private func selectTab(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        browser.select(tab)
        done(["id": Bench.short(tab), "active": true])
    }

    // MARK: - page

    @MainActor
    func clearHighlights(from origin: DriveOrigin? = nil) {
        for tab in browser.allTabs {
            if let web = tab.built { clearHighlight(web, from: origin) }
        }
    }

    @MainActor
    private func clearHighlight(_ web: PageView, from origin: DriveOrigin?) {
        // Never build a view or inject a driver just to clean up an overlay.
        web.evaluateJavaScript("window.__drive && window.__drive.clearHighlight(\(origin.map { json($0.tag) } ?? "null"))",
                               in: nil, in: Drive.agentWorld) { _ in }
    }

    @MainActor
    private func go(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        guard let url = (args["url"] as? String).flatMap(Address.url(from:)) else {
            done(["error": "page.go needs a url"])
            return
        }
        tab.go(to: url)
        Bench.shared.house(tab)
        done(["id": Bench.short(tab), "url": tab.address?.absoluteString ?? url.absoluteString])
    }

    @MainActor
    private func nav(_ op: String, _ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        switch op {
        case "page.back", "page.forward":
            // Going back in a tab that isn't holding a page would only stand
            // one up to nothing — a sleeping tab's history waits for a reload.
            guard tab.built != nil else {
                done(["error": "tab \(Bench.short(tab)) is asleep — page.reload or tabs.select it first"])
                return
            }
            Bench.shared.house(tab)
            if op == "page.back" { tab.back() } else { tab.forward() }
        case "page.reload":
            // Reload is the wake itself: it brings a rested tab back rather
            // than refusing it. A blank one has nothing to reload, though.
            guard tab.built != nil || tab.asleep else {
                done(["error": "tab \(Bench.short(tab)) has no page yet"])
                return
            }
            tab.reload()
            Bench.shared.house(tab)
        default:
            break
        }
        done(["id": Bench.short(tab)])
    }

    @MainActor
    private func wait(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        let limit = Date().addingTimeInterval((args["seconds"] as? NSNumber)?.doubleValue ?? 30)
        Bench.shared.wait(for: tab, in: browser, until: limit, done)
    }

    @MainActor
    private func text(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        view.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
            MainActor.assumeIsolated {
                if let error { done(["error": error.localizedDescription]); return }
                var text = (value as? String) ?? ""
                var cut = false
                if text.count > 120_000 { text = String(text.prefix(120_000)); cut = true }
                done(["text": text, "truncated": cut,
                      "url": tab.address?.absoluteString ?? "", "title": tab.title])
            }
        }
    }

    @MainActor
    private func eval(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let js = args["js"] as? String else { done(["error": "page.eval needs js"]); return }
        scriptCompletion(view, mutating: false, cancellationToken: args["_cancelToken"] as? String, { complete in
            view.evaluateJavaScript(js) { value, error in
                MainActor.assumeIsolated {
                    if let error { complete(["error": error.localizedDescription]); return }
                    complete(["value": Bench.plain(value)])
                }
            }
        }, done)
    }

    // MARK: - drive.js

    /// Whether `JSONSerialization.data` can take the value at all. It does
    /// not throw a catchable error on a non-finite number or a non-JSON type
    /// (NSDate, NSData, …) — it raises NSInvalidArgumentException, which
    /// takes the app down with it, and `-1e999`/`NaN` arrive off the wire as
    /// exactly those numbers. So it's checked, not caught: every leaf a
    /// finite number, a string, a bool, or null; every key a string.
    nonisolated static func jsonSafe(_ value: Any, depth: Int = 0) -> Bool {
        guard depth < 400 else { return false }
        switch value {
        case is NSNull, is String:
            return true
        case let number as NSNumber:
            return number.doubleValue.isFinite
        case let array as [Any]:
            return array.allSatisfy { jsonSafe($0, depth: depth + 1) }
        case let dict as [String: Any]:
            return dict.values.allSatisfy { jsonSafe($0, depth: depth + 1) }
        default:
            return false
        }
    }

    /// A literal for embedding in a script — a JSON value, which JavaScript
    /// is happy to read as its own. Fragments allowed because scalars are
    /// embedded too — a bare string thrown at JSONSerialization is not an
    /// error you can catch, it's an exception that takes the app with it.
    /// Callers check `jsonSafe` on the whole request first, so what reaches
    /// here has already been proven writable.
    @MainActor
    private func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Call into the page's `window.__drive`, loading drive.js into it first.
    /// The load is idempotent (the script's own `if (window.__drive)` guard),
    /// and a page that still has no driver afterwards answers the "not
    /// loaded" error rather than a thrown blank. `call` is a function taking
    /// `d`; what it returns may be a promise — `callAsyncJavaScript` waits
    /// for those, which is the only way `act` and `run` can answer at all.
    /// A thrown drive.js error keeps its `code` (STALE_REF and friends are
    /// part of the protocol, not noise). `mutating` marks a call whose action
    /// may legitimately end in the page navigating away — the act.* tier —
    /// so a commit mid-call still answers `navChanged`; any other op dying
    /// the same death produced nothing and is the error `navigated mid-call`.
    @MainActor
    private func drive(_ view: PageView, _ call: String, mutating: Bool = false,
                       world: WKContentWorld = Drive.agentWorld, cancellationToken: String? = nil,
                       _ done: @escaping ([String: Any]) -> Void) {
        let js = """
        window.__driveRefNamespace = \(world == .page ? "'code-'" : "''");
        \(AskJS.load("drive.js"))
        ;return (async function () {
          var d = window.__drive;
          if (!d) return { error: "drive.js not loaded" };
          // A tab painting in the dark (the offscreen room, anything
          // backgrounded) gets no animation frames, and drive.js's
          // actionability loop lives on them — lend it a 16ms tick for the
          // span of the call. The page's own rAF is restored after.
          var rafWas = window.requestAnimationFrame;
          var dark = document.visibilityState !== 'visible';
          if (dark) {
            try { window.requestAnimationFrame = function (f) { return setTimeout(function () { f(Date.now()); }, 16); }; }
            catch (e) { dark = false; }
          }
          try { return await (\(call))(d); }
          catch (e) {
            var o = { error: "" + (e && e.message || e) };
            if (e && e.code) o.code = "" + e.code;
            return o;
          }
          finally { if (dark) { try { window.requestAnimationFrame = rafWas; } catch (e) {} } }
        })()
        """
        scriptCompletion(view, mutating: mutating, cancellationToken: cancellationToken, { complete in
            view.callAsyncJavaScript(js, arguments: [:], in: nil, in: world) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value):
                        complete(value as? [String: Any] ?? ["value": Bench.plain(value)])
                    case .failure(let error):
                        complete(["error": error.localizedDescription])
                    }
                }
            }
        }, done)
    }

    /// One completion path for script calls that can outlive their WebKit
    /// callback. It also releases a blocked script when an intercepted dialog
    /// appears, leaving the caller free to query and answer it.
    @MainActor
    private func scriptCompletion(_ view: PageView, mutating: Bool, cancellationToken: String? = nil,
                                  _ start: (@escaping ([String: Any]) -> Void) -> Void,
                                  _ done: @escaping ([String: Any]) -> Void) {
        if let cancellationToken, cancelled(["_cancelToken": cancellationToken], done) { return }
        let tabID = browser.allTabs.first { $0.built === view }?.id
        let ticket = nextFlight; nextFlight += 1
        var settled = false
        var watcher: UUID?
        var reply: (([String: Any]) -> Void)? = done
        let settle: ([String: Any]) -> Void = { [weak self, weak view] out in
            guard !settled else { return }
            settled = true
            let complete = reply
            reply = nil
            if let watcher, let view {
                AgentInteractions.shared.stopWatching(ObjectIdentifier(view), id: watcher)
            }
            if let tabID { self?.flying[tabID]?[ticket] = nil }
            complete?(out)
        }
        if let tabID { flying[tabID, default: [:]][ticket] = (mutating, cancellationToken, settle) }
        switch AgentInteractions.shared.watchPending(view, requestToken: cancellationToken,
            found: { settle(["error": "JavaScript dialog is pending", "code": "DIALOG_PENDING",
                             "dialogPending": true, "outcome": "unknown"]) },
            cancelled: { settle(["error": "cancelled while waiting on JavaScript dialog",
                                 "code": "CANCELLED", "outcome": "unknown"]) }) {
        case .unavailable:
            break
        case .alreadyPending:
            settle(["error": "JavaScript dialog is pending", "code": "DIALOG_PENDING",
                    "dialogPending": true, "outcome": "unknown"])
        case .watching(let id):
            watcher = id
        }
        guard !settled else { return }
        start { result in settle(result) }
    }

    @MainActor
    @discardableResult
    private func cancelScriptFlights(_ token: String, in view: WKWebView) -> Bool {
        guard let tab = browser.allTabs.first(where: { $0.built === view }) else { return false }
        let settle = flying[tab.id]?.values
            .filter { $0.cancellationToken == token }
            .map(\.settle) ?? []
        for complete in settle {
            complete(["error": "cancelled; outcome unknown", "code": "CANCELLED",
                      "guardStopped": true, "outcome": "unknown"])
        }
        return !settle.isEmpty
    }

    /// A commit is the page's context going away. What it still owed us
    /// splits on what the call was doing: a mutation may well have caused
    /// the navigation it dies of, so it still answers "the action ran, the
    /// page moved" — but a read interrupted mid-call produced nothing, and
    /// saying so is the honest answer.
    @MainActor
    private func navigated(_ view: WKWebView) {
        guard let tab = browser.allTabs.first(where: { $0.built === view }),
              let owed = flying.removeValue(forKey: tab.id) else { return }
        for flight in owed.values {
            flight.settle(flight.mutating
                          ? ["ok": true, "navChanged": true]
                          : ["error": "navigated mid-call", "code": "NAVIGATED"])
        }
    }

    /// Called from `webView(_:didCommit:)` — the moment a new document
    /// replaces the one in-flight calls were talking to.
    static func noteCommit(webView: WKWebView) {
        MainActor.assumeIsolated { (AskRuntime.drive as? Drive)?.navigated(webView) }
    }

    @MainActor
    private func snapshot(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        var opts: [String: Any] = [:]
        for key in ["scope", "boxes", "textColors", "maxChars", "cssLocators", "interactive", "selector", "ref"] { if let v = args[key] { opts[key] = v } }
        drive(view, "function (d) { return d.snapshot(\(json(opts))); }",
              cancellationToken: args["_cancelToken"] as? String, done)
    }

    @MainActor
    private func code(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let js = args["js"] as? String else { done(["error": "page.code needs js"]); return }
        // run() answers {value, consoleLines} — the value as safe() carried
        // it, and how much the console heard meanwhile. A commit mid-run is
        // an error, not navChanged: a program torn down before it returned
        // produced nothing, whatever it was about to do.
        drive(view, "function (d) { return d.run(\(json(js))); }", world: .page,
              cancellationToken: args["_cancelToken"] as? String, done)
    }

    @MainActor
    private func console(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        drive(view, """
        function (d) {
          var c = d.console, m = (typeof c === 'function') ? c.call(d) : c;
          if (m && m.messages) return m;
          if (m) return { messages: m };
          return { messages: [] };
        }
        """, world: .page, cancellationToken: args["_cancelToken"] as? String, done)
    }

    @MainActor
    private func frames(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        drive(view, """
        function (d) {
          var f = d.frames, m = (typeof f === 'function') ? f.call(d) : f;
          if (m && m.frames) return m;
          if (m) return { frames: m };
          return { frames: [] };
        }
        """, cancellationToken: args["_cancelToken"] as? String, done)
    }

    // MARK: - screenshots

    /// Where shots go that no path was given for: the app's own folder, under
    /// ask/shots, named by tab and time.
    @MainActor
    private func shotsFolder() -> URL {
        let folder = Store.file("ask").appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    private func screenshot(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        let path = (args["path"] as? String).map { NSString(string: $0).expandingTildeInPath }
            ?? shotsFolder().appendingPathComponent("shot-\(Bench.short(tab))-\(Int(Date().timeIntervalSince1970 * 1000)).png").path
        let marks = args["marks"] as? Bool == true
        let width = (args["width"] as? NSNumber)?.doubleValue
        if let width, (!width.isFinite || width < 1 || width > 8192) {
            done(["error": "screenshot width must be a finite value from 1 to 8192", "code": "INVALID_ARGUMENT"])
            return
        }

        func finish(_ reply: [String: Any]) {
            if marks {
                drive(view, "function(d) { d.unmark(); return {ok:true}; }", cancellationToken: args["_cancelToken"] as? String) { _ in done(reply) }
            } else {
                done(reply)
            }
        }
        func viewport(_ done: @escaping ([Int]?, String?) -> Void) {
            drive(view, "function(d) { return {size: [innerWidth, innerHeight]}; }", cancellationToken: args["_cancelToken"] as? String) { out in
                guard let size = (out["size"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }),
                      size.count == 2, size.allSatisfy({ $0 > 0 }) else {
                    done(nil, out["error"] as? String ?? "page viewport is unavailable")
                    return
                }
                done(size, nil)
            }
        }
        func resized(_ source: NSBitmapImageRep, width: Int, height: Int) -> NSBitmapImageRep? {
            guard width > 0, height > 0,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let sourceImage = source.cgImage else { return nil }
            context.interpolationQuality = .high
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image)
        }
        func snap(_ viewportSize: [Int]) {
            if cancelled(args, done) { return }
            let shot = WKSnapshotConfiguration()
            shot.afterScreenUpdates = true
            if let width { shot.snapshotWidth = NSNumber(value: width) }
            view.takeSnapshot(with: shot) { image, error in
                MainActor.assumeIsolated {
                    if self.cancelled(args, done) { return }
                    guard let image, let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff)
                    else {
                        finish(["error": error?.localizedDescription ?? "no picture"])
                        return
                    }
                    // Agent coordinates use CSS pixels. A default AppKit
                    // snapshot is backing-scale pixels, so resample it to
                    // the page viewport before returning it. An explicit
                    // width retains WKSnapshotConfiguration's existing
                    // point-width behavior and reports its resulting scale.
                    var output = rep
                    if width == nil && (rep.pixelsWide != viewportSize[0] || rep.pixelsHigh != viewportSize[1]) {
                        guard let normalized = resized(rep, width: viewportSize[0], height: viewportSize[1]) else {
                            finish(["error": "could not normalize screenshot to CSS pixels"]); return
                        }
                        output = normalized
                    }
                    let png = output.representation(using: .png, properties: [:])
                    var data = png
                    if let bytes = png, bytes.count > 1_500_000 {
                        data = output.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                    }
                    guard let data else { finish(["error": "no picture"]); return }
                    if self.cancelled(args, done) { return }
                    do {
                        try data.write(to: URL(fileURLWithPath: path))
                        finish(["path": path, "width": output.pixelsWide, "height": output.pixelsHigh,
                                "viewport": ["width": viewportSize[0], "height": viewportSize[1]],
                                "scale": Double(output.pixelsWide) / Double(viewportSize[0]),
                                "data": data.base64EncodedString(),
                                "format": data.starts(with: Data([0x89, 0x50, 0x4e, 0x47])) ? "png" : "jpeg"])
                    } catch {
                        finish(["error": error.localizedDescription])
                    }
                }
            }
        }
        if marks {
            drive(view, "function(d) { d.mark(); return {ok:true}; }", cancellationToken: args["_cancelToken"] as? String) { _ in
                viewport { size, error in
                    guard let size else { finish(["error": error ?? "page viewport is unavailable"]); return }
                    snap(size)
                }
            }
        } else {
            viewport { size, error in
                guard let size else { finish(["error": error ?? "page viewport is unavailable"]); return }
                snap(size)
            }
        }
    }

    @MainActor
    private func pdf(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        view.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.cancelled(args, done) { return }
                guard self.granted(tab, origin) else {
                    done(["error": "tab ownership changed while rendering the PDF", "code": "CANCELLED"]); return
                }
                do {
                    let saved = try self.artifacts.savePDF(try result.get(), tab: Bench.short(tab),
                                                          host: tab.address?.host() ?? "", origin: origin)
                    done(saved)
                } catch {
                    done(["error": error.localizedDescription, "code": "PDF_FAILED"])
                }
            }
        }
    }

    // MARK: - actions

    /// What an act's locator keys amount to, for `__drive.resolve`. `ref`,
    /// `loc` (`css:`/`role:`/`href:`/`xpath:`), `css`, and — for verbs that
    /// don't take `text` as a payload — `text=…` by the element's words.
    @MainActor
    private func query(_ verb: String, _ args: [String: Any]) -> [String: Any] {
        if verb == "drag" {
            if let source = args["source"] as? [String: Any] { return source }
            if let source = args["source"] as? [Any] { return ["at": source] }
            return [:]
        }
        var q: [String: Any] = [:]
        for key in ["ref", "loc", "css"] { if let v = args[key] { q[key] = v } }
        if !["fill", "type", "press", "clickAt"].contains(verb), let t = args["text"] { q["text"] = t }
        return q
    }

    /// The arguments handed to `__drive.act` — everything but the tab, and
    /// never a gate-only key: the gate read `why` for the card's text, and
    /// the page is not the card's business.
    @MainActor
    private func actArgs(_ args: [String: Any]) -> [String: Any] {
        args.filter { $0.key != "tab" && $0.key != "_cancelToken" && !$0.key.hasPrefix("_guard") && !Policy.gateKeys.contains($0.key) }
    }

    @MainActor
    private func postSnapshotCall(_ args: [String: Any]) -> String {
        let opts: [String: Any] = ["maxChars": args["snapshotMaxChars"] ?? NSNull(),
                                  "cssLocators": args["cssLocators"] ?? true]
        return "function (d) { return d.snapshot(\(json(opts))); }"
    }

    /// A mutating action through drive.js, with a fresh snapshot folded in
    /// when the caller asked for one.
    @MainActor
    private func actJS(_ op: String, _ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        let verb = String(op.dropFirst(4))
        // Scroll's "page" is a word, not a locator — the driver reads
        // `query === 'page'` before it resolves anything.
        var q: Any = query(verb, args)
        if verb == "scroll" {
            if (args["ref"] as? String) == "page" { q = "page" }
            else if (q as? [String: Any])?.isEmpty == true { q = NSNull() }
        }
        let snapshotCall = postSnapshotCall(args)
        drive(view, guardCall(op, args, query: q, verb: verb), mutating: true,
              cancellationToken: args["_cancelToken"] as? String) { [weak self] out in
            MainActor.assumeIsolated {
                if out["error"] == nil {
                    let words = ["click": "Click", "hover": "Hover", "scroll": "Scroll", "fill": "Fill",
                                 "select": "Select", "check": "Check", "submit": "Submit"]
                    AgentCursor.shared.glide(tab.id, to: (out["at"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue },
                                             word: words[verb], tap: verb == "click" || verb == "check")
                }
                // drive.js folds a fresh snapshot in itself when asked; this
                // is the backstop for one that doesn't know withSnapshot.
                guard args["withSnapshot"] as? Bool == true, out["error"] == nil, out["snapshot"] == nil else {
                    done(out)
                    return
                }
                self?.drive(view, snapshotCall,
                            cancellationToken: args["_cancelToken"] as? String) { snap in
                    var out = out
                    if snap["error"] == nil {
                        out["snapshot"] = snap["snapshot"] ?? snap
                        out["snapshotTruncated"] = snap["truncated"] ?? false
                        out["snapshotVersion"] = snap["version"]
                    }
                    done(out)
                }
            }
        }
    }

    /// The middle of what a locator names, in the page's points, scrolled into
    /// view first — through `__drive` when there's a `ref`/`loc` to honour,
    /// through bench's finder for `css`/`text=`, which need nothing page-side.
    @MainActor
    private func point(_ view: PageView, _ q: [String: Any], cancellationToken: String? = nil,
                       _ done: @escaping ([Double]?, String?) -> Void) {
        drive(view, """
        function(d) {
          var el = d.resolve(\(json(q)));
          el.scrollIntoView({block:'center',inline:'nearest'});
          var r = el.getBoundingClientRect();
          return {at:[r.left+r.width/2,r.top+r.height/2]};
        }
        """, cancellationToken: cancellationToken) { out in
            done((out["at"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }, out["error"] as? String)
        }
    }

    @MainActor
    private func focus(_ view: PageView, _ q: [String: Any], cancellationToken: String? = nil,
                       _ done: @escaping (String?, [Double]?) -> Void) {
        guard !q.isEmpty else { done(nil, nil); return }
        drive(view, """
        function(d) {
          var el = d.resolve(\(json(q)));
          el.scrollIntoView({block:'center',inline:'nearest'});
          if (el.focus) el.focus();
          var r = el.getBoundingClientRect();
          return {ok:true, at:[r.left+Math.min(r.width/2, 24),r.top+r.height/2]};
        }
        """, cancellationToken: cancellationToken) { out in
            done(out["error"] as? String, (out["at"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue })
        }
    }

    @MainActor
    private func mousePointError(_ view: PageView, _ point: [Double]) -> [String: Any]? {
        guard point.count == 2, point.allSatisfy(\.isFinite), point[0] >= 0, point[1] >= 0,
              point[0] < view.bounds.width, point[1] < view.bounds.height else {
            return ["error": "click point must be finite and inside the page viewport", "code": "INVALID_ARGUMENT"]
        }
        return nil
    }

    /// A real press at a page point — down and up on the view itself, the way
    /// `bench tap` clicks: trusted, in whichever window the view is housed.
    @MainActor
    private func mouse(_ view: PageView, tab: Tab, at point: [Double], button: String, clicks: Int, flags: NSEvent.ModifierFlags,
                       origin: DriveOrigin, args: [String: Any] = [:], done: @escaping ([String: Any]?, Bool, Bool) -> Void) {
        if let error = mousePointError(view, point) { done(error, false, false); return }
        let word = button == "right" ? "Right-click" : (clicks > 1 ? "Double-click" : "Click")
        AgentCursor.shared.approach(tab.id, in: view, to: point, word: word) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var stopped: [String: Any]?
                if self.cancelled(args, { stopped = $0 }) { done(stopped, false, false); return }
                guard self.granted(tab, origin), tab.built === view else {
                    done(["error": "tab ownership or page changed", "code": "CANCELLED"], false, false)
                    return
                }
                AgentCursor.shared.tap(tab.id, at: point)
                self.pressMouse(view, tab: tab, at: point, button: button, clicks: clicks, flags: flags, origin: origin, done: done)
            }
        }
    }

    @MainActor
    private func pressMouse(_ view: PageView, tab: Tab, at point: [Double], button: String, clicks: Int, flags: NSEvent.ModifierFlags,
                       origin: DriveOrigin, done: @escaping ([String: Any]?, Bool, Bool) -> Void) {
        guard let window = view.window else { done(["error": "the tab's view has no window", "code": "NOT_VISIBLE"], false, false); return }
        let local = NSPoint(x: point[0], y: view.isFlipped ? point[1] : view.bounds.height - point[1])
        let spot = view.convert(local, to: nil)
        let downType: NSEvent.EventType
        let upType: NSEvent.EventType
        switch button {
        case "right": (downType, upType) = (.rightMouseDown, .rightMouseUp)
        case "middle": (downType, upType) = (.otherMouseDown, .otherMouseUp)
        default: (downType, upType) = (.leftMouseDown, .leftMouseUp)
        }
        var creationFailed = false
        let ack = MouseAck(view: view, origin: origin) { dialogPending, cancelled in
            let error = creationFailed ? ["error": "could not create native mouse event", "code": "ERROR"] as [String: Any] : nil
            done(error, dialogPending, cancelled)
        }
        guard ack.watch() else {
            done(["error": "a page dialog is already pending", "code": "DIALOG_PENDING"], true, false)
            return
        }
        Drive.injecting += 1
        defer { Drive.injecting -= 1 }
        outer: for click in 1...max(1, clicks) {
            for type in [downType, upType] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: spot, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: nativeMouseEventNumber, clickCount: click, pressure: type == downType ? 1 : 0
                ) else { creationFailed = true; break outer }
                nativeMouseEventNumber &+= 1
                let heldButtonMask: UInt = button == "right" ? 1 << 1 : (button == "middle" ? 1 << 2 : 1)
                let held = type == downType ? heldButtonMask : 0
                SyntheticMouseButtons.with(held) {
                    Drive.note(event)
                    switch type {
                    case .leftMouseDown: view.mouseDown(with: event)
                    case .leftMouseUp: view.mouseUp(with: event)
                    case .rightMouseDown: view.rightMouseDown(with: event)
                    case .rightMouseUp: view.rightMouseUp(with: event)
                    case .otherMouseDown: view.otherMouseDown(with: event)
                    case .otherMouseUp: view.otherMouseUp(with: event)
                    default: break
                    }
                }
                view.syntheticMousePoint = NSPoint(x: point[0], y: point[1])
            }
        }
        ack.wait()
    }

    /// One key, down and up, as a real event on the view — `bench key`'s
    /// delivery for a single press.
    @MainActor
    private func key(_ view: PageView, code: UInt16, chars: String, flags: NSEvent.ModifierFlags,
                     tabID: UUID, origin: DriveOrigin) {
        Drive.injecting += 1
        defer { Drive.injecting -= 1 }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            ) else { continue }
            Drive.note(event)
            if type == .keyDown {
                let action: Selector?
                if flags.contains(.command), !flags.contains(.shift), !flags.contains(.control), !flags.contains(.option), chars.count == 1 {
                    switch chars.lowercased() {
                    case "a": action = NSSelectorFromString("selectAll:")
                    case "c": action = NSSelectorFromString("copy:")
                    case "v": action = NSSelectorFromString("paste:")
                    case "x": action = NSSelectorFromString("cut:")
                    default: action = nil
                    }
                } else { action = nil }
                armKeyBounceMonitor()
                if let action {
                    let resend = KeyResend(event: event, view: view, action: action, tabID: tabID, origin: origin)
                    keyResends.append(resend)
                }
                view.keyDown(with: event)
            } else { view.keyUp(with: event) }
        }
    }

    @MainActor
    private func armKeyBounceMonitor() {
        guard keyBounceMonitor == nil else { return }
        keyBounceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.consumeKeyBounce(event) }
            return consumed ? nil : event
        }
    }

    @MainActor
    private func afterPendingKeyEvents(_ view: PageView, _ done: @escaping () -> Void) {
        func finished() {
            keyResends.removeAll { $0.view === view }
            done()
        }
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingKeyEvents:")
        guard view.responds(to: selector) else {
            view.evaluateJavaScript("void 0") { _, _ in MainActor.assumeIsolated { finished() } }
            return
        }
        typealias Completion = @convention(block) () -> Void
        typealias Call = @convention(c) (AnyObject, Selector, Completion) -> Void
        let completion: Completion = { MainActor.assumeIsolated { finished() } }
        unsafeBitCast(view.method(for: selector), to: Call.self)(view, selector, completion)
    }

    @MainActor
    private func consumeKeyBounce(_ event: NSEvent) -> Bool {
        if let index = keyResends.firstIndex(where: {
            $0.event.windowNumber == event.windowNumber && PageView.same($0.event, event)
        }) {
            let resend = keyResends.remove(at: index)
            if let view = resend.view, view.window?.windowNumber == event.windowNumber,
               let tab = browser.allTabs.first(where: { $0.id == resend.tabID }), tab.built === view,
               granted(tab, resend.origin) {
                _ = view.tryToPerform(resend.action, with: view)
            }
            return true
        }
        if let window = event.window, Bench.shared.isRoom(window) { return true }
        return Drive.injected.contains {
            $0.type == .keyDown && $0.windowNumber == event.windowNumber && PageView.same($0, event)
        }
    }

    @MainActor
    private func modifierFlag(_ name: String) -> NSEvent.ModifierFlags? {
        switch name.lowercased() {
        case "cmd", "meta": return .command
        case "shift": return .shift
        case "ctrl": return .control
        case "opt", "alt": return .option
        default: return nil
        }
    }

    @MainActor
    private func flags(_ raw: Any?) -> NSEvent.ModifierFlags? {
        guard let raw else { return [] }
        guard let names = raw as? [String] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            guard let flag = modifierFlag(name) else { return nil }
            flags.insert(flag)
        }
        return flags
    }

    /// A key by name — "Enter", "Tab", "Escape", "Backspace", "a" — as the
    /// key code and characters an event carries. The table is drive.js's own
    /// keymap's: same named keys, same digits, so a press lands the same with
    /// or without a driver in the page.
    @MainActor
    private func keyFor(_ rawName: String, flags rawFlags: NSEvent.ModifierFlags) -> (UInt16, String, NSEvent.ModifierFlags)? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = rawName.count == 1 ? [rawName] : trimmed.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var flags = rawFlags
        var explicitShift = flags.contains(.shift)
        for name in parts.dropLast() {
            guard let flag = modifierFlag(name) else { return nil }
            flags.insert(flag)
            explicitShift = explicitShift || flag == .shift
        }
        let name = parts.last!
        let key: (UInt16, String)
        switch name.lowercased() {
        case "enter", "return": key = (36, "\r")
        case "tab": key = (48, "\t")
        case "escape", "esc": key = (53, "\u{1B}")
        case "backspace": key = (51, "\u{7F}")
        case "delete", "del": key = (117, "\u{F728}")
        case " ", "space", "spacebar": key = (49, " ")
        case "arrowup", "up": key = (126, "\u{F700}")
        case "arrowdown", "down": key = (125, "\u{F701}")
        case "arrowleft", "left": key = (123, "\u{F702}")
        case "arrowright", "right": key = (124, "\u{F703}")
        case "home": key = (115, "\u{F729}")
        case "end": key = (119, "\u{F72B}")
        case "pageup": key = (116, "\u{F72C}")
        case "pagedown": key = (121, "\u{F72D}")
        case "f1": key = (122, "\u{F704}")
        case "f2": key = (120, "\u{F705}")
        case "f3": key = (99, "\u{F706}")
        case "f4": key = (118, "\u{F707}")
        case "f5": key = (96, "\u{F708}")
        case "f6": key = (97, "\u{F709}")
        case "f7": key = (98, "\u{F70A}")
        case "f8": key = (100, "\u{F70B}")
        case "f9": key = (101, "\u{F70C}")
        case "f10": key = (109, "\u{F70D}")
        case "f11": key = (103, "\u{F70E}")
        case "f12": key = (111, "\u{F70F}")
        default:
            guard name.count == 1, let character = name.first, character.isASCII else { return nil }
            let digits: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29]
            let punctuation: [Character: UInt16] = [";": 41, "=": 24, ",": 43, "-": 27, ".": 47, "/": 44,
                                                     "`": 50, "[": 33, "\\": 42, "]": 30, "'": 39]
            let shifted: [Character: UInt16] = ["!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26,
                "*": 28, "(": 25, ")": 29, ":": 41, "+": 24, "<": 43, "_": 27, ">": 47, "?": 44,
                "~": 50, "{": 33, "|": 42, "}": 30, "\"": 39]
            if let code = shifted[character] {
                flags.insert(.shift)
                key = (code, String(character))
            } else if character.isLetter {
                let commandish = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
                let wantsShift = explicitShift || (character.isUppercase && !commandish)
                if wantsShift { flags.insert(.shift) }
                let chars = wantsShift ? String(character).uppercased() : String(character).lowercased()
                key = (Bench.keyCode(for: character), chars)
            } else if let code = digits[character] ?? punctuation[character] {
                let shiftedDigit: [Character: Character] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")"]
                let chars = flags.contains(.shift) ? String(shiftedDigit[character] ?? character) : String(character)
                key = (code, chars)
            } else {
                return nil
            }
        }
        return (key.0, key.1, flags)
    }

    @MainActor
    private func click(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        let tier = args["tier"] as? String ?? "auto"
        guard flags(args["modifiers"]) != nil else {
            done(["error": "act.click modifiers must be a list of cmd, meta, shift, ctrl, or alt", "code": "INVALID_ARGUMENT"])
            return
        }
        if tier == "js" { actJS("act.click", args, done, from: origin); return }
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        let q = query("click", args)
        var callArgs = actArgs(args)
        callArgs["tier"] = "event"
        // The driver does the actionability work — scrolls, waits the box
        // still, asks what sits at the centre — and for the event tier hands
        // the point back rather than clicking: the trusted part is ours.
        callArgs["_guardFingerprint"] = args["_guardFingerprint"]
        callArgs["_guardOp"] = args["_guardOp"]
        drive(view, guardCall("act.click", callArgs, query: q, verb: "click"), mutating: true,
              cancellationToken: args["_cancelToken"] as? String) { [weak self] out in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.cancelled(args, done) { return }
                if let at = (out["at"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }),
                   (out["handoff"] as? String) == "event" {
                    self.validateGuard(view, args, done, at: at) {
                        self.handClick(view, tab: tab, from: origin, out: out, at: at, args: args, done)
                    }
                    return
                }
                let missing = (out["error"] as? String) == "drive.js not loaded"
                if missing, args["_guardFingerprint"] == nil, q["ref"] == nil, q["loc"] == nil {
                    // No driver in the page — but css/text are locators the
                    // bench's own finder can still take to a point.
                    self.clickResolved(view, tab: tab, from: origin, q, args: args, done)
                } else {
                    done(out)
                }
            }
        }
    }

    /// A handoff or escalation answer became a real click: down and up at the
    /// point the driver proved out, with its button/double/modifiers.
    @MainActor
    private func handClick(_ view: PageView, tab: Tab, from origin: DriveOrigin, out: [String: Any], at: [Double],
                           args: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        guard let flags = flags(out["modifiers"] ?? args["modifiers"]) else {
            done(["error": "act.click modifiers must be a list of cmd, meta, shift, ctrl, or alt", "code": "INVALID_ARGUMENT"])
            return
        }
        let clicks = (out["double"] as? Bool ?? args["double"] as? Bool) == true ? 2 : 1
        mouse(view, tab: tab, at: at, button: out["button"] as? String ?? args["button"] as? String ?? "left", clicks: clicks, flags: flags,
              origin: origin, args: args) { error, dialogPending, cancelled in
            MainActor.assumeIsolated {
                if cancelled { done(["error": "tab ownership or page changed", "code": "CANCELLED"]); return }
                if let error { done(error); return }
                if self.cancelled(args, done) { return }
                guard self.granted(tab, origin), tab.built === view else {
                    done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                    return
                }
                var reply = out
                reply["ok"] = true
                reply["tier"] = "event"
                reply["handoff"] = nil
                reply["at"] = at.map { Int($0) }
                reply["navChanged"] = nil
                if dialogPending {
                    reply["dialogPending"] = true
                    if args["withSnapshot"] as? Bool == true { reply["snapshotError"] = "snapshot unavailable while a page dialog is pending" }
                    done(reply)
                    return
                }
                if args["withSnapshot"] as? Bool == true {
                    self.drive(view, self.postSnapshotCall(args),
                               cancellationToken: args["_cancelToken"] as? String) { snapshot in
                        if self.cancelled(args, done) { return }
                        guard self.granted(tab, origin), tab.built === view else {
                            done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                            return
                        }
                        if let tree = snapshot["snapshot"] {
                            reply["snapshot"] = tree
                            reply["snapshotTruncated"] = snapshot["truncated"] ?? false
                            reply["snapshotVersion"] = snapshot["version"]
                        }
                        if let error = snapshot["error"] { reply["snapshotError"] = error }
                        done(reply)
                    }
                } else { done(reply) }
            }
        }
    }

    /// The event tier with no driver to ask: bench's finder takes a css/text
    /// locator to a point, and the click lands for real.
    @MainActor
    private func clickResolved(_ view: PageView, tab: Tab, from origin: DriveOrigin, _ q: [String: Any],
                               args: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        point(view, q, cancellationToken: args["_cancelToken"] as? String) { at, error in
            MainActor.assumeIsolated {
                if self.cancelled(args, done) { return }
                guard let at else { done(["error": error ?? "nothing to click"]); return }
                guard let flags = self.flags(args["modifiers"]) else {
                    done(["error": "act.click modifiers must be a list of cmd, meta, shift, ctrl, or alt", "code": "INVALID_ARGUMENT"])
                    return
                }
                let clicks = (args["double"] as? Bool == true) ? 2 : 1
                self.mouse(view, tab: tab, at: at, button: args["button"] as? String ?? "left", clicks: clicks, flags: flags,
                           origin: origin, args: args) { error, dialogPending, cancelled in
                    MainActor.assumeIsolated {
                        if cancelled { done(["error": "tab ownership or page changed", "code": "CANCELLED"]); return }
                        if let error { done(error); return }
                        if self.cancelled(args, done) { return }
                        guard self.granted(tab, origin), tab.built === view else {
                            done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                            return
                        }
                        var reply: [String: Any] = ["ok": true, "at": at.map { Int($0) }, "tier": "event"]
                        if dialogPending { reply["dialogPending"] = true }
                        guard args["withSnapshot"] as? Bool == true else { done(reply); return }
                        if dialogPending {
                            reply["snapshotError"] = "snapshot unavailable while a page dialog is pending"
                            done(reply)
                            return
                        }
                        self.drive(view, self.postSnapshotCall(args),
                                   cancellationToken: args["_cancelToken"] as? String) { snapshot in
                            if self.cancelled(args, done) { return }
                            guard self.granted(tab, origin), tab.built === view else {
                                done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                                return
                            }
                            if let tree = snapshot["snapshot"] {
                                reply["snapshot"] = tree
                                reply["snapshotTruncated"] = snapshot["truncated"] ?? false
                                reply["snapshotVersion"] = snapshot["version"]
                            }
                            if let error = snapshot["error"] { reply["snapshotError"] = error }
                            done(reply)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func drag(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let flags = flags(args["modifiers"]) else {
            done(["error": "act.drag modifiers must be a list of cmd, meta, shift, ctrl, or alt", "code": "INVALID_ARGUMENT"])
            return
        }
        let holdMs: Int
        if let raw = args["holdMs"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (0...2000).contains(number.doubleValue) else {
                done(["error": "act.drag holdMs must be an integer from 0 to 2000", "code": "INVALID_ARGUMENT"]); return
            }
            holdMs = number.intValue
        } else { holdMs = 0 }
        let steps: Int
        if let raw = args["steps"] as? NSNumber {
            let value = raw.doubleValue
            guard value.isFinite, value.rounded() == value, (1...64).contains(value) else {
                done(["error": "act.drag steps must be an integer from 1 to 64", "code": "INVALID_ARGUMENT"]); return
            }
            steps = Int(value)
        } else { steps = 8 }
        let q = query("drag", args)
        drive(view, guardCall("act.drag", args, query: q, verb: "drag"), mutating: true,
              cancellationToken: args["_cancelToken"] as? String) { [weak self] out in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.cancelled(args, done) { return }
                guard out["error"] == nil,
                      let start = (out["from"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), start.count == 2,
                      let end = (out["to"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), end.count == 2,
                      (start + end).allSatisfy(\.isFinite), out["handoff"] as? String == "drag" else {
                    done(out["error"] == nil ? ["error": "drive.js did not prepare a drag", "code": "ERROR"] : out)
                    return
                }
                self.validateGuard(view, args, done) {
                    AgentCursor.shared.approach(tab.id, in: view, to: start, word: "Drag") {
                        MainActor.assumeIsolated {
                            if self.cancelled(args, done) { return }
                            guard self.granted(tab, origin), tab.built === view else {
                                done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                                return
                            }
                            view.window?.makeFirstResponder(view)
                            self.nativeDrag(view, tab: tab, from: origin, start: start, to: end, steps: steps, path: args["path"], holdMs: holdMs,
                                            flags: flags, args: args) { result in
                                var reply = out
                                reply["ok"] = result["error"] == nil
                                reply["tier"] = "event"
                                reply["from"] = start.map { Int($0) }
                                reply["to"] = end.map { Int($0) }
                                reply["steps"] = steps
                                reply["holdMs"] = holdMs
                                reply["handoff"] = nil
                                for (key, value) in result { reply[key] = value }
                                done(reply)
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func nativeDrag(_ view: PageView, tab: Tab, from origin: DriveOrigin,
                            start: [Double], to end: [Double], steps: Int,
                            path rawPath: Any?,
                            holdMs: Int,
                            flags: NSEvent.ModifierFlags, args: [String: Any],
                            done: @escaping ([String: Any]) -> Void) {
        guard let window = view.window else { done(["error": "the tab's view has no window"]); return }
        var targets: [[Double]] = []
        var pace = 0.008
        var mouseDown = false
        func spot(_ p: [Double]) -> NSPoint {
            let local = NSPoint(x: p[0], y: view.isFlipped ? p[1] : view.bounds.height - p[1])
            return view.convert(local, to: nil)
        }
        func send(_ type: NSEvent.EventType, _ p: [Double], pressure: Swift.Float) -> Bool {
            let simulate = NSSelectorFromString("_simulateMouseMove:")
            let setCurrent = NSSelectorFromString("_setCurrentEvent:")
            if type == .mouseMoved && (!view.responds(to: simulate) || !NSApp.responds(to: setCurrent)) { return false }
            nativeMouseEventNumber &+= 1
            guard let event = NSEvent.mouseEvent(with: type, location: spot(p), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: NSGraphicsContext.current, eventNumber: nativeMouseEventNumber,
                clickCount: type == .mouseMoved ? 0 : 1, pressure: pressure) else { return false }
            var deliveredEvent = event
            if type == .mouseMoved {
                guard let cgEvent = event.cgEvent else { return false }
                cgEvent.setIntegerValueField(.mouseEventDeltaX,
                                             value: Int64((p[0] - Double(view.syntheticMousePoint.x)).rounded()))
                cgEvent.setIntegerValueField(.mouseEventDeltaY,
                                             value: Int64((p[1] - Double(view.syntheticMousePoint.y)).rounded()))
                guard let rebuilt = NSEvent(cgEvent: cgEvent) else { return false }
                deliveredEvent = rebuilt
            }
            Drive.note(deliveredEvent)
            Drive.injecting += 1
            defer { Drive.injecting -= 1 }
            if type == .leftMouseDown {
                mouseDown = true
                AgentCursor.shared.hold(tab.id, true)
                AgentCursor.shared.trace(tab.id, through: targets, over: pace * Double(targets.count))
            } else if type == .leftMouseUp {
                mouseDown = false
                AgentCursor.shared.hold(tab.id, false)
            }
            let held: UInt = type == .leftMouseUp || type == .mouseMoved ? 0 : 1
            SyntheticMouseButtons.with(held) {
                switch type {
                case .mouseMoved:
                    let currentEvent = NSApp.currentEvent
                    typealias SetCurrentEvent = @convention(c) (AnyObject, Selector, NSEvent?) -> Void
                    typealias SimulateMouseMove = @convention(c) (AnyObject, Selector, NSEvent) -> Void
                    let setCurrentEvent = unsafeBitCast(NSApp.method(for: setCurrent), to: SetCurrentEvent.self)
                    let simulateMouseMove = unsafeBitCast(view.method(for: simulate), to: SimulateMouseMove.self)
                    setCurrentEvent(NSApp, setCurrent, deliveredEvent)
                    defer { setCurrentEvent(NSApp, setCurrent, currentEvent) }
                    simulateMouseMove(view, simulate, deliveredEvent)
                case .leftMouseDown: view.mouseDown(with: event)
                case .leftMouseDragged: view.mouseDragged(with: event)
                case .leftMouseUp: view.mouseUp(with: event)
                default: break
                }
            }
            view.syntheticMousePoint = NSPoint(x: p[0], y: p[1])
            return true
        }
        if let rawPath {
            guard let points = rawPath as? [[Any]], points.count <= 128 else {
                done(["error": "drag path must contain at most 128 viewport points", "code": "INVALID_ARGUMENT"]); return
            }
            for point in points {
                guard point.count == 2, let x = (point[0] as? NSNumber)?.doubleValue,
                      let y = (point[1] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite,
                      x >= 0, y >= 0, x < view.bounds.width, y < view.bounds.height else {
                    done(["error": "drag path points must be finite coordinates inside the viewport", "code": "INVALID_ARGUMENT"]); return
                }
                targets.append([x, y])
            }
            targets.append(end)
        } else {
            targets = (1...steps).map { index in
                let fraction = Double(index) / Double(steps)
                return [start[0] + (end[0] - start[0]) * fraction,
                        start[1] + (end[1] - start[1]) * fraction]
            }
        }
        pace = AgentCursor.shared.dragPace(tab.id, in: view, steps: targets.count)
        var finalResult: [String: Any] = [:]
        var step = 0
        var current = start
        var holdUntil: TimeInterval?
        let ack = MouseAck(view: view, origin: origin) { dialogPending, cancelled in
            // A watcher may finish before the next movement or hold tick.
            if mouseDown { _ = send(.leftMouseUp, current, pressure: 0.0) }
            AgentCursor.shared.hold(tab.id, false)
            var result = finalResult
            if dialogPending { result["dialogPending"] = true }
            if cancelled {
                done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                return
            }
            if result["error"] == nil {
                if self.cancelled(args, { _ in }) {
                    done(["error": "drag cancelled", "code": "GUARD_CANCELLED", "guardStopped": true])
                    return
                }
                guard self.granted(tab, origin), tab.built === view, view.window === window else {
                    done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                    return
                }
            }
            done(result)
        }
        guard ack.watch() else {
            done(["error": "a page dialog is already pending", "code": "DIALOG_PENDING"])
            return
        }
        func finish(_ point: [Double], result: [String: Any]) {
            finalResult = result
            if !send(.leftMouseUp, point, pressure: 0.0), finalResult["error"] == nil {
                finalResult = ["error": "could not create drag release event", "code": "ERROR"]
            }
            ack.wait()
        }
        guard send(.mouseMoved, start, pressure: 0.0) else {
            finalResult = ["error": "could not create drag origin event", "code": "ERROR"]
            ack.finish(dialogPending: false)
            return
        }
        func advance() {
            MainActor.assumeIsolated {
                if ack.finished {
                    if mouseDown { _ = send(.leftMouseUp, current, pressure: 0.0) }
                    return
                }
                if ack.dialogPending {
                    finish(current, result: [:])
                    return
                }
                if self.cancelled(args, { _ in }) {
                    finish(current, result: ["error": "drag cancelled", "code": "GUARD_CANCELLED", "guardStopped": true])
                    return
                }
                guard self.granted(tab, origin), tab.built === view, view.window === window else {
                    finish(current, result: ["error": "tab ownership or page changed", "code": "CANCELLED"])
                    return
                }
                guard step < targets.count else {
                    if let holdUntil {
                        let remaining = holdUntil - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + min(0.016, remaining), execute: advance)
                            return
                        }
                    }
                    finish(current, result: [:])
                    return
                }
                let point = targets[step]
                guard send(.leftMouseDragged, point, pressure: 1.0) else {
                    finish(current, result: ["error": "could not create drag event"])
                    return
                }
                current = point
                step += 1
                if step == targets.count && holdMs > 0 {
                    holdUntil = ProcessInfo.processInfo.systemUptime + Double(holdMs) / 1000
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + pace, execute: advance)
            }
        }
        ack.afterPendingMouseEvents {
            guard !ack.finished else { return }
            view.callAsyncJavaScript("return await new Promise(resolve => setTimeout(resolve, 32));",
                                     arguments: [:], in: nil, in: .page) { result in
                MainActor.assumeIsolated {
                    ack.continueAfterWait {
                        if case .failure(let error) = result {
                            finalResult = ["error": "could not prepare drag origin", "code": "ERROR", "detail": error.localizedDescription]
                            ack.finish(dialogPending: false)
                            return
                        }
                        if ack.dialogPending {
                            ack.finish(dialogPending: true)
                            return
                        }
                        if self.cancelled(args, { _ in }) {
                            finalResult = ["error": "drag cancelled", "code": "GUARD_CANCELLED", "guardStopped": true]
                            ack.finish(dialogPending: false)
                            return
                        }
                        guard self.granted(tab, origin), tab.built === view, view.window === window else {
                            finalResult = ["error": "tab ownership or page changed", "code": "CANCELLED"]
                            ack.finish(dialogPending: false)
                            return
                        }
                        guard send(.leftMouseDown, start, pressure: 1.0) else {
                            finalResult = ["error": "could not create drag event", "code": "ERROR"]
                            ack.finish(dialogPending: false)
                            return
                        }
                        advance()
                    }
                }
            }
        }
    }

    @MainActor
    private func type(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let text = args["text"] as? String else { done(["error": "act.type needs text"]); return }
        // Every character is paced, even at delay 0 — a burst sent
        // recursively inside one run-loop turn loses keys to WebKit's own
        // input handling. 16ms is a frame: fast enough to feel typed, slow
        // enough for each event to land before the next is handed over.
        let pace = max((args["delay"] as? NSNumber)?.doubleValue ?? 0, 16) / 1000
        focus(view, query("type", args), cancellationToken: args["_cancelToken"] as? String) { error, at in
            MainActor.assumeIsolated {
                if self.cancelled(args, done) { return }
                if let error { done(["error": error]); return }
                AgentCursor.shared.glide(tab.id, to: at, word: "Typing")
                view.window?.makeFirstResponder(view)
                let characters = Array(text)
                var sent = 0
                func next() {
                    MainActor.assumeIsolated {
                        if self.cancelled(args, { result in
                            var result = result
                            result["typedCount"] = sent
                            done(result)
                        }) { return }
                        guard self.granted(tab, origin), tab.built === view else {
                            done(["error": "tab ownership or page changed", "code": "CANCELLED", "typedCount": sent])
                            return
                        }
                        if sent >= characters.count {
                            self.afterPendingKeyEvents(view) {
                                MainActor.assumeIsolated {
                                    if self.cancelled(args, { result in
                                        var result = result
                                        result["typedCount"] = sent
                                        done(result)
                                    }) { return }
                                    guard self.granted(tab, origin), tab.built === view else {
                                        done(["error": "tab ownership or page changed", "code": "CANCELLED", "typedCount": sent])
                                        return
                                    }
                                    done(["ok": true, "typed": text])
                                }
                            }
                            return
                        }
                        let character = characters[sent]
                        sent += 1
                        AgentCursor.shared.key(tab.id)
                        self.key(view, code: Bench.keyCode(for: character), chars: String(character), flags: [],
                                 tabID: tab.id, origin: origin)
                        DispatchQueue.main.asyncAfter(deadline: .now() + pace) { next() }
                    }
                }
                self.validateGuard(view, args, done) { next() }
            }
        }
    }

    @MainActor
    private func press(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let name = args["key"] as? String else { done(["error": "act.press needs key"]); return }
        guard let mflags = flags(args["modifiers"]) else {
            done(["error": "act.press modifiers must be a list of cmd, meta, shift, ctrl, or alt", "code": "INVALID_ARGUMENT"])
            return
        }
        guard let (code, chars, mflags) = keyFor(name, flags: mflags) else {
            done(["error": "act.press has an unknown key or modifier: \(name)", "code": "INVALID_ARGUMENT"])
            return
        }
        // A locator, when one came, gets the focus first — Enter on a field
        // is a different press from Enter on the page.
        focus(view, query("press", args), cancellationToken: args["_cancelToken"] as? String) { error, at in
            MainActor.assumeIsolated {
                if self.cancelled(args, done) { return }
                if let error { done(["error": error]); return }
                AgentCursor.shared.glide(tab.id, to: at, word: Drive.keyWord(name, modifiers: args["modifiers"]))
                view.window?.makeFirstResponder(view)
                self.validateGuard(view, args, done) {
                    self.key(view, code: code, chars: chars, flags: mflags, tabID: tab.id, origin: origin)
                    // WebKit finishes the native editing action before the next op can move focus.
                    self.afterPendingKeyEvents(view) {
                        MainActor.assumeIsolated {
                            if self.cancelled(args, done) { return }
                            guard self.granted(tab, origin), tab.built === view else {
                                done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                                return
                            }
                            done(["ok": true, "key": name])
                        }
                    }
                }
            }
        }
    }

    private static func keyWord(_ name: String, modifiers: Any?) -> String {
        let marks: [String: String] = ["cmd": "⌘", "meta": "⌘", "shift": "⇧", "ctrl": "⌃", "opt": "⌥", "alt": "⌥"]
        let held = ((modifiers as? [String]) ?? []).compactMap { marks[$0.lowercased()] }.joined()
        let keys: [String: String] = ["enter": "Return", "return": "Return", "tab": "Tab", "escape": "Esc", "esc": "Esc",
                                      "backspace": "Delete", "arrowup": "↑", "arrowdown": "↓", "arrowleft": "←",
                                      "arrowright": "→", " ": "Space", "space": "Space"]
        let shown = keys[name.lowercased()] ?? (name.count == 1 ? name.uppercased() : name)
        return "Press " + held + shown
    }

    @MainActor
    private func clickAt(_ args: [String: Any], _ done: @escaping ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin), let view = view(of: tab, done) else { return }
        guard let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue else {
            done(["error": "act.clickAt needs finite x and y coordinates", "code": "INVALID_ARGUMENT"])
            return
        }
        if let error = mousePointError(view, [x, y]) {
            done(error)
            return
        }
        guard let flags = flags(args["modifiers"]) else {
            done(["error": "act.clickAt modifiers must be a list of cmd, meta, shift, ctrl, or alt", "code": "INVALID_ARGUMENT"])
            return
        }
        let clicks = (args["double"] as? Bool == true) ? 2 : 1
        // What's there is worth knowing even though the tier needs nothing
        // page-side — the driver describes whatever the point lands on.
        drive(view, """
        function (d) {
          var el = document.elementFromPoint ? document.elementFromPoint(\(x), \(y)) : null;
          return { element: el && d._describe ? d._describe(el) : null };
        }
        """, cancellationToken: args["_cancelToken"] as? String) { out in
            MainActor.assumeIsolated {
                if self.cancelled(args, done) { return }
                self.validateGuard(view, args, done) {
                    self.mouse(view, tab: tab, at: [x, y], button: args["button"] as? String ?? "left", clicks: clicks, flags: flags,
                               origin: origin, args: args) { error, dialogPending, cancelled in
                        MainActor.assumeIsolated {
                            if cancelled { done(["error": "tab ownership or page changed", "code": "CANCELLED"]); return }
                            if let error { done(error); return }
                            if self.cancelled(args, done) { return }
                            guard self.granted(tab, origin), tab.built === view else {
                                done(["error": "tab ownership or page changed", "code": "CANCELLED"])
                                return
                            }
                            var reply: [String: Any] = ["ok": true, "at": [Int(x), Int(y)], "tier": "event"]
                            if dialogPending { reply["dialogPending"] = true }
                            if let element = out["element"], !(element is NSNull) { reply["element"] = element }
                            done(reply)
                        }
                    }
                }
            }
        }
    }

    // MARK: - agent.meta

    @MainActor
    private func lease(_ args: [String: Any], _ done: ([String: Any]) -> Void, from origin: DriveOrigin) {
        guard let tab = own(args, done, origin) else { return }
        let on = args["on"] as? Bool ?? true
        if on {
            sessions[origin, default: Share()].leases.insert(tab.id)
            armTouchMonitor()
        } else {
            sessions[origin]?.leases.remove(tab.id)
        }
        done(["id": Bench.short(tab), "lease": on])
    }

    /// The wire's hand on the Ask rail — and a line into the agent behind
    /// it. `open` shows or hides the panel as ever; `send` posts the text
    /// as the user's own message through Mind.send, so the turn that
    /// answers is the real in-app agent's — the composer's return key
    /// makes the same call. `steer` is the follow-up box's equivalent —
    /// Mind.steer, which sends when no chat is open — and `stop` the stop
    /// button's: Mind.stop ends the running turn. The calls ride one
    /// request fine (open the rail and send into it), and `send` alone
    /// runs behind a shut panel: the harness is seated here because the
    /// panel's first appearance is what otherwise seats it — a steer that
    /// falls back to send needs the seat just the same.
    @MainActor
    private func ask(_ args: [String: Any], _ done: ([String: Any]) -> Void) {
        if args["status"] as? Bool == true {
            let mind = Mind.shared
            let chat = mind.current
            let chatID = mind.currentID
            let model = chat.map { $0.model.isEmpty ? mind.model.id : $0.model } ?? mind.model.id
            let waiting = chatID != nil && ((mind.question?.chat == chatID) ||
                mind.pendingApprovals.contains { $0.chat == chatID })
            done([
                "chat": chatID?.uuidString as Any? ?? NSNull(),
                "running": chatID != nil && mind.runningChatID == chatID && mind.running,
                "model": model,
                "effort": chat?.effort as Any? ?? NSNull(),
                "activity": chatID != nil && mind.runningChatID == chatID ? mind.activity : "",
                "waiting": waiting
            ])
            return
        }
        if let on = args["open"] as? Bool { Mind.shared.open = on }
        var reply: [String: Any] = ["open": Mind.shared.open]
        if args["new"] as? Bool == true {
            guard !Mind.shared.running, Mind.shared.runningChatID == nil else {
                reply["error"] = "stop the active Ask turn before starting a new chat"
                reply["code"] = "CHAT_RUNNING"
                done(reply)
                return
            }
            // A fresh chat per scenario — Mind.newChat also clears the
            // chips' grants, which is exactly the isolation the runner is
            // after (design/benchmarks.md §"the one code addition").
            let chat = Mind.shared.newChatForAgent()
            appChat = chat
            reply["ok"] = true
            reply["newChat"] = true
            reply["chat"] = chat.uuidString
        }
        if let text = args["send"] as? String {
            // Mind.send lets a blank fall on the floor — say so rather
            // than name a chat nothing was ever posted to.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply["error"] = "ui.ask send needs a non-empty text"
                done(reply)
                return
            }
            Harness.shared.attach()
            Mind.shared.send(text)
            appChat = Mind.shared.currentID
            reply["ok"] = true
            if let chat = Mind.shared.currentID {
                reply["chat"] = chat.uuidString
            }
        }
        if let text = args["steer"] as? String {
            // Same honesty as send: Mind.steer lets a blank fall on the
            // floor — say so rather than answer ok to nothing.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply["error"] = "ui.ask steer needs a non-empty text"
                done(reply)
                return
            }
            Harness.shared.attach()
            Mind.shared.steer(text)
            appChat = Mind.shared.currentID
            reply["ok"] = true
            // A steer with no chat open is a send — carry the chat it made.
            if let chat = Mind.shared.currentID {
                reply["chat"] = chat.uuidString
            }
        }
        if args["stop"] as? Bool == true {
            Mind.shared.stop()
            reply["ok"] = true
        }
        done(reply)
    }

    /// The user's own act on a page, as PageView sees it: a mouse down or a
    /// key press on the real window. Clicks that reach PageView this way are
    /// real by definition — the driver's own events are handed to the view
    /// directly (`injecting` still guards the path, in case one day they are
    /// posted through `sendEvent`). A view painting in the offscreen room
    /// answers to nobody's hand.
    static func noteTouch(webView: PageView) {
        guard injecting == 0, let window = webView.window, window === Links.window else { return }
        // A key WebKit sent back up the chain unused is still our key — same
        // timestamp, same code. (Only keys come back that way, and asking a
        // mouse event for its keyCode is an exception, so keys only.)
        if let event = NSApp.currentEvent, event.type == .keyDown || event.type == .keyUp,
           injected.contains(where: { $0.type == event.type && PageView.same($0, event) }) {
            return
        }
        MainActor.assumeIsolated { (AskRuntime.drive as? Drive)?.touched(webView) }
    }

    /// The event tap that watches the real stream. PageView never sees most
    /// clicks — WebKit's inner view takes them first — so the lease listens
    /// upstream, at `sendEvent`, where every event on the real window passes
    /// and none of the driver's do (they're handed to the view, not sent).
    @MainActor private var touchMonitor: Any?

    @MainActor
    private func armTouchMonitor() {
        guard touchMonitor == nil else { return }
        touchMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.realTouch(event) }
            return event
        }
    }

    /// A real event on the real window, before it lands. On the page itself,
    /// the touch belongs to that page's tab; anywhere else in the window —
    /// the strip, the field, a shortcut that swallows the key — it belongs
    /// to whichever tab is on stage, the one the lease is about.
    @MainActor
    private func realTouch(_ event: NSEvent) {
        guard let window = event.window, window === Links.window,
              sessions.values.contains(where: { !$0.leases.isEmpty }) else { return }
        var view: NSView?
        if event.type == .keyDown {
            view = window.firstResponder as? NSView
        } else {
            view = window.contentView?.hitTest(event.locationInWindow)
        }
        while let v = view {
            if let page = v as? PageView { touched(page); return }
            view = v.superview
        }
        if let active = browser.active { release(active.id) }
    }

    /// A lease on this tab, whoever holds it, ends — `lease.lost` goes only
    /// to the session that was holding it.
    @MainActor
    private func release(_ tab: UUID) {
        for held in Array(sessions.keys) where sessions[held]?.leases.contains(tab) == true {
            sessions[held]?.leases.remove(tab)
            emit("lease.lost", ["id": String(tab.uuidString.prefix(8)).lowercased()], to: held)
        }
    }

    @MainActor
    private func touched(_ view: PageView) {
        guard let tab = browser.allTabs.first(where: { $0.built === view }) else { return }
        release(tab.id)
    }

    // MARK: - the row as events

    /// The 0.5s coalesced diff that turns `browser.allTabs` into `tab.added`,
    /// `tab.navigated`, `tab.title` and `tab.closed` — on for as long as
    /// anyone is listening.
    @MainActor
    private func armDiff() {
        guard diffTimer == nil, onEvent != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.diff() }
        timer.resume()
        diffTimer = timer
    }

    /// The watched row — agent tabs and attached ones — against what it was
    /// last time this ran. The first pass only primes, so tabs that predate
    /// the listener aren't announced as new. `tab.*` is a broadcast: every
    /// subscribed session watches the same row, and a tab one session holds
    /// is news for all of them.
    @MainActor
    private func diff() {
        let held = Set(sessions.values.flatMap(\.attached))
        let watched = browser.allTabs.filter { $0.bench || held.contains($0.id) }
        let now = Dictionary(uniqueKeysWithValues: watched.map {
            ($0.id, ($0.address?.absoluteString ?? "", $0.title))
        })
        defer { seen = now; primed = true }
        guard primed else { return }
        for tab in watched {
            let id = Bench.short(tab)
            let url = tab.address?.absoluteString ?? ""
            switch seen[tab.id] {
            case .none:
                emit("tab.added", ["id": id, "url": url, "title": tab.title])
            case .some(let old) where old.0 != url:
                emit("tab.navigated", ["id": id, "url": url, "title": tab.title])
            case .some(let old) where old.1 != tab.title:
                emit("tab.title", ["id": id, "title": tab.title])
            default:
                break
            }
        }
        for id in seen.keys where now[id] == nil {
            emit("tab.closed", ["id": String(id.uuidString.prefix(8)).lowercased()])
            drop(id)
        }
    }
}

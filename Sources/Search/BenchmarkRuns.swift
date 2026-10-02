import Foundation
import WebKit

/// Independent production harness seats in one disposable benchmark app.
@MainActor
final class BenchmarkRuns {
    static let shared = BenchmarkRuns()

    @MainActor final class Run {
        let engine = Harness(registering: false)
        let store = WKWebsiteDataStore.nonPersistent()
        var chat = AskChat()
        var engineFinished = false
        var pendingOperations = 0
        var finished: Bool { engineFinished && pendingOperations == 0 }
        var error: String?
        var isJudge = false
        var fixtureDirectory: URL?
        var fixturePaths: Set<String> = []
        var observations: [[String: Any]] = []
    }
    @MainActor private final class CheckReply {
        var values: [[String: Any]] = []
        var first: [String: Any]? { values.first }
        func receive(_ value: [String: Any]) { values.append(value) }
    }
    private var runs: [UUID: Run] = [:]
    // ponytail: native FIFO shares keyboard focus; parallel input needs isolated focus contexts.
    private var queue: [() -> Void] = []
    private var busy = false

    private static let actionTimeout: TimeInterval = 30
    private static let screenshotTimeout: TimeInterval = 8

    func websiteStore(for origin: DriveOrigin) -> WKWebsiteDataStore? {
        guard case .socket(let id) = origin else { return nil }
        return runs[id]?.store
    }

    func handle(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        if request["action"] as? String == "check-steer" { checkSteering(answer); return }
        if request["action"] as? String == "check-fixtures" { checkFixtures(answer); return }
        if request["action"] as? String == "check-queue" { checkQueue(answer); return }
        if request["action"] as? String == "check-js-dialogs" { checkJSDialogs(answer); return }
        if request["action"] as? String == "check-storage" { checkStorage(answer); return }
        if request["action"] as? String == "check-host" {
            let engine = Harness(registering: false)
            engine.origin = .socket(UUID())
            engine.checkRestart { result in
                answer(result)
            }
            return
        }
        if request["action"] as? String == "start" {
            guard runs.count < 16, let prompt = request["prompt"] as? String, !prompt.isEmpty else {
                answer(["error": "start needs a prompt and a free benchmark seat"]); return
            }
            let run = Run(), id = run.chat.id
            run.chat.model = request["echo"] as? Bool == true ? "echo" : "codex/gpt-6-luna"
            run.chat.effort = "xhigh"
            run.chat.mode = .full
            run.isJudge = request["judge"] as? Bool == true
            if run.isJudge { run.chat.title = "Benchmark judge" }
            run.chat.turn = UUID()
            var taskPrompt = prompt
            if request["judge"] as? Bool != true, request["fixtures"] as? Bool == true {
                do { try stageFixtures(run) }
                catch { removeFixtures(run); answer(["error": "could not stage benchmark fixtures"]); return }
                taskPrompt += "\n\nGenerated sample files are available only for browser-use.github.io stress-test forms that accept any file of the required type: " + run.fixturePaths.sorted().joined(separator: ", ") + ". Use them when task content does not specify a particular file. Do not substitute them for user-provided or specific-content files."
            }
            run.chat.messages = [AskMessage(role: .you, text: taskPrompt)]
            run.engine.origin = .socket(id)
            (AskRuntime.drive as? Drive)?.setMode(.full, for: run.engine.origin)
            run.engine.onAsk = { [weak run] _, _ in run?.engine.resolveAsk(["declined": "benchmark has no interactive user"]) }
            run.engine.sink = { [weak run] event in
                guard let run else { return }
                switch event {
                case .message(_, let message): run.chat.messages.append(message)
                case .done(_, let error): run.engineFinished = true; run.error = error
                default: break
                }
            }
            runs[id] = run
            var attachments: [AskAttach] = []
            if run.chat.title == "Benchmark judge", let images = request["images"] as? [String] {
                for path in images.prefix(10) {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count < 8_000_000 {
                        var image = AskAttach(kind: .image, label: "Browser evidence")
                        image.data = data.base64EncodedString()
                        image.mime = data.starts(with: [0xff, 0xd8]) ? "image/jpeg" : "image/png"
                        attachments.append(image)
                    }
                }
            }
            run.engine.run(AskJob(chat: run.chat, tabs: [], attachments: attachments, text: taskPrompt))
            answer(["id": id.uuidString, "model": run.chat.model, "effort": "xhigh"])
            return
        }
        guard let raw = request["id"] as? String, let id = UUID(uuidString: raw), let run = runs[id] else {
            answer(["error": "unknown benchmark run"]); return
        }
        switch request["action"] as? String {
        case "steer":
            guard !run.isJudge, run.engine.running, !run.engineFinished,
                  let text = request["text"] as? String, !text.isEmpty else {
                answer(["error": "steer requires an active executor and text"]); return
            }
            run.engine.steer(text)
            answer(["steered": true])
        case "stop": run.engine.stop(); answer(["stopped": true])
        case "release":
            guard run.finished else { answer(["error": "stop and await completion before release"]); return }
            run.engine.shutdown()
            (AskRuntime.drive as? Drive)?.leave(run.engine.origin)
            runs[id] = nil
            removeFixtures(run)
            try? FileManager.default.removeItem(at: Store.file("benchmark-shots/" + id.uuidString))
            answer(["released": true])
        case "status":
            if request["detail"] as? Bool != true {
                answer(["id": raw, "finished": run.finished, "error": run.error ?? NSNull(), "tools": run.observations.count])
                return
            }
            let data = try? JSONEncoder().encode(run.chat)
            let chat = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
            answer(["id": raw, "finished": run.finished, "error": run.error ?? NSNull(),
                    "chat": chat, "observations": run.observations, "tabs": (AskRuntime.drive as? Drive)?.sessionTabs(run.engine.origin).map(Bench.short) ?? []])
        default: answer(["error": "unknown agent-run action"])
        }
    }

    private func checkSteering(_ answer: @escaping ([String: Any]) -> Void) {
        handle(["action": "start", "echo": true, "prompt": "steering contract check"]) { started in
            guard let raw = started["id"] as? String, let id = UUID(uuidString: raw), let run = self.runs[id] else {
                answer(["ok": false, "error": "check executor did not start"]); return
            }
            self.handle(["action": "steer", "id": raw, "text": "finish verified work"]) { active in
                run.isJudge = true
                self.handle(["action": "steer", "id": raw, "text": "must be rejected"]) { judge in
                    run.isJudge = false
                    run.engine.stop()
                    self.handle(["action": "steer", "id": raw, "text": "must be rejected"]) { stopped in
                        run.engine.shutdown()
                        (AskRuntime.drive as? Drive)?.leave(run.engine.origin)
                        self.runs[id] = nil
                        answer(["ok": active["steered"] as? Bool == true && judge["error"] != nil && stopped["error"] != nil,
                                "active_accepted": active["steered"] ?? false,
                                "judge_rejected": judge["error"] != nil, "stopped_rejected": stopped["error"] != nil])
                    }
                }
            }
        }
    }

    private func stageFixtures(_ run: Run) throws {
        let folder = Store.file("benchmark-fixtures/" + run.chat.id.uuidString)
        run.fixtureDirectory = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let files: [String: Data] = ["sample.txt": Data("Generated benchmark sample.\n".utf8),
                                   "sample.png": Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNwaDgAAAKEAYEml6crAAAAAElFTkSuQmCC")!]
        for (name, data) in files {
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            run.fixturePaths.insert(url.path)
        }
    }

    private func removeFixtures(_ run: Run) {
        if let folder = run.fixtureDirectory { try? FileManager.default.removeItem(at: folder) }
        run.fixtureDirectory = nil
        run.fixturePaths = []
    }

    private func allowedFixturePaths(_ paths: [String]?, run: Run) -> Bool {
        guard let paths else { return false }
        return paths.allSatisfy { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            return run.fixturePaths.contains(path) && url.path == path
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func allowedFixtureDestination(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host?.lowercased() == "browser-use.github.io"
            && url.user == nil && url.password == nil && url.port == nil
            && url.path.hasPrefix("/stress-tests/challenges/") && url.path.hasSuffix("-form.html")
            && !url.pathComponents.contains("..")
    }

    private func checkFixtures(_ answer: @escaping ([String: Any]) -> Void) {
        guard runs.isEmpty else { answer(["error": "fixture check requires an idle runner"]); return }
        let first = Run(), second = Run(), interactions = AgentInteractions.shared
        let web = WKWebView(), origin = DriveOrigin.socket(first.chat.id)
        defer { removeFixtures(first); removeFixtures(second); interactions.clear(web) }
        do { try stageFixtures(first); try stageFixtures(second) }
        catch { answer(["error": "could not stage fixture check"]); return }
        let own = first.fixturePaths.sorted(), foreign = second.fixturePaths.sorted()
        let acceptsOwn = allowedFixturePaths(own, run: first)
        let rejectsForeign = !allowedFixturePaths(foreign, run: first)
        let rejectsHost = !allowedFixturePaths(["/etc/hosts"], run: first)
        let rejectsAlias = !allowedFixturePaths([first.fixtureDirectory!.path + "/../" + first.chat.id.uuidString + "/sample.txt"], run: first)
        let acceptsCancel = allowedFixturePaths([], run: first)
        _ = interactions.configure(web, session: origin, enabled: true) { _ in }
        var chooserFilesOK = true
        for path in own {
            var selected: [URL]?
            _ = interactions.capture(web, kind: "file") { accept, _, urls in if accept { selected = urls } }
            let pending = interactions.status(web, session: origin)["pending"] as? [String: Any]
            let response = interactions.answer(web, session: origin, args: ["dialog": pending?["id"] ?? "", "paths": [path]], files: true)
            chooserFilesOK = chooserFilesOK && response["ok"] as? Bool == true && selected?.map(\.path) == [path]
        }
        var cancelled = false
        _ = interactions.capture(web, kind: "file") { accept, _, urls in cancelled = !accept && urls == nil }
        let pending = interactions.status(web, session: origin)["pending"] as? [String: Any]
        let result = interactions.answer(web, session: origin, args: ["dialog": pending?["id"] ?? "", "paths": []], files: true)
        let clearsPending = interactions.status(web, session: origin)["pending"] is NSNull
        let link = first.fixtureDirectory!.appendingPathComponent("sample.txt")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: foreign[0])
        let rejectsSymlink = !allowedFixturePaths([link.path], run: first)
        let destinationOK = allowedFixtureDestination(URL(string: "https://browser-use.github.io/stress-tests/challenges/angularjs-form.html"))
            && ["https://example.com/stress-tests/challenges/angularjs-form.html",
                "https://browser-use.github.io/real-form.html",
                "http://browser-use.github.io/stress-tests/challenges/angularjs-form.html",
                "https://user:secret@browser-use.github.io/stress-tests/challenges/angularjs-form.html",
                "https://browser-use.github.io:443/stress-tests/challenges/angularjs-form.html",
                "https://browser-use.github.io/stress-tests/challenges/../challenges/angularjs-form.html",
                "https://browser-use.github.io/stress-tests/challenges/%2e%2e/challenges/angularjs-form.html"]
                .allSatisfy { !allowedFixtureDestination(URL(string: $0)) }
        let firstFolder = first.fixtureDirectory!, secondFolder = second.fixtureDirectory!
        first.engine.origin = origin
        first.engineFinished = true
        runs[first.chat.id] = first
        let released = CheckReply()
        handle(["action": "release", "id": first.chat.id.uuidString]) { released.receive($0) }
        removeFixtures(second)
        let cleanupOK = released.first?["released"] as? Bool == true && runs[first.chat.id] == nil
            && first.fixturePaths.isEmpty && second.fixturePaths.isEmpty
            && !FileManager.default.fileExists(atPath: firstFolder.path)
            && !FileManager.default.fileExists(atPath: secondFolder.path)
        let failed = Run(), failureFolder = Store.file("benchmark-fixtures/" + failed.chat.id.uuidString)
        failed.fixtureDirectory = failureFolder
        defer { removeFixtures(failed) }
        var failureCleanupOK = false
        do {
            try Data().write(to: failureFolder)
            do { try stageFixtures(failed) }
            catch {
                removeFixtures(failed)
                failureCleanupOK = failed.fixtureDirectory == nil && failed.fixturePaths.isEmpty
                    && !FileManager.default.fileExists(atPath: failureFolder.path)
            }
        } catch {}
        answer(["ok": acceptsOwn && rejectsForeign && rejectsHost && rejectsAlias && acceptsCancel && rejectsSymlink && cancelled && clearsPending && result["ok"] as? Bool == true && cleanupOK && failureCleanupOK && chooserFilesOK && destinationOK,
                "own_files": acceptsOwn, "foreign_files_denied": rejectsForeign, "host_files_denied": rejectsHost,
                "aliases_denied": rejectsAlias, "symlink_escape_denied": rejectsSymlink,
                "empty_selection_cancels": cancelled && clearsPending,
                "release_cleanup": cleanupOK, "setup_failure_cleanup": failureCleanupOK,
                "chooser_files": chooserFilesOK, "synthetic_destination_only": destinationOK])
    }

    private func checkStorage(_ answer: @escaping ([String: Any]) -> Void) {
        guard runs.isEmpty, let drive = AskRuntime.drive as? Drive else { answer(["error": "storage check requires an idle driver"]); return }
        let first = Run(), second = Run()
        for run in [first, second] {
            run.engine.origin = .socket(run.chat.id)
            runs[run.chat.id] = run
        }
        Task { @MainActor in
            defer {
                for run in [first, second] {
                    drive.leave(.socket(run.chat.id))
                    run.engine.shutdown()
                    runs[run.chat.id] = nil
                }
            }
            for run in [first, first, second] {
                let result: [String: Any] = await withCheckedContinuation { continuation in
                    drive.perform("tabs.open", ["url": "http://127.0.0.1:9/benchmark-storage-check"], from: .socket(run.chat.id)) {
                        continuation.resume(returning: $0)
                    }
                }
                if let error = result["error"] { answer(["error": error]); return }
            }
            let a = drive.sessionTabs(.socket(first.chat.id)), b = drive.sessionTabs(.socket(second.chat.id))
            let reused = a.count == 2 && a.allSatisfy { $0.store === first.store }
            let isolated = b.count == 1 && b[0].store === second.store && first.store !== second.store
            answer(["ok": reused && isolated && !first.store.isPersistent && !second.store.isPersistent,
                    "within_seat_shared": reused, "across_seats_isolated": isolated, "persistent": first.store.isPersistent])
        }
    }

    private func checkJSDialogs(_ answer: @escaping ([String: Any]) -> Void) {
        guard runs.isEmpty, queue.isEmpty, !busy, let drive = AskRuntime.drive as? Drive else {
            answer(["error": "JavaScript dialog check requires an idle native driver"])
            return
        }
        let run = Run(), id = run.chat.id
        let origin = DriveOrigin.socket(id)
        run.engine.origin = origin
        runs[id] = run
        Task { @MainActor in
            defer {
                drive.leave(origin)
                run.engine.shutdown()
                self.runs[id] = nil
            }
            let result = await self.exerciseJSDialogs(drive, origin: origin)
            answer(result)
        }
    }

    private func exerciseJSDialogs(_ drive: Drive, origin: DriveOrigin) async -> [String: Any] {
        let opened = await checkRequest(drive, "tabs.open", ["url": "about:blank"], origin: origin, timeout: 3)
        guard let tab = opened.first?["id"] as? String else { return ["error": "could not open the isolated test tab"] }
        let loaded = await checkRequest(drive, "page.wait", ["tab": tab, "seconds": 3], origin: origin, timeout: 4)
        guard let loadedResult = loaded.first, loadedResult["timeout"] as? Bool != true else {
            return ["error": "isolated test tab did not load"]
        }
        let setup = #"""
        window.__dialogCheck = {};
        document.documentElement.innerHTML = `<select id="choice"><option value="a">A</option><option value="b">B</option></select>`;
        document.querySelector("#choice").addEventListener("change", () => {
          alert("select"); window.__dialogCheck.selectProgress = true;
        });
        true
        """#
        let prepared = await checkRequest(drive, "page.eval", ["tab": tab, "js": setup], origin: origin)
        guard let preparedResult = prepared.first, preparedResult["error"] == nil else {
            return ["error": "could not prepare the isolated dialog test"]
        }
        let configured = await checkRequest(drive, "page.dialogs", ["tab": tab], origin: origin)
        guard let enabled = configured.first, enabled["enabled"] as? Bool == true else {
            return ["error": "could not prepare the isolated dialog test"]
        }

        let selectOK = await checkDialog(drive, origin: origin, tab: tab, op: "act.select",
                                         args: ["css": "#choice", "values": ["b"]],
                                         answer: ["accept": true],
                                         progress: "window.__dialogCheck.selectProgress === true")
        let confirmOK = await checkDialog(drive, origin: origin, tab: tab, op: "page.eval",
                                          args: ["js": "window.__dialogCheck.confirmValue = confirm('confirm'); window.__dialogCheck.confirmProgress = true; true"],
                                          answer: ["accept": true],
                                          progress: "window.__dialogCheck.confirmProgress === true && window.__dialogCheck.confirmValue === true")
        let promptOK = await checkDialog(drive, origin: origin, tab: tab, op: "page.eval",
                                         args: ["js": "window.__dialogCheck.promptValue = prompt('prompt'); window.__dialogCheck.promptProgress = true; true"],
                                         answer: ["accept": true, "text": "benchmark"],
                                         progress: "window.__dialogCheck.promptProgress === true && window.__dialogCheck.promptValue === 'benchmark'")
        let cancellationOK = await checkCancelledScript(drive, origin: origin, tab: tab)
        return ["ok": selectOK && confirmOK && promptOK && cancellationOK, "act_select": selectOK,
                "page_eval_confirm": confirmOK, "page_eval_prompt": promptOK,
                "script_cancellation": cancellationOK]
    }

    private func checkCancelledScript(_ drive: Drive, origin: DriveOrigin, tab: String) async -> Bool {
        let cancellation = AgentCancellation()
        let reply = CheckReply()
        var requestToken: String?
        drive.perform("page.code", ["tab": tab, "js": "window.__dialogCheck.cancelStarted = true; await new Promise(resolve => setTimeout(() => { window.__dialogCheck.cancelProgress = true; resolve(); }, 1500)); return 'late'"],
                      from: origin, cancellation: cancellation, tokenReady: { requestToken = $0 }) { reply.receive($0) }
        guard let requestToken,
              let view = drive.sessionTabs(origin).first(where: { Bench.short($0) == tab })?.built else {
            cancellation.cancel()
            return false
        }
        let deadline = Date().addingTimeInterval(2)
        var started = false
        while !started && Date() < deadline {
            let state = await checkRequest(drive, "page.eval",
                                           ["tab": tab, "js": "window.__dialogCheck.cancelStarted === true && window.__dialogCheck.cancelProgress !== true"],
                                           origin: origin, timeout: 0.2)
            started = state.first?["value"] as? Bool == true
            if !started { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        guard started else { cancellation.cancel(); return false }
        let active = drive.checkScriptState(view, requestToken: requestToken)
        cancellation.cancel()
        guard active["flight_present"] == true, active["watcher_present"] == true else { return false }
        let immediate = drive.checkScriptState(view, requestToken: requestToken)
        guard reply.values.count == 1,
              reply.first?["code"] as? String == "CANCELLED",
              reply.first?["outcome"] as? String == "unknown",
              immediate["flight_removed"] == true,
              immediate["watcher_removed"] == true,
              drive.checkScriptCancellationGate(view, origin: origin, tab: tab) else { return false }
        try? await Task.sleep(nanoseconds: 1_700_000_000)
        // The page-side timer proves the cancelled async function finished.
        let progress = await checkRequest(drive, "page.eval",
                                          ["tab": tab, "js": "window.__dialogCheck.cancelProgress === true"],
                                          origin: origin, timeout: 1)
        guard progress.first?["value"] as? Bool == true else { return false }
        let afterLate = drive.checkScriptState(view, requestToken: requestToken)
        return reply.values.count == 1
            && afterLate["flight_removed"] == immediate["flight_removed"]
            && afterLate["watcher_removed"] == immediate["watcher_removed"]
    }

    private func checkDialog(_ drive: Drive, origin: DriveOrigin, tab: String, op: String,
                             args: [String: Any], answer: [String: Any], progress: String) async -> Bool {
        let call = await checkRequest(drive, op, args.merging(["tab": tab]) { _, new in new }, origin: origin, timeout: 2)
        guard let result = call.first, result["code"] as? String == "DIALOG_PENDING",
              result["dialogPending"] as? Bool == true, result["outcome"] as? String == "unknown" else { return false }

        let alreadyPending = await checkRequest(drive, "page.eval",
                                                ["tab": tab, "js": "window.__dialogCheck.whilePending = true; true"],
                                                origin: origin)
        guard alreadyPending.first?["code"] as? String == "DIALOG_PENDING",
              alreadyPending.first?["dialogPending"] as? Bool == true else { return false }

        let status = await checkRequest(drive, "page.dialogs", ["tab": tab], origin: origin)
        guard let pending = status.first?["pending"] as? [String: Any],
              let dialog = pending["id"] as? String else { return false }
        let response = await checkRequest(drive, "page.dialog",
                                          answer.merging(["tab": tab, "dialog": dialog]) { _, new in new },
                                          origin: origin)
        guard response.first?["ok"] as? Bool == true else { return false }
        let check = await checkRequest(drive, "page.eval",
                                       ["tab": tab, "js": progress + " && window.__dialogCheck.whilePending !== true"],
                                       origin: origin)
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let value = check.first?["value"] as? Bool else { return false }
        return value && call.values.count == 1 && alreadyPending.values.count == 1
    }

    private func checkRequest(_ drive: Drive, _ op: String, _ args: [String: Any], origin: DriveOrigin,
                              timeout: TimeInterval = 2) async -> CheckReply {
        let reply = CheckReply()
        drive.perform(op, args, from: origin) { reply.receive($0) }
        let deadline = Date().addingTimeInterval(timeout)
        while reply.first == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return reply
    }

    private func checkQueue(_ answer: @escaping ([String: Any]) -> Void) {
        guard runs.isEmpty, queue.isEmpty, !busy else {
            answer(["error": "queue check requires an idle benchmark runner"])
            return
        }
        guard let drive = AskRuntime.drive as? Drive else {
            answer(["error": "queue check requires the native driver"])
            return
        }
        let run = Run(), id = run.chat.id
        run.engine.origin = .socket(id)
        runs[id] = run
        let actionCancellation = AgentCancellation()
        let autoCaptureCancellation = AgentCancellation()
        let queuedCancellation = AgentCancellation()
        var lateAction: (([String: Any]) -> Void)?
        var lateAutoCapture: (([String: Any]) -> Void)?
        var actionTimeoutCount = 0
        var autoCaptureTimeoutCount = 0
        var replyCount = 0
        var startOrder: [String] = []
        var replyOrder: [String] = []
        var queuedOperationStarted = false
        var queuedCancellationStayedBehindHead = false
        var followupStarted = false
        var followupSawCancellations = false
        run.pendingOperations = 3
        actionCancellation.onCancel = { lateAction?(["marker": "synchronous-action-cancel-callback"]) }
        autoCaptureCancellation.onCancel = { lateAutoCapture?(["path": "synchronous-capture-cancel-callback"]) }
        let finishAction = operationCompletion(run: run, name: "check.action", args: [:],
                                               origin: run.engine.origin) { _ in replyCount += 1; replyOrder.append("action") }
        let finishCapture = operationCompletion(run: run, name: "check.auto-capture", args: [:],
                                                origin: run.engine.origin) { _ in replyCount += 1; replyOrder.append("auto-capture") }
        let finishQueued = operationCompletion(run: run, name: "check.queued", args: [:],
                                               origin: run.engine.origin) { _ in replyCount += 1; replyOrder.append("queued") }
        queuedCancellation.onCancel = {
            finishQueued(["error": "cancelled before action started", "code": "CANCELLED",
                          "guardStopped": true, "outcome": "cancelled"], nil, false)
            queuedCancellationStayedBehindHead = replyCount == 1 && self.queue.count == 3 && !followupStarted
        }

        enqueue {
            startOrder.append("action")
            self.withDeadline(0.02, timeoutResult: self.actionTimeoutResult("act.select", args: [:], tab: nil),
                              cancellation: actionCancellation, capture: { complete in
                lateAction = complete
            }) { result, timedOut in
                if timedOut { actionTimeoutCount += 1 }
                finishAction(result, nil, true)
            }
        }
        enqueue {
            startOrder.append("auto-capture")
            self.withDeadline(0.02, timeoutResult: ["error": "test auto-capture timed out", "code": "BENCHMARK_SCREENSHOT_TIMEOUT"],
                              cancellation: autoCaptureCancellation, capture: { complete in
                lateAutoCapture = complete
            }) { result, timedOut in
                if timedOut { autoCaptureTimeoutCount += 1 }
                finishCapture(result, nil, true)
            }
        }
        enqueue {
            startOrder.append("queued-slot")
            if queuedCancellation.isCancelled {
                finishQueued(["error": "cancelled before action started", "code": "CANCELLED",
                              "guardStopped": true, "outcome": "cancelled"], nil, false)
                self.next()
                return
            }
            queuedOperationStarted = true
            finishQueued(["error": "queued cancellation was missed"], nil, true)
        }
        enqueue {
            startOrder.append("followup")
            followupStarted = true
            followupSawCancellations = actionCancellation.isCancelled
                && autoCaptureCancellation.isCancelled && queuedCancellation.isCancelled
            self.next()
        }
        queuedCancellation.cancel()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            lateAction?(["marker": "late-action-callback"])
            try? await Task.sleep(nanoseconds: 30_000_000)
            lateAutoCapture?(["path": "late-auto-capture-callback"])
            try? await Task.sleep(nanoseconds: 10_000_000)
            lateAction?(["marker": "second-late-action-callback"])
            lateAutoCapture?(["path": "second-late-auto-capture-callback"])
            try? await Task.sleep(nanoseconds: 10_000_000)
            let queueEmpty = self.queue.isEmpty && !self.busy
            let lateCallbacksIgnored = replyCount == 3 && run.observations.count == 3
            let recorded = run.observations.map {
                "\($0["op"] as? String ?? ""):\((($0["result"] as? [String: Any])?["code"] as? String) ?? "")"
            }
            let recordsMatch = recorded == ["check.queued:CANCELLED", "check.action:BENCHMARK_ACTION_TIMEOUT",
                                           "check.auto-capture:BENCHMARK_SCREENSHOT_TIMEOUT"]
            let orderMatches = startOrder == ["action", "auto-capture", "queued-slot", "followup"]
                && replyOrder == ["queued", "action", "auto-capture"] && recordsMatch
            let driveCancellation = drive.checkCancellationDoor()
            let driveCancellationOK = driveCancellation["ok"] as? Bool == true
            let readReply = CheckReply(), readCancellation = AgentCancellation()
            var lateRead: (([String: Any]) -> Void)?
            readCancellation.onCancel = { lateRead?(["marker": "synchronous-read-cancel-callback"]) }
            self.withDeadline(0.02, timeoutResult: self.actionTimeoutResult("page.snapshot", args: [:], tab: nil),
                              cancellation: readCancellation, capture: { lateRead = $0 }) { result, _ in readReply.receive(result) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            lateRead?(["marker": "late-read-callback"])
            try? await Task.sleep(nanoseconds: 10_000_000)
            let pdfTimeout = self.actionTimeoutResult("page.pdf", args: [:], tab: nil)
            let unknownTimeout = self.actionTimeoutResult("unlisted.check", args: [:], tab: nil)
            let unclassifiedStops = [pdfTimeout, unknownTimeout].allSatisfy {
                $0["guardStopped"] as? Bool == true && $0["outcome"] as? String == "unknown"
            }
            let readTimeoutRecoverable = readReply.values.count == 1 && readCancellation.isCancelled
                && readReply.first?["code"] as? String == "BENCHMARK_READ_TIMEOUT"
                && readReply.first?["guardStopped"] == nil && readReply.first?["outcome"] == nil
            let ok = actionTimeoutCount == 1 && autoCaptureTimeoutCount == 1 && replyCount == 3
                && run.pendingOperations == 0 && run.observations.count == 3
                && queuedCancellationStayedBehindHead && !queuedOperationStarted
                && followupStarted && followupSawCancellations && queueEmpty && lateCallbacksIgnored
                && orderMatches && driveCancellationOK && readTimeoutRecoverable && unclassifiedStops
            run.engine.shutdown()
            self.runs[id] = nil
            answer(["ok": ok, "action_timeout_count": actionTimeoutCount,
                    "auto_capture_timeout_count": autoCaptureTimeoutCount, "reply_count": replyCount,
                    "observations": run.observations.count, "pending_operations": run.pendingOperations,
                    "queued_cancellation_stayed_behind_head": queuedCancellationStayedBehindHead,
                    "followup_started": followupStarted, "cancelled_before_followup": followupSawCancellations,
                    "late_callbacks_ignored": lateCallbacksIgnored, "queue_empty": queueEmpty,
                    "order_matches": orderMatches, "operation_order": startOrder,
                    "drive_cancellation": driveCancellation, "read_timeout_recoverable": readTimeoutRecoverable, "unclassified_timeout_stops": unclassifiedStops])
        }
    }

    private func actionTimeoutResult(_ op: String, args: [String: Any], tab: Tab?) -> [String: Any] {
        if Policy.classify(op, args: args, tab: tab) == .read {
            return ["error": "benchmark observation timed out", "code": "BENCHMARK_READ_TIMEOUT"]
        }
        return ["error": "benchmark action timed out; outcome unknown", "code": "BENCHMARK_ACTION_TIMEOUT",
                "guardStopped": true, "outcome": "unknown"]
    }

    /// Native keyboard focus is shared. Inference overlaps; browser calls do not.
    func perform(_ name: String, _ args: [String: Any], origin: DriveOrigin,
                 cancellation: AgentCancellation, reply: @escaping ([String: Any]) -> Void) {
        var args = args
        // Public benchmark pages can choose only their generated sample files.
        if ["tabs.open", "page.go"].contains(name), let address = args["url"] as? String,
           let scheme = URL(string: address)?.scheme, !["http", "https"].contains(scheme.lowercased()) {
            let result: [String: Any] = ["error": "benchmark navigation requires HTTP or HTTPS", "code": "BENCHMARK_URL"]
            record(name, args, result, from: origin)
            reply(result)
            return
        }
        guard case .socket(let id) = origin, let run = runs[id] else {
            reply(["error": "benchmark seat unavailable"])
            return
        }
        if name == "page.files" {
            let paths = args["paths"] as? [String]
            let tab = (AskRuntime.drive as? Drive)?.sessionTabs(origin).first { Bench.short($0) == args["tab"] as? String }
            guard allowedFixturePaths(paths, run: run), paths?.isEmpty == true || allowedFixtureDestination(tab?.built?.url) else {
                let result: [String: Any] = ["error": "only this session's sample files on synthetic stress-test forms are available", "code": "BENCHMARK_FILE"]
                record(name, args, result, from: origin)
                reply(result)
                return
            }
        }
        if name == "page.screenshot" {
            let folder = Store.file("benchmark-shots/" + id.uuidString)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            args["path"] = folder.appendingPathComponent(UUID().uuidString + ".png").path
        }
        run.pendingOperations += 1
        let finish = operationCompletion(run: run, name: name, args: args, origin: origin, reply: reply)
        var started = false
        cancellation.onCancel = {
            guard !started else { return }
            finish(["error": "cancelled before action started", "code": "CANCELLED",
                    "guardStopped": true, "outcome": "cancelled"], nil, false)
        }
        enqueue { [weak self] in
            guard let self else { finish(["error": "benchmark seat unavailable"], nil, true); return }
            if cancellation.isCancelled {
                finish(["error": "cancelled before action started", "code": "CANCELLED",
                        "guardStopped": true, "outcome": "cancelled"], nil, false)
                self.next()
                return
            }
            started = true
            cancellation.onCancel = nil
            guard let drive = AskRuntime.drive as? Drive, self.runs[id] === run else {
                finish(["error": "benchmark seat unavailable"], nil, true)
                return
            }
            // Keep result pages in this disposable world, including at done.
            if name == "tabs.surface" {
                finish(["error": "benchmark results remain in their isolated session", "code": "BENCHMARK_NO_USER"], nil, true)
                return
            }
            if name == "tabs.attach", let tab = args["id"] as? String, !drive.sessionTabs(origin).contains(where: { Bench.short($0) == tab }) {
                finish(["error": "tab belongs to another benchmark session"], nil, true)
                return
            }
            if name == "page.screenshot" {
                self.withDeadline(Self.screenshotTimeout,
                                  timeoutResult: ["error": "benchmark screenshot timed out", "code": "BENCHMARK_SCREENSHOT_TIMEOUT"],
                                  cancellation: cancellation, capture: { complete in
                    drive.perform(name, args, from: origin, cancellation: cancellation, done: complete)
                }) { result, _ in
                    finish(result, result["path"] as? String, true)
                }
                return
            }
            let subject = drive.sessionTabs(origin).first { Bench.short($0) == ((args["tab"] ?? args["id"]) as? String) }
            self.withDeadline(Self.actionTimeout,
                              timeoutResult: self.actionTimeoutResult(name, args: args, tab: subject),
                              cancellation: cancellation, capture: { complete in
                drive.perform(name, args, from: origin, cancellation: cancellation, done: complete)
            }) { result, timedOut in
                guard !timedOut else { finish(result, nil, true); return }
                var result = result
                if name == "tabs.list", let tabs = result["tabs"] as? [[String: Any]] {
                    result["tabs"] = tabs.filter { row in drive.sessionTabs(origin).contains { Bench.short($0) == row["id"] as? String } }
                }
                let target = (args["tab"] as? String) ?? (name == "tabs.open" ? result["id"] as? String : nil)
                if result["error"] == nil, let target, name != "page.screenshot", run.observations.count < 100 {
                    let folder = Store.file("benchmark-shots/" + id.uuidString)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let path = folder.appendingPathComponent("\(run.observations.count).png").path
                    self.withDeadline(Self.screenshotTimeout,
                                      timeoutResult: ["error": "benchmark screenshot timed out", "code": "BENCHMARK_SCREENSHOT_TIMEOUT"],
                                      cancellation: cancellation, capture: { complete in
                        drive.perform("page.screenshot", ["tab": target, "path": path], from: origin,
                                      cancellation: cancellation, done: complete)
                    }) { shot, _ in
                        finish(result, shot["path"] as? String, true)
                    }
                } else { finish(result, nil, true) }
            }
        }
    }

    private func operationCompletion(run: Run, name: String, args: [String: Any], origin: DriveOrigin,
                                     reply: @escaping ([String: Any]) -> Void)
        -> ([String: Any], String?, Bool) -> Void {
        var completed = false
        return { result, screenshot, advanceQueue in
            guard !completed else { return }
            completed = true
            self.record(name, args, result, from: origin, screenshot: screenshot)
            reply(result)
            run.pendingOperations = max(0, run.pendingOperations - 1)
            if advanceQueue { self.next() }
        }
    }

    /// Resolve dropped native callbacks without holding the shared FIFO forever. Set the
    /// one-shot latch before cancelling because cancellation may synchronously call back.
    private func withDeadline(
        _ timeout: TimeInterval,
        timeoutResult: [String: Any],
        cancellation: AgentCancellation,
        capture: (@escaping ([String: Any]) -> Void) -> Void,
        completion: @escaping ([String: Any], Bool) -> Void
    ) {
        var settled = false
        var watchdog: DispatchWorkItem?
        func settle(_ result: [String: Any], timedOut: Bool) {
            guard !settled else { return }
            settled = true
            watchdog?.cancel()
            if timedOut { cancellation.cancel() }
            completion(result, timedOut)
        }
        let item = DispatchWorkItem {
            settle(timeoutResult, timedOut: true)
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        capture { result in
            DispatchQueue.main.async { settle(result, timedOut: false) }
        }
    }

    private func enqueue(_ work: @escaping () -> Void) {
        queue.append(work)
        if !busy { next() }
    }

    private func record(_ name: String, _ args: [String: Any], _ result: [String: Any],
                        from origin: DriveOrigin, screenshot: String? = nil) {
        guard case .socket(let id) = origin, let run = runs[id] else { return }
        var result = result
        result.removeValue(forKey: "image")
        result.removeValue(forKey: "data")
        var observation: [String: Any] = ["op": name, "args": args, "result": result, "time": Date().timeIntervalSince1970]
        if let screenshot { observation["screenshot"] = screenshot }
        run.observations.append(observation)
    }

    private func next() {
        busy = !queue.isEmpty
        guard busy else { return }
        let work = queue.removeFirst()
        // Avoid synchronous callback recursion and let stop/status requests run.
        DispatchQueue.main.async { work() }
    }
}

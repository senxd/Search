import AppKit
import WebKit

setbuf(stdout, nil)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

@MainActor
final class Check {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    var bridge: AgentInspector!
    var events: [[String: Any]] = []
    init() {
        web.isInspectable = true
        web.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        bridge = AgentInspector(web: web)
        bridge.onEvent = { [weak self] event in self?.events.append(event) }
    }
    func log(_ name: String, _ result: Any) {
        let data = try! JSONSerialization.data(withJSONObject: ["check": name, "result": result], options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
    func command(_ method: String, _ params: [String: Any] = [:], target: String? = nil, owner: String = "bridge") async throws -> [String: Any] {
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            bridge.perform(method: method, params: params, targetID: target, owner: owner) { continuation.resume(with: $0) }
        }
        if method == "Heap.snapshot" {
            log(method, ["snapshotBytes": (result["snapshotData"] as? String)?.utf8.count ?? 0])
        } else { log(method, result) }
        return result
    }
    func load(_ path: String) async throws {
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:18764/" + path)!))
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<100 {
            if !web.isLoading { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AgentInspector.Failure("Navigation timed out")
    }
    func event(_ method: String, after index: Int) async throws -> [String: Any] {
        for _ in 0..<100 {
            if let event = events.dropFirst(index).first(where: { $0["method"] as? String == method }) {
                return event["params"] as? [String: Any] ?? [:]
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AgentInspector.Failure("No \(method) event")
    }
    func run() async {
        do {
            let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("search-artifact-check-\(UUID())")
            defer { try? FileManager.default.removeItem(at: artifacts) }
            for number in 0..<34 {
                let reference = try AgentInspectorArtifact.write(json: ["number": number], directory: artifacts)
                let path = (reference["artifact"] as! [String: Any])["path"] as! String
                let read = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
                assert(read["number"] as? Int == number)
            }
            let retained = try FileManager.default.contentsOfDirectory(atPath: artifacts.path)
            assert(retained.count == 32)
            let oversizedOldFile = artifacts.appendingPathComponent("inspector-old.json")
            FileManager.default.createFile(atPath: oversizedOldFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: oversizedOldFile)
            try handle.truncate(atOffset: 128 * 1024 * 1024)
            try handle.close()
            _ = try AgentInspectorArtifact.write(json: ["latest": true], directory: artifacts)
            assert(!FileManager.default.fileExists(atPath: oversizedOldFile.path))
            log("artifactRetention", 32)
            try await load("")
            let capabilities: [String: Any] = try await withCheckedThrowingContinuation { c in bridge.capabilities { c.resume(with: $0) } }
            try JSONSerialization.data(withJSONObject: capabilities, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: "/tmp/search-inspector-capabilities.json"))
            log("capabilities", ["mainTargetID": capabilities["mainTargetID"]!,
                                 "frames": capabilities["frames"] ?? [],
                                 "targets": (capabilities["targets"] as! [[String: Any]]).map {
                                     ["targetID": $0["targetID"]!, "domains": $0["domains"]!,
                                      "commandCount": ($0["commands"] as! [Any]).count]
                                 }])
            let native = web.perform(NSSelectorFromString("_inspector"))!.takeUnretainedValue() as! NSObject
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let visible = NSSelectorFromString("isVisible")
            assert(!unsafeBitCast(native.method(for: visible), to: Getter.self)(native, visible))
            let value = try await command("Runtime.evaluate", ["expression": "window.probeValue", "returnByValue": true])
            assert((value["result"] as? [String: Any])?["value"] as? Int == 42)
            _ = try await command("Network.enable")
            _ = try await command("Runtime.enable")
            try await load("")
            _ = try await command("Runtime.evaluate", ["expression": "fetch('/body').then(r=>r.text());'started'", "returnByValue": true])
            try await Task.sleep(for: .seconds(1))
            let response = events.last { ($0["method"] as? String) == "Network.responseReceived" && (($0["params"] as? [String: Any])?["response"] as? [String: Any])?["url"] as? String == "http://127.0.0.1:18764/body" }
            guard let requestID = (response?["params"] as? [String: Any])?["requestId"] as? String else { throw AgentInspector.Failure("No network response event") }
            let body = try await command("Network.getResponseBody", ["requestId": requestID])
            assert(body["body"] as? String == "inspector-response-body")
            _ = try await command("Console.enable")
            let consoleStart = events.count
            _ = try await command("Runtime.evaluate", ["expression": "console.warn('inspector-native-console', {answer:42});'logged'", "returnByValue": true])
            let console = try await event("Console.messageAdded", after: consoleStart)
            assert((console["message"] as? [String: Any])?["text"] as? String == "inspector-native-console")
            assert(((console["message"] as? [String: Any])?["parameters"] as? [Any])?.count == 2)
            log("nativeConsole", console)
            let remote = try await command("Runtime.evaluate", ["expression": "({answer:42,nested:{ok:true}})", "objectGroup": "inspector-check", "generatePreview": true])
            guard let objectID = (remote["result"] as? [String: Any])?["objectId"] as? String else { throw AgentInspector.Failure("No remote object handle") }
            let properties = try await command("Runtime.getProperties", ["objectId": objectID, "ownProperties": true])
            assert((properties["properties"] as? [[String: Any]])?.contains { $0["name"] as? String == "answer" && ($0["value"] as? [String: Any])?["value"] as? Int == 42 } == true)
            let called = try await command("Runtime.callFunctionOn", ["objectId": objectID, "functionDeclaration": "function(){return this.answer+1}", "returnByValue": true])
            assert((called["result"] as? [String: Any])?["value"] as? Int == 43)
            _ = try await command("Runtime.releaseObjectGroup", ["objectGroup": "inspector-check"])
            do { _ = try await command("Runtime.getProperties", ["objectId": objectID]); throw AgentInspector.Failure("Released object unexpectedly survived") }
            catch let error as AgentInspector.Failure { assert(error.code != nil) }
            let socketStart = events.count
            _ = try await command("Runtime.evaluate", ["expression": "window.socket=new WebSocket('ws://127.0.0.1:18764/socket');socket.onopen=()=>socket.send('inspector-echo');socket.onmessage=e=>window.socketEcho=e.data;'started'", "returnByValue": true])
            _ = try await event("Network.webSocketClosed", after: socketStart)
            for method in ["Network.webSocketCreated", "Network.webSocketWillSendHandshakeRequest", "Network.webSocketHandshakeResponseReceived", "Network.webSocketFrameSent", "Network.webSocketFrameReceived"] {
                _ = try await event(method, after: socketStart)
            }
            let echoed = try await command("Runtime.evaluate", ["expression": "window.socketEcho", "returnByValue": true])
            assert((echoed["result"] as? [String: Any])?["value"] as? String == "inspector-echo")
            log("webSocketEvents", events.dropFirst(socketStart).filter { ($0["method"] as? String)?.hasPrefix("Network.webSocket") == true })
            do { _ = try await command("Timeline.enable") }
            catch let error as AgentInspector.Failure { guard error.message == "Timeline domain already enabled" else { throw error } }
            let timelineStart = events.count
            _ = try await command("Timeline.start", ["maxCallStackDepth": 5])
            _ = try await command("Runtime.evaluate", ["expression": "setTimeout(()=>{document.body.style.padding='10px';window.layoutWidth=document.body.offsetWidth},0);'started'", "returnByValue": true])
            _ = try await event("Timeline.eventRecorded", after: timelineStart)
            _ = try await command("Timeline.stop")
            _ = try await event("Timeline.recordingStarted", after: timelineStart)
            _ = try await event("Timeline.recordingStopped", after: timelineStart)
            log("timelineEvents", events.dropFirst(timelineStart).filter { ($0["method"] as? String)?.hasPrefix("Timeline.") == true }.map {
                ["method": $0["method"]!, "recordType": (($0["params"] as? [String: Any])?["record"] as? [String: Any])?["type"] ?? NSNull()]
            })
            do { _ = try await command("Debugger.enable") }
            catch let error as AgentInspector.Failure { guard error.message == "Debugger domain already enabled" else { throw error } }
            let breakpoint = try await command("Debugger.setBreakpointByUrl", ["url": "http://127.0.0.1:18764/debug.js", "lineNumber": 1])
            assert(!(breakpoint["locations"] as? [Any] ?? []).isEmpty)
            let pauseStart = events.count
            _ = try await command("Runtime.evaluate", ["expression": "setTimeout(inspectorOuter,0);'scheduled'", "returnByValue": true])
            let paused = try await event("Debugger.paused", after: pauseStart)
            guard let callFrames = paused["callFrames"] as? [[String: Any]], let callFrame = callFrames.first,
                  let callFrameID = callFrame["callFrameId"] as? String else { throw AgentInspector.Failure("No paused call frame") }
            assert(callFrames.contains { $0["functionName"] as? String == "inspectorInner" })
            assert(callFrames.contains { $0["functionName"] as? String == "inspectorOuter" })
            let local = try await command("Debugger.evaluateOnCallFrame", ["callFrameId": callFrameID, "expression": "value", "returnByValue": true])
            assert((local["result"] as? [String: Any])?["value"] as? Int == 20)
            let stepStart = events.count
            _ = try await command("Debugger.stepOver")
            let stepped = try await event("Debugger.paused", after: stepStart)
            let steppedFrame = (stepped["callFrames"] as? [[String: Any]])?.first
            assert((steppedFrame?["location"] as? [String: Any])?["lineNumber"] as? Int == 2)
            _ = try await command("Debugger.removeBreakpoint", ["breakpointId": breakpoint["breakpointId"]!])
            let resumeStart = events.count
            _ = try await command("Debugger.resume")
            _ = try await event("Debugger.resumed", after: resumeStart)
            let completed = try await command("Runtime.evaluate", ["expression": "window.debugResult", "returnByValue": true])
            assert((completed["result"] as? [String: Any])?["value"] as? Int == 42)
            log("debuggerPausedStack", paused)
            _ = try await command("ScriptProfiler.startTracking", ["includeSamples": true])
            _ = try await command("CPUProfiler.startTracking")
            _ = try await command("Runtime.evaluate", ["expression": "window.work=setInterval(function inspectorWork(){let x=0,end=Date.now()+80;while(Date.now()<end){for(let i=0;i<10000;i++)x+=Math.sqrt(i)}window.workResult=x},5);'working'", "returnByValue": true])
            try await Task.sleep(for: .milliseconds(500))
            _ = try await command("Runtime.evaluate", ["expression": "clearInterval(window.work);window.workResult", "returnByValue": true])
            _ = try await command("CPUProfiler.stopTracking")
            _ = try await command("ScriptProfiler.stopTracking")
            try await Task.sleep(for: .milliseconds(200))
            let profile = events.filter { ($0["method"] as? String)?.hasPrefix("ScriptProfiler.") == true || ($0["method"] as? String)?.hasPrefix("CPUProfiler.") == true }
            assert(profile.contains { $0["method"] as? String == "ScriptProfiler.trackingComplete" })
            assert(profile.contains { $0["method"] as? String == "CPUProfiler.trackingUpdate" })
            let samples = (profile.last { $0["method"] as? String == "ScriptProfiler.trackingComplete" }?["params"] as? [String: Any])?["samples"] as? [String: Any]
            assert(!(samples?["stackTraces"] as? [Any] ?? []).isEmpty)
            log("profileEvents", profile)
            try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: "/tmp/search-inspector-profile.json"))
            let tree = try await command("Page.getResourceTree")
            guard let frames = (tree["frameTree"] as? [String: Any])?["childFrames"] as? [[String: Any]],
                  let frame = frames.first?["frame"] as? [String: Any], let frameID = frame["id"] as? String else { throw AgentInspector.Failure("No cross origin frame") }
            guard let created = events.last(where: {
                $0["method"] as? String == "Runtime.executionContextCreated" &&
                (($0["params"] as? [String: Any])?["context"] as? [String: Any])?["frameId"] as? String == frameID
            }), let context = (created["params"] as? [String: Any])?["context"] as? [String: Any], let contextID = context["id"] else {
                throw AgentInspector.Failure("No cross origin execution context")
            }
            let frameValue = try await command("Runtime.evaluate", ["expression": "location.origin", "contextId": contextID, "returnByValue": true])
            assert((frameValue["result"] as? [String: Any])?["value"] as? String == "http://localhost:18765")
            _ = try await command("Debugger.setBreakpointsActive", ["active": false])
            _ = try await command("Debugger.setBreakpointsActive", ["active": true])
            do { _ = try await command("Network.setInterceptionEnabled", ["enabled": true]) }
            catch let error as AgentInspector.Failure { guard error.message == "Interception already enabled" else { throw error } }
            let interceptedURL = "http://127.0.0.1:18764/intercepted"
            _ = try await command("Network.addInterception", ["url": interceptedURL, "stage": "request"])
            let interceptionStart = events.count
            let promise = try await command("Runtime.evaluate", ["expression": "fetch('/intercepted').then(r=>r.text())"])
            let intercepted = try await event("Network.requestIntercepted", after: interceptionStart)
            guard let interceptedID = intercepted["requestId"] as? String,
                  let promiseID = (promise["result"] as? [String: Any])?["objectId"] as? String else { throw AgentInspector.Failure("Missing intercepted request or promise") }
            _ = try await command("Network.interceptRequestWithResponse", ["requestId": interceptedID, "content": "inspector-mocked-body", "base64Encoded": false, "mimeType": "text/plain", "status": 200, "statusText": "OK", "headers": [:]])
            let mocked = try await command("Runtime.awaitPromise", ["promiseObjectId": promiseID, "returnByValue": true])
            assert((mocked["result"] as? [String: Any])?["value"] as? String == "inspector-mocked-body")
            _ = try await command("Network.removeInterception", ["url": interceptedURL, "stage": "request"])
            let responseRule: [String: Any] = ["url": "http://127\\.0\\.0\\.1:18764/BODY$", "stage": "response", "isRegex": true, "caseSensitive": false]
            _ = try await command("Network.addInterception", responseRule)
            let responseStart = events.count
            let responsePromise = try await command("Runtime.evaluate", ["expression": "fetch('/body').then(r=>r.text())"])
            let interceptedResponse = try await event("Network.responseIntercepted", after: responseStart)
            _ = try await command("Network.interceptWithResponse", ["requestId": interceptedResponse["requestId"]!, "content": "inspector-response-override", "base64Encoded": false, "mimeType": "text/plain"])
            let replaced = try await command("Runtime.awaitPromise", ["promiseObjectId": (responsePromise["result"] as! [String: Any])["objectId"]!, "returnByValue": true])
            assert((replaced["result"] as? [String: Any])?["value"] as? String == "inspector-response-override")
            _ = try await command("Network.removeInterception", responseRule)
            let cleanupURL = "http://127.0.0.1:18764/cleanup"
            _ = try await command("Network.addInterception", ["url": cleanupURL, "stage": "request"], owner: "departing")
            do {
                _ = try await command("Network.removeInterception", ["url": cleanupURL, "stage": "request"], owner: "observer")
                throw AgentInspector.Failure("Another session removed an owned rule")
            } catch let error as AgentInspector.Failure { assert(error.message == "Interception rule belongs to another session.") }
            let cleanupStart = events.count
            let cleanupPromise = try await command("Runtime.evaluate", ["expression": "fetch('/cleanup').then(r=>r.text())"])
            _ = try await event("Network.requestIntercepted", after: cleanupStart)
            await withCheckedContinuation { continuation in bridge.release(owner: "departing") { continuation.resume() } }
            let cleaned = try await command("Runtime.awaitPromise", ["promiseObjectId": (cleanupPromise["result"] as! [String: Any])["objectId"]!, "returnByValue": true])
            assert((cleaned["result"] as? [String: Any])?["value"] as? String == "missing")
            let afterCleanup = events.count
            let unblocked = try await command("Runtime.evaluate", ["expression": "fetch('/cleanup').then(r=>r.text())"])
            let unblockedResult = try await command("Runtime.awaitPromise", ["promiseObjectId": (unblocked["result"] as! [String: Any])["objectId"]!, "returnByValue": true])
            assert((unblockedResult["result"] as? [String: Any])?["value"] as? String == "missing")
            assert(!events.dropFirst(afterCleanup).contains { $0["method"] as? String == "Network.requestIntercepted" })
            log("interceptionOwnerCleanup", true)
            let heap = try await command("Heap.snapshot")
            assert(heap["snapshotData"] as? String != nil)
            let heapReference = try AgentInspectorArtifact.write(json: heap, directory: artifacts)
            log("heapArtifact", heapReference)
            _ = try await command("Runtime.evaluate", ["expression": "window.worker=new Worker('/worker.js');'started'", "returnByValue": true])
            try await Task.sleep(for: .milliseconds(500))
            let workerCapabilities: [String: Any] = try await withCheckedThrowingContinuation { c in bridge.capabilities { c.resume(with: $0) } }
            log("workerTargets", (workerCapabilities["targets"] as! [[String: Any]]).map {
                ["targetID": $0["targetID"]!, "type": $0["type"]!]
            })
            let targets = workerCapabilities["targets"] as? [[String: Any]] ?? []
            guard let worker = targets.first(where: { $0["type"] as? String == "worker" }), let workerID = worker["targetID"] as? String else { throw AgentInspector.Failure("No worker target") }
            let workerValue = try await command("Runtime.evaluate", ["expression": "self.workerValue", "returnByValue": true], target: workerID)
            assert((workerValue["result"] as? [String: Any])?["value"] as? Int == 73)
            try await load("second")
            let navigated = try await command("Runtime.evaluate", ["expression": "location.pathname", "returnByValue": true])
            assert((navigated["result"] as? [String: Any])?["value"] as? String == "/second")
            log("navigationEvents", events.filter { $0["method"] as? String == "Target.targetCreated" || $0["method"] as? String == "Target.targetDestroyed" || ($0["method"] as? String)?.hasPrefix("Runtime.executionContext") == true })
            do { _ = try await command("Search.invalidCommand"); throw AgentInspector.Failure("Invalid command unexpectedly succeeded") }
            catch let error as AgentInspector.Failure { assert(error.code == -32601); log("invalidCommand", ["code": error.code!, "message": error.message]) }
            bridge.disconnect()
            let reconnected = try await command("Runtime.evaluate", ["expression": "6*7", "returnByValue": true])
            assert((reconnected["result"] as? [String: Any])?["value"] as? Int == 42)
            bridge.disconnect()
            log("PASS", true)
            exit(0)
        } catch {
            log("FAIL", error.localizedDescription)
            print((error as NSError).userInfo)
            bridge.disconnect()
            exit(1)
        }
    }
}
Task { @MainActor in await Check().run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("FAIL overall timeout"); exit(1) }
application.run()

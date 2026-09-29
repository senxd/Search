import Foundation
import WebKit

/// WebKit protocol, transported by its own hidden inspector frontend. This uses
/// guarded private selectors and reports an error when this WebKit lacks them.
@MainActor
final class AgentInspector: NSObject, WKScriptMessageHandler {
    private final class EventHandler: NSObject, WKScriptMessageHandler {
        weak var owner: AgentInspector?
        init(_ owner: AgentInspector) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(controller, didReceive: message)
        }
    }
    private weak var web: WKWebView?
    private var inspector: NSObject?
    private var frontend: WKWebView?
    private let channel = "searchInspector" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var connecting = false
    private var waitingForLoad = false
    private var previousDelegate: AnyObject?
    private var waiting: [(Result<WKWebView, Error>) -> Void] = []
    private var generation = 0
    private var opened = false
    private var requests: [UUID: (Result<[String: Any], Error>) -> Void] = [:]
    var onEvent: (([String: Any]) -> Void)?

    init(web: WKWebView) { self.web = web }

    struct Failure: LocalizedError {
        let message: String
        let code: Int?
        var errorDescription: String? { message }
        init(_ message: String, code: Int? = nil) { self.message = message; self.code = code }
    }

    func perform(method: String, params: [String: Any] = [:], targetID: String? = nil, owner: String = "bridge",
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard method.contains("."), JSONSerialization.isValidJSONObject(params) else {
            completion(.failure(Failure("A protocol method and JSON object parameters are required.")))
            return
        }
        let request = UUID()
        requests[request] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.complete(request, .failure(Failure("Inspector command timed out.", code: -32000)))
        }
        connect { [weak self] result in
            guard let self else { completion(.failure(Failure("Inspector disconnected."))); return }
            let completion: (Result<[String: Any], Error>) -> Void = { self.complete(request, $0) }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let frontend):
                frontend.callAsyncJavaScript("return await window[channel].command(method, params, targetID, owner);",
                    arguments: ["channel": self.channel, "method": method, "params": params,
                                "targetID": targetID as Any? ?? NSNull(), "owner": owner], in: nil, in: .page) { result in
                    switch result {
                    case .failure(let error): completion(.failure(error))
                    case .success(let value):
                        guard let reply = value as? [String: Any] else {
                            completion(.failure(Failure("Invalid inspector response."))); return
                        }
                        if let error = reply["error"] as? [String: Any] {
                            completion(.failure(Failure(error["message"] as? String ?? "Protocol command failed.",
                                                        code: error["code"] as? Int)))
                        } else { completion(.success(reply["result"] as? [String: Any] ?? [:])) }
                    }
                }
            }
        }
    }

    func release(owner: String, completion: (() -> Void)? = nil) {
        guard let frontend else { completion?(); return }
        frontend.callAsyncJavaScript("await window[channel]?.release(owner);",
            arguments: ["channel": channel, "owner": owner], in: nil, in: .page) { _ in completion?() }
    }

    func capabilities(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        connect { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let frontend):
                frontend.evaluateJavaScript(Self.capabilityScript) { value, error in
                    if let error { completion(.failure(error)) }
                    else if let value = value as? [String: Any] { completion(.success(value)) }
                    else { completion(.failure(Failure("Invalid inspector capabilities."))) }
                }
            }
        }
    }

    func disconnect() {
        generation += 1
        connecting = false
        let callbacks = waiting
        waiting.removeAll()
        callbacks.forEach { $0(.failure(Failure("Inspector disconnected."))) }
        let pending = requests
        requests.removeAll()
        pending.values.forEach { $0(.failure(Failure("Inspector disconnected.", code: -32000))) }
        if let frontend {
            frontend.evaluateJavaScript("window[\(Self.json(channel))]?.close(); delete window[\(Self.json(channel))];", completionHandler: nil)
            frontend.configuration.userContentController.removeScriptMessageHandler(forName: channel)
        }
        if opened, let inspector, !Self.flag(inspector, "isVisible") {
            Self.send(inspector, "close")
        }
        restoreDelegate()
        frontend = nil
        inspector = nil
        opened = false
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == channel, let event = message.body as? [String: Any] else { return }
        onEvent?(event)
    }

    private func connect(_ completion: @escaping (Result<WKWebView, Error>) -> Void) {
        waiting.append(completion)
        guard !connecting else { return }
        connecting = true
        let token = generation
        guard let web, web.responds(to: NSSelectorFromString("_inspector")),
              let inspector = web.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("connect")),
              inspector.responds(to: NSSelectorFromString("delegate")),
              inspector.responds(to: NSSelectorFromString("setDelegate:")),
              inspector.responds(to: NSSelectorFromString("inspectorWebView")) else {
            finish(.failure(Failure("This WebKit does not expose a local inspector connection.")), token: token)
            return
        }
        self.inspector = inspector
        if !Self.flag(inspector, "isConnected") {
            opened = true
            waitingForLoad = true
            previousDelegate = inspector.perform(NSSelectorFromString("delegate"))?.takeUnretainedValue()
            inspector.perform(NSSelectorFromString("setDelegate:"), with: self)
            Self.send(inspector, "connect")
        }
        prepare(deadline: Date().addingTimeInterval(10), token: token)
    }

    private func prepare(deadline: Date, token: Int) {
        guard token == generation, let inspector else { return }
        guard Date() < deadline else {
            finish(.failure(Failure("WebKit inspector did not become ready. The tab must have developer extras enabled and a loaded page.")), token: token)
            return
        }
        if waitingForLoad {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.prepare(deadline: deadline, token: token) }
            return
        }
        guard let view = inspector.perform(NSSelectorFromString("inspectorWebView"))?.takeUnretainedValue() as? WKWebView else {
            if !Self.flag(inspector, "isConnected") { Self.send(inspector, "connect") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.prepare(deadline: deadline, token: token) }
            return
        }
        view.evaluateJavaScript("!!(window.InspectorBackend?.Connection && window.WI?.mainTarget)") { [weak self] ready, error in
            guard let self, token == self.generation else { return }
            guard error == nil, ready as? Bool == true else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.prepare(deadline: deadline, token: token) }
                return
            }
            if self.frontend !== view {
                self.frontend?.configuration.userContentController.removeScriptMessageHandler(forName: self.channel)
                self.frontend = view
                view.configuration.userContentController.add(EventHandler(self), name: self.channel)
            }
            view.evaluateJavaScript(Self.installScript(channel: self.channel)) { _, error in
                guard token == self.generation else { return }
                self.finish(error.map { .failure($0) } ?? .success(view), token: token)
            }
        }
    }

    private func finish(_ result: Result<WKWebView, Error>, token: Int) {
        guard generation == token else { return }
        connecting = false
        restoreDelegate()
        let callbacks = waiting
        waiting.removeAll()
        callbacks.forEach { $0(result) }
    }

    private func complete(_ id: UUID, _ result: Result<[String: Any], Error>) {
        requests.removeValue(forKey: id)?(result)
    }

    @objc func inspectorFrontendLoaded(_ inspector: NSObject) {
        waitingForLoad = false
        let selector = NSSelectorFromString("inspectorFrontendLoaded:")
        if let delegate = previousDelegate as? NSObject, delegate.responds(to: selector) {
            delegate.perform(selector, with: inspector)
        }
    }

    @objc func inspector(_ inspector: NSObject, openURLExternally url: NSURL) {
        let selector = NSSelectorFromString("inspector:openURLExternally:")
        if let delegate = previousDelegate as? NSObject, delegate.responds(to: selector) {
            delegate.perform(selector, with: inspector, with: url)
        }
    }

    private func restoreDelegate() {
        if waitingForLoad || previousDelegate != nil {
            inspector?.perform(NSSelectorFromString("setDelegate:"), with: previousDelegate)
        } else if let inspector,
                  inspector.perform(NSSelectorFromString("delegate"))?.takeUnretainedValue() === self {
            inspector.perform(NSSelectorFromString("setDelegate:"), with: nil)
        }
        previousDelegate = nil
        waitingForLoad = false
    }

    private static func send(_ object: NSObject, _ method: String) {
        let selector = NSSelectorFromString(method)
        if object.responds(to: selector) { object.perform(selector) }
    }

    private static func flag(_ object: NSObject, _ method: String) -> Bool {
        let selector = NSSelectorFromString(method)
        guard object.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
    }

    private static func json(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), encoding: .utf8)!
    }

    private static let capabilityScript = """
    (() => {
      const describe = t => ({targetID:t.identifier,type:t.type,name:t.name || "",domains:Object.keys(t._agents),
        commands:Array.from(t._supportedCommandParameters || [], ([method,c]) =>
          ({method,parameters:c._callSignature || [],returns:c._replySignature || []})),
        events:Array.from(t._supportedEventParameters || [], ([method,e]) =>
          ({method,parameters:e._parameterNames || []}))});
      return {protocol:"webkit",transport:"local-inspector",mainTargetID:WI.mainTarget.identifier,
        frames:WI.networkManager.frames.map(f => ({frameID:f.id,parentFrameID:f.parentFrame?.id || null,
          url:f.url,securityOrigin:f.securityOrigin,contexts:f.executionContextList.contexts.map(c =>
            ({contextID:c.id,targetID:c.target.identifier,type:c.type,name:c.name}))})),
        targets:WI.targets.map(describe),backend:InspectorBackend.backendConnection.target ?
          {...describe(InspectorBackend.backendConnection.target),targetID:"backend",
           engineTargetID:InspectorBackend.backendConnection.target.identifier} : null};
    })()
    """

    private static func installScript(channel: String) -> String {
        """
        (() => {
          const channel = \(json(channel));
          if (window[channel]) return true;
          const pending = new Map;
          const rules = new Map;
          const intercepted = new Map;
          const epochs = new Map;
          const ruleKey = (connection, p) => JSON.stringify([connection.target?.identifier, p.url, p.stage, p.caseSensitive !== false, !!p.isRegex]);
          const interceptKey = (targetID, requestId) => JSON.stringify([targetID, requestId]);
          const matches = (r, url) => {
            try { return r.isRegex ? new RegExp(r.url, r.caseSensitive !== false ? "" : "i").test(url) :
              (r.caseSensitive !== false ? r.url === url : r.url.toLowerCase() === url.toLowerCase()); }
            catch { return false; }
          };
          const prototype = InspectorBackend.Connection.prototype;
          const original = prototype.dispatch;
          const dispatch = function(message) {
            const m = typeof message === "string" ? JSON.parse(message) : message;
            const request = pending.get(m.id);
            if (request && request.connection === this) {
              if (!m.error && request.method === "Network.addInterception") {
                const rule = {...request.params, key:ruleKey(this, request.params), targetID:this.target?.identifier, owner:request.owner};
                rules.set(rule.key, rule);
                if (request.epoch !== (epochs.get(request.owner) || 0)) api.release(request.owner);
              }
              if (!m.error && request.method === "Network.removeInterception" && rules.get(ruleKey(this, request.params)) === request.rule)
                rules.delete(ruleKey(this, request.params));
              if (!m.error && request.method.startsWith("Network.intercept")) intercepted.delete(interceptKey(this.target?.identifier, request.params.requestId));
              pending.delete(m.id); clearTimeout(request.timer); request.resolve(m); return;
            }
            if (m.method) window.webkit?.messageHandlers[channel]?.postMessage({
              targetID:this.target?.identifier || "backend",method:m.method,params:m.params || {}});
            if (m.method === "Network.requestIntercepted" || m.method === "Network.responseIntercepted") {
              const stage = m.method === "Network.requestIntercepted" ? "request" : "response";
              const url = (m.params.request || m.params.response).url;
              const rule = Array.from(rules.values()).find(r => r.targetID === this.target?.identifier && r.stage === stage && matches(r, url));
              if (rule) {
                intercepted.set(interceptKey(rule.targetID, m.params.requestId), {requestId:m.params.requestId,stage,targetID:rule.targetID,owner:rule.owner});
                return;
              }
            }
            return original.call(this, message);
          };
          prototype.dispatch = dispatch;
          const api = window[channel] = {
            command(method, params, targetID, owner = "bridge") {
              const target = targetID ? WI.targets.find(t => t.identifier === targetID) : WI.mainTarget;
              const connection = targetID === "backend" ? InspectorBackend.backendConnection : target?.connection;
              if (!connection) return Promise.resolve({error:{code:-32000,message:"Inspector target no longer exists."}});
              if ((method === "Network.addInterception" || method === "Network.removeInterception") &&
                  rules.get(ruleKey(connection, params))?.owner !== undefined && rules.get(ruleKey(connection, params)).owner !== owner)
                return Promise.resolve({error:{code:-32000,message:"Interception rule belongs to another session."}});
              const id = InspectorBackend.globalSequenceId++;
              return new Promise(resolve => {
                const timer = setTimeout(() => {
                  pending.delete(id); resolve({error:{code:-32000,message:"Inspector command timed out."}});
                }, 30000);
                pending.set(id,{connection,resolve,timer,method,params,owner,epoch:epochs.get(owner) || 0,rule:rules.get(ruleKey(connection, params))});
                try { connection.sendMessageToBackend(JSON.stringify({id,method,params})); }
                catch (e) { pending.delete(id); clearTimeout(timer); resolve({error:{code:-32000,message:String(e)}}); }
              });
            },
            async release(owner) {
              epochs.set(owner, (epochs.get(owner) || 0) + 1);
              const held = Array.from(intercepted.values()).filter(r => r.owner === owner);
              const owned = Array.from(rules.values()).filter(r => r.owner === owner);
              for (const r of owned) rules.delete(r.key);
              await Promise.all(held.map(r => this.command("Network.interceptContinue", {requestId:r.requestId,stage:r.stage}, r.targetID, owner)));
              await Promise.all(owned.map(r => this.command("Network.removeInterception", {url:r.url,stage:r.stage,caseSensitive:r.caseSensitive,isRegex:r.isRegex}, r.targetID, owner)));
            },
            async close() {
              await Promise.all(Array.from(new Set(Array.from(rules.values(), r => r.owner))).map(owner => this.release(owner)));
              if (prototype.dispatch === dispatch) prototype.dispatch = original;
              for (const request of pending.values()) {
                clearTimeout(request.timer); request.resolve({error:{code:-32000,message:"Inspector disconnected."}});
              }
              pending.clear();
            }
          };
          return true;
        })()
        """
    }
}

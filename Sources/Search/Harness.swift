import Foundation
import WebKit

// Ask's model host. The agent loop is JavaScript — Runtime/ask/harness.js —
// running in a hidden WKWebView that is never added to a window. The page
// holds the loop; this object holds everything the loop cannot have: the
// network (window.fetch would be CORS-bound, and keys must never enter JS),
// the browser itself (through AskRuntime.drive), and the chat (Mind.hear).
//
// The page talks over one messageHandler, "searchHarness", in four kinds:
//
//   {kind:"fetch", id, url, method, headers, body, stream, auth}
//       URLSession does the request off-main. stream:true answers with
//       __h._fetchMeta(id, status, headersJSON), one __h._fetchLine(id, line)
//       per response line (SSE), then __h._fetchEnd(id, status, null, null).
//       stream:false answers with _fetchMeta then _fetchEnd(id, status, body).
//       Errors arrive as _fetchEnd(id, 0, null, message). `auth` names a key
//       (see authHosts); the secret is added here so the page never holds it.
//   {kind:"abort", id} — cancels a running fetch.
//   {kind:"tool", id, name, args} — name is a Drive op ("tabs.list",
//       "page.snapshot", …); the reply is __h._tool(id, resultObject).
//       The model's own door: `granted` is stripped from args whatever the
//       op, and `tabs.grant` is refused — consent is never a tool call.
//   {kind:"grant", id, tab} — the chip door, emitted by attachTabs alone:
//       forwards the tab the user's chip named to Drive's tabs.grant, the
//       one op that writes consent; answered through the same __h._tool.
//   {kind:"event", name, data} — mapped onto Mind.shared.hear: "delta"
//       {chat,text}, "message" {chat,message}, "tool" {chat,tool},
//       "activity" {chat,text}, "done" {chat,error}.
//   {kind:"log", text} — NSLog.

@MainActor
final class Harness: NSObject, AskEngine {
    static let shared = Harness()

    private var web: WKWebView?
    private var loaded = false
    private var pendingJS: [(js: String, onError: (@MainActor (Error) -> Void)?)] = []
    private var fetches: [Int: Task<Void, Never>] = [:]
    private var activeChat: UUID?
    /// The bridge id of a parked ask_user — one question at a time. The
    /// seat frees on the answer (resolveAsk), on the turn ending, and on
    /// a new run taking over.
    private var pendingAsk: Int?
    /// The live turn's stamp — run() puts it on the job's chat and the
    /// harness echoes it on every event, so a killed turn's tail can't
    /// write into the chat that took its place.
    private var lastRunTurn: UUID?

    private(set) var running = false

    override init() {
        super.init()
        attach()
    }

    /// Registers this engine with the panel's state. Touching
    /// `Harness.shared` already does it — init calls this — so an explicit
    /// call is for clarity, or to reclaim the seat after something else sat
    /// in it.
    func attach() { Mind.shared.engine = self }

    // MARK: - the hidden page

    @discardableResult
    private func boot() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // A background agent: its timers and streams must never throttle.
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.add(self, name: "searchHarness")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        let bridge = "window.__native={post:function(m){window.webkit.messageHandlers.searchHarness.postMessage(m);}};"
        web.loadHTMLString("<meta charset=utf-8><script>" + bridge + AskJS.load("harness.js") + "</script>", baseURL: nil)
        self.web = web
        return web
    }

    /// Run JS in the page — queued until the harness script has loaded.
    /// `onError` hears when the evaluation itself fails (a page that died
    /// without a crash signal), never what the script did afterwards.
    private func tell(_ js: String, onError: (@MainActor (Error) -> Void)? = nil) {
        guard let web else {
            onError?(NSError(domain: "AskHarness", code: 0,
                             userInfo: [NSLocalizedDescriptionKey: "no harness page"]))
            return
        }
        if !loaded {
            pendingJS.append((js, onError))
            return
        }
        web.evaluateJavaScript(js) { _, error in
            guard let error, let onError else { return }
            MainActor.assumeIsolated { onError(error) }
        }
    }

    // MARK: - AskEngine

    func run(_ job: AskJob) {
        running = true
        activeChat = job.chat.id
        // A new turn replaces the old one's open seats: a question the last
        // turn was holding goes, and its parked approval cards settle —
        // the consent was that turn's.
        pendingAsk = nil
        (AskRuntime.drive as? Drive)?.denyPending(for: .app, reason: "a new turn took over")
        _ = boot()
        struct JobJSON: Encodable {
            var chat: AskChat
            var tabs: [AskTab]
            /// The composer's typed pieces — images, files, sites — filled
            /// at send (AskAttach.filled): harness.js folds them into the
            /// turn's user message as context lines or image parts.
            var attachments: [AskAttach]
            var text: String
        }
        guard let data = try? JSONEncoder().encode(JobJSON(chat: job.chat, tabs: job.tabs,
                                                           attachments: job.attachments, text: job.text)),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var chatObject = object["chat"] as? [String: Any]
        else {
            running = false
            Mind.shared.hear(.done(chat: job.chat.id, error: "could not encode the job"))
            return
        }
        // The turn stamp (design/interaction.md §2): the harness echoes
        // job.chat.turn on every emit, and event() drops a stale turn's
        // tail. A chat that already carries a stamp keeps it — Mind marks
        // turn on send/retry — otherwise the run mints one here.
        let stamp = (chatObject["turn"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
        chatObject["turn"] = stamp.uuidString
        object["chat"] = chatObject
        lastRunTurn = stamp
        guard let stamped = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: stamped, encoding: .utf8)
        else {
            running = false
            Mind.shared.hear(.done(chat: job.chat.id, error: "could not encode the job"))
            return
        }
        tell("__h.run(\(json));") { [weak self] error in
            // The page took the call but couldn't run it — a dead webview
            // that never told us. Say the turn ended rather than leaving
            // running stuck true.
            guard let self else { return }
            NSLog("[harness] __h.run never landed: %@", error.localizedDescription)
            self.running = false
            if self.activeChat == job.chat.id { self.activeChat = nil }
            Mind.shared.hear(.done(chat: job.chat.id, error: "harness page didn't answer"))
        }
    }

    func steer(_ text: String) {
        tell("__h.steer(\(jsLiteral(text)));")
    }

    func stop() {
        tell("__h.stop();")
        running = false
        // The JS side flushes its parked tool promises on kill; the seats
        // on this side have to empty too — a question card's seat, and any
        // approval cards Drive still holds for the app's session.
        pendingAsk = nil
        (AskRuntime.drive as? Drive)?.denyPending(for: .app, reason: "the turn was stopped")
    }

    /// Mind's answer to a parked ask_user — the question card resolved. A
    /// late answer (the kill already force-resolved the JS promise) finds
    /// an empty seat and goes nowhere.
    func resolveAsk(_ result: [String: Any]) {
        guard let id = pendingAsk else { return }
        pendingAsk = nil
        toolReply(id, result)
    }

    /// Mind's answer to a parked approval card — Drive owns the finish.
    func settleApproval(_ id: UUID, _ verdict: ApprovalVerdict) {
        (AskRuntime.drive as? Drive)?.settleApproval(id, verdict)
    }

    // MARK: - the bridge in

    private func fetch(_ body: [String: Any]) {
        guard let id = (body["id"] as? NSNumber)?.intValue,
              let urlString = body["url"] as? String,
              let url = URL(string: urlString)
        else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.httpMethod = (body["method"] as? String) ?? "GET"
        for (key, value) in (body["headers"] as? [String: String]) ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let text = body["body"] as? String { request.httpBody = Data(text.utf8) }
        injectAuth(&request, spec: body["auth"] as? String)
        let stream = (body["stream"] as? Bool) ?? false
        let task = Task.detached { [weak self] in
            defer { Task { @MainActor in self?.fetches[id] = nil } }
            do {
                if stream {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    await self?.fetchMeta(id, http?.statusCode ?? 0, Self.headers(of: http))
                    for try await line in bytes.lines {
                        await self?.fetchLine(id, line)
                    }
                    await self?.fetchEnd(id, http?.statusCode ?? 0, nil, nil)
                } else {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let http = response as? HTTPURLResponse
                    await self?.fetchMeta(id, http?.statusCode ?? 0, Self.headers(of: http))
                    await self?.fetchEnd(id, http?.statusCode ?? 0, String(decoding: data, as: UTF8.self), nil)
                }
            } catch {
                await self?.fetchEnd(id, 0, nil, error.localizedDescription)
            }
        }
        fetches[id] = task
    }

    private func abort(_ body: [String: Any]) {
        guard let id = (body["id"] as? NSNumber)?.intValue else { return }
        fetches[id]?.cancel()
    }

    private func fetchMeta(_ id: Int, _ status: Int, _ headers: [String: String]) {
        let json = (try? JSONSerialization.data(withJSONObject: headers))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        tell("__h._fetchMeta(\(id), \(status), \(jsLiteral(json)));")
    }

    private func fetchLine(_ id: Int, _ line: String) {
        tell("__h._fetchLine(\(id), \(jsLiteral(line)));")
    }

    private func fetchEnd(_ id: Int, _ status: Int, _ body: String?, _ error: String?) {
        tell("__h._fetchEnd(\(id), \(status), \(jsLiteral(body)), \(jsLiteral(error)));")
    }

    private nonisolated static func headers(of response: HTTPURLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            headers["\(key)".lowercased()] = "\(value)"
        }
        return headers
    }

    /// Hosts each bridge credential may be sent to — the page names a
    /// provider (`auth:"openrouter"`); the secret is added here so the
    /// script never holds a key.
    private static let authHosts: [String: [String]] = [
        "openrouter": ["openrouter.ai"],
        "codex": ["chatgpt.com", "auth.openai.com"],
        "devin": ["api.devin.ai", "server.codeium.com"],
    ]

    private func injectAuth(_ request: inout URLRequest, spec: String?) {
        guard let spec,
              let hosts = Harness.authHosts[spec],
              let host = request.url?.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return }
        if spec == "codex" {
            // Keys.get("codex") is the ChatGPT login blob —
            // {access_token, account_id, refresh_token}, or a whole pasted
            // ~/.codex/auth.json where they live under "tokens".
            guard let raw = Keys.get("codex"),
                  var creds = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            else { return }
            if let nested = creds["tokens"] as? [String: Any] { creds = nested }
            if let token = creds["access_token"] as? String {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let account = creds["account_id"] as? String {
                request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            return
        }
        guard let key = Keys.get(spec) else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func tool(_ body: [String: Any]) {
        guard let id = (body["id"] as? NSNumber)?.intValue,
              let name = body["name"] as? String else { return }
        var args = (body["args"] as? [String: Any]) ?? [:]
        // Consent never crosses this door: `granted` belongs to the grant
        // kind alone, so the key is stripped whatever the op — a model
        // writing `tab_attach {granted:true}` is reaching for a chip nobody
        // gave. And the grant op itself is not a tool the loop may name.
        args.removeValue(forKey: "granted")
        guard name != "tabs.grant" else {
            toolReply(id, ["error": "tabs.grant isn't a tool — a tab's chip in Ask is the only grant"])
            return
        }
        // ask.user never reaches Drive — it's the model asking the human,
        // parked here until the question card answers (resolveAsk).
        if name == "ask.user" { poseAsk(id, args); return }
        guard let drive = AskRuntime.drive else {
            toolReply(id, ["error": "driver not up"])
            return
        }
        drive.perform(name, args) { [weak self] result in
            var result = result
            // A screenshot the model can see: the file Drive wrote, inlined
            // as a data URL alongside its path.
            if name == "page.screenshot", let path = result["path"] as? String,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               !data.isEmpty, data.count < 8_000_000 {
                result["image"] = "data:image/png;base64," + data.base64EncodedString()
            }
            Task { @MainActor in self?.toolReply(id, result) }
        }
    }

    /// The model asking the human mid-turn (design/interaction.md §1): the
    /// tool promise just parks — the bridge is already async — while the
    /// question card goes up through Mind. One seat: a second ask while
    /// one is open is declined "busy", and no live chat means nobody is
    /// listening — declined "unavailable" rather than parked forever.
    private func poseAsk(_ id: Int, _ args: [String: Any]) {
        guard pendingAsk == nil else {
            toolReply(id, ["declined": "busy — another question is open"])
            return
        }
        guard let chat = activeChat else {
            toolReply(id, ["declined": "unavailable"])
            return
        }
        pendingAsk = id
        Mind.shared.pose(args["question"] as? String ?? "",
                         options: args["options"] as? [String] ?? [], in: chat)
    }

    /// The grant door. Only attachTabs in harness.js sends this kind — one
    /// per chip the user placed — and Drive performs `tabs.grant` as the
    /// app's own session, which is the single origin that op accepts. The
    /// model can never reach it: `tool` calls can't name the op and can't
    /// carry `granted`, and no wire speaks this kind at all.
    private func grant(_ body: [String: Any]) {
        guard let id = (body["id"] as? NSNumber)?.intValue,
              let tab = body["tab"] as? String else { return }
        guard let drive = AskRuntime.drive else {
            toolReply(id, ["error": "driver not up"])
            return
        }
        drive.perform("tabs.grant", ["id": tab], from: .app) { [weak self] result in
            Task { @MainActor in self?.toolReply(id, result) }
        }
    }

    private func toolReply(_ id: Int, _ result: [String: Any]) {
        tell("__h._tool(\(id), \(jsLiteral(result)));")
    }

    /// True when the event carries a turn stamp that isn't the live turn's
    /// — the trailing words of a killed run, dropped before they can write
    /// into whatever took its place. An unstamped event (an old harness.js)
    /// passes, as before.
    private func stale(_ data: [String: Any]) -> Bool {
        guard let stamp = lastRunTurn,
              let turn = (data["turn"] as? String).flatMap({ UUID(uuidString: $0) })
        else { return false }
        return turn != stamp
    }

    private func event(_ body: [String: Any]) {
        guard let name = body["name"] as? String,
              let data = body["data"] as? [String: Any],
              let chatID = data["chat"] as? String,
              let chat = UUID(uuidString: chatID) else { return }
        switch name {
        case "delta":
            guard !stale(data), let text = data["text"] as? String else { return }
            Mind.shared.hear(.delta(chat: chat, text: text))
        case "message":
            guard !stale(data),
                  let raw = data["message"],
                  let json = try? JSONSerialization.data(withJSONObject: raw),
                  let message = try? JSONDecoder().decode(AskMessage.self, from: json) else { return }
            Mind.shared.hear(.message(chat: chat, message))
        case "tool":
            guard !stale(data),
                  let raw = data["tool"],
                  let json = try? JSONSerialization.data(withJSONObject: raw),
                  let tool = try? JSONDecoder().decode(AskMessage.Tool.self, from: json) else { return }
            Mind.shared.hear(.tool(chat: chat, tool))
        case "activity":
            guard !stale(data) else { return }
            Mind.shared.hear(.activity(chat: chat, (data["text"] as? String) ?? ""))
        case "done":
            // A killed turn's trailing done is dropped whole, not just
            // barred from the flags: Mind.hear(.done) clears the chat's
            // question and parked approvals, which by then are the *new*
            // turn's — its ask_user would wait out a question nobody can
            // see, its cards would vanish while their finishes hang. The
            // live turn's own done bears the right stamp, and an
            // unstamped one (an old harness.js, a test) lands as ever.
            // Tearing a turn down needs nothing from this event: stop()
            // and run() clear pendingAsk and denyPending locally.
            guard !stale(data) else { return }
            if chat == activeChat {
                running = false
                activeChat = nil
                pendingAsk = nil
            }
            Mind.shared.hear(.done(chat: chat, error: data["error"] as? String))
        default:
            break
        }
    }

    /// A JS literal for an evaluateJavaScript call — JSON is a subset.
    /// nil is a quiet null; a value that can't be made JSON-safe warns —
    /// it lands in the page as null and would otherwise fail invisibly.
    private func jsLiteral<T>(_ value: T?) -> String {
        guard let value else { return "null" }
        if let string = value as? String {
            if let data = try? JSONEncoder().encode(string),
               let text = String(data: data, encoding: .utf8) { return text }
            NSLog("[harness] a string would not serialize for the page — sent null")
            return "null"
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) { return text }
        NSLog("[harness] a value would not serialize for the page — sent null: %@",
              String(String(describing: value).prefix(160)))
        return "null"
    }
}

extension Harness: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            switch body["kind"] as? String {
            case "fetch": fetch(body)
            case "abort": abort(body)
            case "tool": tool(body)
            case "grant": grant(body)
            case "event": event(body)
            case "log": NSLog("[harness] %@", (body["text"] as? String) ?? "")
            default: break
            }
        }
    }
}

extension Harness: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard webView === web else { return }
            loaded = true
            let pending = pendingJS
            pendingJS = []
            for item in pending { tell(item.js, onError: item.onError) }
            // If the script file was missing the page still "loaded" — say so
            // rather than leaving the turn spinning forever.
            webView.evaluateJavaScript("typeof __h") { result, _ in
                MainActor.assumeIsolated {
                    guard (result as? String) != "object" else { return }
                    NSLog("[harness] harness.js did not load — Runtime/ask/harness.js missing?")
                    if let chat = self.activeChat, self.running {
                        self.running = false
                        self.activeChat = nil
                        Mind.shared.hear(.done(chat: chat, error: "the agent script is missing"))
                    }
                }
            }
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard webView === web else { return }
            // The page and the turn in it are gone; the next run() boots a
            // fresh one lazily.
            web = nil
            loaded = false
            pendingJS = []
            for task in fetches.values { task.cancel() }
            fetches = [:]
            // The seats die with the page that was holding them.
            pendingAsk = nil
            (AskRuntime.drive as? Drive)?.denyPending(for: .app, reason: "the turn's host died")
            if running {
                running = false
                if let chat = activeChat {
                    activeChat = nil
                    Mind.shared.hear(.done(chat: chat, error: "the model host crashed — ask again"))
                }
            }
        }
    }
}

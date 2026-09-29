import Foundation

/// Test-only entry point for exercising the real app-origin Ask gate.
/// Every operation still passes through Drive.perform and its real page view.
@MainActor
enum GuardTesting {
    private static var results: [String: [String: Any]] = [:]
    private static var cancellations: [String: AgentCancellation] = [:]
    private static var cancellationOps: [String: String] = [:]

    static func handle(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "guard-test only works in a --test run"]); return }
        let action = request["action"] as? String ?? ""
        switch action {
        case "setup":
            Store.settings.set("ask", forKey: "settings.page")
            Mind.shared.newChat()
            Mind.shared.model = AskModel(provider: "echo", model: "echo")
            Mind.shared.setMode(.guard)
            Mind.shared.open = true
            Mind.shared.send("Mock guard test")
            answer(["mode": "guard", "model": "echo/echo"])

        case "start":
            guard let op = request["op"] as? String,
                  let args = request["args"] as? [String: Any],
                  let drive = AskRuntime.drive as? Drive
            else { answer(["error": "start needs op, args, and a running Drive"]); return }
            let id = UUID().uuidString
            results[id] = ["pending": true]
            if request["cancellable"] as? Bool == true {
                let cancellation = AgentCancellation()
                cancellations[id] = cancellation
                cancellationOps[id] = op
                drive.perform(op, args, from: .app, cancellation: cancellation) { result in
                    results[id] = result
                    cancellations[id] = nil
                    cancellationOps[id] = nil
                }
            } else {
                drive.perform(op, args, from: .app) { result in
                    results[id] = result
                }
            }
            answer(["id": id])

        case "result":
            guard let id = request["id"] as? String else { answer(["error": "result needs id"]); return }
            answer(results[id] ?? ["error": "unknown request"])

        case "cancel":
            guard let id = request["id"] as? String, let cancellation = cancellations[id] else {
                answer(["error": "cancel needs a cancellable request id"]); return
            }
            let op = cancellationOps[id]
            cancellation.cancel()
            for approval in Mind.shared.pendingApprovals where approval.op == op {
                Mind.shared.resolve(approval, .deny)
            }
            answer(["cancelled": id])

        case "pending":
            answer(["approvals": Mind.shared.pendingApprovals.map { approval in
                ["id": approval.id.uuidString, "op": approval.op,
                 "summary": approval.summary, "host": approval.host ?? "",
                 "shotPath": approval.shotPath ?? "", "details": approval.details ?? "",
                 "categories": (approval.categories ?? []).map(\.rawValue).joined(separator: ",")]
            }])

        case "resolve":
            guard let id = request["id"] as? String,
                  let uuid = UUID(uuidString: id),
                  let approval = Mind.shared.pendingApprovals.first(where: { $0.id == uuid }),
                  let verdict = (request["verdict"] as? String).flatMap(ApprovalVerdict.init(rawValue:))
            else { answer(["error": "resolve needs a pending approval id and allow|deny|always"]); return }
            Mind.shared.resolve(approval, verdict)
            answer(["resolved": id, "verdict": verdict.rawValue])

        case "refresh":
            guard let id = (request["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                answer(["error": "refresh needs id"]); return
            }
            (AskRuntime.drive as? Drive)?.refreshApproval(id)
            answer(["ok": true])

        case "setting":
            guard let name = request["category"] as? String,
                  let category = GuardCategory.allCases.first(where: { $0.rawValue == name }),
                  let enabled = request["enabled"] as? Bool
            else { answer(["error": "setting needs a guard category and enabled boolean"]); return }
            Store.settings.set(enabled, forKey: category.settingsKey)
            answer(["category": name, "enabled": enabled])

        default:
            answer(["error": "unknown guard-test action"])
        }
    }
}

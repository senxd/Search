import Foundation

// Run: swiftc Sources/Search/AgentRequests.swift sdk/test_agent_requests.swift -o /tmp/search-request-check && /tmp/search-request-check
@main
struct RequestCheck {
    @MainActor
    static func main() {
        let requests = AgentRequests()
        assert(AgentRequests.key(true) == nil)
        assert(AgentRequests.key(NSNull()) == nil)
        assert(AgentRequests.key(1) == AgentRequests.key(1.0))
        assert(AgentRequests.key(1) != AgentRequests.key("1"))
        let receipt = requests.begin(id: 1, op: "page.js").0!
        assert(requests.begin(id: 1.0, op: "page.js").1 == "DUPLICATE_REQUEST_ID")
        receipt.answered = true
        receipt.timedOut = true
        var cancellations = 0
        receipt.cancellation.onCancel = { cancellations += 1 }
        receipt.cancellation.cancel()
        receipt.cancellation.cancel()
        assert(cancellations == 1)
        assert(receipt.state == "running" && receipt.outcome == "unknown")
        requests.finish(receipt, reply: ["ok": true])
        assert(receipt.state == "finished" && receipt.outcome == "succeeded")
        requests.finish(receipt, reply: ["error": "second callback"])
        assert(receipt.outcome == "succeeded")
        for id in 2...65 { assert(requests.begin(id: id, op: "page.js").0 != nil) }
        assert(requests.begin(id: 66, op: "page.js").1 == "TOO_MANY_REQUESTS")
        let control = requests.begin(id: 66, op: "request.cancel", control: true).0!
        requests.finish(control, reply: ["ok": true])
        requests.cancelAll()
        assert(requests.lookup(2)!.cancellation.isCancelled)
        for id in 2...65 {
            requests.finish(requests.lookup(id)!, reply: ["error": "stopped", "code": "CANCELLED", "typedCount": 3])
        }
        assert(requests.lookup(2)!.outcome == "cancelled")
        assert(requests.lookup(2)!.json["typedCount"] as? Int == 3)
        assert(requests.lookup(2)!.json["error"] == nil)
        assert(requests.lookup(2)!.json["errorMessage"] as? String == "stopped")
        let guardCancelled = requests.begin(id: 67, op: "act.type").0!
        requests.finish(guardCancelled, reply: ["error": "Action cancelled", "code": "GUARD_CANCELLED"])
        assert(guardCancelled.outcome == "cancelled")
        let failed = requests.begin(id: 68, op: "page.code").0!
        requests.finish(failed, reply: ["error": "script failed", "code": "SCRIPT_ERROR"])
        assert(failed.outcome == "failed")
        for id in 69...400 {
            let next = requests.begin(id: id, op: "ping").0!
            requests.finish(next, reply: ["pong": true])
        }
        assert(requests.lookup(1) == nil)
        assert(requests.lookup(400)!.outcome == "succeeded")
        let unknown = requests.begin(id: 401, op: "inspector.send").0!
        requests.finish(unknown, reply: ["error": "watchdog expired", "outcome": "unknown"])
        assert(unknown.state == "finished" && unknown.outcome == "unknown")
        print("request lifecycle checks passed")
    }
}

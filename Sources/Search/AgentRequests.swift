import Foundation

@MainActor
final class AgentCancellation {
    private(set) var isCancelled = false
    var onCancel: (() -> Void)?
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let notify = onCancel
        onCancel = nil
        notify?()
    }
}

/// Session-local receipts retain metadata, never page results or screenshots.
@MainActor
final class AgentRequests {
    @MainActor
    final class Receipt {
        let id: Any
        let op: String
        let cancellation = AgentCancellation()
        var state = "running"
        var outcome = "unknown"
        var answered = false
        var timedOut = false
        var timer: DispatchSourceTimer?
        var code: String?
        var error: String?
        var typedCount: Int?
        init(id: Any, op: String) { self.id = id; self.op = op }
        var json: [String: Any] {
            var result: [String: Any] = ["requestId": id, "op": op, "state": state, "outcome": outcome,
                                        "cancelRequested": cancellation.isCancelled, "timedOut": timedOut]
            if let code { result["code"] = code }
            if let error { result["errorMessage"] = error }
            if let typedCount { result["typedCount"] = typedCount }
            return result
        }
    }

    static let pendingLimit = 64
    static let historyLimit = 256
    private var receipts: [String: Receipt] = [:]
    private var terminal: [String] = []
    private var pending = 0

    static func key(_ id: Any?) -> String? {
        if let id = id as? String, !id.isEmpty, id.utf8.count <= 128 { return "s:" + id }
        if let id = id as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
           id.doubleValue.isFinite, abs(id.doubleValue) <= 9_007_199_254_740_991,
           id.doubleValue.rounded() == id.doubleValue { return "n:" + String(Int64(id.doubleValue)) }
        return nil
    }

    func begin(id: Any, op: String, control: Bool = false) -> (Receipt?, String?) {
        guard let key = Self.key(id) else { return (nil, "INVALID_REQUEST_ID") }
        guard op.utf8.count <= 128 else { return (nil, "INVALID_OP") }
        guard receipts[key] == nil else { return (nil, "DUPLICATE_REQUEST_ID") }
        guard control || pending < Self.pendingLimit else { return (nil, "TOO_MANY_REQUESTS") }
        let receipt = Receipt(id: id, op: op)
        receipts[key] = receipt
        pending += 1
        return (receipt, nil)
    }

    func lookup(_ id: Any?) -> Receipt? {
        guard let key = Self.key(id) else { return nil }
        return receipts[key]
    }

    func finish(_ receipt: Receipt, reply: [String: Any]) {
        guard receipt.state == "running", let key = Self.key(receipt.id) else { return }
        receipt.timer?.setEventHandler {}
        receipt.timer?.cancel()
        receipt.timer = nil
        receipt.state = "finished"
        receipt.code = (reply["code"] as? String).map { String($0.prefix(128)) }
        receipt.error = (reply["error"] as? String).map { String($0.prefix(512)) }
        receipt.typedCount = reply["typedCount"] as? Int
        receipt.outcome = reply["outcome"] as? String == "unknown" ? "unknown"
            : reply["code"] as? String == "CANCELLED" ? "cancelled"
            : reply["error"] == nil ? "succeeded" : "failed"
        pending -= 1
        terminal.append(key)
        if terminal.count > Self.historyLimit {
            receipts.removeValue(forKey: terminal.removeFirst())
        }
    }

    func cancelAll() {
        for receipt in receipts.values where receipt.state == "running" { receipt.cancellation.cancel() }
    }
}

import Foundation
import GRDB

/// One agent_actions row — a write-tool proposal the assistant made. Go owns
/// every status transition (`watchtower actions …`); the Desktop only reads
/// and observes. Mirrors `internal/db/agent_actions.go`.
package struct AgentAction: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let tool: String
    package let external: Bool
    package let argsJSON: String
    package let reason: String
    package let surface: String
    package let conversationID: Int64
    package let contextType: String
    package let contextID: String
    package let turnID: String
    package let status: String
    package let trustAtCreate: String
    package let resultJSON: String
    package let error: String
    package let createdAt: String
    package let decidedAt: String
    package let appliedAt: String

    package init(row: Row) {
        id = row["id"]
        tool = row["tool"]
        external = row["external"] ?? false
        argsJSON = row["args_json"] ?? ""
        reason = row["reason"] ?? ""
        surface = row["surface"] ?? ""
        conversationID = row["conversation_id"] ?? 0
        contextType = row["context_type"] ?? ""
        contextID = row["context_id"] ?? ""
        turnID = row["turn_id"] ?? ""
        status = row["status"] ?? "pending"
        trustAtCreate = row["trust_at_create"] ?? "ask"
        resultJSON = row["result_json"] ?? ""
        error = row["error"] ?? ""
        createdAt = row["created_at"] ?? ""
        decidedAt = row["decided_at"] ?? ""
        appliedAt = row["applied_at"] ?? ""
    }

    package var isPending: Bool { status == "pending" }
    package var isTerminal: Bool { status == "applied" || status == "rejected" }
    /// `Registry.Apply`'s claim: the tool is running right now, in some other
    /// process. Nothing on the card may act on the row while it holds.
    package var isExecuting: Bool { status == "executing" }
    /// `Registry.Apply` accepts `approved` as well as `failed`, so an approve
    /// whose CLI process died before the claim is retriable, not a dead end.
    package var canRetry: Bool { status == "failed" || status == "approved" }

    /// Decodes `argsJSON` — which for `edit_confluence_page` holds the whole
    /// new page storage (up to 4 MiB) — on every access: never call it from a
    /// view's `body` path without a memo. `argsDecodes` counts the decodes
    /// (the test seam proving a render does not re-decode).
    package var args: [String: Any] {
        Self.argsDecodes.increment()
        return Self.object(argsJSON)
    }

    package static let argsDecodes = DecodeCounter()
    package var result: [String: Any] { Self.object(resultJSON) }

    package func argString(_ key: String) -> String? { Self.stringValue(args[key]) }
    package func resultString(_ key: String) -> String? { Self.stringValue(result[key]) }

    private static func object(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.compactMap { stringValue($0) }.joined(separator: ", ")
        default: return nil
        }
    }
}

/// A thread-safe counter (a test seam for work a view must not repeat).
package final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    package init() {}

    package func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    package var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

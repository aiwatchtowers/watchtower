import Foundation

/// One agent action — a write-tool proposal the assistant made — as both devices' approval card reads it (ask #1409).
/// Go owns every status transition (`watchtower actions …` on the Mac, the hub's `chat_action_answer` on the phone);
/// the card only reads. The Mac builds it from the whole `agent_actions` row (`WatchtowerCore`'s `init(row:)`,
/// mirroring `internal/db/agent_actions.go`); the phone, and a Mac card whose row is not loaded yet, from the
/// `approval` part payload (`init(payload:)`).
public struct ChatAgentAction: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let tool: String
    public let external: Bool
    /// The stored args on the Mac; on the phone the payload's display text (indented, clipped past 4000 characters).
    public let argsJSON: String
    /// The digest the phone pins on approve (Go `tools.ArgsSHA256` over the stored bytes). "" on a Mac row:
    /// `AgentActionFeed` hashes `argsJSON` at approve time (AGENT-07).
    public let argsSHA256: String
    /// False: `args_display` was clipped; editors and the Confluence diff are off.
    public let argsComplete: Bool
    public let reason: String
    public let surface: String
    public let conversationID: Int64
    public let contextType: String
    public let contextID: String
    public let turnID: String
    public let status: String
    public let trustAtCreate: String
    public let resultJSON: String
    public let error: String
    public let createdAt: String
    public let decidedAt: String
    public let appliedAt: String
    /// When the owner dismissed a session call whose outcome is unknown
    /// (`ConnectorCallProposal.awaitsDismissal`); "" = not dismissed.
    public let dismissedAt: String

    public init(
        id: Int64,
        tool: String,
        external: Bool = false,
        argsJSON: String = "",
        argsSHA256: String = "",
        argsComplete: Bool = true,
        reason: String = "",
        surface: String = "",
        conversationID: Int64 = 0,
        contextType: String = "",
        contextID: String = "",
        turnID: String = "",
        status: String = "pending",
        trustAtCreate: String = "ask",
        resultJSON: String = "",
        error: String = "",
        createdAt: String = "",
        decidedAt: String = "",
        appliedAt: String = "",
        dismissedAt: String = ""
    ) {
        self.id = id
        self.tool = tool
        self.external = external
        self.argsJSON = argsJSON
        self.argsSHA256 = argsSHA256
        self.argsComplete = argsComplete
        self.reason = reason
        self.surface = surface
        self.conversationID = conversationID
        self.contextType = contextType
        self.contextID = contextID
        self.turnID = turnID
        self.status = status
        self.trustAtCreate = trustAtCreate
        self.resultJSON = resultJSON
        self.error = error
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.appliedAt = appliedAt
        self.dismissedAt = dismissedAt
    }

    /// The phone, and a Mac card whose row is not loaded yet: what the payload carries. The row columns it does not
    /// carry (surface, context, trust, times) stay at their defaults; the result keeps only the card's keys.
    public init(payload: ChatApprovalPayload) {
        self.init(
            id: payload.id,
            tool: payload.tool,
            external: payload.external,
            argsJSON: payload.argsDisplay,
            argsSHA256: payload.argsSHA256,
            argsComplete: payload.argsComplete,
            reason: payload.reason ?? "",
            turnID: payload.turnID,
            status: payload.status,
            resultJSON: Self.json(payload.result),
            error: payload.error
        )
    }

    public var isPending: Bool { status == "pending" }
    public var isTerminal: Bool { status == "applied" || status == "rejected" }
    /// `Registry.Apply`'s claim: the tool is running right now, in some other
    /// process. Nothing on the card may act on the row while it holds.
    public var isExecuting: Bool { status == "executing" }
    /// `Registry.Apply` accepts `approved` as well as `failed`, so an approve
    /// whose CLI process died before the claim is retriable, not a dead end —
    /// except a session-applied call, which Apply refuses outright (only the
    /// chat session that proposed it runs it).
    public var canRetry: Bool { !isSessionApplied && (status == "failed" || status == "approved") }
    /// Go `Tool.AppliedBySession`: approve stops at `approved`, `actions
    /// apply` is refused, and once failed it waits on nobody — except an
    /// unknown outcome, which waits for the owner's Dismiss
    /// (`ConnectorCallProposal.awaitsDismissal`, `AgentActionQueries`).
    public var isSessionApplied: Bool { tool == ConnectorCallProposal.tool }

    /// Decodes `argsJSON` — which for `edit_confluence_page` holds the whole
    /// new page storage (up to 4 MiB) — on every access: never call it from a
    /// view's `body` path without a memo. `argsDecodes` counts the decodes
    /// (the test seam proving a render does not re-decode).
    public var args: [String: Any] {
        Self.argsDecodes.increment()
        return Self.object(argsJSON)
    }

    public static let argsDecodes = DecodeCounter()
    public var result: [String: Any] { Self.object(resultJSON) }

    public func argString(_ key: String) -> String? { Self.stringValue(args[key]) }
    public func resultString(_ key: String) -> String? { Self.stringValue(result[key]) }

    private static func object(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// The payload's result as stored JSON text; "" when empty.
    private static func json(_ result: [String: String]) -> String {
        guard !result.isEmpty, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A decoded args/result value as display text (numbers and string
    /// arrays included), for a caller holding an already-decoded `args`.
    public static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.compactMap { stringValue($0) }.joined(separator: ", ")
        default: return nil
        }
    }
}

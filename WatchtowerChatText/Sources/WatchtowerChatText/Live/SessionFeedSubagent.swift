import Foundation

/// A subagent marker of `watchtower workbench session-feed --json` (Go
/// `sessionfeed.SubagentRef`): the Agent call, its subagent and its status.
public struct SessionFeedSubagent: Decodable, Hashable, Sendable {
    public var toolUseID: String
    public var agentID: String
    public var type: String
    public var description: String
    /// "running", "finished" or "unknown".
    public var status: String
    /// When the Agent call started; only the feed's `subagents` list carries
    /// it (`started_at`). nil when absent or Go's zero time.
    public var startedAt: Date?

    public init(
        toolUseID: String,
        agentID: String = "",
        type: String = "",
        description: String = "",
        status: String = "unknown",
        startedAt: Date? = nil
    ) {
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.type = type
        self.description = description
        self.status = status
        self.startedAt = startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FeedWireKey.self)
        toolUseID = try c.wire(String.self, "tool_use_id") ?? ""
        agentID = try c.wire(String.self, "agent_id") ?? ""
        type = try c.wire(String.self, "type") ?? ""
        description = try c.wire(String.self, "description") ?? ""
        status = try c.wire(String.self, "status") ?? "unknown"
        startedAt = try c.wireDate("started_at")
    }
}

import Foundation

/// A subagent marker of `watchtower workbench session-feed --json` (Go
/// `sessionfeed.SubagentRef`): the Agent call, its subagent and its status.
public struct SessionFeedSubagent: Decodable, Equatable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case toolUseID = "tool_use_id"
        case agentID = "agent_id"
        case startedAt = "started_at"
        case type, description, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID) ?? ""
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        startedAt = SessionFeedDate.parse(try c.decodeIfPresent(String.self, forKey: .startedAt))
    }
}

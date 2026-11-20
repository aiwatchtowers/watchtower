import Foundation

/// The agent's current step from `session-feed --json` (`activity`): the tool
/// call that has started and not returned. Never an entry and never stored in
/// the history; the live line shows it.
public struct SessionFeedActivity: Decodable, Equatable, Sendable {
    public var tool: String
    public var summary: String
    public var startedAt: Date?
    /// Other calls running beside this one.
    public var more: Int

    public init(tool: String, summary: String, startedAt: Date? = nil, more: Int = 0) {
        self.tool = tool
        self.summary = summary
        self.startedAt = startedAt
        self.more = more
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FeedWireKey.self)
        tool = try c.wire(String.self, "tool") ?? ""
        summary = try c.wire(String.self, "summary") ?? ""
        startedAt = try c.wireDate("started_at")
        more = try c.wire(Int.self, "more") ?? 0
    }
}

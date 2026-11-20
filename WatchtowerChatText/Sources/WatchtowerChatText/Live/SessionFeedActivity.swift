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

    private enum CodingKeys: String, CodingKey {
        case tool, summary, more
        case startedAt = "started_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        startedAt = SessionFeedDate.parse(try c.decodeIfPresent(String.self, forKey: .startedAt))
        more = try c.decodeIfPresent(Int.self, forKey: .more) ?? 0
    }
}

import Foundation

/// The agent's current step from `session-feed --json` (`activity`): the tool
/// call that has started and not returned. Never an entry and never stored in
/// the history; the live line shows it.
package struct SessionFeedActivity: Decodable, Equatable, Sendable {
    package var tool: String
    package var summary: String
    package var startedAt: Date?
    /// Other calls running beside this one.
    package var more: Int

    package init(tool: String, summary: String, startedAt: Date? = nil, more: Int = 0) {
        self.tool = tool
        self.summary = summary
        self.startedAt = startedAt
        self.more = more
    }

    private enum CodingKeys: String, CodingKey {
        case tool, summary, more
        case startedAt = "started_at"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        startedAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .startedAt))
        more = try c.decodeIfPresent(Int.self, forKey: .more) ?? 0
    }
}

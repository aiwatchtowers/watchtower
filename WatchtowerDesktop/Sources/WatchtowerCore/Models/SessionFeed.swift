import Foundation

/// `watchtower workbench session-feed --json`: the dialog of one Claude Code
/// session, built by Go (`internal/sessionfeed`) without AI. The Desktop only
/// decodes and shows it. An unknown `kind` decodes as-is so a newer CLI never
/// breaks an older app; the store hides kinds it does not know.
package struct SessionFeedSubagent: Decodable, Equatable, Sendable {
    package var toolUseID: String
    package var agentID: String
    package var type: String
    package var description: String
    /// "running", "finished" or "unknown".
    package var status: String
    /// When the Agent call started; only the feed's `subagents` list carries
    /// it (`started_at`). nil when absent or Go's zero time.
    package var startedAt: Date?

    package init(
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

    /// The status of `subagent` in the feed's current markers (a read
    /// updates a marker in place); the copy itself when no marker has it —
    /// a copy kept since it was opened would never see it finish.
    package static func currentStatus(of subagent: Self, in entries: [SessionFeedEntry]) -> String {
        entries.last { $0.subagent?.toolUseID == subagent.toolUseID }?.subagent?.status ?? subagent.status
    }

    private enum CodingKeys: String, CodingKey {
        case toolUseID = "tool_use_id"
        case agentID = "agent_id"
        case startedAt = "started_at"
        case type, description, status
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID) ?? ""
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        startedAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .startedAt))
    }
}

package struct SessionFeedEntry: Decodable, Identifiable, Equatable, Sendable {
    /// Kinds this app renders; anything else is forward-compatible noise.
    package static let knownKinds: Set<String> = [
        "owner", "agent", "ask_answer", "watchtower", "brief", "subagent", "separator", "event"
    ]
    /// Kinds the phone slice carries (FEED-02); `event` is Desktop only.
    package static let phoneKinds: Set<String> = [
        "owner", "agent", "ask_answer", "watchtower", "brief", "subagent", "separator"
    ]

    package var id: String
    package var kind: String
    /// nil for Go's zero time (a separator or a meta-only subagent marker).
    package var at: Date?
    package var text: String
    package var conversation: String
    package var askID: Int64?
    package var title: String?
    package var via: String?
    /// "task" or "teammate" on an `event` entry.
    package var eventType: String?
    package var subagent: SessionFeedSubagent?

    package init(
        id: String,
        kind: String,
        at: Date? = nil,
        text: String = "",
        conversation: String = "",
        askID: Int64? = nil,
        title: String? = nil,
        via: String? = nil,
        eventType: String? = nil,
        subagent: SessionFeedSubagent? = nil
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.text = text
        self.conversation = conversation
        self.askID = askID
        self.title = title
        self.via = via
        self.eventType = eventType
        self.subagent = subagent
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, at, text, conversation, title, via, subagent
        case askID = "ask_id"
        case eventType = "event_type"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        at = Self.parseDate(try c.decodeIfPresent(String.self, forKey: .at))
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation) ?? ""
        askID = try c.decodeIfPresent(Int64.self, forKey: .askID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        via = try c.decodeIfPresent(String.self, forKey: .via)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        subagent = try c.decodeIfPresent(SessionFeedSubagent.self, forKey: .subagent)
    }

    /// RFC 3339 with or without fractional seconds; Go's zero time and
    /// anything unparsable mean "no time". The formatters are made once: a
    /// formatter per date cost most of a large feed's decode (#2065).
    package static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("0001-01-01") else { return nil }
        return fractionalDate.date(from: s) ?? plainDate.date(from: s)
    }

    private static let plainDate = ISO8601DateFormatter()
    private static let fractionalDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

package struct SessionFeedPayload: Decodable, Sendable {
    package var sessionID: Int64
    /// "" when nothing was read yet: the next refresh is a full read.
    package var cursor: String
    package var entries: [SessionFeedEntry]
    /// Current state of the subagent markers (status changes after the marker
    /// was first emitted).
    package var subagents: [SessionFeedEntry]
    /// The agent's open tool call; nil = none (or an older CLI).
    package var activity: SessionFeedActivity?
    package var live: SessionFeedLive?
    package var liveOK: Bool
    package var liveError: String?
    /// A `--tail` read's page start: the id to pass as `--before` for the
    /// page before it; "" when absent (nothing earlier, or not a tail read).
    package var before: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cursor, entries, subagents, activity, live, before
        case liveOK = "live_ok", liveError = "live_error"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decodeIfPresent(Int64.self, forKey: .sessionID) ?? 0
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        entries = try c.decodeIfPresent([SessionFeedEntry].self, forKey: .entries) ?? []
        subagents = try c.decodeIfPresent([SessionFeedEntry].self, forKey: .subagents) ?? []
        activity = try c.decodeIfPresent(SessionFeedActivity.self, forKey: .activity)
        live = try c.decodeIfPresent(SessionFeedLive.self, forKey: .live)
        liveOK = try c.decodeIfPresent(Bool.self, forKey: .liveOK) ?? false
        liveError = try c.decodeIfPresent(String.self, forKey: .liveError)
        before = try c.decodeIfPresent(String.self, forKey: .before) ?? ""
    }
}

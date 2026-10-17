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

    package init(toolUseID: String, agentID: String = "", type: String = "", description: String = "", status: String = "unknown") {
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.type = type
        self.description = description
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case toolUseID = "tool_use_id"
        case agentID = "agent_id"
        case type, description, status
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID) ?? ""
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    }
}

package struct SessionFeedEntry: Decodable, Identifiable, Equatable, Sendable {
    /// Kinds this app renders; anything else is forward-compatible noise.
    package static let knownKinds: Set<String> = [
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
        self.subagent = subagent
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, at, text, conversation, title, via, subagent
        case askID = "ask_id"
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
        subagent = try c.decodeIfPresent(SessionFeedSubagent.self, forKey: .subagent)
    }

    /// RFC 3339 with or without fractional seconds; Go's zero time and
    /// anything unparsable mean "no time".
    private static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("0001-01-01") else { return nil }
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s)
    }
}

package struct SessionFeedPayload: Decodable, Sendable {
    package var sessionID: Int64
    /// "" when nothing was read yet: the next refresh is a full read.
    package var cursor: String
    package var entries: [SessionFeedEntry]
    /// Current state of the subagent markers (status changes after the marker
    /// was first emitted).
    package var subagents: [SessionFeedEntry]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cursor, entries, subagents
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decodeIfPresent(Int64.self, forKey: .sessionID) ?? 0
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        entries = try c.decodeIfPresent([SessionFeedEntry].self, forKey: .entries) ?? []
        subagents = try c.decodeIfPresent([SessionFeedEntry].self, forKey: .subagents) ?? []
    }
}

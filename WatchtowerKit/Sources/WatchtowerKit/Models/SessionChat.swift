import Foundation
import WatchtowerSync

/// The `session_chat` slice, record name `session_chat-<session id>` for the
/// main feed and `session_chat-<session id>-<agent id>` for a subagent: the
/// dialog of a workbench session (owner, agent text, ask answers, Watchtower
/// lines), newest 300 entries, oldest first. Written only while a phone
/// watches it.
public struct SessionChat: SliceMirror, Equatable {
    public static let sliceKind = SliceKind.sessionChat

    public struct Entry: Hashable, Sendable, Decodable, Identifiable {
        /// rawValues are wire format; a kind added by a newer Mac decodes as
        /// an unknown value.
        public struct Kind: OpenWireValue {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }

            public static let owner = Self(rawValue: "owner")
            public static let agent = Self(rawValue: "agent")
            public static let askAnswer = Self(rawValue: "ask_answer")
            public static let watchtower = Self(rawValue: "watchtower")
            public static let brief = Self(rawValue: "brief")
            public static let subagent = Self(rawValue: "subagent")
            public static let separator = Self(rawValue: "separator")
            public static let knownValues: [Self] = [
                .owner, .agent, .askAnswer, .watchtower, .brief, .subagent, .separator
            ]
        }

        public struct Subagent: Hashable, Sendable, Decodable {
            public let agentID: String
            /// The CLI's `--subagent` selector; `agentID` only names the record.
            public let toolUseID: String
            public let type: String
            /// Cap 200.
            public let description: String
            public let status: String

            public init(agentID: String, toolUseID: String = "", type: String, description: String, status: String) {
                self.agentID = agentID
                self.toolUseID = toolUseID
                self.type = type
                self.description = description
                self.status = status
            }

            // convertFromSnakeCase maps "agent_id" -> "agentId".
            enum CodingKeys: String, CodingKey {
                case agentID = "agentId"
                case toolUseID = "toolUseId"
                case type, description, status
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                agentID = try c.decode(String.self, forKey: .agentID)
                toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID) ?? ""
                type = try c.decode(String.self, forKey: .type)
                description = try c.decode(String.self, forKey: .description)
                status = try c.decode(String.self, forKey: .status)
            }
        }

        public let id: String
        public let kind: Kind
        public let at: Date?
        /// Cap 4000.
        public let text: String
        public let textClipped: Bool
        /// The ask an `ask_answer` entry belongs to.
        public let askID: Int64?
        /// Cap 200.
        public let title: String?
        public let via: String?
        public let subagent: Subagent?

        public init(
            id: String,
            kind: Kind,
            at: Date? = nil,
            text: String,
            textClipped: Bool = false,
            askID: Int64? = nil,
            title: String? = nil,
            via: String? = nil,
            subagent: Subagent? = nil
        ) {
            self.id = id
            self.kind = kind
            self.at = at
            self.text = text
            self.textClipped = textClipped
            self.askID = askID
            self.title = title
            self.via = via
            self.subagent = subagent
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            at = try c.decodeIfPresent(Date.self, forKey: .at)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            textClipped = try c.decodeIfPresent(Bool.self, forKey: .textClipped) ?? false
            askID = try c.decodeIfPresent(Int64.self, forKey: .askID)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            via = try c.decodeIfPresent(String.self, forKey: .via)
            subagent = try c.decodeIfPresent(Subagent.self, forKey: .subagent)
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, at, text, textClipped
            case askID = "askId"
            case title, via, subagent
        }
    }

    public let sessionID: Int64
    /// nil for the main feed.
    public let agentID: String?
    /// The session is still running; the Mac refreshes a live chat every 10 s.
    public let live: Bool
    /// Older entries cut by the 300-entry and byte caps.
    public let entriesMore: Int
    /// Oldest first.
    public let entries: [Entry]

    public init(
        sessionID: Int64,
        agentID: String? = nil,
        live: Bool,
        entriesMore: Int = 0,
        entries: [Entry]
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.live = live
        self.entriesMore = entriesMore
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(Int64.self, forKey: .sessionID)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        entriesMore = try c.decodeIfPresent(Int.self, forKey: .entriesMore) ?? 0
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    // convertFromSnakeCase maps "session_id" -> "sessionId" (lowercase d).
    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case agentID = "agentId"
        case live, entriesMore, entries
    }

    /// `session_chat-<session id>` or `session_chat-<session id>-<agent id>`.
    public static func recordName(sessionID: Int64, agentID: String?) -> String {
        let id = agentID.map { "\(sessionID)-\($0)" } ?? "\(sessionID)"
        return SliceKind.sessionChat.recordName(id: id)
    }
}

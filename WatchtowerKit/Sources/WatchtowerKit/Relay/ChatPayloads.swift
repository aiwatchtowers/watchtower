import Foundation

/// What a chat thread is ABOUT, when it is bound to one entity rather than
/// being the generic secretary chat: the mobile mirror of the desktop's
/// `chat_conversations.context_type`/`context_id` pair.
///
/// A bound thread and its desktop counterpart are ONE conversation — the relay
/// resolves this context to the desktop's existing row, reuses its CLI session,
/// and writes both sides' turns into it.
public struct ChatContext: Codable, Equatable, Sendable {
    /// `chat_conversations.context_type`. Today the phone only ever sends
    /// "situation"; the field is the type, not an enum, so a desktop that
    /// learns new context kinds needs no wire change here.
    public let type: String
    /// `chat_conversations.context_id` — the entity id as a string.
    public let id: String

    public static func situation(_ situationID: Int) -> ChatContext {
        ChatContext(type: "situation", id: String(situationID))
    }

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

/// One user turn sent from mobile to the desktop agent.
public struct ChatMessagePayload: Codable, Equatable {
    public let id: String
    public let sessionID: String
    public let text: String
    public let createdAt: Date
    /// Set when the turn belongs to an entity-bound thread (a situation's
    /// Discuss chat); nil for the generic secretary chat.
    ///
    /// Optional for the same reason as `ChatChunkPayload.isError`: nil encodes
    /// to an absent key (synthesized encodeIfPresent) and pre-context records
    /// decode to nil, so old and new desktops/phones interoperate without a
    /// wire change — a context-less payload takes the desktop's generic path
    /// exactly as before.
    public let context: ChatContext?

    public var recordName: String { "chatmsg-\(id)" }

    // convertFromSnakeCase maps "session_id" -> "sessionId" (lowercase d),
    // so the CodingKey stringValue must be "sessionId" to round-trip correctly.
    // "context" is a single lowercase word — its default stringValue survives
    // both key strategies untouched, and ChatContext's own keys ("type"/"id")
    // are likewise single words.
    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case text
        case createdAt
        case context
    }

    public init(
        id: String,
        sessionID: String,
        text: String,
        createdAt: Date,
        context: ChatContext? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.createdAt = createdAt
        self.context = context
    }
}

/// Monotonic response chunks (pseudo-streaming). Chunks are append-only
/// records — never rewritten — so they cannot conflict.
public struct ChatChunkPayload: Codable, Equatable {
    public let sessionID: String
    public let messageID: String
    public let seq: Int
    public let text: String
    public let done: Bool
    /// Set on error-path final chunks (stream failure, watchdog timeout).
    /// Optional so pre-flag records decode to nil and nil encodes to an
    /// absent key (synthesized encodeIfPresent) — old and new versions
    /// interoperate without a wire change.
    public let isError: Bool? // swiftlint:disable:this discouraged_optional_boolean

    public var recordName: String { "chatchunk-\(messageID)-\(seq)" }

    // convertFromSnakeCase maps "session_id" -> "sessionId" and
    // "message_id" -> "messageId" (lowercase d), so CodingKey stringValues
    // must use the lowercase-d form to match. "isError" needs no explicit
    // rawValue: the default stringValue is already the camelCase form the
    // decoder produces from "is_error" (and the encoder snake_cases it back).
    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case messageID = "messageId"
        case seq
        case text
        case done
        case isError
    }

    // swiftlint:disable:next discouraged_optional_boolean
    public init(sessionID: String, messageID: String, seq: Int, text: String, done: Bool, isError: Bool? = nil) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.seq = seq
        self.text = text
        self.done = done
        self.isError = isError
    }
}

/// Desktop liveness marker, refreshed every 5 minutes (spec Section 2).
public struct HeartbeatPayload: Codable, Equatable {
    public static let recordName = "heartbeat"

    public let updatedAt: Date
    public let appVersion: String

    public init(updatedAt: Date, appVersion: String) {
        self.updatedAt = updatedAt
        self.appVersion = appVersion
    }
}

import Foundation

/// One user turn sent from mobile to the desktop agent.
public struct ChatMessagePayload: Codable, Equatable {
    public let id: String
    public let sessionID: String
    public let text: String
    public let createdAt: Date

    public var recordName: String { "chatmsg-\(id)" }

    // convertFromSnakeCase maps "session_id" -> "sessionId" (lowercase d),
    // so the CodingKey stringValue must be "sessionId" to round-trip correctly.
    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case text
        case createdAt
    }

    public init(id: String, sessionID: String, text: String, createdAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.createdAt = createdAt
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

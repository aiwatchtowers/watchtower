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

    public var recordName: String { "chatchunk-\(messageID)-\(seq)" }

    // convertFromSnakeCase maps "session_id" -> "sessionId" and
    // "message_id" -> "messageId" (lowercase d), so CodingKey stringValues
    // must use the lowercase-d form to match.
    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case messageID = "messageId"
        case seq
        case text
        case done
    }

    public init(sessionID: String, messageID: String, seq: Int, text: String, done: Bool) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.seq = seq
        self.text = text
        self.done = done
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

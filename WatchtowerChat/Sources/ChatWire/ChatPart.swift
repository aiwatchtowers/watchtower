import Foundation

/// One typed piece of a message (unified chat spec §5.3): its kind, the kind's payload and the fallback a client
/// that cannot draw the kind shows instead. The engine builds every part that does not live in the answer text
/// (Go `chatengine/parts.go`); `artifact` and `question` are client-derived — split out of the `text` part by
/// WatchtowerChatText, never sent. `payload` is nil when the client did not list the kind in its hello (D15).
public struct ChatPart: Hashable, Sendable, Decodable {
    public let kind: String
    public let payload: ChatJSONValue?
    public let fallback: ChatPartFallback

    public init(kind: String, payload: ChatJSONValue?, fallback: ChatPartFallback) {
        self.kind = kind
        self.payload = payload
        self.fallback = fallback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        payload = try c.decodeIfPresent(ChatJSONValue.self, forKey: .payload)
        fallback = try c.decodeIfPresent(ChatPartFallback.self, forKey: .fallback) ?? ChatPartFallback(text: "")
    }

    /// The payload as `T`, read with the wire's key rules (snake_case on the wire, camelCase in Swift); nil when
    /// the part carries none.
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let payload else { return nil }
        let data = try ChatWireCoder.makeEncoder().encode(payload)
        return try ChatWireCoder.makeDecoder().decode(type, from: data)
    }

    enum CodingKeys: String, CodingKey {
        case kind, payload, fallback
    }
}

/// What a client that cannot draw a part shows: a text and at most a few generic buttons (CHAT-05: open a link,
/// send a fixed owner text, or nothing).
public struct ChatPartFallback: Hashable, Sendable, Decodable {
    public struct Action: Hashable, Sendable, Decodable {
        public let label: String
        /// `chat_turn`, `open_url` or `none`.
        public let action: String
        /// The fixed owner text of a `chat_turn`.
        public let text: String?
        /// The link of an `open_url`.
        public let url: String?

        public init(label: String, action: String, text: String? = nil, url: String? = nil) {
            self.label = label
            self.action = action
            self.text = text
            self.url = url
        }
    }

    public let text: String
    public let actions: [Action]

    public init(text: String, actions: [Action] = []) {
        self.text = text
        self.actions = actions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case text, actions
    }
}

/// The part kinds of v1, in the spec's order (Go `chatengine.PartKinds`, pinned by `parts.json`).
public enum ChatPartKind {
    public static let text = "text"
    public static let steps = "steps"
    public static let sources = "sources"
    public static let artifact = "artifact"
    public static let approval = "approval"
    public static let question = "question"
    public static let error = "error"
    public static let rememberMark = "remember_mark"
    public static let knowledgeMark = "knowledge_mark"
    public static let publishedLink = "published_link"
    public static let attachment = "attachment"
    public static let routingNote = "routing_note"

    public static let all: [String] = [
        text, steps, sources, artifact, approval, question, error, rememberMark, knowledgeMark, publishedLink,
        attachment, routingNote
    ]
}

/// A JSON value: a part's payload. Named apart from the Kit's `JSONValue`, which the phone imports beside ChatWire.
public enum ChatJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])
}

extension ChatJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? c.decode(Double.self) {
            self = .double(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([String: Self].self) {
            self = .object(value)
        } else {
            self = .array(try c.decode([Self].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .double(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

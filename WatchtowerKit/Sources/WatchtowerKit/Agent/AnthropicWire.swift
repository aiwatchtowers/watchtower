import Foundation

/// Model choices for the BYOK direct-API agent. Raw values are the exact
/// Anthropic model IDs from the 2026-06 API surface — no date suffixes.
public enum AgentModel: String, CaseIterable, Sendable {
    case sonnet5 = "claude-sonnet-5"
    case opus48 = "claude-opus-4-8"
    case haiku45 = "claude-haiku-4-5"

    public var displayName: String {
        switch self {
        case .sonnet5: "Claude Sonnet 5"
        case .opus48: "Claude Opus 4.8"
        case .haiku45: "Claude Haiku 4.5"
        }
    }
}

/// Recursive JSON value for tool inputs and `input_schema` literals.
/// (`JSONValue` mirrors SQLite's flat storage classes and cannot nest;
/// Anthropic tool schemas and inputs are arbitrary JSON objects.)
public enum WireJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported WireJSON payload"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// Literal conveniences so tool `input_schema` definitions read as plain JSON
/// (see `ReplicaToolbox`). Purely additive sugar over the existing cases —
/// `encode(to:)`/`init(from:)` are untouched, so the wire bytes pinned by
/// `testRequestBodyMatchesFrozenFixture` cannot change.
extension WireJSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(dictionaryLiteral elements: (String, WireJSON)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    public init(arrayLiteral elements: WireJSON...) {
        self = .array(elements)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .int(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

/// One content block inside a message. The three request-side shapes:
/// `{"type":"text",...}` / `{"type":"tool_use",...}` / `{"type":"tool_result",...}`.
public enum APIContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: WireJSON)
    case toolResult(toolUseID: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case content
        case toolUseID = "tool_use_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(WireJSON.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: try container.decode(String.self, forKey: .content)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .toolUse(id, name, input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case let .toolResult(toolUseID, content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
        }
    }
}

/// One conversation turn: role + content block array.
public struct APIMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var role: Role
    public var content: [APIContentBlock]

    public init(role: Role, content: [APIContentBlock]) {
        self.role = role
        self.content = content
    }
}

/// Tool definition: name, description, and a JSON-schema object.
public struct APITool: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: WireJSON

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }

    public init(name: String, description: String, inputSchema: WireJSON) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Body for `POST /v1/messages`. Always streams. Deliberately narrow:
/// no `temperature`/`top_p`/`top_k` (400 on claude-sonnet-5) and no `thinking`
/// config (omitting it lets sonnet 5 run adaptive thinking by default).
/// The encoded byte shape is frozen by `testRequestBodyMatchesFrozenFixture`.
public struct AnthropicRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: String
    public var messages: [APIMessage]
    public var tools: [APITool]
    public let stream = true

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case stream
    }

    public init(
        model: AgentModel,
        system: String,
        messages: [APIMessage],
        tools: [APITool],
        maxTokens: Int = 8192
    ) {
        self.model = model.rawValue
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

/// Deterministic encoder for the Anthropic wire format: explicit snake_case
/// CodingKeys (never `convertToSnakeCase` — it would rewrite tool-input keys)
/// plus `.sortedKeys` so fixtures pin exact bytes.
enum AnthropicWireCoder {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

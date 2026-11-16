import Foundation

/// Any JSON value carried as is: the Swift side of Go's `json.RawMessage`
/// (a request's params, a response's result). `data` is the value's
/// canonical JSON (sorted keys), so decoding and re-encoding a value is
/// byte-stable after that first canonical encode.
public struct RawJSON: Codable, Hashable, Sendable {
    /// The value's canonical JSON.
    public let data: Data

    /// Wraps JSON bytes; throws when `data` is not one JSON value.
    public init(data: Data) throws {
        self.data = try Self.canonical(JSONDecoder().decode(JSONValue.self, from: data))
    }

    public init(from decoder: Decoder) throws {
        data = try Self.canonical(JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try JSONDecoder().decode(JSONValue.self, from: data).encode(to: encoder)
    }

    private static func canonical(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// One JSON value, decoded only to be encoded again.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

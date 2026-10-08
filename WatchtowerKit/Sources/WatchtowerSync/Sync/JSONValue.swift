import Foundation
import GRDB

/// JSON-representable mirror of SQLite's five storage classes, plus the
/// JSON-only shapes an action's `params` and `result` carry.
/// The sync payload is a `[column: JSONValue]` object, so the sync layer
/// never needs models to be Codable — it round-trips raw rows.
///
/// A row never produces `.bool`, `.array` or `.object`: they exist for the
/// relay params (mobile POC spec §5.2: `plan_first`, the `answer` object),
/// which are JSON, not rows.
public enum JSONValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case string(String)
    case blob(Data)
    case bool(Bool)
    case array([Self])
    case object([String: Self])

    public init(_ dbValue: DatabaseValue) {
        switch dbValue.storage {
        case .null: self = .null
        case .int64(let value): self = .integer(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .blob(let value): self = .blob(value)
        }
    }

    public var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .integer(let value): return value.databaseValue
        case .double(let value): return value.databaseValue
        case .string(let value): return value.databaseValue
        case .blob(let value): return value.databaseValue
        // Not row values; stored the way SQLite keeps them (0/1, JSON text).
        case .bool(let value): return (value ? 1 : 0).databaseValue
        case .array, .object: return Self.jsonText(self).databaseValue
        }
    }

    private static func jsonText(_ value: Self) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a JSONValue cannot fail: every case is plain JSON.
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

extension JSONValue: Codable {
    private static let blobKey = "$blob"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Before the numbers: JSONDecoder reads a JSON bool only as Bool.
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let object = try? container.decode([String: String].self),
                  let base64 = object[Self.blobKey],
                  let data = Data(base64Encoded: base64) {
            self = .blob(data)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSONValue payload"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .blob(let value): try container.encode([Self.blobKey: value.base64EncodedString()])
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

import Foundation
import GRDB

/// Encodes a GRDB row as a JSON object of column name → JSONValue,
/// and reconstructs a Row from such a payload. Schema-agnostic: works
/// for any slice table, models decode via their existing init(row:).
public enum RowPayloadCoder {
    public static func payload(from row: Row) throws -> Data {
        var dict: [String: JSONValue] = [:]
        for (column, dbValue) in row {
            dict[column] = JSONValue(dbValue)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(dict)
    }

    /// Column order is not preserved and duplicate column names collapse
    /// (last write wins) — models decode by column name, so neither matters.
    public static func row(from payload: Data) throws -> Row {
        let dict = try JSONDecoder().decode([String: JSONValue].self, from: payload)
        var rowDict: [String: DatabaseValueConvertible?] = [:]
        for (column, value) in dict {
            rowDict[column] = value.databaseValue
        }
        return Row(rowDict)
    }
}

import Foundation
import GRDB

/// The shared chat-writes fixture (`internal/chatstore/testdata/chat_writes.json`,
/// spec 2026-11-15-mobile-inbox-design §8): one case per Go `chat.*` command,
/// naming the Swift writer it ports. Go's `TestChatWritesCases` runs the
/// command; `ChatWritesFixtureTests` (Core writers) and
/// `ChatWritesAppFixtureTests` (writers in the app target) run the Swift
/// writer on the same seed and must leave the same rows.
package enum ChatWritesFixture {
    /// The case writers in the app target, which the Core tests cannot reach.
    package static let appWriters: Set<String> = ["TuningChatSurface.setTitleIfEmpty", "MeetingTranscriptQueries.delete"]

    package struct Check {
        package let sql: String
        package let rows: [[Cell]]
    }

    package struct Case {
        package let name: String
        package let command: String
        package let swift: String
        package let seed: [String]
        /// The command's params as JSON decodes them.
        package let params: [String: Any]
        /// Set when the Go command refuses: the Swift writer may throw.
        package let refusal: String?
        package let checks: [Check]
    }

    /// A column value as both sides compare it: every number as a Double.
    package enum Cell: Equatable, CustomStringConvertible {
        case null
        case number(Double)
        case text(String)

        package var description: String {
            switch self {
            case .null: "null"
            case .number(let n): "\(n)"
            case .text(let s): "\"\(s)\""
            }
        }

        init(json: Any) {
            switch json {
            case let n as NSNumber: self = .number(n.doubleValue)
            case let s as String: self = .text(s)
            default: self = .null
            }
        }

        init(_ value: DatabaseValue) {
            switch value.storage {
            case .null: self = .null
            case .int64(let n): self = .number(Double(n))
            case .double(let d): self = .number(d)
            case .string(let s): self = .text(s)
            case .blob(let b): self = .text(String(bytes: b, encoding: .utf8) ?? "")
            }
        }
    }

    /// Every case, from `<repo>/internal/chatstore/testdata/chat_writes.json`.
    package static func cases(file: StaticString = #filePath) throws -> [Case] {
        var url = URL(fileURLWithPath: "\(file)")
        while url.pathComponents.count > 1, !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("internal/chatstore/testdata/chat_writes.json").path) {
            url.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: url.appendingPathComponent("internal/chatstore/testdata/chat_writes.json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (root["cases"] as? [[String: Any]] ?? []).map { raw in
            Case(
                name: raw["name"] as? String ?? "",
                command: raw["command"] as? String ?? "",
                swift: raw["swift"] as? String ?? "",
                seed: raw["seed"] as? [String] ?? [],
                params: raw["params"] as? [String: Any] ?? [:],
                refusal: raw["refusal"] as? String,
                checks: (raw["check"] as? [[String: Any]] ?? []).map { check in
                    Check(sql: check["sql"] as? String ?? "",
                          rows: (check["rows"] as? [[Any]] ?? []).map { $0.map(Cell.init(json:)) })
                }
            )
        }
    }

    /// Seeds a fresh pool with the case's rows.
    package static func seeded(_ fixtureCase: Case) throws -> (DatabasePool, String) {
        let (pool, path) = try TestDatabase.createPool()
        try pool.write { db in
            for sql in fixtureCase.seed { try db.execute(sql: sql) }
        }
        return (pool, path)
    }

    /// The case's checks that do not hold on `pool`, worded for a failure.
    package static func mismatches(_ fixtureCase: Case, in pool: DatabasePool) throws -> [String] {
        try pool.read { db in
            try fixtureCase.checks.compactMap { check in
                let got = try Row.fetchAll(db, sql: check.sql).map { row in Array(row.databaseValues.map(Cell.init)) }
                return got == check.rows ? nil : "\(check.sql): want \(check.rows), got \(got)"
            }
        }
    }
}

/// Typed reads of a case's params.
extension [String: Any] {
    package func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    package func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    package func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    package func string(_ key: String) -> String? { self[key] as? String }
    package func int64s(_ key: String) -> [Int64] { (self[key] as? [NSNumber] ?? []).map(\.int64Value) }
    package func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
}

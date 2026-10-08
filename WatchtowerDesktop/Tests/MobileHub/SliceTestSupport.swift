import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// JSON helpers for the hub projection tests. The Desktop test target cannot
/// import WatchtowerKit, so a payload's wire shape is pinned against the Kit
/// mirror's fixture file instead (desktop lane rule).
enum SliceJSON {
    static func object(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(value as? [String: Any], "payload is not a JSON object", file: file, line: line)
    }

    static func objects(_ records: [SliceRecord]) throws -> [[String: Any]] {
        try records.map { try object($0.payload) }
    }

    /// A Kit fixture, e.g. `workbench/workbench.json`, read from the repo.
    static func kitFixture(_ relative: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let repo = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent() // MobileHub
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent("WatchtowerKit/Tests/Fixtures").appendingPathComponent(relative)
        return try object(try Data(contentsOf: url), file: file, line: line)
    }

    /// A Kit fixture written inline in a Kit test (no JSON file): the first
    /// `#"…"#` literal after `func <test>(` in `WatchtowerKit/Tests/<kitFile>`,
    /// read from the repo so a mirror change shows on the hub side too. The
    /// repo is located from this helper's own path; `file`/`line` only
    /// attribute a failure to the caller.
    static func kitInlineFixture(
        _ kitFile: String,
        test: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent() // MobileHub
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
            .appendingPathComponent("WatchtowerKit/Tests")
            .appendingPathComponent(kitFile)
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func \(test)("), "no \(test) in \(kitFile)", file: file, line: line)
        let open = try XCTUnwrap(source.range(of: "#\"", range: start.upperBound..<source.endIndex), file: file, line: line)
        let close = try XCTUnwrap(source.range(of: "\"#", range: open.upperBound..<source.endIndex), file: file, line: line)
        return Data(source[open.upperBound..<close.lowerBound].utf8)
    }

    /// Every key at any depth (objects inside arrays included).
    static func allKeys(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { $0.formUnion(allKeys($1.value)) }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
        }
        return []
    }

    /// The JSON literal type: object, array, string, bool, number or null.
    static func literalKind(_ value: Any) -> String {
        switch value {
        case is [String: Any]: return "object"
        case is [Any]: return "array"
        case is String: return "string"
        case is NSNull: return "null"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        default: return "unknown"
        }
    }
}

/// Pins `payload` to the Kit fixture: every key it has is a fixture key or
/// one of `optionalKeys` (omitted when nil), every required fixture key is
/// present, and shared keys carry the same literal type. Nested objects are
/// compared the same way.
func assertWireShape(
    _ payload: [String: Any],
    matches fixture: [String: Any],
    optionalKeys: Set<String> = [],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for key in payload.keys where fixture[key] == nil && !optionalKeys.contains(key) {
        XCTFail("key \(key) is not in the Kit fixture", file: file, line: line)
    }
    for key in fixture.keys where payload[key] == nil && !optionalKeys.contains(key) {
        XCTFail("required key \(key) is missing", file: file, line: line)
    }
    for (key, expected) in fixture {
        guard let actual = payload[key] else { continue }
        XCTAssertEqual(
            SliceJSON.literalKind(actual), SliceJSON.literalKind(expected), "literal type of \(key)", file: file, line: line
        )
        if let nested = actual as? [String: Any], let nestedFixture = expected as? [String: Any] {
            assertWireShape(nested, matches: nestedFixture, file: file, line: line)
        }
    }
}

/// The never-published columns (spec §4, constraints "Never published").
let neverPublishedKeys: Set<String> = ["folder_path", "claude_session_id", "agent_turn_end", "agent_tool_run"]

/// A UTC `YYYY-MM-DDTHH:MM:SSZ` stamp, the DB's datetime format.
func dbStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

/// Board fixtures beyond `TestDatabase+Workbenches`: timestamps, history,
/// sessions and their target links.
enum SliceSeed {
    static func setTargetTimes(_ db: Database, id: Int64, updatedAt: Date, createdAt: Date? = nil) throws {
        try db.execute(
            sql: "UPDATE targets SET updated_at = ?, created_at = ? WHERE id = ?",
            arguments: [dbStamp(updatedAt), dbStamp(createdAt ?? updatedAt), id]
        )
    }

    /// A closed target: status `done`, closed (history and `updated_at`) at
    /// `closedAt`.
    static func close(_ db: Database, id: Int64, at closedAt: Date, status: String = "done") throws {
        try db.execute(sql: "UPDATE targets SET status = ?, status_actor = 'owner' WHERE id = ?", arguments: [status, id])
        try db.execute(sql: "UPDATE target_status_history SET changed_at = ? WHERE target_id = ?", arguments: [dbStamp(closedAt), id])
        try setTargetTimes(db, id: id, updatedAt: closedAt)
    }

    @discardableResult
    static func insertSession(
        _ db: Database,
        projectID: Int64,
        kind: String = "claude",
        targetID: Int64? = nil,
        lastActiveAt: Date = Date(),
        folder: String = "/tmp/acme"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO terminal_sessions (project_id, kind, title, target_id, folder_path, claude_session_id,
                                               last_active_at, agent_turn_end, agent_tool_run)
                VALUES (?, ?, 'Session', ?, ?, ?, ?, 10, 1)
                """,
            arguments: [
                projectID, kind, targetID, folder, kind == "claude" ? UUID().uuidString.lowercased() : nil,
                dbStamp(lastActiveAt)
            ]
        )
        return db.lastInsertedRowID
    }

    static func linkSession(_ db: Database, sessionID: Int64, targetID: Int64) throws {
        let now = dbStamp(Date())
        try db.execute(
            sql: "INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, ?, ?)",
            arguments: [sessionID, targetID, now, now]
        )
    }
}

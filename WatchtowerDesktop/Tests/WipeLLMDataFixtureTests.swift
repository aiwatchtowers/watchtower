import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerTestSupport
import XCTest

/// Today's Swift Wipe LLM Data (`DatabaseManager.wipeLLMData`) and its Go
/// twin (`db.WipeLLMData`, `watchtower db wipe-llm`) leave the same rows
/// over the shared fixture `internal/db/testdata/wipe_llm.json` (Go runs it
/// in `TestWipeLLMData_LeavesTheFixtureRows`). Deleted with the Swift wipe;
/// the fixture stays as the Go golden.
final class WipeLLMDataFixtureTests: XCTestCase {
    /// …/internal/db/testdata, from …/WatchtowerDesktop/Tests/<this file>.
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/db/testdata/wipe_llm.json")

    private struct Fixture: Decodable {
        let seed: [String]
        let rows: [String: [[String: Cell]]]
    }

    /// A fixture cell: a string or a number.
    private enum Cell: Decodable, CustomStringConvertible {
        case text(String), number(Int64)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int64.self) {
                self = .number(n)
            } else {
                self = .text(try c.decode(String.self))
            }
        }

        var description: String {
            switch self {
            case let .text(s): return "\"\(s)\""
            case let .number(n): return String(n)
            }
        }

        func matches(_ value: DatabaseValue) -> Bool {
            switch (self, value.storage) {
            case let (.text(w), .string(s)): return w == s
            case let (.number(w), .int64(n)): return w == n
            default: return false
            }
        }
    }

    func testSwiftWipeLeavesTheGoFixtureRows() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        let (manager, _) = try TestDatabase.createDatabaseManager()
        try await manager.dbPool.write { db in
            for statement in fixture.seed { try db.execute(sql: statement) }
        }

        try await manager.wipeLLMData()

        try await manager.dbPool.read { db in
            for (table, want) in fixture.rows.sorted(by: { $0.key < $1.key }) {
                let columns = want.first?.keys.sorted() ?? []
                let select = columns.isEmpty ? "1" : columns.joined(separator: ", ")
                let rows = try Row.fetchAll(db, sql: "SELECT \(select) FROM \(table) ORDER BY rowid")
                XCTAssertEqual(rows.count, want.count, "\(table) rows")
                for (index, (row, expected)) in zip(rows, want).enumerated() {
                    for (position, column) in columns.enumerated() {
                        guard let cell = expected[column] else { continue }
                        let value: DatabaseValue = row[position]
                        XCTAssertTrue(cell.matches(value), "\(table) row \(index) \(column) = \(value), want \(cell)")
                    }
                }
            }
        }
    }
}

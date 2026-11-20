import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport
import XCTest

/// The test fake of Go's screen writers (`FakeScreenTower.applying`, which
/// the view models' tests write through) answers every case of the Go
/// golden `internal/inboxfeed/testdata/screen_writes.json` (Go runs it in
/// `TestScreenWritesCases`) as Go does: the same status, refusal code and
/// sentence, `already`, reported result and rows (`"*"` is any non-empty
/// value, `null` a NULL; a table key may carry a `WHERE`). A drift between
/// the fake and Go fails here, not in a view model test that trusts it.
final class ScreenTowerWritesFixtureTests: XCTestCase {
    /// …/internal/inboxfeed/testdata, from …/WatchtowerDesktop/Tests/Core/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Core
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/inboxfeed/testdata")

    private struct WriteCase: Decodable {
        let name: String
        let seed: [String]
        let now: String
        let command: String
        let call: RawJSON
        let expect: Expect
    }

    private struct Expect: Decodable {
        let status: String
        let code: String?
        let sentence: String?
        let already: RawJSON?
        let result: RawJSON?
        let rows: [String: [[String: Cell]]]?
    }

    /// A fixture cell: a string, a number, a bool or null.
    private enum Cell: Decodable, CustomStringConvertible {
        case text(String), number(Int64), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .number(b ? 1 : 0)
            } else if let n = try? c.decode(Int64.self) {
                self = .number(n)
            } else {
                self = .text(try c.decode(String.self))
            }
        }

        var description: String {
            switch self {
            case let .text(s): return "\"\(s)\""
            case let .number(n): return String(n)
            case .null: return "null"
            }
        }

        func matches(_ value: DatabaseValue) -> Bool {
            switch (self, value.storage) {
            case (.null, .null): return true
            case let (.text("*"), .string(s)): return !s.isEmpty
            case let (.text(w), .string(s)): return w == s
            case let (.number(w), .int64(n)): return w == n
            default: return false
            }
        }
    }

    func testFakeAnswersEveryGoCaseAsGo() async throws {
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("screen_writes.json"))
        let cases = try JSONDecoder().decode([WriteCase].self, from: data)
        XCTAssertGreaterThanOrEqual(cases.count, 85)
        for item in cases {
            let command = try XCTUnwrap(TowerCommand(rawValue: item.command), "\(item.name): \(item.command)")
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: item.now), item.name)
            let queue = try TestDatabase.create()
            try await queue.write { db in
                for statement in item.seed { try db.execute(sql: statement) }
            }
            let tower = FakeScreenTower.applying(queue) { now }
            let outcome: TowerActOutcome<RawJSON> = await tower.act(command, key: item.name) { _ in item.call }

            XCTAssertEqual(tower.unmodelled, [], "\(item.name): the fake models \(item.command)")
            switch (item.expect.status, outcome) {
            case let ("ok", .ok(answer)):
                let got = try JSONSerialization.jsonObject(with: answer.data) as? [String: Any] ?? [:]
                let want = try item.expect.already.map { try JSONSerialization.jsonObject(with: $0.data, options: .fragmentsAllowed) as? Bool }
                XCTAssertEqual(got["already"] as? Bool ?? false, want ?? false, "\(item.name): already")
                let result = try item.expect.result.map { try JSONSerialization.jsonObject(with: $0.data) as? [String: Any] ?? [:] }
                for (key, value) in result ?? [:] {
                    XCTAssertEqual(got[key] as? NSObject, value as? NSObject, "\(item.name): result \(key)")
                }
            case let ("refused", .refused(refusal)):
                XCTAssertEqual(refusal.code.rawValue, item.expect.code, "\(item.name): code")
                XCTAssertEqual(refusal.sentence, item.expect.sentence, "\(item.name): sentence")
            default:
                XCTFail("\(item.name): want \(item.expect.status), got \(outcome)")
            }
            try await queue.read { db in
                for (table, rows) in (item.expect.rows ?? [:]).sorted(by: { $0.key < $1.key }) {
                    try Self.assertRows(db, table: table, want: rows, name: item.name)
                }
            }
        }
    }

    /// A command the fake does not model is refused, never answered ok.
    func testUnmodelledCommandIsRefusedLoudly() async throws {
        let tower = FakeScreenTower.applying(try TestDatabase.create())
        let outcome: TowerActOutcome<ActResult> = await tower.act(.syncPause, key: "pause") { ScreenIDRequest(requestID: $0, id: 1) }
        guard case let .refused(refusal) = outcome else { return XCTFail("unmodelled answered \(outcome)") }
        XCTAssertEqual(refusal.sentence, "FakeScreenTower does not model sync.pause.")
        XCTAssertEqual(tower.unmodelled, [.syncPause])
    }

    private static func assertRows(_ db: Database, table: String, want: [[String: Cell]], name: String) throws {
        let columns = (want.first?.keys.sorted()) ?? []
        let order = table.hasPrefix("decision_reads") ? "digest_id, decision_idx" : "rowid"
        let select = columns.isEmpty ? "1" : columns.joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: "SELECT \(select) FROM \(table) ORDER BY \(order)")
        XCTAssertEqual(rows.count, want.count, "\(name): \(table) rows")
        for (index, (row, expected)) in zip(rows, want).enumerated() {
            for (position, column) in columns.enumerated() {
                guard let cell = expected[column] else { continue }
                let value: DatabaseValue = row[position]
                XCTAssertTrue(cell.matches(value), "\(name): \(table) row \(index) \(column) = \(value), want \(cell)")
            }
        }
    }
}

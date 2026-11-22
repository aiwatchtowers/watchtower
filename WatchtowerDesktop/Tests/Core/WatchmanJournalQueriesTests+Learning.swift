import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// What waits for learning (tuning spec §3, D5): the journal's count is Go's
/// `WatchmanWaitingForLearning` case for case — both read
/// `internal/db/testdata/watchman_waiting_learning_cases.json` (its shape is
/// documented in `internal/db/watchman_learning_test.go`).
extension WatchmanJournalQueriesTests {
    func testWaitingForLearningSharedCases() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/watchman_waiting_learning_cases.json")
        let cases = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let workbench = try XCTUnwrap((item["workbench_id"] as? NSNumber)?.int64Value, name)
            let want = try XCTUnwrap(item["want"] as? Int, name)
            let queue = try TestDatabase.create()
            try queue.write { db in try Self.seed(db, item) }
            let (count, byWorkbench) = try queue.read { db in
                (try WatchmanJournalQueries.waitingForLearning(db, workbench: workbench),
                 try WatchmanJournalQueries.waitingForLearningByWorkbench(db))
            }
            XCTAssertEqual(count, want, name)
            XCTAssertEqual(byWorkbench[workbench] ?? 0, want, "\(name) (by workbench)")
            XCTAssertFalse(byWorkbench.values.contains(0), "\(name): a workbench with nothing waiting is left out")
        }
    }

    /// The case's rows, table by table in the file's order, as Go's `seed`.
    private static func seed(_ db: Database, _ item: [String: Any]) throws {
        let tables = ["projects", "targets", "terminal_sessions", "owner_asks", "watchman_arming",
                      "watchman_workbenches", "watchman_precedents", "watchman_items"]
        for table in tables {
            for row in item[table] as? [[String: Any]] ?? [] {
                let columns = row.keys.sorted()
                let values: [(any DatabaseValueConvertible)?] = columns.map { column in
                    switch row[column] {
                    case let text as String: text
                    case let number as NSNumber:
                        number.doubleValue == number.doubleValue.rounded() ? number.int64Value : number.doubleValue
                    default: nil
                    }
                }
                try db.execute(sql: """
                    INSERT INTO \(table) (\(columns.joined(separator: ", ")))
                    VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
                    """, arguments: StatementArguments(values))
            }
        }
    }
}

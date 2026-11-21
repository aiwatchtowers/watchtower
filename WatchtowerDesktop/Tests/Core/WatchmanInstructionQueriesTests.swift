import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The stored instruction the arm and edit sheets pre-fill (tuning spec §2,
/// D7), read from the generated test schema's `watchman_instructions`.
final class WatchmanInstructionQueriesTests: XCTestCase {
    func testReadsTheScopesOwnText() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO watchman_instructions (scope, ref_id, text, updated_at) VALUES
                    ('session', 5, 'ship task 3 only', '2026-11-21T01:00:00Z'),
                    ('target', 5, 'keep the public API', '2026-11-21T01:00:00Z')
                """)
        }
        try queue.read { db in
            XCTAssertEqual(try WatchmanInstructionQueries.text(db, scope: .session(5)), "ship task 3 only")
            XCTAssertEqual(try WatchmanInstructionQueries.text(db, scope: .target(5)), "keep the public API")
            XCTAssertEqual(try WatchmanInstructionQueries.text(db, scope: .session(6)), "", "none stored")
            XCTAssertEqual(try WatchmanInstructionQueries.text(db, scope: .allRunning), "")
        }
    }
}

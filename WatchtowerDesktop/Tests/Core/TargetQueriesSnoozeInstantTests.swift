import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Home's target Hide snoozes to an instant: `snooze_until` holds it as a
/// UTC "yyyy-MM-ddTHH:mm" minute, the form Go's `UnsnoozeExpiredTargets`
/// compares against, so the target comes back at that instant and not at
/// 00:00 UTC of a bare date.
final class TargetQueriesSnoozeInstantTests: XCTestCase {
    private func stored(_ instant: Date) throws -> Row? {
        let db = try TestDatabase.create()
        let id = try db.write { Int(try TestDatabase.insertTarget($0, text: "Ship it")) }
        try db.write { try TargetQueries.snooze($0, id: id, untilInstant: instant) }
        return try db.read { try Row.fetchOne($0, sql: "SELECT status, snooze_until FROM targets WHERE id = ?", arguments: [id]) }
    }

    func testStoresTheInstantAsAUTCMinute() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T16:00:59Z"))
        let row = try stored(instant)
        XCTAssertEqual(row?["status"], "snoozed")
        XCTAssertEqual(row?["snooze_until"], "2026-10-20T16:00")
    }

    func testMissingTargetThrows() throws {
        let db = try TestDatabase.create()
        XCTAssertThrowsError(try db.write { try TargetQueries.snooze($0, id: 999, untilInstant: Date()) }) {
            XCTAssertTrue($0 is TargetNotFoundError, "unexpected \($0)")
        }
    }
}

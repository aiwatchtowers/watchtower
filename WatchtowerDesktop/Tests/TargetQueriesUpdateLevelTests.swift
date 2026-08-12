import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

final class TargetQueriesUpdateLevelTests: XCTestCase {

    func testUpdateLevel_ChangesLevel() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int in
            try TargetQueries.create(
                db,
                text: "ship Q3 roadmap",
                level: "day",
                periodStart: "2026-06-27",
                periodEnd: "2026-06-27",
                sourceType: "manual",
                sourceID: ""
            )
        }

        try queue.write { db in
            try TargetQueries.updateLevel(db, id: id, level: "quarter")
        }

        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.level, "quarter")
    }

    func testUpdateLevel_ClearsCustomLabel_WhenSwitchingToStandardLevel() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int in
            try TargetQueries.create(
                db,
                text: "custom push",
                level: "custom",
                customLabel: "Q3 push",
                periodStart: "2026-07-01",
                periodEnd: "2026-09-30",
                sourceType: "manual",
                sourceID: ""
            )
        }

        try queue.write { db in
            try TargetQueries.updateLevel(db, id: id, level: "month")
        }

        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.level, "month")
        XCTAssertEqual(target?.customLabel, "", "switching to a standard level should clear the custom label")
    }

    func testUpdateLevel_WritesPeriod_WhenWindowSupplied() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int in
            try TargetQueries.create(
                db,
                text: "ship it",
                level: "day",
                periodStart: "2026-06-27",
                periodEnd: "2026-06-27",
                sourceType: "manual",
                sourceID: ""
            )
        }

        let window = Target.periodWindow(for: "quarter", anchoredOn: "2026-06-27")
        try queue.write { db in
            try TargetQueries.updateLevel(
                db, id: id, level: "quarter",
                periodStart: window?.start, periodEnd: window?.end
            )
        }

        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.level, "quarter")
        XCTAssertEqual(target?.periodStart, "2026-04-01", "period expands to the quarter containing the anchor")
        XCTAssertEqual(target?.periodEnd, "2026-06-30")
    }
}

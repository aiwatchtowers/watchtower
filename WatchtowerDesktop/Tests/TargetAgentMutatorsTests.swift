import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TargetAgentMutatorsTests: XCTestCase {
    func testUpdateProgressClampsAndPersists() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try TargetQueries.create(db, text: "t", periodStart: "2026-06-26", periodEnd: "2026-06-26")
        }
        try queue.write { db in
            try TargetQueries.updateProgress(db, id: id, progress: 0.42)
        }
        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.progress ?? 0, 0.42, accuracy: 0.0001)
    }

    func testUpdateProgressClampsOutOfRange() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try TargetQueries.create(db, text: "t", periodStart: "2026-06-26", periodEnd: "2026-06-26")
        }
        // Above 1.0 clamps to 1.0, below 0.0 clamps to 0.0.
        try queue.write { db in try TargetQueries.updateProgress(db, id: id, progress: 1.5) }
        let high = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(high?.progress ?? -1, 1.0, accuracy: 0.0001)

        try queue.write { db in try TargetQueries.updateProgress(db, id: id, progress: -0.3) }
        let low = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(low?.progress ?? -1, 0.0, accuracy: 0.0001)
    }

    @MainActor
    func testCreateChildInheritsPeriodAndParent() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let parentID = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "parent", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let parent = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: parentID) }!
        let vm = TargetsViewModel(dbManager: manager)

        let childID = vm.createChild(parent, text: "child", intent: "do x", priority: "high")
        XCTAssertNotNil(childID)

        let child = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: childID!) }!
        XCTAssertEqual(child.parentId, parentID)
        XCTAssertEqual(child.periodStart, "2026-06-01")
        XCTAssertEqual(child.periodEnd, "2026-06-30")
        XCTAssertEqual(child.priority, "high")
        XCTAssertEqual(child.intent, "do x")
    }
}

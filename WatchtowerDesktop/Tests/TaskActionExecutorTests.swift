import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class TaskActionExecutorTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "parent", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    func testApplyUpdateStatus() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.status, "done")
    }

    func testApplyUpdateProgressDividesByHundred() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateProgress, reason: "half", progress: 50)
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.progress, 0.5, accuracy: 0.0001)
    }

    func testApplyAddNote() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateNotes, reason: "log", note: "spoke to Bob")
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertTrue(after.decodedNotes.contains { $0.text == "spoke to Bob" })
    }

    func testApplyAddSubItem() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .addSubItem, reason: "step", text: "draft reply")
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertTrue(after.decodedSubItems.contains { $0.text == "draft reply" })
    }

    func testApplyCreateChildTarget() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .createChildTarget, reason: "spin off",
                                    text: "Ping Bob", intent: "unblock", priority: "high")
        let summary = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let children = try manager.dbPool.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets WHERE parent_id = ?", arguments: [target.id])
        }
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.text, "Ping Bob")
        XCTAssertFalse(summary.isEmpty)
    }
}

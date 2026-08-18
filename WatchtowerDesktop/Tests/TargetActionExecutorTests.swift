import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TargetActionExecutorTests: XCTestCase {
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
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.status, "done")
    }

    func testApplyUpdateProgressDividesByHundred() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateProgress, reason: "half", progress: 50)
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.progress, 0.5, accuracy: 0.0001)
    }

    func testApplyAddNote() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateNotes, reason: "log", note: "spoke to Bob")
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertTrue(after.decodedNotes.contains { $0.text == "spoke to Bob" })
    }

    func testApplyAddSubItem() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .addSubItem, reason: "step", text: "draft reply")
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

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
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let children = try manager.dbPool.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets WHERE parent_id = ?", arguments: [target.id])
        }
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.text, "Ping Bob")
        XCTAssertFalse(summary.isEmpty)
    }

    func testApplyLinkTarget() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let otherID = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "other", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .linkTarget, reason: "blocks it",
                                    targetId: otherID, relation: "blocks")
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let links = try manager.dbPool.read { db in
            try TargetLink.fetchAll(
                db, sql: "SELECT * FROM target_links WHERE source_target_id = ?", arguments: [target.id]
            )
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.targetTargetId, otherID)
        XCTAssertEqual(links.first?.relation, "blocks")
    }

    func testApplyLinkTargetRejectsUnknownTarget() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        // The AI hallucinated an id — no such row. The executor must throw at
        // apply time, and no dangling link row may be written.
        let action = ProposedAction(type: .linkTarget, reason: "x",
                                    targetId: 999_999, relation: "blocks")
        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: target, viewModel: vm)) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not exist"))
        }

        let links = try manager.dbPool.read { db in
            try TargetLink.fetchAll(
                db, sql: "SELECT * FROM target_links WHERE source_target_id = ?", arguments: [target.id]
            )
        }
        XCTAssertTrue(links.isEmpty)
    }

    func testApplyWriteFailureDetectedEvenWhenIdenticalToPriorError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)
        // Close the pool so every mutator write fails with the SAME error text
        // each time — the shape a prior-error snapshot used to mask: the second
        // failure looked identical to the stale snapshot and read as success.
        try manager.dbPool.close()

        let action = ProposedAction(type: .updateStatus, reason: "x", status: "done")
        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: target, viewModel: vm))
        // The second identical failure must ALSO throw — never a false "Applied".
        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: target, viewModel: vm))
    }

    func testApplyLinkTargetRejectsSelfLink() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .linkTarget, reason: "x",
                                    targetId: target.id, relation: "blocks")
        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: target, viewModel: vm))
    }

    func testApplyUpdateTitle() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateTitle, reason: "clean title", text: "Ship the registry")
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.text, "Ship the registry")
        XCTAssertTrue(summary.contains("Ship the registry"))
    }

    func testApplyUpdatePriority() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updatePriority, reason: "deadline", priority: "high")
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.priority, "high")
        XCTAssertEqual(summary, "set priority to high")
    }

    func testApplyUpdateDue() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateDue, reason: "friday", text: "2026-09-01")
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.dueDate, "2026-09-01")
        XCTAssertEqual(summary, "set due date to 2026-09-01")
    }

    func testApplyUpdateIntent() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateIntent, reason: "directive", text: "Unblock the API team first")
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.intent, "Unblock the API team first")
        XCTAssertEqual(summary, "updated context")
    }

    func testApplyUpdateTitleRejectsBlankText() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        // A whitespace-only title would silently no-op in the ViewModel; the
        // executor must throw instead of reporting a false rename.
        let action = ProposedAction(type: .updateTitle, reason: "x", text: "   ")
        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: target, viewModel: vm))

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.text, "parent") // unchanged
    }

    func testApplyThrowsOnMissingRequiredField() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        // update_status without a status must throw, not silently no-op.
        let action = ProposedAction(type: .updateStatus, reason: "x", status: nil)
        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: target, viewModel: vm))

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.status, "todo") // unchanged
    }
}

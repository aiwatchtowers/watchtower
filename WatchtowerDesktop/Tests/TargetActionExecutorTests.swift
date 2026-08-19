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
        // The summary must carry the new child's id — it is echoed back into the
        // conversation, and the assistant needs it to address the child next.
        let childID = try XCTUnwrap(children.first?.id)
        XCTAssertTrue(summary.contains("#\(childID)"), "summary should name the new child id: \(summary)")
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

    // MARK: - Sub-item mutations

    /// Creates a target with three sub-items and returns the re-fetched row.
    private func makeTargetWithSubItems(_ manager: DatabaseManager, vm: TargetsViewModel) throws -> Target {
        let target = try makeTarget(manager)
        vm.addSubItem(target, text: "write spec")
        var fresh = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        vm.addSubItem(fresh, text: "review PR")
        fresh = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        vm.addSubItem(fresh, text: "ship it")
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
    }

    func testApplyToggleSubItem() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let action = ProposedAction(type: .toggleSubItem, reason: "user did it",
                                    index: 1, match: "review PR", done: true)
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertTrue(after.decodedSubItems[1].done)
    }

    /// Toggling to the state the item is already in is a reported no-op, not a flip.
    func testApplyToggleSubItemAlreadyInStateIsNoOp() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let action = ProposedAction(type: .toggleSubItem, reason: "r",
                                    index: 0, match: "write spec", done: false)
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)
        XCTAssertTrue(summary.contains("already"))

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertFalse(after.decodedSubItems[0].done)
    }

    func testApplyEditSubItem() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let action = ProposedAction(type: .editSubItem, reason: "reword",
                                    text: "ship it to staging", index: 2, match: "ship it")
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.decodedSubItems[2].text, "ship it to staging")
    }

    func testApplyDeleteSubItem() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let action = ProposedAction(type: .deleteSubItem, reason: "obsolete",
                                    index: 1, match: "review PR")
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.decodedSubItems.map(\.text), ["write spec", "ship it"])
    }

    /// The AI's index went stale (items shifted) but the text still uniquely
    /// identifies the item — the executor must resolve it, not delete the wrong row.
    func testApplyDeleteSubItemStaleIndexResolvesByText() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let action = ProposedAction(type: .deleteSubItem, reason: "obsolete",
                                    index: 0, match: "ship it")
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.decodedSubItems.map(\.text), ["write spec", "review PR"])
    }

    func testApplyDeleteSubItemNoMatchThrows() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let action = ProposedAction(type: .deleteSubItem, reason: "r",
                                    index: 0, match: "never existed")
        XCTAssertThrowsError(try TargetActionExecutor.apply(action, target: target, viewModel: vm))

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.decodedSubItems.count, 3) // unchanged
    }

    func testApplySetSubItemDueAndClear() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let set = ProposedAction(type: .setSubItemDue, reason: "deadline",
                                 index: 0, match: "write spec", dueDate: "2026-09-01")
        _ = try TargetActionExecutor.apply(set, target: target, viewModel: vm)
        var after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.decodedSubItems[0].dueDate, "2026-09-01")

        let clear = ProposedAction(type: .setSubItemDue, reason: "slipped",
                                   index: 0, match: "write spec", dueDate: "")
        _ = try TargetActionExecutor.apply(clear, target: after, viewModel: vm)
        after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertNil(after.decodedSubItems[0].dueDate)
    }

    /// Summaries quote item texts capped with an ellipsis — a batch follow-up
    /// must not echo whole checklists into the transcript.
    func testApplySummariesTruncateLongItemText() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTarget(manager)
        let longText = String(repeating: "release checklist item ", count: 8) // ~180 chars
        vm.addSubItem(target, text: longText)
        let fresh = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })

        let action = ProposedAction(type: .toggleSubItem, reason: "r",
                                    index: 0, match: longText, done: true)
        let summary = try TargetActionExecutor.apply(action, target: fresh, viewModel: vm)

        XCTAssertTrue(summary.contains("…"), "long text must be truncated, got: \(summary)")
        XCTAssertFalse(summary.contains(longText), "full text must not be echoed, got: \(summary)")
    }

    /// The edit summary names only the new text — the old text is redundant
    /// (the card's match already identified the item) and doubles the noise.
    func testApplyEditSubItemSummaryOmitsOldText() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = TargetsViewModel(dbManager: manager)
        let target = try makeTargetWithSubItems(manager, vm: vm)

        let action = ProposedAction(type: .editSubItem, reason: "reword",
                                    text: "ship to staging", index: 2, match: "ship it")
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        XCTAssertTrue(summary.contains("ship to staging"))
        XCTAssertFalse(summary.contains("\"ship it\""), "old text must not be echoed, got: \(summary)")
    }

    // MARK: - Target field mutations

    func testApplyUpdateDueDate() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateDueDate, reason: "agreed", dueDate: "2026-08-22")
        let summary = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.dueDate, "2026-08-22")
        XCTAssertEqual(summary, "set due date to 2026-08-22")
    }

    func testApplyUpdateBallOn() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateBallOn, reason: "handed off", ballOn: "@petya")
        _ = try TargetActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.ballOn, "@petya")
    }
}

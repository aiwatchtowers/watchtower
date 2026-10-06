import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// The side panel's state in `WorkbenchBoardViewModel` (spec 2026-10-06
/// Part 3): the navigation path, the status history and the description save.
@MainActor
final class WorkbenchBoardPanelViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WorkbenchBoardPanelViewModelTests-\(UUID().uuidString)"
        do {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    /// A group with two tasks: (project, group, task A, task B).
    private func seedGroup() throws -> (Int64, Int, Int, Int) {
        try dbManager.dbPool.write { db -> (Int64, Int, Int, Int) in
            let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            let group = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Group")
            let taskA = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Task A", parentID: group)
            let taskB = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Task B", parentID: group)
            return (pid, Int(group), Int(taskA), Int(taskB))
        }
    }

    private func makeVM(project: Int64) -> WorkbenchBoardViewModel {
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: project, defaults: defaults)
        vm.load()
        return vm
    }

    private func delete(_ id: Int) throws {
        try dbManager.dbPool.write { db in
            try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Path

    func testSelectResetsThePath() throws {
        let (pid, group, taskA, taskB) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        vm.push(group)
        XCTAssertEqual(vm.panelPath, [taskA, group])

        vm.select(taskB)

        XCTAssertEqual(vm.panelPath, [taskB])
        XCTAssertEqual(vm.selectedTargetID, taskB)
        XCTAssertFalse(vm.canGoBack)

        vm.select(nil)
        XCTAssertEqual(vm.panelPath, [])
        XCTAssertNil(vm.selectedTargetID)
    }

    func testPushAndBack() throws {
        let (pid, group, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(group)
        XCTAssertFalse(vm.canGoBack)

        vm.push(taskA)
        XCTAssertEqual(vm.panelPath, [group, taskA])
        XCTAssertEqual(vm.selectedTargetID, taskA)
        XCTAssertEqual(vm.selectedNode?.target.text, "Task A")
        XCTAssertTrue(vm.canGoBack)

        vm.back()
        XCTAssertEqual(vm.panelPath, [group])
        XCTAssertEqual(vm.selectedNode?.target.text, "Group")
        XCTAssertFalse(vm.canGoBack)
    }

    func testPushOfTheOpenTargetAddsNoEntry() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        vm.push(taskA)
        XCTAssertEqual(vm.panelPath, [taskA])
    }

    func testPushOfAnIDAlreadyOnThePathCutsBackToIt() throws {
        let (pid, group, taskA, taskB) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        vm.push(group)
        vm.push(taskB)
        XCTAssertEqual(vm.panelPath, [taskA, group, taskB])

        vm.push(taskA)

        XCTAssertEqual(vm.panelPath, [taskA], "no duplicate entry: the path is cut back to the earlier one")
        XCTAssertEqual(vm.selectedNode?.target.text, "Task A")
        XCTAssertFalse(vm.canGoBack)

        vm.push(group)
        vm.push(taskB)
        vm.push(group)
        XCTAssertEqual(vm.panelPath, [taskA, group])
    }

    func testSelectedParentIsTheNearestParentAndNilAtTheTop() throws {
        let (pid, group, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        XCTAssertEqual(vm.selectedParent?.target.id, group)

        vm.push(group)
        XCTAssertNil(vm.selectedParent)

        vm.select(nil)
        XCTAssertNil(vm.selectedParent)
    }

    func testPushWithAClosedPanelOpensIt() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.push(taskA)
        XCTAssertEqual(vm.panelPath, [taskA])
        XCTAssertFalse(vm.canGoBack)
    }

    func testBackOnOneEntryIsANoOp() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)

        vm.back()

        XCTAssertEqual(vm.panelPath, [taskA])
        XCTAssertEqual(vm.selectedTargetID, taskA)

        vm.select(nil)
        vm.back()
        XCTAssertEqual(vm.panelPath, [])
    }

    func testReloadAfterTheLastIDIsDeletedPopsToTheSurvivingOneThenCloses() throws {
        let (pid, group, taskA, taskB) = try seedGroup()
        _ = try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkbenchComment(db, projectID: pid, body: "On the group", targetID: Int64(group))
        }
        let vm = makeVM(project: pid)
        vm.select(group)
        vm.push(taskA)
        vm.push(taskB)

        try delete(taskB)
        vm.load()
        XCTAssertEqual(vm.panelPath, [group, taskA])
        XCTAssertEqual(vm.selectedNode?.target.text, "Task A")

        try delete(taskA)
        vm.load()
        XCTAssertEqual(vm.panelPath, [group])
        XCTAssertEqual(vm.threads.map(\.root.body), ["On the group"], "the surviving entry's comments load")

        try delete(group)
        vm.load()
        XCTAssertEqual(vm.panelPath, [])
        XCTAssertNil(vm.selectedNode)
        XCTAssertTrue(vm.threads.isEmpty)
        XCTAssertEqual(vm.selectedHistory, [])
    }

    func testAMissingMiddleEntryIsDroppedSoBackNeverLandsOnIt() throws {
        let (pid, group, taskA, taskB) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(group)
        vm.push(taskA)
        vm.push(taskB)

        try delete(taskA)
        vm.load()

        XCTAssertEqual(vm.panelPath, [group, taskB])
    }

    /// The Session view's `boardFocus` handoff (`WorkbenchBoardView.takeFocus`)
    /// opens its target the way a board click does: `select`, a fresh path.
    func testBoardFocusHandoffResetsThePath() throws {
        let (pid, group, taskA, taskB) = try seedGroup()
        let projects = WorkbenchesViewModel(dbPool: dbManager.dbPool, cli: nil, defaults: defaults)
        projects.boardFocus[pid] = Int64(taskB)
        let vm = makeVM(project: pid)
        vm.select(group)
        vm.push(taskA)

        let focus = try XCTUnwrap(projects.takeBoardFocus(projectID: pid))
        vm.select(Int(focus))

        XCTAssertEqual(vm.panelPath, [taskB])
        XCTAssertNil(projects.takeBoardFocus(projectID: pid), "the handoff is taken once")
    }

    // MARK: - Comment drafts

    /// A half-typed comment belongs to the target it was typed for: it never
    /// follows the panel to another one, and it is back on returning.
    func testCommentDraftIsPerTargetAndNeverPostedToAnother() throws {
        let (pid, group, taskA, taskB) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        vm.commentDraft = "Answer for A"

        vm.push(taskB)
        XCTAssertEqual(vm.commentDraft, "", "B starts with its own, empty draft")
        XCTAssertFalse(vm.sendCommentDraft(), "an empty draft on B sends nothing")
        vm.commentDraft = "Note for B"
        XCTAssertTrue(vm.sendCommentDraft())
        XCTAssertEqual(vm.threads.map(\.root.body), ["Note for B"])
        XCTAssertEqual(vm.commentDraft, "", "a sent draft is cleared")

        vm.back()
        XCTAssertEqual(vm.commentDraft, "Answer for A", "A's draft is restored")
        XCTAssertTrue(vm.threads.isEmpty, "nothing was posted to A")

        vm.select(group)
        vm.closeDetail()
        vm.commentDraft = "Ignored"
        vm.select(taskA)
        XCTAssertEqual(vm.commentDraft, "Answer for A", "survives closing and reopening the same target")
        let comments = try dbManager.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT target_id, body FROM project_comments WHERE project_id = ?",
                             arguments: [pid])
        }
        XCTAssertEqual(comments.map { $0["body"] as String }, ["Note for B"])
        XCTAssertEqual(comments.map { $0["target_id"] as Int }, [taskB])
    }

    func testAFailedSendKeepsTheTargetsDraft() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        vm.commentDraft = "Kept"
        try dbManager.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_comment_insert BEFORE INSERT ON project_comments
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        XCTAssertFalse(vm.sendCommentDraft())
        XCTAssertEqual(vm.commentDraft, "Kept")
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Mark read, stale content, banner

    /// A panel move whose read fails never shows the previous target's
    /// comments under the new header.
    func testAFailedReadOnAPanelMoveDropsThePreviousTargetsContent() throws {
        let (pid, _, taskA, taskB) = try seedGroup()
        _ = try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkbenchComment(db, projectID: pid, author: "owner", body: "On A",
                                                    targetID: Int64(taskA))
        }
        let pool = try DatabasePool(path: dbPath)
        let vm = WorkbenchBoardViewModel(dbPool: pool, projectID: pid, defaults: defaults)
        vm.load()
        vm.select(taskA)
        XCTAssertEqual(vm.threads.map(\.root.body), ["On A"])
        try pool.close()

        vm.push(taskB)

        XCTAssertEqual(vm.selectedTargetID, taskB)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.threads.isEmpty, "A's comment is not shown under B")
        XCTAssertEqual(vm.selectedHistory, [])
        XCTAssertEqual(vm.selectedAsks.count, 0)
        XCTAssertEqual(vm.selectedImages.count, 0)
    }

    /// The banner follows the panel actually drawn. A target the board has
    /// not read yet (the Session view's handoff of a new target) opened while
    /// the read fails leaves its id selected with no panel on screen: the
    /// error must show on the board.
    func testTheBannerShowsTheErrorWhenNoPanelIsDrawnForTheSelection() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let pool = try DatabasePool(path: dbPath)
        let vm = WorkbenchBoardViewModel(dbPool: pool, projectID: pid, defaults: defaults)
        vm.load()
        vm.select(taskA)
        vm.refuseCrossLaneDrop()
        XCTAssertNil(vm.boardBannerError, "the open panel shows it in its own row")
        try pool.close()

        vm.select(999_999)

        XCTAssertEqual(vm.selectedTargetID, 999_999)
        XCTAssertNil(vm.selectedNode)
        let error = try XCTUnwrap(vm.errorMessage)
        XCTAssertEqual(vm.boardBannerError, error)
    }

    // MARK: - Writes the panel refuses

    func testACrossLaneDropIsRefusedWithAReasonAndWritesNothing() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        let before = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }

        vm.refuseCrossLaneDrop()

        XCTAssertEqual(vm.errorMessage, "A card moves within its own lane — use Move to… to change its group.")
        let after = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }
        XCTAssertEqual(after?.status, before?.status)
        XCTAssertEqual(after?.updatedAt, before?.updatedAt)
        XCTAssertEqual(reported, 0)
    }

    /// Spec Part 5: a group's status is never written from the panel.
    func testThePanelStatusMenuNeverWritesAGroupsStatus() throws {
        let (pid, group, _, _) = try seedGroup()
        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET updated_at = '2026-01-01T00:00:00Z' WHERE id = ?", arguments: [group])
        }
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.select(group)

        vm.setStatus("done")

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: group) }
        XCTAssertEqual(stored?.status, "todo")
        XCTAssertEqual(stored?.updatedAt, "2026-01-01T00:00:00Z", "nothing was written")
        XCTAssertEqual(reported, 0)
    }

    // MARK: - History
    // MARK: - History

    func testHistoryIsNewestFirstAndFollowsTheSelection() throws {
        let (pid, _, taskA, taskB) = try seedGroup()
        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET status = 'in_progress', status_actor = 'agent' WHERE id = ?",
                           arguments: [taskA])
            try TargetQueries.updateStatus(db, id: taskA, status: "done")
        }
        let vm = makeVM(project: pid)
        vm.select(taskA)

        XCTAssertEqual(vm.selectedHistory.map(\.toStatus), ["done", "in_progress", "todo"])
        XCTAssertEqual(vm.selectedHistory.map(\.actor), ["owner", "agent", "owner"])

        vm.push(taskB)
        XCTAssertEqual(vm.selectedHistory.map(\.toStatus), ["todo"])

        try dbManager.dbPool.write { try TargetQueries.updateStatus($0, id: taskB, status: "blocked") }
        // An explicit reload: the poll fingerprint's `updated_at` has second
        // resolution, so a same-second write may not move it.
        vm.load()
        XCTAssertEqual(vm.selectedHistory.map(\.toStatus), ["blocked", "todo"], "a reload reads it again")
    }

    // MARK: - Description

    func testSaveIntentWritesAndReportsTheOwnerWrite() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported: [WorkbenchSubject] = []
        vm.onOwnerWrite = { _, subject in reported.append(subject) }
        vm.select(taskA)

        XCTAssertTrue(vm.saveIntent("Ship the v2 endpoint"))

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }
        XCTAssertEqual(stored?.intent, "Ship the v2 endpoint")
        XCTAssertEqual(vm.selectedNode?.target.intent, "Ship the v2 endpoint")
        XCTAssertEqual(reported, [.target(Int64(taskA))])
    }

    func testSaveIntentUnchangedWritesNothing() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.select(taskA)

        // An old stamp: a write in the same second as the seed would not move
        // a fresh one (`updated_at` has second resolution).
        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET updated_at = '2026-01-01T00:00:00Z' WHERE id = ?", arguments: [taskA])
        }

        XCTAssertTrue(vm.saveIntent(""))
        XCTAssertTrue(vm.saveIntent(" \n\t "), "blank once trimmed is the empty description")

        let after = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }
        XCTAssertEqual(reported, 0)
        XCTAssertEqual(after?.updatedAt, "2026-01-01T00:00:00Z", "nothing was written")
    }

    func testSaveIntentTrimsBeforeComparingAndWriting() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.select(taskA)

        XCTAssertTrue(vm.saveIntent("\n  Ship the v2 endpoint \n"))
        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }
        XCTAssertEqual(stored?.intent, "Ship the v2 endpoint")
        XCTAssertEqual(reported, 1)

        XCTAssertTrue(vm.saveIntent("Ship the v2 endpoint\n"))
        XCTAssertEqual(reported, 1, "equal once trimmed: no second write")
    }

    // MARK: - Asks

    func testOpenAskGoesThroughShowAskWithThisWorkbench() async throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        var calls: [(Int64, Int64)] = []

        await vm.openAsk(42) { askID, projectID in
            calls.append((askID, projectID))
            return true
        }

        XCTAssertEqual(calls.map(\.0), [42])
        XCTAssertEqual(calls.map(\.1), [pid])
        XCTAssertNil(vm.errorMessage)
    }

    func testOpenAskOnAGoneAskShowsItInTheErrorRow() async throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)

        await vm.openAsk(42) { _, _ in false }

        XCTAssertEqual(vm.errorMessage, "This ask is gone.")
        XCTAssertEqual(vm.panelPath, [taskA], "the panel stays open")

        await vm.openAsk(42, show: { _, _ in false }, failure: { "Could not load the ask: disk I/O error" })
        XCTAssertEqual(vm.errorMessage, "Could not open the ask: Could not load the ask: disk I/O error",
                       "a read failure is named, not reported as gone")
    }

    func testSaveIntentFailureKeepsTheErrorAndReturnsFalse() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.select(taskA)
        try dbManager.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_intent_update BEFORE UPDATE OF intent ON targets
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        XCTAssertFalse(vm.saveIntent("Draft the owner keeps"))

        let error = try XCTUnwrap(vm.errorMessage)
        XCTAssertTrue(error.contains("disk full"), error)
        XCTAssertEqual(reported, 0)
        vm.load()
        XCTAssertEqual(vm.errorMessage, error, "a reload keeps the error")
    }

    func testSaveIntentForTheEditorsTargetAfterThePanelMovedOn() throws {
        let (pid, _, taskA, taskB) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported: [WorkbenchSubject] = []
        vm.onOwnerWrite = { _, subject in reported.append(subject) }
        vm.select(taskA)
        vm.select(taskB)

        XCTAssertTrue(vm.saveIntent("Written on A", for: taskA))

        let (storedA, storedB) = try dbManager.dbPool.read { db in
            (try TargetQueries.fetchByID(db, id: taskA), try TargetQueries.fetchByID(db, id: taskB))
        }
        XCTAssertEqual(storedA?.intent, "Written on A")
        XCTAssertEqual(storedB?.intent, "", "the open target is untouched")
        XCTAssertEqual(reported, [.target(Int64(taskA))])
        XCTAssertFalse(vm.saveIntent("Lost", for: 999_999), "a target not on the board writes nothing")
        let error = try XCTUnwrap(vm.errorMessage, "a draft that cannot be saved says why")
        XCTAssertTrue(error.contains("#999999"), error)
    }

    /// The editor's switch-save fails (the trigger fixture): the error is
    /// set after the panel moved on, so the owner sees why the draft stayed.
    func testAFailedSaveOnASwitchLeavesTheErrorSet() throws {
        let (pid, _, taskA, taskB) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)
        try dbManager.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_intent_update BEFORE UPDATE OF intent ON targets
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        vm.select(taskB)

        XCTAssertFalse(vm.saveIntent("Draft on A", original: "", for: taskA))

        let error = try XCTUnwrap(vm.errorMessage)
        XCTAssertTrue(error.contains("disk full"), error)
        XCTAssertEqual(vm.selectedTargetID, taskB)
    }

    func testSaveIntentWithNothingSelectedWritesNothing() throws {
        let (pid, _, _, _) = try seedGroup()
        let vm = makeVM(project: pid)
        XCTAssertFalse(vm.saveIntent("Lost"))
        XCTAssertNil(vm.errorMessage, "nothing open and no editor's target: silent")
    }

    // MARK: - Description: a newer description is never overwritten

    /// The agent's `update_target` lands while the editor is open.
    private func agentWritesIntent(_ text: String, on id: Int) throws {
        try dbManager.dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET intent = ?, updated_at = '2026-01-02T00:00:00Z' WHERE id = ?",
                           arguments: [text, id])
        }
    }

    func testAnUntouchedEditorNeverWritesItsSnapshotOverTheAgentsText() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.select(taskA)
        let opened = try XCTUnwrap(vm.selectedNode?.target.intent)
        try agentWritesIntent("Agent's newer text", on: taskA)
        vm.load()

        XCTAssertTrue(vm.saveIntent(opened, original: opened, for: taskA), "nothing to save is no failure")

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }
        XCTAssertEqual(stored?.intent, "Agent's newer text")
        XCTAssertEqual(stored?.updatedAt, "2026-01-02T00:00:00Z", "nothing was written")
        XCTAssertEqual(reported, 0)
        XCTAssertNil(vm.errorMessage)
    }

    func testAnEditedDraftOverANewerDescriptionIsRefusedAndKept() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        var reported = 0
        vm.onOwnerWrite = { _, _ in reported += 1 }
        vm.select(taskA)
        try agentWritesIntent("Agent's newer text", on: taskA)
        vm.load()

        XCTAssertFalse(vm.saveIntent("Owner's draft", original: "", for: taskA))

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }
        XCTAssertEqual(stored?.intent, "Agent's newer text")
        XCTAssertEqual(stored?.updatedAt, "2026-01-02T00:00:00Z")
        XCTAssertEqual(reported, 0)
        let error = try XCTUnwrap(vm.errorMessage)
        XCTAssertTrue(error.contains("changed while you were editing"), error)
    }

    func testAnEditedDraftOverAnUnchangedDescriptionSaves() throws {
        let (pid, _, taskA, _) = try seedGroup()
        let vm = makeVM(project: pid)
        vm.select(taskA)

        XCTAssertTrue(vm.saveIntent("Owner's draft", original: "", for: taskA))

        let stored = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: taskA) }
        XCTAssertEqual(stored?.intent, "Owner's draft")
    }
}

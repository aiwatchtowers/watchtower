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

        XCTAssertTrue(vm.saveIntent(""))
        XCTAssertEqual(reported, 0)
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

    func testSaveIntentWithNothingSelectedWritesNothing() throws {
        let (pid, _, _, _) = try seedGroup()
        let vm = makeVM(project: pid)
        XCTAssertFalse(vm.saveIntent("Lost"))
    }
}

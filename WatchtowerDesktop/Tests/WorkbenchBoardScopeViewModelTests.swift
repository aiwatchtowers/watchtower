import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Entering a group in `WorkbenchBoardViewModel` (spec 2026-10-06 Part 4):
/// `enterScope`, `leaveScope`, `scopePath`, remembered per workbench and
/// shared by Kanban and List.
@MainActor
final class WorkbenchBoardScopeViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WorkbenchBoardScopeViewModelTests-\(UUID().uuidString)"
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

    private struct Board {
        let project: Int64
        let plan: Int
        let feature: Int
        let deep: Int
        let leaf: Int
    }

    /// Plan › { Feature › { Task, Deep task }, Plan task }; Other › { Other task }.
    private func seedBoard() throws -> Board {
        try dbManager.dbPool.write { db -> Board in
            let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            let plan = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Plan")
            let feature = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Feature", parentID: plan)
            let deep = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Task", parentID: feature)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Deep task", parentID: feature)
            let leaf = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Plan task", parentID: plan)
            let other = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Other")
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Other task", parentID: other)
            return Board(project: pid, plan: Int(plan), feature: Int(feature), deep: Int(deep), leaf: Int(leaf))
        }
    }

    private func makeVM(project: Int64) -> WorkbenchBoardViewModel {
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: project, defaults: defaults)
        vm.load()
        return vm
    }

    func testEnteringAScopeIsRememberedAndSurvivesSwitchingListAndKanban() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.mode = .kanban
        vm.enterScope(board.feature)
        XCTAssertEqual(vm.scopePath.map(\.target.id), [board.plan, board.feature])
        XCTAssertEqual(vm.kanban.scopeID, board.feature)
        XCTAssertEqual(WorkbenchBoardPreferences(workbenchID: board.project, defaults: defaults).boardScopeID,
                       board.feature)

        vm.mode = .list
        XCTAssertEqual(vm.scopeNode?.target.id, board.feature)
        XCTAssertEqual(vm.rows.filter { $0.depth == 0 }.map(\.node.target.text), ["Task", "Deep task"],
                       "the List shows the scope's subtree")
        vm.mode = .kanban
        XCTAssertEqual(vm.kanban.scopeID, board.feature)

        let reopened = makeVM(project: board.project)
        XCTAssertEqual(reopened.scopePath.map(\.target.id), [board.plan, board.feature])
    }

    func testLeavingGoesUpOneLevelAtATime() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.enterScope(board.feature)

        vm.leaveScope()
        XCTAssertEqual(vm.scopePath.map(\.target.id), [board.plan], "depth 2 leaves to depth 1")
        vm.leaveScope()
        XCTAssertTrue(vm.scopePath.isEmpty)
        XCTAssertNil(vm.boardScopeID)
        vm.leaveScope()
        XCTAssertNil(vm.boardScopeID, "the board root has no level above")
        XCTAssertNil(WorkbenchBoardPreferences(workbenchID: board.project, defaults: defaults).boardScopeID)
    }

    func testAPathStepJumpsToThatLevel() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.enterScope(board.feature)
        vm.enterScope(board.plan)
        XCTAssertEqual(vm.scopePath.map(\.target.id), [board.plan])

        vm.enterScope(board.feature)
        vm.enterScope(nil)
        XCTAssertTrue(vm.scopePath.isEmpty, "Board: the whole board")
    }

    func testOnlyAGroupOnThisBoardIsEntered() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.enterScope(board.plan)
        for id in [board.leaf, board.deep, 9_999] {
            vm.enterScope(id)
            XCTAssertEqual(vm.boardScopeID, board.plan, "#\(id) is no group here")
        }
    }

    func testEnteringKeepsThePanelOpen() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.select(board.feature)
        vm.enterScope(board.feature)
        XCTAssertEqual(vm.selectedTargetID, board.feature)
    }

    func testAStaleRememberedScopeShowsTheBoardAndLeavesToIt() throws {
        let board = try seedBoard()
        WorkbenchBoardPreferences(workbenchID: board.project, defaults: defaults).boardScopeID = 9_999
        let vm = makeVM(project: board.project)
        XCTAssertTrue(vm.scopePath.isEmpty)
        XCTAssertNil(vm.scopeNode)
        XCTAssertNil(vm.kanban.scopeID)

        vm.leaveScope()
        XCTAssertNil(vm.boardScopeID)
    }

    /// The list's "Archive (K)" counts the archived targets under the scope,
    /// as Kanban's counts its archived cards there.
    func testTheListArchiveCountFollowsTheScope() throws {
        let (pid, feature) = try dbManager.dbPool.write { db -> (Int64, Int) in
            let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            let plan = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Plan")
            let feature = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Feature", parentID: plan)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Live", parentID: feature)
            let old = try TestDatabase.insertWorkbenchTarget(
                db, projectID: pid, text: "Old", status: "done", parentID: feature
            )
            let older = try TestDatabase.insertWorkbenchTarget(
                db, projectID: pid, text: "Older", status: "done", parentID: plan
            )
            try db.execute(
                sql: """
                    UPDATE target_status_history SET changed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-30 days')
                    WHERE target_id IN (?, ?)
                    """,
                arguments: [old, older]
            )
            return (pid, Int(feature))
        }
        let vm = makeVM(project: pid)
        vm.mode = .list
        XCTAssertEqual(vm.archivedCount, 2)
        vm.enterScope(feature)
        XCTAssertEqual(vm.archivedCount, 1, "only Old is under Feature")
    }

    func testTheEmptyBoardTextNeverAsksForAToggleThatIsOn() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        XCTAssertTrue(vm.emptyBoardText.contains("Turn on Show done"))
        vm.showDone = true
        XCTAssertFalse(vm.emptyBoardText.contains("Show done"))
        XCTAssertTrue(vm.emptyBoardText.contains("Turn on Archive"))
        vm.showArchived = true
        XCTAssertFalse(vm.emptyBoardText.contains("Turn on"))
    }
}

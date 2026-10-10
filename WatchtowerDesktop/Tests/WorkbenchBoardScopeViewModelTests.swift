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

    // MARK: - Esc

    func testEscClosesThePanelFirstThenLeavesOneLevel() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.enterScope(board.feature)
        vm.select(board.deep)

        XCTAssertTrue(vm.escape())
        XCTAssertNil(vm.selectedTargetID, "the panel closes")
        XCTAssertEqual(vm.scopeNode?.target.id, board.feature, "the scope stays")

        XCTAssertTrue(vm.escape())
        XCTAssertEqual(vm.scopeNode?.target.id, board.plan, "up one level")
        XCTAssertTrue(vm.escape())
        XCTAssertNil(vm.scopeNode)

        XCTAssertFalse(vm.escape(), "at the board root Esc does nothing")
        XCTAssertNil(vm.boardScopeID)
    }

    // MARK: - Lane header double-click (R15)

    func testEnteringALaneClosesThePanelItsFirstClickOpened() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.mode = .kanban
        vm.select(board.plan)

        XCTAssertTrue(vm.enterLane(board.plan))
        XCTAssertEqual(vm.scopeNode?.target.id, board.plan)
        XCTAssertNil(vm.selectedTargetID, "the group's panel the single click opened closes")

        vm.select(board.leaf)
        XCTAssertTrue(vm.enterLane(board.feature))
        XCTAssertEqual(vm.scopeNode?.target.id, board.feature)
        XCTAssertEqual(vm.selectedTargetID, board.leaf, "a panel on another target stays")
    }

    /// The contract the lane header's VoiceOver Open Group relies on:
    /// `enterScope` (unlike the double-click's `enterLane`) leaves a panel
    /// open on the group. The view wiring that picks `enterScope` for that
    /// action is not covered here — it is checked by hand.
    func testOpenGroupOnALaneKeepsThePanelOnTheGroup() throws {
        let board = try seedBoard()
        let vm = makeVM(project: board.project)
        vm.mode = .kanban
        vm.select(board.plan)

        XCTAssertTrue(vm.enterScope(board.plan))

        XCTAssertEqual(vm.scopeNode?.target.id, board.plan)
        XCTAssertEqual(vm.selectedTargetID, board.plan)
    }

    // MARK: - Archived groups

    /// Old › { Old task }, both done 30 days ago: archived (default 14 days).
    private func seedArchivedGroup(_ project: Int64) throws -> Int {
        try dbManager.dbPool.write { db -> Int in
            let group = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "Old", status: "done")
            let task = try TestDatabase.insertWorkbenchTarget(
                db, projectID: project, text: "Old task", status: "done", parentID: group
            )
            try db.execute(
                sql: """
                    UPDATE target_status_history SET changed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-30 days')
                    WHERE target_id IN (?, ?)
                    """,
                arguments: [group, task]
            )
            return Int(group)
        }
    }

    func testAnArchivedGroupIsRefusedWithAReasonWhileArchiveIsOff() throws {
        let board = try seedBoard()
        let old = try seedArchivedGroup(board.project)
        let vm = makeVM(project: board.project)

        XCTAssertFalse(vm.enterScope(old))
        XCTAssertNil(vm.boardScopeID)
        XCTAssertEqual(vm.errorMessage, "This group is archived. Turn on Archive to open it.")

        vm.dismissError()
        XCTAssertFalse(vm.enterScope(board.leaf), "a leaf is no group")
        XCTAssertNil(vm.errorMessage, "and no archived one either: nothing to say")

        vm.showArchived = true
        XCTAssertTrue(vm.enterScope(old))
        XCTAssertEqual(vm.scopeNode?.target.id, old)
    }

    /// R16: a scope entered under a search follows the stale rule once the
    /// search is cleared — an archived one shows the board root with Archive
    /// off, its id kept, and is back with Archive on.
    func testAnArchivedGroupEnteredDuringASearchFollowsTheStaleRuleAfterIt() throws {
        let board = try seedBoard()
        let old = try seedArchivedGroup(board.project)
        let vm = makeVM(project: board.project)
        vm.searchText = "old"

        XCTAssertTrue(vm.enterScope(old), "a search shows the archive, so the group opens")
        XCTAssertEqual(vm.scopePath.map(\.target.id), [old])
        XCTAssertNil(vm.errorMessage)

        vm.searchText = ""
        XCTAssertTrue(vm.scopePath.isEmpty, "Archive off and no search: the board root")
        XCTAssertNil(vm.scopeNode)
        XCTAssertNil(vm.kanban.scopeID)
        XCTAssertEqual(vm.boardScopeID, old, "the stale rule keeps the remembered id")

        vm.showArchived = true
        XCTAssertEqual(vm.scopeNode?.target.id, old)
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

import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Kanban lanes' state in `WorkbenchBoardViewModel` (spec 2026-10-06
/// Part 2): the Lanes switch, folded lanes and the per-lane Done fold.
@MainActor
final class WorkbenchBoardLanesViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WorkbenchBoardLanesViewModelTests-\(UUID().uuidString)"
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

    /// A group with one task and a loose top-level task: (project, group).
    private func seedBoard() throws -> (Int64, Int) {
        try dbManager.dbPool.write { db -> (Int64, Int) in
            let pid = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme-\(UUID().uuidString)")
            let group = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Group")
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Task", parentID: group)
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Loose")
            return (pid, Int(group))
        }
    }

    private func makeVM(project: Int64) -> WorkbenchBoardViewModel {
        let vm = WorkbenchBoardViewModel(dbPool: dbManager.dbPool, projectID: project, defaults: defaults)
        vm.load()
        return vm
    }

    private func preferences(_ project: Int64) -> WorkbenchBoardPreferences {
        WorkbenchBoardPreferences(workbenchID: project, defaults: defaults)
    }

    func testLanesModeDefaultsToLanesAndSwitchesToColumns() throws {
        let (pid, _) = try seedBoard()
        let vm = makeVM(project: pid)
        XCTAssertEqual(vm.lanesMode, .group)
        XCTAssertEqual(vm.kanbanLayout, .lanes)

        vm.lanesMode = .none
        XCTAssertEqual(vm.kanbanLayout, .columns)
        XCTAssertEqual(preferences(pid).lanesMode, .none)
        XCTAssertEqual(makeVM(project: pid).kanbanLayout, .columns, "the switch is remembered per workbench")
    }

    func testToggleLanePersistsThroughPreferences() throws {
        let (pid, group) = try seedBoard()
        let vm = makeVM(project: pid)
        XCTAssertEqual(vm.kanban.lanes.map(\.id), [group, 0])

        vm.toggleLane(group)
        vm.toggleLane(0)
        XCTAssertEqual(preferences(pid).foldedLanes, [group, 0])
        let reopened = makeVM(project: pid)
        XCTAssertEqual(reopened.foldedLaneIDs(in: reopened.kanban.lanes), [group, 0])

        reopened.toggleLane(group)
        XCTAssertEqual(preferences(pid).foldedLanes, [0])
        XCTAssertEqual(reopened.foldedLaneIDs(in: reopened.kanban.lanes), [0])
    }

    func testFoldedIDThatIsNoLongerALaneIsIgnoredButKept() throws {
        let (pid, group) = try seedBoard()
        let stale = 9_999
        preferences(pid).foldedLanes = [stale, group]
        let vm = makeVM(project: pid)
        XCTAssertEqual(vm.foldedLaneIDs(in: vm.kanban.lanes), [group])

        vm.toggleLane(group)
        XCTAssertEqual(vm.foldedLaneIDs(in: vm.kanban.lanes), [])
        XCTAssertEqual(preferences(pid).foldedLanes, [stale], "a stale id stays stored")
    }

    func testFoldingALaneKeepsStaleIDsStored() throws {
        let (pid, group) = try seedBoard()
        let stale = 9_999
        preferences(pid).foldedLanes = [stale]
        let vm = makeVM(project: pid)
        vm.toggleLane(group)
        XCTAssertEqual(preferences(pid).foldedLanes, [stale, group])
        XCTAssertEqual(vm.foldedLaneIDs(in: vm.kanban.lanes), [group])
    }

    /// Opening one lane's "✓ N done" leaves every other lane's Done folded.
    func testOneLanesDoneUnfoldLeavesTheOtherLanesFolded() throws {
        let (pid, group) = try seedBoard()
        try dbManager.dbPool.write { db in
            _ = try TestDatabase.insertWorkbenchTarget(
                db, projectID: pid, text: "Shipped", status: "done", parentID: Int64(group)
            )
            _ = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: "Loose done", status: "done")
        }
        let vm = makeVM(project: pid)
        vm.toggleLaneDone(group)

        let shown = Dictionary(uniqueKeysWithValues: vm.kanban.lanes.map { lane in
            let done = lane.columns.first { $0.status == "done" }
            let cards = done.map { lane.cards($0, unfolded: vm.unfoldedDoneLanes.contains(lane.id)) } ?? []
            return (lane.id, cards.map(\.node.target.text))
        })
        XCTAssertEqual(shown[group], ["Shipped"])
        XCTAssertEqual(shown[0], [], "No group's Done stays folded")
        XCTAssertEqual(vm.kanban.lanes.first { $0.id == 0 }?.doneCount, 1)
    }

    func testDoneUnfoldIsPerLaneAndNotRemembered() throws {
        let (pid, group) = try seedBoard()
        let vm = makeVM(project: pid)
        vm.toggleLaneDone(group)
        XCTAssertEqual(vm.unfoldedDoneLanes, [group])
        XCTAssertEqual(makeVM(project: pid).unfoldedDoneLanes, [], "session state only")
        vm.toggleLaneDone(group)
        XCTAssertEqual(vm.unfoldedDoneLanes, [])
    }
}

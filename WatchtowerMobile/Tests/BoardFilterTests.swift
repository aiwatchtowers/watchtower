import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The board tree and its filters (spec §4.3, §13 B2): Open, In progress,
/// Blocked and Archive over the demo board.
final class BoardFilterTests: XCTestCase {
    private let now = Date()

    private func board(_ filter: BoardFilter) throws -> BoardModel {
        BoardModel(workbenchID: DemoSeed.acmeID, snapshot: try demoSnapshot(now: now), filter: filter)
    }

    private func archivedIDs() throws -> Set<Int64> {
        Set(try demoSnapshot(now: now).targets.filter(\.archived).map(\.id))
    }

    func testTheFiltersInOrder() {
        XCTAssertEqual(BoardFilter.allCases.map(\.title), ["Open", "In progress", "Blocked", "Archive"])
    }

    func testArchiveShowsOnlyArchivedRecords() throws {
        let archive = try board(.archive)
        XCTAssertEqual(archive.visibleIDs, try archivedIDs())
        XCTAssertEqual(archive.visibleIDs, [390, 391, 417])
        // An archived child of a live group is a root here.
        XCTAssertEqual(Set(archive.roots.map(\.id)), [390, 391, 417])
    }

    func testTheOtherFiltersNeverShowArchivedRecords() throws {
        let archived = try archivedIDs()
        for filter in BoardFilter.allCases where filter != .archive {
            let visible = try board(filter).visibleIDs
            XCTAssertTrue(visible.isDisjoint(with: archived), "\(filter.title) shows an archived target")
            XCTAssertFalse(visible.isEmpty, "\(filter.title) is empty on the demo board")
        }
    }

    func testOpenKeepsTheTreeAndHidesDone() throws {
        let open = try board(.open)
        // The Mac's sibling order: priority, then status, then id.
        XCTAssertEqual(open.roots.map(\.id), [400, 430, 420, 431])
        let archiveGroup = try XCTUnwrap(open.roots.first { $0.id == 400 })
        XCTAssertEqual(archiveGroup.children.map(\.id), [415, 416], "the archived child stays under Archive")
        // A shown group keeps its done child, greyed, for context.
        let hierarchy = try XCTUnwrap(open.roots.first { $0.id == 420 })
        XCTAssertEqual(hierarchy.children.map(\.id), [421, 422])
        let done = try XCTUnwrap(hierarchy.children.last).row
        XCTAssertTrue(done.isDimmed)
        XCTAssertEqual(done.progressText, "done")
        XCTAssertFalse(try XCTUnwrap(hierarchy.children.first).row.isDimmed)
    }

    /// A done target with no shown parent stays out of Open, and the other
    /// filters keep no done children.
    func testDoneTargetsShowOnlyUnderAShownParentInOpen() throws {
        XCTAssertFalse(try board(.inProgress).visibleIDs.contains(422))
        XCTAssertEqual(try board(.blocked).roots.first?.children.map(\.id), [421])
        let website = BoardModel(workbenchID: DemoSeed.websiteID, snapshot: try demoSnapshot(now: now), filter: .open)
        XCTAssertEqual(website.visibleIDs, [500], "a top-level done target is not open")
    }

    /// Twin of Core's `WorkbenchBoardOrder` and Go's `boardSiblingOrder`.
    func testSiblingOrderIsPriorityThenStatusThenID() throws {
        func target(_ id: Int64, _ priority: String, _ status: String) throws -> WorkbenchTarget {
            try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(id, workbench: 1, ["priority": priority, "status": status]))
        }
        let targets = [
            try target(1, "low", "in_progress"),
            try target(2, "medium", "todo"),
            try target(3, "high", "todo"),
            try target(4, "medium", "in_progress"),
            try target(5, "medium", "blocked"),
            try target(6, "medium", "in_review"),
            try target(7, "high", "todo"),
            try target(8, "medium", "done")
        ]
        XCTAssertEqual(targets.sorted(by: BoardModel.boardOrder).map(\.id), [3, 7, 4, 6, 5, 2, 8, 1])
    }

    func testBlockedKeepsItsAncestorsForContext() throws {
        let blocked = try board(.blocked)
        XCTAssertEqual(blocked.roots.map(\.id), [420])
        XCTAssertEqual(blocked.roots.first?.children.map(\.id), [421])
    }

    func testFilterCountsMatchTheWorkbenchCounts() throws {
        let open = try board(.open)
        XCTAssertEqual(open.count(.open), 7)
        XCTAssertEqual(open.count(.inProgress), 3)
        XCTAssertEqual(open.count(.blocked), 1)
        XCTAssertNil(open.count(.archive), "the Archive chip carries no count")
    }

    func testATargetWithZeroChildrenHasNoDisclosure() throws {
        let open = try board(.open)
        let group = try XCTUnwrap(open.roots.first { $0.id == 400 })
        XCTAssertTrue(group.hasDisclosure)
        let leaf = try XCTUnwrap(group.children.first { $0.id == 416 })
        XCTAssertFalse(leaf.hasDisclosure)
        XCTAssertFalse(try XCTUnwrap(open.roots.first { $0.id == 431 }).hasDisclosure)
    }

    func testARowShowsAsksSessionPRPriorityAndProgress() throws {
        let open = try board(.open)
        let row = try XCTUnwrap(open.roots.first { $0.id == 400 }?.children.first { $0.id == 415 }).row
        XCTAssertEqual(row.title, "Archive Closed Targets Now")
        XCTAssertEqual(row.priorityLabel, "HIGH")
        XCTAssertEqual(row.priorityTone, .red)
        XCTAssertEqual(row.progressText, "50%")
        XCTAssertEqual(row.details.map(\.text), ["2 asks", "1 session", "PR #175"])
        XCTAssertEqual(row.details.first?.tone, .orange)

        let report = try XCTUnwrap(open.roots.first { $0.id == 430 }).row
        XCTAssertEqual(report.details.map(\.text), ["Session working"])
        XCTAssertEqual(report.details.first?.tone, .green)
        XCTAssertNil(report.priorityLabel, "medium is the default and carries no label")
    }

    func testTheTargetDetailIsReadOnlyAndComplete() throws {
        let snapshot = try demoSnapshot(now: now)
        let detail = try XCTUnwrap(BoardTargetDetailModel(targetID: 415, snapshot: snapshot, now: now))
        XCTAssertEqual(detail.title, "Archive Closed Targets Now")
        XCTAssertEqual(detail.statusLabel, "In progress")
        XCTAssertEqual(detail.intent, "Archive closed targets on demand from the header menu.")
        XCTAssertEqual(detail.sessions.map(\.id), [11])
        XCTAssertEqual(detail.asks.map(\.id), [111, 109])
        XCTAssertEqual(detail.comments.map(\.id), [80, 81])
        XCTAssertEqual(detail.comments.map(\.isReply), [false, true])
        XCTAssertNil(BoardTargetDetailModel(targetID: 999, snapshot: snapshot, now: now))

        let group = try XCTUnwrap(BoardTargetDetailModel(targetID: 400, snapshot: snapshot, now: now))
        XCTAssertEqual(group.children.map(\.id), [415, 416], "archived children stay out of the detail")
    }
}

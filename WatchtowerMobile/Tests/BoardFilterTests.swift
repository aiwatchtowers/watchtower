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
        XCTAssertEqual(open.roots.map(\.id), [400, 420, 430, 431])
        let archiveGroup = try XCTUnwrap(open.roots.first { $0.id == 400 })
        XCTAssertEqual(archiveGroup.children.map(\.id), [415, 416])
        let hierarchy = try XCTUnwrap(open.roots.first { $0.id == 420 })
        XCTAssertEqual(hierarchy.children.map(\.id), [421], "the done child is not open")
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

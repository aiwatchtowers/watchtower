import XCTest
@testable import WatchtowerCore

final class PendingSessionDeletesTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ id: Int64, workbench: Int64? = 1) -> PendingSessionDeletes.Entry {
        PendingSessionDeletes.Entry(sessionID: id, workbenchID: workbench, title: "Session \(id)")
    }

    func testAddRestartsTheDeadline() {
        var pending = PendingSessionDeletes()
        XCTAssertNil(pending.deadline)
        pending.enqueueSessionDelete(entry(1), now: start)
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(PendingSessionDeletes.window))
        pending.enqueueSessionDelete(entry(2), now: start.addingTimeInterval(3))
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(3 + PendingSessionDeletes.window))
        XCTAssertEqual(pending.batch.map(\.sessionID), [1, 2], "delete order")
        XCTAssertEqual(pending.ids, [1, 2])
        XCTAssertEqual(PendingSessionDeletes.window, 5)
    }

    func testToastTextCountsTheBatch() {
        var pending = PendingSessionDeletes()
        XCTAssertNil(pending.toastText)
        pending.enqueueSessionDelete(entry(1), now: start)
        XCTAssertEqual(pending.toastText, "Session deleted")
        pending.enqueueSessionDelete(entry(1), now: start)
        XCTAssertEqual(pending.toastText, "Session deleted", "the same session twice is one delete")
        pending.enqueueSessionDelete(entry(2), now: start)
        pending.enqueueSessionDelete(entry(3, workbench: nil), now: start)
        XCTAssertEqual(pending.toastText, "3 sessions deleted")
    }

    func testUndoReturnsTheWholeBatchAndClears() {
        var pending = PendingSessionDeletes()
        pending.enqueueSessionDelete(entry(1), now: start)
        pending.enqueueSessionDelete(entry(2), now: start)
        XCTAssertEqual(pending.restoreBatch(), [entry(1), entry(2)])
        XCTAssertTrue(pending.batch.isEmpty)
        XCTAssertNil(pending.deadline)
        XCTAssertNil(pending.toastText)
        XCTAssertEqual(pending.restoreBatch(), [], "nothing pending: nothing to restore")
    }

    func testExpireOnlyAfterTheDeadline() {
        var pending = PendingSessionDeletes()
        XCTAssertNil(pending.expiredBatch(now: start), "nothing pending")
        pending.enqueueSessionDelete(entry(1), now: start)
        XCTAssertNil(pending.expiredBatch(now: start.addingTimeInterval(4.9)))
        XCTAssertEqual(pending.ids, [1], "still pending before the deadline")
        XCTAssertEqual(pending.expiredBatch(now: start.addingTimeInterval(5)), [entry(1)])
        XCTAssertTrue(pending.ids.isEmpty)
        XCTAssertNil(pending.deadline)
    }

    func testTakeAllEmptiesTheBatch() {
        var pending = PendingSessionDeletes()
        pending.enqueueSessionDelete(entry(1), now: start)
        pending.enqueueSessionDelete(entry(2, workbench: nil), now: start)
        XCTAssertEqual(pending.takeBatch(), [entry(1), entry(2, workbench: nil)], "before the deadline too")
        XCTAssertEqual(pending, PendingSessionDeletes())
    }

    func testDropRemovesOnlyThatWorkbench() {
        var pending = PendingSessionDeletes()
        pending.enqueueSessionDelete(entry(1, workbench: 1), now: start)
        pending.enqueueSessionDelete(entry(2, workbench: 2), now: start)
        pending.enqueueSessionDelete(entry(3, workbench: nil), now: start)
        pending.discardBatch(workbenchID: 1)
        XCTAssertEqual(pending.batch.map(\.sessionID), [2, 3])
        XCTAssertNotNil(pending.deadline, "the rest of the batch keeps its window")
        pending.discardBatch(workbenchID: 2)
        XCTAssertEqual(pending.ids, [3])
        pending.enqueueSessionDelete(entry(4, workbench: 2), now: start)
        pending.discardBatch(workbenchID: 2)
        XCTAssertEqual(pending.ids, [3])
        XCTAssertNotNil(pending.deadline)
        var lone = PendingSessionDeletes()
        lone.enqueueSessionDelete(entry(5, workbench: 7), now: start)
        lone.discardBatch(workbenchID: 7)
        XCTAssertNil(lone.deadline, "an emptied batch has no deadline")
    }
}

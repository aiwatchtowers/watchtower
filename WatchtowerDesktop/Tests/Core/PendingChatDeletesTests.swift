import XCTest
@testable import WatchtowerCore

/// The Chats panel's quick delete (spec 2026-10-26 §5.3): one chat waits
/// at a time, another delete replaces it and hands it back to commit.
final class PendingChatDeletesTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ id: Int64) -> PendingChatDeletes.Entry {
        PendingChatDeletes.Entry(conversationID: id, title: "Chat \(id)")
    }

    func testTheWindowIsTheSessionsPanels() {
        XCTAssertEqual(PendingChatDeletes.window, PendingSessionDeletes.window)
        XCTAssertEqual(PendingChatDeletes.window, 5)
    }

    func testEnqueueHidesTheChatAndSetsTheDeadline() {
        var pending = PendingChatDeletes()
        XCTAssertNil(pending.toastText)
        XCTAssertNil(pending.deadline)
        XCTAssertEqual(pending.ids, [])
        XCTAssertNil(pending.enqueue(entry(1), now: start))
        XCTAssertEqual(pending.ids, [1])
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(5))
        XCTAssertEqual(pending.toastText, "Chat “Chat 1” deleted")
    }

    func testAnotherDeleteReplacesAndReturnsThePreviousToCommit() {
        var pending = PendingChatDeletes()
        _ = pending.enqueue(entry(1), now: start)
        XCTAssertEqual(pending.enqueue(entry(2), now: start.addingTimeInterval(3)), entry(1))
        XCTAssertEqual(pending.ids, [2])
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(8), "the window restarts")
        XCTAssertNil(pending.enqueue(entry(2), now: start.addingTimeInterval(4)), "the same chat twice is one delete")
    }

    func testExpiresOnlyAtTheDeadline() {
        var pending = PendingChatDeletes()
        _ = pending.enqueue(entry(1), now: start)
        XCTAssertNil(pending.expired(now: start.addingTimeInterval(4.9)))
        XCTAssertEqual(pending.ids, [1])
        XCTAssertEqual(pending.expired(now: start.addingTimeInterval(5)), entry(1))
        XCTAssertNil(pending.pending)
        XCTAssertNil(pending.deadline)
        XCTAssertNil(pending.expired(now: start.addingTimeInterval(10)), "nothing left")
    }

    func testUndoAndTakeClear() {
        var pending = PendingChatDeletes()
        _ = pending.enqueue(entry(1), now: start)
        XCTAssertEqual(pending.restore(), entry(1))
        XCTAssertNil(pending.toastText)
        XCTAssertNil(pending.restore(), "nothing to undo")
        _ = pending.enqueue(entry(2), now: start)
        XCTAssertEqual(pending.take(), entry(2), "taken before the deadline (tab left, quit)")
        XCTAssertNil(pending.deadline)
    }

    /// No ✕ (and no ⌘⌫ without the alert) while it answers or waits.
    func testQuickDeleteOnlyWhenNeitherAnsweringNorWaiting() {
        let quick = ChatPanelRowState.allCases.filter(\.allowsQuickDelete)
        XCTAssertEqual(quick, [.unread, .read])
    }
}

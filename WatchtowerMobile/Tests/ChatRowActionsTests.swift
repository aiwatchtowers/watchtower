import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A chat row's actions (iPhone chat spec §6.2, mockup 1j): Pin/Unpin and Rename go at once; Delete hides the row
/// behind a 5 s Undo bar and sends `chat_manage delete` only when the bar ends; Undo sends nothing.
@MainActor
final class ChatRowActionsTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var actions: ChatRowActions!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        let sleeper = try XCTUnwrap(sleeper)
        actions = ChatRowActions(sender: recorder.sender) { try await sleeper.sleep($0) }
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func sent() throws -> [ChatManageParams] {
        try recorder.sent.map {
            XCTAssertEqual($0.kind, .chatManage)
            return try ChatManageParams(wireParams: $0.params)
        }
    }

    func testUndoSendsNothingAndTheRowComesBack() async throws {
        actions.delete(7)
        XCTAssertEqual(actions.pendingDelete, 7)
        XCTAssertEqual(actions.hiddenIDs, [7])
        try await poll({ self.sleeper.waitingCount == 1 }, "the bar's timer runs")
        XCTAssertEqual(sleeper.requested, [.seconds(5)])

        actions.undo()
        XCTAssertNil(actions.pendingDelete)
        XCTAssertEqual(actions.hiddenIDs, [])
        try await poll({ self.sleeper.waitingCount == 0 }, "the timer was cancelled")
        sleeper.tick()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(recorder.sent.isEmpty, "Undo sends nothing")
    }

    func testTheDeleteGoesWhenTheBarEnds() async throws {
        actions.delete(7)
        try await poll({ self.sleeper.waitingCount == 1 }, "the bar's timer runs")
        XCTAssertTrue(recorder.sent.isEmpty, "nothing before the bar ends")
        sleeper.tick()
        try await poll({ !self.recorder.sent.isEmpty }, "the delete went")
        XCTAssertEqual(try sent(), [ChatManageParams(conversationID: 7, op: .delete)])
        XCTAssertNil(actions.pendingDelete, "the bar is gone")
        XCTAssertEqual(actions.hiddenIDs, [7], "the row stays hidden until the hub's list drops it")
        actions.prune(keeping: [7, 8])
        XCTAssertEqual(actions.hiddenIDs, [7])
        actions.prune(keeping: [8])
        XCTAssertEqual(actions.hiddenIDs, [])
    }

    func testASecondDeleteEndsTheFirstBarAtOnce() async throws {
        actions.delete(7)
        actions.delete(8)
        try await poll({ !self.recorder.sent.isEmpty }, "the first delete went")
        XCTAssertEqual(try sent().map(\.conversationID), [7])
        XCTAssertEqual(actions.pendingDelete, 8)
        XCTAssertEqual(actions.hiddenIDs, [7, 8])
    }

    func testADeleteThatCannotBeQueuedBringsTheRowBack() async throws {
        recorder.fails = true
        actions.delete(7)
        try await poll({ self.sleeper.waitingCount == 1 }, "the bar's timer runs")
        sleeper.tick()
        try await poll({ self.actions.failure != nil }, "the failure shows")
        XCTAssertEqual(actions.failure, "Couldn't send that. Try again.")
        XCTAssertEqual(actions.hiddenIDs, [])
    }

    func testPinAndUnpinGoAtOnce() async throws {
        await actions.togglePin(ChatFixture.conversation(3))
        await actions.togglePin(ChatFixture.conversation(4, pinned: true))
        XCTAssertEqual(try sent(), [
            ChatManageParams(conversationID: 3, op: .pin), ChatManageParams(conversationID: 4, op: .unpin)
        ])
        XCTAssertEqual(ChatRowActions.pinActionTitle(pinned: false), "Pin")
        XCTAssertEqual(ChatRowActions.pinActionTitle(pinned: true), "Unpin")
    }

    func testRenameNeverSendsAnEmptyOrUnchangedTitle() async throws {
        let chat = ChatFixture.conversation(3, "Q3 roadmap")
        await actions.rename(chat, to: "   ")
        await actions.rename(chat, to: " Q3 roadmap ")
        XCTAssertTrue(recorder.sent.isEmpty)
        await actions.rename(chat, to: "  Q3 roadmap, final  ")
        XCTAssertEqual(try sent(), [ChatManageParams(conversationID: 3, op: .rename, title: "Q3 roadmap, final")])
    }

    func testTheCopy() {
        XCTAssertEqual(ChatRowActions.undoText, "Chat deleted")
        XCTAssertEqual(ChatRowActions.undoAction, "Undo")
        XCTAssertEqual(ChatRowActions.renameTitle, "Rename")
        XCTAssertEqual(ChatRowActions.deleteTitle, "Delete")
        XCTAssertEqual(ChatRowActions.undoWindow, .seconds(5))
    }
}

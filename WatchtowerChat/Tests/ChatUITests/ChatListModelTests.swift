import ChatWire
import XCTest
@testable import ChatUI

@MainActor
final class ChatListModelTests: XCTestCase {
    private func list() -> ChatList {
        ChatList(conversations: [
            .init(id: 1, title: "One", updatedAt: ChatUIFixtures.date, state: .read),
            .init(id: 2, title: "Two", pinned: true, updatedAt: ChatUIFixtures.date, state: .unread),
        ])
    }

    func testListUndoDeleteSendsOnlyAfterUndoWindow() async {
        let client = FakeChatClient()
        let clock = ManualClock()
        let model = ChatListModel(client: client, clock: clock)
        model.store.apply(.snapshot(list()))

        model.delete(1)
        XCTAssertEqual(model.conversations.map(\.id), [2], "the row hides at once")
        XCTAssertTrue(client.ops.isEmpty, "nothing is sent inside the Undo window")
        model.undo()
        XCTAssertEqual(model.conversations.map(\.id), [1, 2])
        clock.fire()
        XCTAssertTrue(client.ops.isEmpty, "Undo sends nothing")

        model.delete(1)
        while clock.pendingSleeps == 0 { await Task.yield() }
        clock.fire()
        await model.pendingCommit?.value
        XCTAssertEqual(client.ops, [.manage(conversationID: 1, op: .delete, title: nil, projectID: nil)])
        XCTAssertNil(model.pendingDelete)
    }

    func testRefusedDeleteBringsTheRowBack() async {
        let client = FakeChatClient()
        let clock = ManualClock()
        let model = ChatListModel(client: client, clock: clock)
        model.store.apply(.snapshot(list()))
        client.respond { _ in .refused(code: "busy", message: "") }
        model.delete(1)
        while clock.pendingSleeps == 0 { await Task.yield() }
        clock.fire()
        await model.pendingCommit?.value
        XCTAssertEqual(model.conversations.map(\.id), [1, 2])
        XCTAssertEqual(model.notice, ChatListModel.deleteFailedLine)
    }

    func testStaleListStaysOnScreen() {
        let model = ChatListModel(client: FakeChatClient(), clock: ManualClock())
        model.store.apply(.snapshot(list()))
        model.store.apply(.resync)
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.conversations.count, 2, "no empty flash on resync")
    }

    func testPinTogglesAndRenameTrims() async {
        let client = FakeChatClient()
        let model = ChatListModel(client: client, clock: ManualClock())
        model.store.apply(.snapshot(list()))
        await model.pin(2)
        await model.rename(1, "  New name ")
        XCTAssertEqual(client.ops, [
            .manage(conversationID: 2, op: .unpin, title: nil, projectID: nil),
            .manage(conversationID: 1, op: .rename, title: "New name", projectID: nil),
        ])
    }

    func testRowContentByState() {
        let now = ChatUIFixtures.date.addingTimeInterval(120)
        let waiting = ChatListRowContent(.init(id: 1, title: "", updatedAt: ChatUIFixtures.date,
                                               project: .init(id: 1, name: "Q3"), state: .waiting), now: now)
        XCTAssertEqual(waiting.title, ChatListRowContent.untitled)
        XCTAssertEqual(waiting.detail, ChatListRowContent.waitingLine)
        XCTAssertNil(waiting.project, "a waiting row names what it waits for, not its project")
        XCTAssertEqual(waiting.age, "2m")
        let read = ChatListRowContent(.init(id: 2, title: "T", updatedAt: ChatUIFixtures.date, state: .read,
                                            lastLine: "last words"), now: now)
        XCTAssertEqual(read.detail, "last words")
        XCTAssertEqual(read.dot, .none)
    }

    func testSearchSnippetMarksAreBold() {
        let snippet = ChatSearchResultsView.snippet("a \u{2}word\u{3} here")
        XCTAssertEqual(String(snippet.characters), "a word here")
        let bold = snippet.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(bold.map { String(snippet[$0.range].characters) }, ["word"])
    }
}

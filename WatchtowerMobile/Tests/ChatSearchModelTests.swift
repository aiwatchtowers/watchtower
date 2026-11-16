import ChatWire
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Chats search (iPhone chat spec §6.2, mockup 1i): titles filter at once; `chat_search` goes after 300 ms of
/// no typing; "The Mac did not answer" after 30 s without a record; offline sends nothing. The debounce and the
/// patience run on a hand-stepped sleeper, never the wall clock.
@MainActor
final class ChatSearchModelTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var model: ChatSearchModel!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        let sleeper = try XCTUnwrap(sleeper)
        model = ChatSearchModel(sender: recorder.sender) { try await sleeper.sleep($0) }
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func sentQueries() throws -> [String] {
        try recorder.sent.map {
            XCTAssertEqual($0.kind, .chatSearch)
            return try ChatSearchParams(wireParams: $0.params).query
        }
    }

    private func waitForSleeps(_ count: Int) async throws {
        try await poll({ self.sleeper.waitingCount == count }, "\(count) sleeps waiting")
    }

    func testTheQueryGoesOnlyAfterTheDebounceWithNoTyping() async throws {
        model.setQuery("bil")
        try await waitForSleeps(1)
        XCTAssertEqual(sleeper.requested, [.milliseconds(300)])
        model.setQuery("billing")
        XCTAssertEqual(model.status(in: [:]), .idle, "no line while the debounce runs")
        // The first wait is cancelled and the second parked before the tick.
        try await poll({ self.sleeper.requested.count == 2 && self.sleeper.waitingCount == 1 }, "the debounce restarted")
        XCTAssertTrue(recorder.sent.isEmpty, "typing restarts the wait; nothing sent yet")

        sleeper.tick()
        try await poll({ !self.recorder.sent.isEmpty }, "the search was sent")
        XCTAssertEqual(try sentQueries(), ["billing"], "only the last query, once")
        XCTAssertEqual(model.status(in: [:]), .searching)
    }

    func testTheHubsRecordFillsInMessagesWithMessageHitsOnly() async throws {
        model.setQuery("  billing ")
        try await waitForSleeps(1)
        sleeper.tick()
        try await poll({ !self.recorder.sent.isEmpty }, "sent")
        XCTAssertEqual(try sentQueries(), ["billing"], "trimmed, as the record is named")
        let found = DemoSeed.Chat.search(now: ChatFixture.now)
        let status = model.status(in: ["billing": found])
        XCTAssertEqual(status, .results(found.hits.filter { $0.messageID != nil }))
        XCTAssertEqual(model.status(in: ["other": found]), .searching, "another query's record does not answer this one")
    }

    func testNoRecordWithinThirtySecondsIsNoAnswerAndRetryAsksAgain() async throws {
        model.setQuery("billing")
        try await waitForSleeps(1)
        sleeper.tick()
        try await waitForSleeps(1)
        XCTAssertEqual(sleeper.requested.last, .seconds(30))
        sleeper.tick()
        try await poll({ self.model.status(in: [:]) == .noAnswer }, "gave up")
        XCTAssertEqual(ChatText.noAnswer(.mac), "The Mac did not answer")

        model.retry()
        try await poll({ self.recorder.sent.count == 2 }, "asked again")
        XCTAssertEqual(try sentQueries(), ["billing", "billing"])
        XCTAssertEqual(model.status(in: [:]), .searching)
        // A record that comes after the give-up still answers.
        try await waitForSleeps(1)
        sleeper.tick()
        try await poll({ self.model.status(in: [:]) == .noAnswer }, "gave up again")
        XCTAssertEqual(model.status(in: ["billing": ChatSearch(query: "billing", hits: [])]), .results([]))
    }

    func testOfflineSearchesTitlesOnly() async throws {
        model.setOnline(false)
        model.setQuery("billing")
        try await waitForSleeps(1)
        sleeper.tick()
        try await poll({ self.model.status(in: [:]) == .offline }, "offline")
        XCTAssertTrue(recorder.sent.isEmpty, "nothing goes to an away Mac")
        XCTAssertEqual(ChatText.searchNeedsHub(.mac), "Searching messages needs your Mac")

        model.setOnline(true)
        try await poll({ self.recorder.sent.count == 1 }, "the held search goes once the Mac is back")
        XCTAssertEqual(model.status(in: [:]), .searching)
    }

    func testAnEmptyQueryAsksNothing() async throws {
        model.setQuery("   ")
        XCTAssertEqual(model.status(in: [:]), .idle)
        XCTAssertEqual(sleeper.waitingCount, 0)
        model.setQuery("a")
        try await waitForSleeps(1)
        model.setQuery("")
        try await poll({ self.sleeper.waitingCount == 0 }, "the debounce was cancelled")
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testASearchThatCannotBeQueuedIsNoAnswer() async throws {
        recorder.fails = true
        model.setQuery("billing")
        try await waitForSleeps(1)
        sleeper.tick()
        try await poll({ self.model.status(in: [:]) == .noAnswer }, "no answer")
    }

    func testTheQueryIsCutAtTheHubsLimitInScalars() {
        let long = String(repeating: "é", count: 150) + String(repeating: "a", count: 100)
        XCTAssertEqual(ChatSearchModel.wireQuery(long).unicodeScalars.count, 200)
    }

    func testSnippetMatchesAreBold() {
        let row = ChatHitRow(
            ChatSearch.Hit(conversationID: 2, title: "Q3", snippet: "…\u{2}Billing\u{3} v2 is on track…", messageID: 21, date: ChatFixture.now),
            now: ChatFixture.now
        )
        XCTAssertEqual(row.snippet, [
            .init(text: "…", isMatch: false), .init(text: "Billing", isMatch: true), .init(text: " v2 is on track…", isMatch: false)
        ])
        XCTAssertEqual(row.route, ChatRoute(id: 2, messageID: 21))
        XCTAssertEqual(row.age, "now")
    }

    /// Review fix 6: a hit of a chat under its Undo bar or deleted is left out.
    func testHitsOfHiddenChatsAreLeftOut() {
        let found = DemoSeed.Chat.search(now: ChatFixture.now).hits.filter { $0.messageID != nil }
        XCTAssertEqual(ChatHitRow.rows(found, hidden: [], now: ChatFixture.now).count, 2)
        XCTAssertEqual(ChatHitRow.rows(found, hidden: [2], now: ChatFixture.now).map(\.route.id), [100])
    }

    func testTheCopy() {
        XCTAssertEqual(ChatText.searching(.mac), "Searching on your Mac…")
        XCTAssertEqual(ChatListModel.titlesTitle, "Titles")
        XCTAssertEqual(ChatListModel.messagesTitle, "In messages")
        XCTAssertEqual(ChatListModel.searchPrompt, "Search chats")
    }
}

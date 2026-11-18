import ChatWire
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Entering the Chat tab: resume the last conversation within 2 h of its
/// last activity (or while a turn runs), otherwise the landing.
final class ChatLandingPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private typealias Last = ChatLandingPolicy.LastConversation

    private func last(
        id: Int64 = 7, idle: TimeInterval, archived: Bool = false, hasMessages: Bool = true, streaming: Bool = false
    ) -> Last {
        Last(id: id, updatedAt: now.addingTimeInterval(-idle), isArchived: archived,
             hasMessages: hasMessages, isStreaming: streaming)
    }

    private func decide(_ last: Last?, viewedAgo: TimeInterval? = nil) -> ChatLandingPolicy.Decision {
        ChatLandingPolicy.decide(last: last, lastViewedAt: viewedAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    /// ⌘N / New Chat follow the panel's project only while the panel is
    /// visible; a hidden panel's remembered level lands outside projects.
    func testANewChatFollowsTheProjectOnlyWhileThePanelIsVisible() {
        XCTAssertEqual(ChatLandingPolicy.newChatProject(level: .project(7), panelVisible: true), 7)
        XCTAssertNil(ChatLandingPolicy.newChatProject(level: .project(7), panelVisible: false))
        XCTAssertNil(ChatLandingPolicy.newChatProject(level: .all, panelVisible: true))
        XCTAssertNil(ChatLandingPolicy.newChatProject(level: .all, panelVisible: false))
    }

    func testResumeWindowIsTwoHours() {
        XCTAssertEqual(ChatLandingPolicy.resumeWindow, 2 * 60 * 60)
    }

    func testResumesInsideTheWindow() {
        XCTAssertEqual(decide(last(idle: 5 * 60)), .resume(7))
        XCTAssertEqual(decide(last(idle: 2 * 3600 - 1)), .resume(7))
    }

    func testLandsOutsideTheWindow() {
        XCTAssertEqual(decide(last(idle: 2 * 3600 + 1)), .landing)
        XCTAssertEqual(decide(last(idle: 3 * 86_400)), .landing)
    }

    func testExactlyAtTheBoundaryLands() {
        XCTAssertEqual(decide(last(idle: 2 * 3600)), .landing)
    }

    func testStreamingAlwaysResumesWhateverTheTime() {
        XCTAssertEqual(decide(last(idle: 5 * 3600, streaming: true)), .resume(7))
        XCTAssertEqual(decide(last(idle: 2 * 3600, streaming: true)), .resume(7))
    }

    /// Unsent text or attachments count as activity: resume whatever the time.
    func testUnsentInputResumesWhateverTheTime() {
        let stale = last(idle: 5 * 3600)
        XCTAssertEqual(ChatLandingPolicy.decide(last: stale, lastViewedAt: nil, hasUnsentInput: true, now: now), .resume(7))
        XCTAssertEqual(ChatLandingPolicy.decide(last: stale, lastViewedAt: nil, hasUnsentInput: false, now: now), .landing)
        // An empty project chat with a half-typed message is resumed, not lost to the landing.
        let emptyChat = last(idle: 5 * 3600, hasMessages: false)
        XCTAssertEqual(ChatLandingPolicy.decide(last: emptyChat, lastViewedAt: nil, hasUnsentInput: true, now: now),
                       .resume(7))
    }

    func testUnsentInputNeverResurrectsAGoneChat() {
        XCTAssertEqual(ChatLandingPolicy.decide(last: nil, lastViewedAt: nil, hasUnsentInput: true, now: now), .landing)
        XCTAssertEqual(ChatLandingPolicy.decide(last: last(idle: 60, archived: true), lastViewedAt: nil,
                                                hasUnsentInput: true, now: now), .landing)
    }

    func testNoLastConversationLands() {
        XCTAssertEqual(decide(nil), .landing)
        XCTAssertEqual(decide(nil, viewedAgo: 60), .landing)
    }

    func testArchivedLastConversationLandsEvenWhenFresh() {
        XCTAssertEqual(decide(last(idle: 60, archived: true)), .landing)
        XCTAssertEqual(decide(last(idle: 60, archived: true, streaming: true)), .landing)
    }

    /// An untouched "New Chat" has nothing to resume into.
    func testConversationWithoutMessagesLands() {
        XCTAssertEqual(decide(last(idle: 60, hasMessages: false)), .landing)
    }

    /// Having the conversation on screen counts as activity: reading an old
    /// chat and stepping away briefly comes back to it.
    func testRecentViewingExtendsTheWindow() {
        XCTAssertEqual(decide(last(idle: 3 * 86_400), viewedAgo: 10 * 60), .resume(7))
        XCTAssertEqual(decide(last(idle: 3 * 86_400), viewedAgo: 2 * 3600), .landing)
    }

    /// An older view stamp never shortens the window a newer message opened.
    func testOlderViewStampDoesNotShortenTheWindow() {
        XCTAssertEqual(decide(last(idle: 60), viewedAgo: 5 * 3600), .resume(7))
    }

    func testLastConversationSnapshotFromAListRow() {
        let empty = ChatList.Conversation(id: 1, title: "", updatedAt: now, state: .read)
        let full = ChatList.Conversation(id: 2, title: "Plan", updatedAt: now, state: .read)
        XCTAssertFalse(Last(empty, isStreaming: false).hasMessages, "a chat with a message has its title")
        XCTAssertTrue(Last(full, isStreaming: false).hasMessages)
        XCTAssertEqual(Last(full, isStreaming: false).updatedAt, now)
        XCTAssertFalse(Last(full, isStreaming: false).isArchived, "the engine lists no archived chat")
        XCTAssertTrue(Last(empty, isStreaming: true).isStreaming)
    }

    // MARK: - Recents

    private func conversations(_ rows: [(String, TimeInterval, Bool, Bool)]) -> [ChatList.Conversation] {
        rows.enumerated().map { index, row in
            let (title, age, pinned, hasMessages) = row
            return ChatList.Conversation(id: Int64(index + 1), title: hasMessages ? title : "", pinned: pinned,
                                         updatedAt: now.addingTimeInterval(-age), state: .read)
        }
    }

    func testRecentsPutPinnedFirstAndSkipEmptyChats() {
        let convs = conversations([
            ("old", 5000, false, true), ("new", 10, false, true), ("untouched", 1, false, false),
            ("pinned", 90_000, true, true)
        ])
        XCTAssertEqual(ChatLandingPolicy.recents(convs).map(\.title), ["pinned", "new", "old"])
    }

    func testRecentsAreCapped() {
        let rows = (0..<9).map { ("p\($0)", TimeInterval($0), true, true) }
            + (0..<9).map { ("r\($0)", TimeInterval($0), false, true) }
        let titles = ChatLandingPolicy.recents(conversations(rows)).map(\.title)
        XCTAssertEqual(titles, ["p0", "p1", "p2", "p3", "p4", "r0", "r1", "r2", "r3", "r4", "r5"])
    }

    func testRecentsOfNothingIsEmpty() {
        XCTAssertTrue(ChatLandingPolicy.recents([]).isEmpty)
    }
}

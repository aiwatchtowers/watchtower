import ChatWire
import XCTest
@testable import WatchtowerCore

final class ChatProjectSwitcherTests: XCTestCase {
    private typealias Presentation = ChatProjectSwitcherPresentation
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func summary(_ id: Int64, _ name: String, at: Double, unread: Int = 0, waiting: Int = 0, answering: Int = 0) -> Presentation.Summary {
        Presentation.Summary(
            id: id, name: name, lastActivity: Date(timeIntervalSince1970: at),
            unreadCount: unread, waitingCount: waiting, answeringCount: answering
        )
    }

    func testOrderLatestActivityFirstThenName() {
        let rows = [summary(1, "b", at: 10), summary(2, "a", at: 10), summary(3, "z", at: 50)]
        XCTAssertEqual(Presentation.ordered(rows).map(\.id), [3, 2, 1])
    }

    func testMatchingIsCaseAndDiacriticInsensitiveOnNameOnly() {
        let rows = [summary(1, "Café plans", at: 1), summary(2, "Other", at: 2)]
        XCTAssertEqual(Presentation.matching(rows, query: "CAFE").map(\.id), [1])
        XCTAssertEqual(Presentation.matching(rows, query: "  ").map(\.id), [1, 2])
        XCTAssertTrue(Presentation.matching(rows, query: "zzz").isEmpty)
    }

    func testSegmentsPluralsAndTones() {
        XCTAssertEqual(Presentation.segments(summary: summary(1, "a", at: 0, unread: 1), now: now),
                       [SwitcherSegment(text: "1 new answer", tone: .badge)])
        let all = Presentation.segments(summary: summary(1, "a", at: 0, unread: 2, waiting: 3, answering: 1), now: now)
        XCTAssertEqual(all, [
            SwitcherSegment(text: "2 new answers", tone: .badge),
            SwitcherSegment(text: "3 waiting for approval", tone: .warning),
            SwitcherSegment(text: "1 answering", tone: .secondary)
        ])
    }

    func testSegmentsFallBackToAge() {
        let old = now.timeIntervalSince1970 - 8 * 86400
        XCTAssertEqual(Presentation.segments(summary: summary(1, "a", at: old), now: now),
                       [SwitcherSegment(text: "8d", tone: .secondary)])
    }

    /// One row per listed project from the engine's list: its chats' states counted, the latest chat update, no
    /// age for a project without chats; a chat in the Undo window counts for nothing (spec §5.3).
    func testSummariesCountTheListsStates() {
        let a = ChatList.Project(id: 1, name: "A")
        let empty = ChatList.Project(id: 2, name: "Empty")
        func chat(_ id: Int64, _ state: ChatList.State, at: Double, project: ChatList.Project?) -> ChatList.Conversation {
            ChatList.Conversation(id: id, title: "t", updatedAt: Date(timeIntervalSince1970: at), project: project,
                                  state: state)
        }
        let list = ChatList(conversations: [
            chat(1, .unread, at: 201, project: a), chat(2, .waiting, at: 202, project: a),
            chat(3, .answering, at: 203, project: a), chat(4, .read, at: 204, project: nil)
        ], projects: [a, empty])
        let rows = Presentation.summaries(list)
        XCTAssertEqual(rows.map(\.id), [1, 2], "latest activity first; a project with no chat last")
        XCTAssertEqual(rows[0].unreadCount, 1)
        XCTAssertEqual(rows[0].waitingCount, 1)
        XCTAssertEqual(rows[0].answeringCount, 1)
        XCTAssertEqual(rows[0].lastActivity, Date(timeIntervalSince1970: 203), "a chat outside the project is ignored")
        XCTAssertEqual(rows[1].lastActivity, .distantPast)
        XCTAssertEqual(Presentation.segments(summary: rows[1], now: now), [], "no age without a chat")

        let hiding = Presentation.summaries(list, hiding: [1, 3])
        XCTAssertEqual(hiding[0].unreadCount, 0)
        XCTAssertEqual(hiding[0].answeringCount, 0)
        XCTAssertEqual(hiding[0].lastActivity, Date(timeIntervalSince1970: 202))
        XCTAssertTrue(Presentation.summaries(nil).isEmpty)
    }
}

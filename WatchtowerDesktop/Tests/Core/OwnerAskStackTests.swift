import XCTest
import GRDB
@testable import WatchtowerCore

final class OwnerAskStackTests: XCTestCase {
    private func ask(_ id: Int64, session: Int64?, minutesAgo: Double, status: String = "open") throws -> OwnerAsk {
        let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
        return try OwnerAsk(row: Row([
            "id": id, "project_id": 1, "session_id": session, "kind": "question", "title": "Ask \(id)",
            "status": status, "created_at": created
        ]))
    }

    func testOpenAsksAreOrderedByCreationThenID() throws {
        let stack = OwnerAskStack([
            try ask(3, session: 7, minutesAgo: 1),
            try ask(1, session: 8, minutesAgo: 5),
            try ask(2, session: nil, minutesAgo: 5),
            try ask(4, session: 7, minutesAgo: 9, status: "answered")
        ])
        XCTAssertEqual(stack.asks.map(\.id), [1, 2, 3], "oldest first, the id breaks a tie; answered asks are not waiting")
        XCTAssertEqual(stack.count, 3)
    }

    func testCountsPerSession() throws {
        let stack = OwnerAskStack([
            try ask(1, session: 7, minutesAgo: 3),
            try ask(2, session: 7, minutesAgo: 2),
            try ask(3, session: 8, minutesAgo: 1),
            try ask(4, session: nil, minutesAgo: 1)
        ])
        XCTAssertEqual(stack.count(session: 7), 2)
        XCTAssertEqual(stack.count(session: 8), 1)
        XCTAssertEqual(stack.count(session: 9), 0)
        XCTAssertEqual(stack.count(session: nil), 1)
    }

    func testSessionlessAsksAreOneGroupAfterTheSessions() throws {
        let stack = OwnerAskStack([
            try ask(1, session: nil, minutesAgo: 9),
            try ask(2, session: 8, minutesAgo: 5),
            try ask(3, session: 7, minutesAgo: 4),
            try ask(4, session: nil, minutesAgo: 3),
            try ask(5, session: 8, minutesAgo: 2)
        ])
        let groups = stack.groups
        XCTAssertEqual(groups.map(\.sessionID), [8, 7, nil], "sessions by their oldest ask; outside the app last")
        XCTAssertEqual(groups.map { $0.asks.map(\.id) }, [[2, 5], [3], [1, 4]])
        XCTAssertEqual(groups.map(\.isOutsideTheApp), [false, false, true])
        XCTAssertEqual(OwnerAskStack.outsideTheAppTitle, "Outside the app")
    }

    /// Board #364: a drawer opens by itself on the oldest ask of the first
    /// session on screen that holds an ask not closed yet.
    func testAskToOpenTakesTheFirstSessionOnScreenWithAnAskNotClosed() throws {
        let stack = OwnerAskStack([
            try ask(1, session: 7, minutesAgo: 9),
            try ask(2, session: 8, minutesAgo: 5),
            try ask(3, session: 7, minutesAgo: 4),
            try ask(4, session: nil, minutesAgo: 3)
        ])
        XCTAssertEqual(stack.askToOpen(sessionsOnScreen: [7, 8], dismissed: [])?.id, 1)
        XCTAssertEqual(stack.askToOpen(sessionsOnScreen: [8], dismissed: [])?.id, 2)
        XCTAssertEqual(stack.askToOpen(sessionsOnScreen: [7, 8], dismissed: [1, 3])?.id, 2, "session 7 was closed")
        XCTAssertEqual(stack.askToOpen(sessionsOnScreen: [7], dismissed: [1])?.id, 1,
                       "a new ask in a closed session opens the drawer on its oldest ask")
        XCTAssertNil(stack.askToOpen(sessionsOnScreen: [7], dismissed: [1, 3]))
        XCTAssertNil(stack.askToOpen(sessionsOnScreen: [9], dismissed: []), "no session of an ask on screen")
        XCTAssertNil(OwnerAskStack([try ask(4, session: nil, minutesAgo: 1)]).askToOpen(sessionsOnScreen: [7], dismissed: []),
                     "an ask filed outside the app never opens by itself")
        XCTAssertNil(OwnerAskStack([]).askToOpen(sessionsOnScreen: [7], dismissed: []))
    }

    func testNoAsksIsAnEmptyStack() {
        let stack = OwnerAskStack([])
        XCTAssertEqual(stack.count, 0)
        XCTAssertTrue(stack.groups.isEmpty)
    }

    func testPositionAndNextWalkTheWholeStackAndWrap() throws {
        let stack = OwnerAskStack([
            try ask(1, session: 7, minutesAgo: 3),
            try ask(2, session: 8, minutesAgo: 2),
            try ask(3, session: nil, minutesAgo: 1)
        ])
        XCTAssertEqual(stack.askPosition(of: 2), 2)
        XCTAssertNil(stack.askPosition(of: 9), "an ask no longer waiting has no place")
        XCTAssertEqual(stack.next(after: 1)?.id, 2, "the next ask may be another session's")
        XCTAssertEqual(stack.next(after: 3)?.id, 1, "past the last it wraps")
        XCTAssertEqual(stack.next(after: 9)?.id, 1, "from an ask no longer waiting, the oldest")
        XCTAssertNil(OwnerAskStack([try ask(1, session: 7, minutesAgo: 1)]).next(after: 1), "alone, nothing comes next")
    }
}

import XCTest
import GRDB
@testable import WatchtowerCore

/// `ask #N` / `ask N` in a session's terminal is a link to that ask (board
/// #500); the word "ask" on its own, the number on its own.
final class OwnerAskTerminalLinksTests: XCTestCase {
    private func ids(_ line: String) -> [Int64] {
        OwnerAskTerminalLinks.matches(in: line).map(\.askID)
    }

    func testAskWithOrWithoutTheHashIsALinkInAnyCase() {
        XCTAssertEqual(ids("answer ask #12 first"), [12])
        XCTAssertEqual(ids("answer ask 12 first"), [12])
        XCTAssertEqual(ids("Ask #12 is open"), [12])
        XCTAssertEqual(ids("ASK 7."), [7], "trailing punctuation is no part of the number")
        XCTAssertEqual(ids("(ask #3), ask #4"), [3, 4])
    }

    func testOnlyTheWholeWordAskFollowedByAWholeNumberIsALink() {
        XCTAssertEqual(ids("#12 is open"), [], "a number without the word ask")
        XCTAssertEqual(ids("task #12"), [], "ask inside another word")
        XCTAssertEqual(ids("flask 12"), [])
        XCTAssertEqual(ids("ask #12abc"), [], "the number runs into a word")
        XCTAssertEqual(ids("ask #12_3"), [])
        XCTAssertEqual(ids("asks #12"), [])
        XCTAssertEqual(ids("ask#12"), [], "the word and the number are apart")
        XCTAssertEqual(ids("ask #"), [])
        XCTAssertEqual(ids("ask #99999999999999999999"), [], "a number no ask id can be")
    }

    /// The link's span is in characters (one per terminal cell), so a hover
    /// at any cell of `ask #12` finds it, and only there.
    func testTheAskAtAColumn() {
        let line = "→ see ask #12 now"
        let start = 6
        XCTAssertNil(OwnerAskTerminalLinks.askID(inLine: line, at: start - 1))
        for column in start..<(start + 7) {
            XCTAssertEqual(OwnerAskTerminalLinks.askID(inLine: line, at: column), 12, "column \(column)")
        }
        XCTAssertNil(OwnerAskTerminalLinks.askID(inLine: line, at: start + 7))
        XCTAssertEqual(OwnerAskTerminalLinks.matches(in: line).map(\.range), [start..<(start + 7)])
        XCTAssertNil(OwnerAskTerminalLinks.askID(inLine: line, at: 99))
    }

    /// The hover card: the ask's title, then its kind and status.
    func testHoverCardNamesTitleKindAndStatus() throws {
        let ask = try OwnerAsk(row: Row([
            "id": 12, "project_id": 1, "kind": "check", "title": "Try the export", "payload": "{}",
            "status": "open", "withdrawn_reason": ""
        ]))
        XCTAssertEqual(OwnerAskTerminalLinks.cardDetail(ask), "#12 · Check · Waiting for you")
    }
}

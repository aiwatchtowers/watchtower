import XCTest
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

    /// A lookup answers only the hover it started for: leaving the link
    /// and coming back to the same ask while the first lookup runs leaves
    /// one card, not two.
    func testOnlyTheLatestHoverShowsItsCard() throws {
        var hover = OwnerAskTerminalLinks.Hover()
        let first = try XCTUnwrap(hover.enter(12))
        XCTAssertNil(hover.enter(12), "moving over the same link starts no second lookup")
        hover.leave()
        let second = try XCTUnwrap(hover.enter(12))
        XCTAssertFalse(hover.isCurrent(first), "the first lookup's answer is stale")
        XCTAssertTrue(hover.isCurrent(second))
        let other = try XCTUnwrap(hover.enter(13))
        XCTAssertFalse(hover.isCurrent(second), "another link makes it stale too")
        XCTAssertTrue(hover.isCurrent(other))
        hover.leave()
        XCTAssertFalse(hover.isCurrent(other))
        XCTAssertNil(hover.askID)
    }

    /// A click on a link: ⌘ opens at once; a plain click waits out a
    /// double click (which selects as usual) and never opens while the
    /// program in the terminal reports the mouse; a drag's selection or a
    /// double click opens nothing.
    func testWhatAClickOnALinkDoes() {
        typealias Links = OwnerAskTerminalLinks
        XCTAssertEqual(Links.click(clickCount: 1, command: true, selectionActive: false, mouseReporting: true), .openNow)
        XCTAssertEqual(Links.click(clickCount: 1, command: false, selectionActive: false, mouseReporting: false), .openAfterDoubleClick)
        XCTAssertEqual(Links.click(clickCount: 1, command: false, selectionActive: false, mouseReporting: true), .ignore)
        XCTAssertEqual(Links.click(clickCount: 2, command: false, selectionActive: false, mouseReporting: false), .ignore)
        XCTAssertEqual(Links.click(clickCount: 2, command: true, selectionActive: false, mouseReporting: false), .ignore)
        XCTAssertEqual(Links.click(clickCount: 1, command: false, selectionActive: true, mouseReporting: false), .ignore)
        XCTAssertEqual(Links.click(clickCount: 1, command: true, selectionActive: true, mouseReporting: false), .ignore)
    }
}

import XCTest
@testable import WatchtowerCore

/// The Files pane's back/forward stack (spec §8.2): a jump records where it
/// left from, back and forward walk the stack, a jump after back drops the
/// forward side, at most 100 entries.
final class NavigationHistoryTests: XCTestCase {
    private func at(_ path: String, _ line: Int, _ col: Int = 1) -> CodeNavLocation {
        CodeNavLocation(path: path, line: line, col: col)
    }

    func testANewHistoryGoesNowhere() {
        var history = CodeNavigationHistory()
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack(from: at("a.go", 1)))
        XCTAssertNil(history.goForward(from: at("a.go", 1)))
    }

    func testBackReturnsToTheExactLineAndColumnTheJumpLeftFrom() {
        var history = CodeNavigationHistory()
        history.recordJump(from: at("a.go", 12, 7))
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.goBack(from: at("b.go", 40, 3)), at("a.go", 12, 7))
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward(from: at("a.go", 12, 7)), at("b.go", 40, 3), "forward returns where back left from")
        XCTAssertFalse(history.canGoForward)
        XCTAssertTrue(history.canGoBack)
    }

    func testBackAndForwardWalkSeveralJumps() {
        var history = CodeNavigationHistory()
        history.recordJump(from: at("a", 1))
        history.recordJump(from: at("b", 2))
        history.recordJump(from: at("c", 3))
        XCTAssertEqual(history.goBack(from: at("d", 4)), at("c", 3))
        XCTAssertEqual(history.goBack(from: at("c", 3)), at("b", 2))
        XCTAssertEqual(history.goBack(from: at("b", 2)), at("a", 1))
        XCTAssertNil(history.goBack(from: at("a", 1)))
        XCTAssertEqual(history.goForward(from: at("a", 1)), at("b", 2))
        XCTAssertEqual(history.goForward(from: at("b", 2)), at("c", 3))
        XCTAssertEqual(history.goForward(from: at("c", 3)), at("d", 4))
        XCTAssertNil(history.goForward(from: at("d", 4)))
    }

    func testAJumpAfterBackDropsTheForwardSide() {
        var history = CodeNavigationHistory()
        history.recordJump(from: at("a", 1))
        history.recordJump(from: at("b", 2))
        _ = history.goBack(from: at("c", 3))
        XCTAssertTrue(history.canGoForward)
        history.recordJump(from: at("b", 9))
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(from: at("x", 1)), at("b", 9))
        XCTAssertEqual(history.goBack(from: at("b", 9)), at("a", 1))
    }

    func testTheStackKeepsTheLatest100() {
        var history = CodeNavigationHistory()
        for line in 1...130 { history.recordJump(from: at("f", line)) }
        XCTAssertEqual(CodeNavigationHistory.cap, 100)
        var visited: [Int] = []
        var current = at("f", 999)
        while let previous = history.goBack(from: current) {
            visited.append(previous.line)
            current = previous
        }
        XCTAssertEqual(visited, Array((31...130).reversed()))
    }

    func testForwardIsCappedToo() {
        var history = CodeNavigationHistory()
        for line in 1...150 { history.recordJump(from: at("f", line)) }
        var current = at("f", 999)
        while let previous = history.goBack(from: current) { current = previous }
        var steps = 0
        while let next = history.goForward(from: current) {
            current = next
            steps += 1
        }
        XCTAssertEqual(steps, 100)
        XCTAssertEqual(current, at("f", 999))
    }

    func testAJumpFromWhereTheLastOneLeftIsRecordedOnce() {
        var history = CodeNavigationHistory()
        history.recordJump(from: at("a", 5, 2))
        history.recordJump(from: at("a", 5, 2))
        XCTAssertEqual(history.goBack(from: at("b", 1)), at("a", 5, 2))
        XCTAssertFalse(history.canGoBack)
    }

    func testBackWithoutAKnownPositionLeavesNoForwardStep() {
        var history = CodeNavigationHistory()
        history.recordJump(from: at("a", 1))
        XCTAssertEqual(history.goBack(from: nil), at("a", 1))
        XCTAssertFalse(history.canGoForward)
    }

    func testBackFromThePlaceItWouldReturnToSkipsIt() {
        // The cursor already sits where the top entry points (the owner went
        // back by hand): back goes one further rather than nowhere.
        var history = CodeNavigationHistory()
        history.recordJump(from: at("a", 1))
        history.recordJump(from: at("b", 2))
        XCTAssertEqual(history.goBack(from: at("b", 2)), at("a", 1))
    }
}

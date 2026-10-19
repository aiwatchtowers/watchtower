import XCTest
@testable import WatchtowerCore

final class SessionChatPathTests: XCTestCase {
    private func sub(_ id: String) -> SessionFeedSubagent {
        SessionFeedSubagent(toolUseID: id, type: "t-\(id)")
    }

    func testPushPopPopTo() {
        var path = SessionChatPath()
        XCTAssertTrue(path.isRoot)
        path.pop()
        XCTAssertTrue(path.isRoot, "popping the root is a no-op")

        path.push(sub("a"))
        path.push(sub("b"))
        path.push(sub("c"))
        XCTAssertFalse(path.isRoot)
        XCTAssertEqual(path.stack.map(\.toolUseID), ["a", "b", "c"])

        path.pop()
        XCTAssertEqual(path.stack.map(\.toolUseID), ["a", "b"])

        path.popTo(level: 1)
        XCTAssertEqual(path.stack.map(\.toolUseID), ["a"])
        path.popTo(level: 5)
        XCTAssertEqual(path.stack.map(\.toolUseID), ["a"], "a level deeper than the path changes nothing")
        path.popTo(level: 0)
        XCTAssertTrue(path.isRoot)
        path.popTo(level: -1)
        XCTAssertTrue(path.isRoot)
    }
}

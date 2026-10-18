import XCTest
@testable import WatchtowerCore

final class SessionFeedWindowTests: XCTestCase {
    private func entries(_ n: Int) -> [SessionFeedEntry] {
        (0..<n).map { SessionFeedEntry(id: "e\($0)", kind: "agent") }
    }

    func testWindowShowsNewest120() {
        XCTAssertEqual(SessionFeedWindow().range(total: 700), 580..<700)
        XCTAssertEqual(SessionFeedWindow().range(total: 50), 0..<50)
    }

    func testGrowKeepsAnchor() {
        var w = SessionFeedWindow()
        let anchor = w.grow(entries: entries(700))
        XCTAssertEqual(anchor, "e580")
        XCTAssertEqual(w.range(total: 700), 460..<700)
    }

    func testWindowReachesStart() {
        var w = SessionFeedWindow()
        XCTAssertTrue(w.hasEarlier(total: 200))
        _ = w.grow(entries: entries(200))
        XCTAssertFalse(w.hasEarlier(total: 200))
        XCTAssertEqual(w.range(total: 200), 0..<200)
    }

    func testAppendWhileScrolledUpKeepsAnchor() {
        var w = SessionFeedWindow()
        w.following = false
        w.sync(total: 700)
        XCTAssertEqual(w.range(total: 700), 580..<700)
        w.sync(total: 705)
        XCTAssertEqual(w.range(total: 705), 580..<705)
        let anchor = w.grow(entries: entries(705))
        XCTAssertEqual(anchor, "e580")
        XCTAssertEqual(w.range(total: 705), 460..<705)
        w.following = true
        w.sync(total: 710)
        XCTAssertEqual(w.range(total: 710), 470..<710)
    }
}

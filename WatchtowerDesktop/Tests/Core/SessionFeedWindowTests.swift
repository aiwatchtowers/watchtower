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
        w.setFollowing(false, total: 700)
        XCTAssertEqual(w.range(total: 700), 580..<700)
        XCTAssertEqual(w.range(total: 705), 580..<705)
        let anchor = w.grow(entries: entries(705))
        XCTAssertEqual(anchor, "e580")
        XCTAssertEqual(w.range(total: 705), 460..<705)
        w.setFollowing(true, total: 705)
        XCTAssertEqual(w.range(total: 710), 470..<710)
    }

    func testLeavingFollowPinsWithoutSync() {
        var w = SessionFeedWindow()
        w.setFollowing(false, total: 700)
        XCTAssertEqual(w.range(total: 705).lowerBound, 580)
    }

    /// The loading row stays on screen when the content does not fill the
    /// viewport: `onAppear` never fires again, so the measure path grows it.
    func testShortContentNeedsFill() {
        let w = SessionFeedWindow()
        XCTAssertTrue(w.needsFill(total: 200, contentHeight: 300, viewportHeight: 600))
        XCTAssertFalse(w.needsFill(total: 200, contentHeight: 900, viewportHeight: 600), "content fills the viewport")
        XCTAssertFalse(w.needsFill(total: 50, contentHeight: 300, viewportHeight: 600), "nothing earlier to show")
        XCTAssertFalse(w.needsFill(total: 200, contentHeight: 300, viewportHeight: 0), "not laid out yet")
    }

    func testFillGrowsUntilStartOrFull() {
        var w = SessionFeedWindow()
        let all = entries(300)
        var rounds = 0
        while w.needsFill(total: all.count, contentHeight: Double(w.range(total: all.count).count), viewportHeight: 1000) {
            _ = w.grow(entries: all)
            rounds += 1
        }
        XCTAssertEqual(rounds, 2)
        XCTAssertFalse(w.hasEarlier(total: 300))
    }
}

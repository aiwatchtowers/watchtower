import XCTest
@testable import WatchtowerCore

/// The auto-scroll "is the user at the bottom" decision (Task P): a
/// streaming delta or a new message should only pull the viewport down while
/// this stays true, never yank the user back down after they scrolled up.
final class ChatAutoScrollPolicyTests: XCTestCase {
    func testConstant() {
        XCTAssertEqual(ChatAutoScrollPolicy.bottomThreshold, 40)
    }

    func testExactlyAtTheBottomIsAtBottom() {
        XCTAssertTrue(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 0))
    }

    func testNegativeDistanceOverscrollIsAtBottom() {
        XCTAssertTrue(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: -12))
    }

    func testWithinThresholdIsAtBottom() {
        XCTAssertTrue(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 40))
    }

    func testJustPastThresholdIsNotAtBottom() {
        XCTAssertFalse(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 40.01))
    }

    func testFarScrolledUpIsNotAtBottom() {
        XCTAssertFalse(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 400))
    }

    // MARK: - decide(wasFollowing:previous:current:)

    private typealias Metrics = ChatAutoScrollPolicy.Metrics

    /// A viewport 500 pt tall scrolled to the very bottom of 2000 pt of content.
    private let atBottom = Metrics(contentTop: -1500, contentHeight: 2000, viewportHeight: 500)

    private func decide(_ following: Bool, _ previous: Metrics?, _ current: Metrics)
        -> ChatAutoScrollPolicy.Decision {
        ChatAutoScrollPolicy.decide(wasFollowing: following, previous: previous, current: current)
    }

    /// The reported bug: one streamed paragraph taller than the threshold
    /// grows the content below a pinned viewport. The user never scrolled, so
    /// the view must keep following and pull itself down.
    func testStreamedGrowthTallerThanThresholdKeepsFollowingAndPulls() {
        let grown = Metrics(contentTop: -1500, contentHeight: 2120, viewportHeight: 500)
        XCTAssertEqual(decide(true, atBottom, grown), .init(following: true, pullToBottom: true))
    }

    func testSmallGrowthKeepsFollowingAndPulls() {
        let grown = Metrics(contentTop: -1500, contentHeight: 2010, viewportHeight: 500)
        XCTAssertEqual(decide(true, atBottom, grown), .init(following: true, pullToBottom: true))
    }

    /// A viewport that shrank (the composer grew) under a following view.
    func testViewportShrinkKeepsFollowingAndPulls() {
        let shrunk = Metrics(contentTop: -1500, contentHeight: 2000, viewportHeight: 420)
        XCTAssertEqual(decide(true, atBottom, shrunk), .init(following: true, pullToBottom: true))
    }

    /// After the pull lands, the view is at the bottom: follow, nothing to do.
    func testAtBottomAfterPullIsSettled() {
        let pulled = Metrics(contentTop: -1620, contentHeight: 2120, viewportHeight: 500)
        let grown = Metrics(contentTop: -1500, contentHeight: 2120, viewportHeight: 500)
        XCTAssertEqual(decide(true, grown, pulled), .init(following: true, pullToBottom: false))
    }

    /// Any real scroll up stops following — even one still inside the
    /// threshold, so the next delta never yanks the reader back down.
    func testScrollUpInsideThresholdStopsFollowing() {
        let up = Metrics(contentTop: -1490, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(true, atBottom, up), .init(following: false, pullToBottom: false))
    }

    func testFarScrollUpStopsFollowing() {
        let up = Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(true, atBottom, up), .init(following: false, pullToBottom: false))
    }

    /// Streaming continues while the user reads above: stay put.
    func testGrowthWhileScrolledUpStaysPut() {
        let reading = Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500)
        let grown = Metrics(contentTop: -800, contentHeight: 2300, viewportHeight: 500)
        XCTAssertEqual(decide(false, reading, grown), .init(following: false, pullToBottom: false))
    }

    /// Growth right after a small scroll up (distance still inside the
    /// threshold) must not re-pin — only a scroll DOWN near the bottom does.
    func testGrowthAfterSmallScrollUpDoesNotRepin() {
        let up = Metrics(contentTop: -1490, contentHeight: 2000, viewportHeight: 500)
        let grown = Metrics(contentTop: -1490, contentHeight: 2015, viewportHeight: 500)
        XCTAssertEqual(decide(false, up, grown), .init(following: false, pullToBottom: false))
    }

    /// Scrolling back down to within the threshold re-pins and snaps.
    func testScrollDownIntoThresholdRepins() {
        let reading = Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500)
        let near = Metrics(contentTop: -1470, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(false, reading, near), .init(following: true, pullToBottom: true))
    }

    func testScrollDownStillFarAboveStaysUnpinned() {
        let reading = Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500)
        let lower = Metrics(contentTop: -1200, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(false, reading, lower), .init(following: false, pullToBottom: false))
    }

    func testReachingTheExactBottomRepins() {
        let reading = Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(false, reading, atBottom), .init(following: true, pullToBottom: false))
    }

    /// The rubber band past the bottom springing back moves the content top
    /// down, but the bottom never left the viewport: not a scroll away.
    func testOverscrollSpringBackKeepsFollowing() {
        let overscrolled = Metrics(contentTop: -1560, contentHeight: 2000, viewportHeight: 500)
        let springing = Metrics(contentTop: -1530, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(true, overscrolled, springing), .init(following: true, pullToBottom: false))
    }

    /// Sub-epsilon jitter of the content top is not a scroll.
    func testLayoutJitterIsNotAScroll() {
        let jitter = Metrics(contentTop: -1499.5, contentHeight: 2030, viewportHeight: 500)
        XCTAssertEqual(decide(true, atBottom, jitter), .init(following: true, pullToBottom: true))
    }

    /// First measurement (conversation just opened): keep the starting state
    /// and land at the bottom.
    func testFirstMeasurementKeepsFollowingAndPulls() {
        let top = Metrics(contentTop: 0, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(true, nil, top), .init(following: true, pullToBottom: true))
    }

    func testFirstMeasurementNotFollowingStaysPut() {
        let top = Metrics(contentTop: 0, contentHeight: 2000, viewportHeight: 500)
        XCTAssertEqual(decide(false, nil, top), .init(following: false, pullToBottom: false))
    }

    /// Degenerate: content shorter than the viewport is always at the bottom.
    func testShortContentAlwaysFollowsWithoutPulling() {
        let short = Metrics(contentTop: 0, contentHeight: 200, viewportHeight: 500)
        XCTAssertEqual(decide(false, nil, short), .init(following: true, pullToBottom: false))
        XCTAssertEqual(decide(false, short, short), .init(following: true, pullToBottom: false))
    }

    /// Content shrinking at the bottom (a regenerated reply replaced) clamps
    /// the offset, moving the top down — the bottom is still on screen.
    func testShrinkAtBottomKeepsFollowing() {
        let shrunk = Metrics(contentTop: -1300, contentHeight: 1800, viewportHeight: 500)
        XCTAssertEqual(decide(true, atBottom, shrunk), .init(following: true, pullToBottom: false))
    }

    // MARK: - turnStarted(previousLiveMessageID:currentLiveMessageID:)

    /// Sending (or regenerate/edit/continue) starts a live turn: always re-pin.
    func testNewLiveTurnIsATurnStart() {
        XCTAssertTrue(ChatAutoScrollPolicy.turnStarted(previousLiveMessageID: nil, currentLiveMessageID: 7))
        XCTAssertTrue(ChatAutoScrollPolicy.turnStarted(previousLiveMessageID: 7, currentLiveMessageID: 9))
    }

    func testSameOrEndedLiveTurnIsNotATurnStart() {
        XCTAssertFalse(ChatAutoScrollPolicy.turnStarted(previousLiveMessageID: 7, currentLiveMessageID: 7))
        XCTAssertFalse(ChatAutoScrollPolicy.turnStarted(previousLiveMessageID: 7, currentLiveMessageID: nil))
        XCTAssertFalse(ChatAutoScrollPolicy.turnStarted(previousLiveMessageID: nil, currentLiveMessageID: nil))
    }
}

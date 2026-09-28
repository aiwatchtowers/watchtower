import XCTest
@testable import WatchtowerCore

/// The chat's "follow the latest content" decisions: a streaming delta, a
/// tool step or a new row pulls the viewport down only while following, and a
/// user who scrolled up is never yanked back down.
final class ChatAutoScrollPolicyTests: XCTestCase {
    private typealias Metrics = ChatAutoScrollPolicy.Metrics

    // MARK: - isAtBottom

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

    // MARK: - ChatFollowTracker

    /// A 500 pt viewport at the very bottom of 2000 pt of content.
    private let atBottom = Metrics(contentTop: -1500, contentHeight: 2000, viewportHeight: 500)

    /// A tracker that has already seen `first`.
    private func tracker(following: Bool = true, seen first: Metrics) -> ChatFollowTracker {
        var tracker = ChatFollowTracker(following: following)
        _ = tracker.observe(first)
        return tracker
    }

    /// Feeds a run of measurements; returns every pull decision.
    private func feed(_ tracker: inout ChatFollowTracker, _ run: [Metrics]) -> [Bool] {
        run.map { tracker.observe($0) }
    }

    /// The reported bug: streamed text taller than the threshold grows the
    /// content under a pinned viewport. The user never scrolled, so the view
    /// keeps following and pulls itself down after every chunk.
    func testStreamingRunKeepsFollowingAndPullsEveryGrowth() {
        var tracker = tracker(seen: atBottom)
        var run: [Metrics] = []
        var height: CGFloat = 2000
        var top: CGFloat = -1500
        for _ in 0..<5 {
            height += 120 // a streamed paragraph
            run.append(Metrics(contentTop: top, contentHeight: height, viewportHeight: 500))
            top = 500 - height // the pull lands at the new bottom
            run.append(Metrics(contentTop: top, contentHeight: height, viewportHeight: 500))
        }
        XCTAssertEqual(feed(&tracker, run), [true, false, true, false, true, false, true, false, true, false])
        XCTAssertTrue(tracker.following)
    }

    /// Tool steps and artifact blocks are growth like any other: a small one
    /// still pulls.
    func testSmallGrowthPulls() {
        var tracker = tracker(seen: atBottom)
        XCTAssertTrue(tracker.observe(Metrics(contentTop: -1500, contentHeight: 2010, viewportHeight: 500)))
        XCTAssertTrue(tracker.following)
    }

    /// The composer growing shrinks the viewport under a following view.
    func testViewportShrinkPulls() {
        var tracker = tracker(seen: atBottom)
        XCTAssertTrue(tracker.observe(Metrics(contentTop: -1500, contentHeight: 2000, viewportHeight: 420)))
    }

    /// Reviewer finding I1: a slow drag in sub-epsilon steps (0.6 pt per
    /// frame) must add up to a scroll away and never be pulled back — with or
    /// without anything streaming.
    func testSlowSubEpsilonDragUpAccumulatesAndNeverPulls() {
        var tracker = tracker(seen: atBottom)
        let run = (1...10).map { step in
            Metrics(contentTop: -1500 + 0.6 * CGFloat(step), contentHeight: 2000, viewportHeight: 500)
        }
        XCTAssertEqual(feed(&tracker, run), Array(repeating: false, count: 10))
        XCTAssertFalse(tracker.following)
    }

    /// Once the slow drag stopped following, streaming continues below the
    /// reader without pulling them back.
    func testGrowthAfterSlowDragStaysPut() {
        var tracker = tracker(seen: atBottom)
        _ = feed(&tracker, (1...5).map { Metrics(contentTop: -1500 + 0.6 * CGFloat($0), contentHeight: 2000, viewportHeight: 500) })
        let grown = (1...3).map { Metrics(contentTop: -1497, contentHeight: 2000 + 50 * CGFloat($0), viewportHeight: 500) }
        XCTAssertEqual(feed(&tracker, grown), [false, false, false])
        XCTAssertFalse(tracker.following)
    }

    /// A single real scroll up, even inside the threshold, stops following.
    func testScrollUpInsideThresholdStopsFollowing() {
        var tracker = tracker(seen: atBottom)
        XCTAssertFalse(tracker.observe(Metrics(contentTop: -1490, contentHeight: 2000, viewportHeight: 500)))
        XCTAssertFalse(tracker.following)
    }

    /// Streaming continues while the user reads far above: stay put.
    func testGrowthWhileReadingAboveStaysPut() {
        var tracker = tracker(seen: atBottom)
        let run = [
            Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500),
            Metrics(contentTop: -800, contentHeight: 2300, viewportHeight: 500),
            Metrics(contentTop: -800, contentHeight: 2600, viewportHeight: 500)
        ]
        XCTAssertEqual(feed(&tracker, run), [false, false, false])
        XCTAssertFalse(tracker.following)
    }

    /// Scrolling back down near the bottom re-pins; the next growth pulls.
    func testScrollDownIntoThresholdRepinsThenGrowthPulls() {
        var tracker = tracker(seen: atBottom)
        let run = [
            Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500),  // scrolled up
            Metrics(contentTop: -1470, contentHeight: 2000, viewportHeight: 500), // back down, 30 pt off
            Metrics(contentTop: -1470, contentHeight: 2100, viewportHeight: 500)  // growth
        ]
        XCTAssertEqual(feed(&tracker, run), [false, false, true])
        XCTAssertTrue(tracker.following)
    }

    func testScrollDownStillFarAboveStaysUnpinned() {
        var tracker = tracker(seen: atBottom)
        let run = [
            Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500),
            Metrics(contentTop: -1200, contentHeight: 2000, viewportHeight: 500)
        ]
        XCTAssertEqual(feed(&tracker, run), [false, false])
        XCTAssertFalse(tracker.following)
    }

    func testReachingTheExactBottomRepins() {
        var tracker = tracker(seen: atBottom)
        _ = tracker.observe(Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500))
        XCTAssertFalse(tracker.observe(atBottom))
        XCTAssertTrue(tracker.following)
    }

    /// The rubber band past the bottom springing back moves the content top
    /// down, but the bottom never left the viewport: not a scroll away.
    func testOverscrollSpringBackKeepsFollowing() {
        var tracker = tracker(seen: atBottom)
        let run = [
            Metrics(contentTop: -1560, contentHeight: 2000, viewportHeight: 500),
            Metrics(contentTop: -1530, contentHeight: 2000, viewportHeight: 500),
            atBottom
        ]
        XCTAssertEqual(feed(&tracker, run), [false, false, false])
        XCTAssertTrue(tracker.following)
    }

    /// Content shrinking at the bottom (a regenerated reply replaced) clamps
    /// the offset, moving the top down — the bottom is still on screen.
    func testShrinkAtBottomKeepsFollowing() {
        var tracker = tracker(seen: atBottom)
        XCTAssertFalse(tracker.observe(Metrics(contentTop: -1300, contentHeight: 1800, viewportHeight: 500)))
        XCTAssertTrue(tracker.following)
    }

    /// Degenerate: content shorter than the viewport is always at the bottom
    /// and never pulls.
    func testShortContentAlwaysFollowsWithoutPulling() {
        var tracker = ChatFollowTracker(following: false)
        let short = Metrics(contentTop: 0, contentHeight: 200, viewportHeight: 500)
        XCTAssertEqual(feed(&tracker, [short, short, Metrics(contentTop: 0, contentHeight: 300, viewportHeight: 500)]),
                       [false, false, false])
        XCTAssertTrue(tracker.following)
    }

    /// Degenerate: the same measurement again is not growth.
    func testRepeatedIdenticalMeasurementDoesNothing() {
        var tracker = tracker(seen: atBottom)
        let above = Metrics(contentTop: -1480, contentHeight: 2000, viewportHeight: 500)
        _ = tracker.observe(above)
        XCTAssertEqual(feed(&tracker, [above, above]), [false, false])
    }

    // MARK: Reset / repin

    /// A plain conversation switch: the first measurement lands at the bottom.
    func testResetFollowingFirstMeasurementPullsToBottom() {
        var tracker = tracker(following: false, seen: atBottom)
        tracker.reset(following: true)
        XCTAssertNil(tracker.lastMetrics)
        XCTAssertTrue(tracker.observe(Metrics(contentTop: 0, contentHeight: 2000, viewportHeight: 500)))
        XCTAssertTrue(tracker.following)
    }

    /// Reviewer finding I2: a jump to a message (⌘K hit) lands on it and does
    /// not follow — its first measurement, far from the bottom, must not pull.
    func testResetNotFollowingFirstMeasurementStaysOnTheMessage() {
        var tracker = tracker(seen: atBottom)
        tracker.reset(following: false)
        let hit = Metrics(contentTop: -600, contentHeight: 2000, viewportHeight: 500)
        let grown = Metrics(contentTop: -600, contentHeight: 2100, viewportHeight: 500)
        XCTAssertEqual(feed(&tracker, [hit, grown]), [false, false])
        XCTAssertFalse(tracker.following)
    }

    /// A send (or "Jump to latest") re-pins wherever the view is; the next
    /// growth pulls.
    func testRepinFollowsAgain() {
        var tracker = tracker(seen: atBottom)
        _ = tracker.observe(Metrics(contentTop: -800, contentHeight: 2000, viewportHeight: 500))
        XCTAssertFalse(tracker.following)
        tracker.repin()
        XCTAssertTrue(tracker.following)
        XCTAssertTrue(tracker.observe(Metrics(contentTop: -800, contentHeight: 2100, viewportHeight: 500)))
    }

    // MARK: - turnStarted

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

    // MARK: - threadChange

    private typealias State = ChatAutoScrollPolicy.ThreadState

    private func thread(_ conversation: Int64?, last: Int64?, target: Int64? = nil, live: Int64? = nil) -> State {
        State(conversationID: conversation, lastMessageID: last, scrollTarget: target, liveMessageID: live)
    }

    /// A ⌘K hit in another conversation switches AND targets in one update:
    /// the jump wins, so the view lands on the message, not at the bottom.
    func testSearchHitInAnotherConversationIsAJump() {
        let old = thread(1, last: 10)
        let new = thread(2, last: 20, target: 15)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: old, to: new), .jumpToMessage(15))
    }

    func testSearchHitInTheOpenConversationIsAJump() {
        let old = thread(1, last: 10)
        let new = thread(1, last: 10, target: 4)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: old, to: new), .jumpToMessage(4))
    }

    /// A plain switch leaves an earlier (stale) target untouched: it lands at
    /// the bottom, following.
    func testPlainSwitchWithStaleTargetIsASwitch() {
        let old = thread(2, last: 20, target: 15)
        let new = thread(3, last: 30, target: 15)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: old, to: new), .switchedConversation)
    }

    func testNewRowInTheSameConversation() {
        let old = thread(1, last: 10)
        let new = thread(1, last: 11)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: old, to: new), .newLastRow)
    }

    /// Degenerate: a cleared target or nothing changed is no scroll.
    func testClearedTargetOrNoChangeIsNone() {
        let state = thread(1, last: 10, target: 4)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: state, to: state), .none)
        let cleared = thread(1, last: 10)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: state, to: cleared), .none)
    }

    /// Verify finding V1: a ⌘K hit that switches into a conversation whose
    /// reply is still streaming changes the live turn in the same update —
    /// the jump still wins, so the view lands on the hit, not following.
    func testSearchHitIntoAStreamingConversationIsAJump() {
        let old = thread(1, last: 10)
        let new = thread(2, last: 21, target: 15, live: 21)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: old, to: new), .jumpToMessage(15))
    }

    /// A plain switch into a streaming conversation is a switch, not a turn start.
    func testPlainSwitchIntoAStreamingConversationIsASwitch() {
        let old = thread(1, last: 10, live: 9)
        let new = thread(2, last: 21, live: 21)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: old, to: new), .switchedConversation)
    }

    /// A genuine new turn in the same conversation (a send adds the owner row
    /// and the live reply in one update) re-pins.
    func testNewTurnInTheSameConversationIsATurnStart() {
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: thread(1, last: 10), to: thread(1, last: 12, live: 12)),
                       .turnStarted)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: thread(1, last: 12, live: 12),
                                                         to: thread(1, last: 14, live: 14)),
                       .turnStarted)
    }

    /// The live turn ending (same row, liveTurn → nil) is not a turn start.
    func testLiveTurnEndingIsNotATurnStart() {
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: thread(1, last: 12, live: 12), to: thread(1, last: 12)),
                       .none)
    }

    /// Verify finding R2: a ⌘K hit that mounts the thread view (opened from
    /// a project page) arrives as the initial state — it jumps.
    func testMountWithAPendingTargetIsAJump() {
        XCTAssertEqual(ChatAutoScrollPolicy.mountChange(thread(1, last: 10, target: 4)), .jumpToMessage(4))
    }

    /// A plain mount leaves landing to the tracker's first measurement.
    func testMountWithoutATargetIsNone() {
        XCTAssertEqual(ChatAutoScrollPolicy.mountChange(thread(1, last: 10, live: 10)), .none)
        XCTAssertEqual(ChatAutoScrollPolicy.mountChange(thread(nil, last: nil)), .none)
    }

    /// Verify finding V6: once the view consumes a jump (target cleared),
    /// reopening the same hit is a jump again.
    func testReopeningTheSameHitAfterConsumingIsAJumpAgain() {
        let jumped = thread(1, last: 10, target: 4)
        let consumed = thread(1, last: 10)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: jumped, to: consumed), .none)
        XCTAssertEqual(ChatAutoScrollPolicy.threadChange(from: consumed, to: jumped), .jumpToMessage(4))
    }
}

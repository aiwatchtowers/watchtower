import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class LiveTurnTests: XCTestCase {
    func testThrottlePublishesAtMostOncePerInterval() {
        var throttle = TextThrottle(interval: 1.0 / 30)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertTrue(throttle.shouldPublish(now: t0, length: 0))
        XCTAssertFalse(throttle.shouldPublish(now: t0.addingTimeInterval(0.01), length: 0))
        XCTAssertTrue(throttle.shouldPublish(now: t0.addingTimeInterval(0.05), length: 0))
    }

    /// A long streamed text publishes less often (its re-render costs more),
    /// never slower than the cap, and a short one keeps the base rate.
    func testThrottleStretchesWithTextLength() {
        let throttle = TextThrottle(interval: 1.0 / 30)
        XCTAssertEqual(throttle.interval(forLength: 0), 1.0 / 30)
        XCTAssertEqual(throttle.interval(forLength: 2_000), 1.0 / 30)
        XCTAssertEqual(throttle.interval(forLength: 10_000), 0.065, accuracy: 0.001)
        XCTAssertEqual(throttle.interval(forLength: 1_000_000), TextThrottle.maxInterval)

        var stretched = TextThrottle(interval: 1.0 / 30)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertTrue(stretched.shouldPublish(now: t0, length: 30_000))
        XCTAssertFalse(stretched.shouldPublish(now: t0.addingTimeInterval(0.1), length: 30_000))
        XCTAssertTrue(stretched.shouldPublish(now: t0.addingTimeInterval(0.2), length: 30_000))
    }

    /// Deltas inside one frame accumulate in `fullText`; the published `text`
    /// catches up via the trailing flush.
    func testDeltasAccumulateAndTrailingFlushPublishes() async {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date())
        let now = Date()
        turn.appendDelta("Hel", now: now)
        turn.appendDelta("lo", now: now)
        XCTAssertEqual(turn.fullText, "Hello")
        XCTAssertEqual(turn.text, "Hel", "the second delta is inside the same frame")
        let flushed = await waitForCondition { turn.text == "Hello" }
        XCTAssertTrue(flushed)
    }

    func testStepsStartAndFinish() {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date())
        let seq = turn.startStep(ChatToolStart(turnID: "t", id: "a", name: "get_jira_issue", argsJSON: "{}"), at: Date())
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(turn.startStep(ChatToolStart(turnID: "t", id: "a", name: "get_jira_issue", argsJSON: "{}"), at: Date()),
                       0, "a repeated tool_start reuses its step")
        turn.finishStep(ChatToolEnd(turnID: "t", id: "a", ok: false, summary: "nope", sources: []), at: Date())
        XCTAssertEqual(turn.steps.map(\.state), [.failed])
        XCTAssertEqual(turn.steps.first?.summary, "nope")
    }

    /// A tool_end without its tool_start is still a visible step (CHAT-02).
    func testOrphanToolEndStillShowsAStep() {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date())
        turn.finishStep(ChatToolEnd(turnID: "t", id: "z", ok: true, summary: "ok", sources: []), at: Date())
        XCTAssertEqual(turn.steps.map(\.id), ["z"])
        XCTAssertEqual(turn.steps.map(\.state), [.succeeded])
    }

    func testFinishPublishesFullTextAndStopsRunning() {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date())
        let now = Date()
        turn.appendDelta("a", now: now)
        turn.appendDelta("b", now: now)
        turn.finish(.complete, at: now)
        XCTAssertEqual(turn.text, "ab")
        XCTAssertFalse(turn.isRunning)
        XCTAssertEqual(turn.endedAt, now)
    }
}

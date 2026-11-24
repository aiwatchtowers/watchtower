import Foundation
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The browser probe's time bound (#2352): a probe with no answer within
/// `answerTimeout` is `unknown`, its turn is ended, and an answer after that
/// changes nothing. A test clock: nothing here waits on real time.
final class ConnectBrowserProbeTests: XCTestCase {
    private let harness = ConnectHarness(id: "harness-b", name: "Agent B", capability: .browser)
    private var ai = ScriptedAIService()
    private var clock = ConnectTestClock()

    override func setUp() async throws {
        ai = ScriptedAIService()
        clock = ConnectTestClock()
    }

    private func probing() -> Task<ConnectBrowserProbe.Answer, Never> {
        let probe = ConnectBrowserProbe(aiService: ai, clock: clock)
        return Task { [harness] in await probe.answer(for: harness, service: "slack") }
    }

    private func emitList(_ result: String) {
        ai.emit(.toolStart(ChatToolStart(turnID: "p", id: "probe", name: "claude-in-chrome:list_connected_browsers",
                                         argsJSON: "{}")),
                .toolEnd(ChatToolEnd(turnID: "p", id: "probe", ok: true, summary: result, sources: [])),
                call: 0)
    }

    /// The browser MCP server never answers: at the timeout the probe is
    /// `unknown` and its turn is torn down (the process is told to stop).
    func testNoAnswerWithinTheTimeoutIsUnknownAndEndsTheTurn() async {
        let task = probing()
        await ai.untilCalls(1)
        let early = await clock.sleepers(1, orAnswer: [task])
        XCTAssertNil(early, "the probe waits on its timer, not on an answer")
        clock.advance(by: ConnectBrowserProbe.answerTimeout - .seconds(1))
        XCTAssertEqual(clock.sleeperCount, 1, "not yet due")
        clock.advance(by: .seconds(1))
        let answer = await task.value
        XCTAssertEqual(answer, .unknown)
        XCTAssertEqual(ai.terminated, [true], "the probe's stream is cancelled: its process ends")
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    /// An answer after the timeout is never read: the stream is gone.
    func testLateAnswerAfterTheTimeoutChangesNothing() async {
        let task = probing()
        await ai.untilCalls(1)
        _ = await clock.sleepers(1, orAnswer: [task])
        clock.advance(by: ConnectBrowserProbe.answerTimeout)
        let answer = await task.value
        emitList(#"[{"id":"b1"}]"#)
        ai.finish(call: 0)
        XCTAssertEqual(answer, .unknown)
        XCTAssertEqual(ai.calls.count, 1, "no second probe")
    }

    /// An answer in time wins, and the timer goes with the probe: a later
    /// tick wakes nothing.
    func testAnswerInTimeCancelsTheTimer() async {
        let task = probing()
        await ai.untilCalls(1)
        _ = await clock.sleepers(1, orAnswer: [task])
        emitList(#"[{"id":"b1"}]"#)
        let answer = await task.value
        XCTAssertEqual(answer, .connected)
        XCTAssertEqual(clock.sleeperCount, 0, "the timer was cancelled")
        XCTAssertEqual(ai.terminated, [true])
        clock.advance(by: ConnectBrowserProbe.answerTimeout)
        XCTAssertEqual(ai.calls.count, 1)
    }

    /// A probe cancelled by its caller (Cancel, close, a new run) ends its
    /// turn and its timer at once, without waiting for the timeout.
    func testCancelledProbeEndsTurnAndTimer() async {
        let task = probing()
        await ai.untilCalls(1)
        _ = await clock.sleepers(1, orAnswer: [task])
        task.cancel()
        let answer = await task.value
        XCTAssertEqual(answer, .unknown)
        XCTAssertEqual(ai.terminated, [true])
        XCTAssertEqual(clock.sleeperCount, 0)
    }
}

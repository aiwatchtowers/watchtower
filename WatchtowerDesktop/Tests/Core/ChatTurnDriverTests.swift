import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The stream half of a turn: the session (`ai session --persist`) writes
/// the rows, so the driver only folds events into the live turn. The rows'
/// side of these behaviours is Go's (`cmd/ai_session_persist_test.go`,
/// `internal/chatstore`), CHAT-02's persistence guards included.
@MainActor
final class ChatTurnDriverTests: XCTestCase {
    private var clock = ChatTestClock()

    override func setUp() {
        clock = ChatTestClock()
    }

    private func makeDriver() -> ChatTurnDriver {
        let clock = self.clock
        return ChatTurnDriver(conversationID: 1) { clock.now }
    }

    func testTextStreamsAndTheTurnEndsAtTurnSaved() {
        let driver = makeDriver()
        var finished: LiveTurn?
        driver.onTurnFinished = { finished = $0 }
        let turn = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "Hel"))
        driver.apply(.textDelta(turnID: "t", text: "lo"))
        XCTAssertEqual(turn.fullText, "Hello")
        driver.apply(.usage(ChatUsage(turnID: "t", tokensIn: 3, tokensOut: 4, model: "model-b")))
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: "s9"))
        XCTAssertEqual(turn.phase, .complete)
        XCTAssertTrue(driver.isFinishing, "the session's last write is still under way")
        XCTAssertTrue(driver.isBusy)
        XCTAssertNil(finished)
        XCTAssertEqual(driver.sessionID, "s9")

        driver.apply(.turnSaved(turnID: "t"))
        XCTAssertNil(driver.liveTurn)
        XCTAssertFalse(driver.isBusy)
        XCTAssertEqual(finished?.messageID, 7)
    }

    /// CHAT-02's live side: a step shows as it starts and as it ends.
    func testToolStepsShowAsTheyHappen() {
        let driver = makeDriver()
        let turn = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "search_knowledge", argsJSON: "{}")))
        XCTAssertEqual(turn.steps.map(\.state), [.running])
        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "3 hits",
                                          sources: [ChatSource(kind: "slack", title: "x", url: nil, ref: "r")])))
        XCTAssertEqual(turn.steps.map(\.state), [.succeeded])
    }

    func testInterruptedAndExitedKeepTheStreamedText() {
        let driver = makeDriver()
        let first = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "part"))
        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        driver.apply(.turnSaved(turnID: "t"))
        XCTAssertEqual(first.phase, .interrupted)
        XCTAssertEqual(first.fullText, "part")

        let second = driver.begin(messageID: 8, turnID: "t2")
        driver.apply(.textDelta(turnID: "t2", text: "more"))
        driver.apply(.exited(status: 9, stderrTail: ""))
        XCTAssertEqual(second.phase, .interrupted)
        XCTAssertEqual(second.fullText, "more")
        XCTAssertNil(driver.liveTurn, "a dead session ends the turn at once")
    }

    func testErrorFailsTheTurnWithItsCode() {
        let driver = makeDriver()
        let turn = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.error(ChatSessionError(turnID: "t", code: .rateLimit, message: "slow", retryable: true)))
        guard case let .failed(error) = turn.phase else { return XCTFail("not failed: \(turn.phase)") }
        XCTAssertEqual(error.code, .rateLimit)
        XCTAssertEqual(error.message, "slow")
    }

    /// A lost turn (its conversation deleted, its lease taken): the session
    /// lets go of it before any end event; it ends here.
    func testTurnSavedBeforeItsEndEndsARunningTurn() {
        let driver = makeDriver()
        var calls = 0
        driver.onTurnFinished = { _ in calls += 1 }
        let turn = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "x"))
        driver.apply(.turnSaved(turnID: "t"))
        XCTAssertEqual(turn.phase, .interrupted)
        XCTAssertEqual(calls, 1)
        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        XCTAssertEqual(calls, 1, "a late end is ignored")
    }

    func testEventsForAnotherTurnAreIgnored() {
        let driver = makeDriver()
        driver.begin(messageID: 7, turnID: "t")
        driver.apply(.textDelta(turnID: "stale", text: "zzz"))
        driver.apply(.turnDone(turnID: "stale", status: .complete, sessionID: nil))
        driver.apply(.error(ChatSessionError(turnID: "stale", code: .internalError, message: "x", retryable: false)))
        driver.apply(.turnSaved(turnID: "stale"))
        XCTAssertEqual(driver.liveTurn?.fullText, "")
        XCTAssertEqual(driver.liveTurn?.isRunning, true)
    }

    /// A session-level error with no running turn is remembered, not dropped.
    func testSessionErrorWithoutATurnIsKept() {
        let driver = makeDriver()
        driver.apply(.error(ChatSessionError(turnID: nil, code: .auth, message: "login", retryable: false)))
        XCTAssertEqual(driver.lastSessionError?.code, .auth)
    }

    /// Degenerate: finishing with no turn is a no-op, and an ended turn
    /// finishes once.
    func testFinishWithoutARunningTurnIsANoOp() {
        let driver = makeDriver()
        var calls = 0
        driver.onTurnFinished = { _ in calls += 1 }
        driver.finishRunningAsPartial()
        XCTAssertEqual(calls, 0)
        let turn = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        driver.finishRunningAsPartial()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(turn.phase, .complete, "an ended turn is not cut afterwards")
        driver.apply(.turnSaved(turnID: "t"))
        XCTAssertEqual(calls, 1)
    }

    private func wait(_ id: String, action: Int64, turn: String = "t") -> ChatEvent {
        .toolWait(ChatToolWait(turnID: turn, id: id, actionID: action, message: "Waiting for your approval"))
    }

    /// CHAT-02: a call the gate holds for the owner's approval is a visible
    /// waiting step until its `tool_end`; a denied/timed-out one is a red
    /// step carrying the gate's reason, an approved one a normal step.
    /// Waiting is live only — the rows (Go's
    /// `TestChat02WaitingStepIsVisibleUntilItEnds`) see the usual start/end.
    /// BEHAVIOR CHAT-02 — see docs/inventory/chat.md
    func testChat02WaitingStepIsVisibleUntilItEnds() {
        let driver = makeDriver()
        let turn = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "mcp__claude_ai_Gmail__send", argsJSON: "{}")))
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "b", name: "mcp__claude_ai_Docs__create", argsJSON: "{}")))
        driver.apply(wait("a", action: 41))
        driver.apply(wait("b", action: 42))
        XCTAssertEqual(turn.steps.map(\.state), [.waiting(actionID: 41), .waiting(actionID: 42)])
        XCTAssertEqual(turn.steps.map(\.summary), ["Waiting for your approval", "Waiting for your approval"])
        XCTAssertEqual(turn.waitingActionIDs, [41, 42])

        clock.advance(5)
        driver.apply(.textDelta(turnID: "t", text: "still thinking"))
        XCTAssertEqual(turn.steps.first?.state, .waiting(actionID: 41), "a waiting step stays until its tool_end")

        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: false, summary: "not approved within 15 minutes",
                                          sources: [])))
        XCTAssertEqual(turn.steps[0].state, .failed)
        XCTAssertEqual(turn.steps[0].summary, "not approved within 15 minutes")
        XCTAssertEqual(turn.waitingActionIDs, [42], "the other call keeps waiting on its own")

        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "b", ok: true, summary: "created", sources: [])))
        XCTAssertEqual(turn.steps[1].state, .succeeded)
        XCTAssertEqual(turn.waitingActionIDs, [])
    }

    /// A new wait (not a repeat, not a late one) asks the action feeds to
    /// re-read: the session subprocess wrote the row the step points at.
    func testOnlyANewWaitAnnouncesItsAction() {
        let driver = makeDriver()
        var announced: [Int64] = []
        driver.onActionAwaited = { announced.append($0) }
        driver.begin(messageID: 7, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "x", argsJSON: "{}")))
        driver.apply(wait("a", action: 9))
        driver.apply(wait("a", action: 9))
        driver.apply(wait("b", action: 9, turn: "stale"))
        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "", sources: [])))
        driver.apply(wait("a", action: 9))
        XCTAssertEqual(announced, [9])
    }

    /// Degenerate waits: another turn's, a wait for a finished step (late,
    /// never reopens it), a repeated wait, and one whose start never arrived
    /// (still a visible step). A turn that ends while a call waits leaves no
    /// step claiming it still waits.
    func testToolWaitDegenerateCases() {
        let driver = makeDriver()
        let turn = driver.begin(messageID: 7, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "x", argsJSON: "{}")))
        driver.apply(wait("a", action: 1, turn: "stale"))
        XCTAssertEqual(turn.steps.first?.state, .running)

        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "done", sources: [])))
        driver.apply(wait("a", action: 1))
        XCTAssertEqual(turn.steps.first?.state, .succeeded, "a late wait never reopens a finished step")
        XCTAssertEqual(turn.steps.first?.summary, "done")

        driver.apply(wait("orphan", action: 2))
        driver.apply(wait("orphan", action: 2))
        XCTAssertEqual(turn.steps.count, 2, "a wait without its start is one visible step")
        XCTAssertEqual(turn.steps.last?.state, .waiting(actionID: 2))

        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "orphan", name: "late_name", argsJSON: #"{"k":1}"#)))
        XCTAssertEqual(turn.steps.last?.name, "late_name", "a start after its wait names the step")
        XCTAssertEqual(turn.steps.last?.state, .waiting(actionID: 2))

        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        XCTAssertEqual(turn.steps.last?.state, .running, "an ended turn's unfinished call reads as stopped")
        XCTAssertEqual(turn.waitingActionIDs, [])
    }

    /// The actual provider of a routed session shows from its session_ready.
    func testSessionReadyNamesTheActualProvider() {
        let driver = makeDriver()
        driver.apply(.sessionReady(sessionID: nil, provider: "codex", model: "gpt-x",
                                   routing: ChatRoutingMetadata(preferredProvider: "claude", mode: "preferred_reserve",
                                                                reason: "fallback")))
        XCTAssertEqual(driver.actualProvider, "codex")
        XCTAssertEqual(driver.actualModel, "gpt-x")
        XCTAssertEqual(driver.routing?.reason, "fallback")
    }
}

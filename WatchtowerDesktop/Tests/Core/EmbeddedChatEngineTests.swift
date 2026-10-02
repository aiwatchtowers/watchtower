import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class EmbeddedChatEngineTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var conversationID: Int64 = 0
    private var ai: ScriptedAIService!
    private var gate: EmbeddedStreamGate!
    private var clock = ChatTestClock()

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        conversationID = try pool.write { db in try TestDatabase.insertChatConversation(db, contextType: "idea") }
        ai = ScriptedAIService()
        gate = EmbeddedStreamGate(limit: 3)
        clock = ChatTestClock(now: Date())
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    // MARK: - Helpers

    private func spec(
        conversationID: Int64? = nil,
        toolAccess: ChatSurfaceSpec.ToolAccess = .draftOnly,
        postTurn: @escaping @MainActor (ChatPostTurnInput) -> ChatPostTurnResult = ChatPostTurnResult.identity
    ) -> ChatSurfaceSpec {
        let id = conversationID ?? self.conversationID
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "idea", contextID: "1", conversationID: id),
            persistence: .database(conversationID: id),
            toolAccess: toolAccess,
            systemPrompt: { "SYSTEM" },
            turnPrompt: { $0.isResumed ? "CONTEXT\n\n\($0.text)" : $0.text },
            postTurn: postTurn,
            emptyHint: "Ask about this idea"
        )
    }

    private func makeEngine(
        spec: ChatSurfaceSpec? = nil,
        store: EmbeddedChatStore? = nil,
        mirror: EmbeddedDraftMirror? = nil
    ) -> EmbeddedChatEngine {
        let spec = spec ?? self.spec()
        let clock = self.clock
        let store = store ?? DatabaseEmbeddedChatStore(dbPool: pool, conversationID: spec.key.conversationID ?? 0) {
            clock.now
        }
        return EmbeddedChatEngine(spec: spec, store: store, aiService: ai, gate: gate, draftMirror: mirror) { clock.now }
    }

    private func rows(_ id: Int64? = nil) throws -> [ChatMessageRecord] {
        let conv = id ?? conversationID
        return try pool.read { db in try ChatMessageQueries.fetchByConversation(db, conversationID: conv) }
    }

    private func waitIdle(_ engine: EmbeddedChatEngine) async -> Bool {
        await waitForCondition { !engine.isStreaming }
    }

    // MARK: - Full turn

    func testFullTurnStreamsIntoTheLiveRowAndCommitsTheReply() async throws {
        let engine = makeEngine()
        XCTAssertTrue(engine.send("What is this idea about?"))
        XCTAssertTrue(engine.isStreaming)
        XCTAssertEqual(try rows().map(\.role), ["user", "assistant"], "owner row on disk before any event")
        XCTAssertEqual(ai.calls.first?.systemPrompt, "SYSTEM")
        XCTAssertEqual(ai.calls.first?.prompt, "What is this idea about?")
        XCTAssertNil(ai.calls.first?.toolMode, "draft-only surface (AGENT-04)")
        XCTAssertEqual(ai.calls.first?.dbPath, pool.path)

        ai.emit(.sessionID("s1"), .text("It is "), .text("about X."))
        expectTrue(await waitForCondition { engine.liveTurn?.fullText == "It is about X." })
        let liveID = try XCTUnwrap(engine.liveTurn?.messageID)
        XCTAssertEqual(engine.messages.last?.message.text, "", "deltas never touch the rows")

        ai.emit(.turnComplete("It is about X."), .done)
        ai.finish()
        expectTrue(await waitIdle(engine))
        let reply = try XCTUnwrap(try rows().last)
        XCTAssertEqual(reply.id, liveID)
        XCTAssertEqual(reply.text, "It is about X.")
        XCTAssertEqual(reply.status, "complete")
        XCTAssertEqual(engine.messages.map(\.message.text), ["What is this idea about?", "It is about X."])
        let conv = conversationID
        let sessionID = try await pool.read { db in try ChatConversationQueries.fetchByID(db, id: conv)?.sessionID }
        XCTAssertEqual(sessionID, "s1")
    }

    func testResumedTurnSendsNoSystemPromptAndCarriesTheContext() async throws {
        let conv = conversationID
        try await pool.write { db in try ChatConversationQueries.updateSessionID(db, id: conv, sessionID: "old") }
        let engine = makeEngine()
        engine.send("again")
        XCTAssertNil(ai.calls.first?.systemPrompt)
        XCTAssertEqual(ai.calls.first?.sessionID, "old")
        XCTAssertEqual(ai.calls.first?.prompt, "CONTEXT\n\nagain")
    }

    func testTextIsFlushedAtMostOncePerInterval() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.emit(.text("a"))
        expectTrue(await waitForCondition { engine.liveTurn?.fullText == "a" })
        XCTAssertEqual(try rows().last?.text, "", "inside the flush interval")
        clock.advance(1.1)
        ai.emit(.text("b"))
        expectTrue(await waitForCondition { (try? self.rows().last?.text) == "ab" })
        XCTAssertEqual(try rows().last?.status, "partial", "a crash now keeps the partial text")
    }

    func testHundredDeltasLeaveTheRowsAlone() async throws {
        let engine = makeEngine()
        engine.send("q")
        let before = engine.messages
        for _ in 0..<100 { ai.emit(.text("x")) }
        expectTrue(await waitForCondition { engine.liveTurn?.fullText.count == 100 })
        XCTAssertEqual(engine.messages, before, "only the live row changes while streaming")
    }

    // MARK: - Stop / error / retry

    func testStopKeepsThePartialTextAndEndsTheProcess() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.emit(.text("half an ans"))
        expectTrue(await waitForCondition { engine.liveTurn?.fullText == "half an ans" })
        engine.stop()
        XCTAssertFalse(engine.isStreaming)
        let reply = try XCTUnwrap(try rows().last)
        XCTAssertEqual(reply.text, "half an ans")
        XCTAssertEqual(reply.status, "partial")
        expectTrue(await waitForCondition { self.ai.terminated.first == true }, "the ai query stream is torn down")
        XCTAssertFalse(engine.canRetry)
    }

    func testErrorEventKeepsPartialTextWithTheRealMessage() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.emit(.text("Partial"), .error("Not logged in · Please run /login"), .done)
        ai.finish()
        expectTrue(await waitIdle(engine))
        let reply = try XCTUnwrap(try rows().last)
        XCTAssertEqual(reply.status, "error")
        XCTAssertEqual(reply.text, "Partial")
        XCTAssertEqual(reply.errorCode, "auth")
        XCTAssertEqual(reply.errorMessage, "Not logged in · Please run /login")
        XCTAssertTrue(engine.canRetry)
    }

    func testThrownErrorBecomesAnErrorRow() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "claude crashed"))
        expectTrue(await waitIdle(engine))
        let reply = try XCTUnwrap(try rows().last)
        XCTAssertEqual(reply.status, "error")
        XCTAssertEqual(reply.errorCode, "internal")
        XCTAssertEqual(reply.errorMessage, "AI query failed (exit 1): claude crashed")
    }

    func testEmptyCompletedReplyIsAnError() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.emit(.done)
        ai.finish()
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(try rows().last?.status, "error")
        XCTAssertEqual(try rows().last?.errorMessage, EmbeddedChatEngine.emptyReplyMessage)
    }

    func testRetryRerunsTheTurnWithoutASecondOwnerRow() async throws {
        let engine = makeEngine()
        engine.send("the question")
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "boom"))
        expectTrue(await waitIdle(engine))

        engine.retry()
        XCTAssertEqual(ai.calls.count, 2)
        XCTAssertEqual(ai.calls[1].prompt, "the question")
        ai.emit(.text("answer"), call: 1)
        ai.finish(call: 1)
        expectTrue(await waitIdle(engine))
        let all = try rows()
        XCTAssertEqual(all.filter(\.isUser).count, 1, "the owner row is never written twice")
        XCTAssertEqual(all.map(\.status), ["complete", "error", "complete"])
        XCTAssertFalse(engine.canRetry)
    }

    func testRetryIsRefusedAfterASuccessfulTurn() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.emit(.text("fine"))
        ai.finish()
        expectTrue(await waitIdle(engine))
        engine.retry()
        XCTAssertEqual(ai.calls.count, 1)
    }

    // MARK: - postTurn

    func testPostTurnReplacesTheReplyAndAppendsNotices() async throws {
        var seen: ChatPostTurnInput?
        let engine = makeEngine(spec: spec { input in
            seen = input
            return ChatPostTurnResult(displayText: "(proposed 1 action(s))", notices: ["Applied: x"],
                                      failure: "Couldn't read one block")
        })
        engine.send("do it")
        ai.emit(.text("```watchtower-action {}```"))
        ai.finish()
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(seen?.reply, "```watchtower-action {}```")
        let all = try rows()
        XCTAssertEqual(all.map(\.role), ["user", "assistant", "system"])
        XCTAssertEqual(all[1].text, "(proposed 1 action(s))")
        XCTAssertEqual(all[2].text, "Applied: x")
        XCTAssertEqual(engine.postTurnResults[all[1].id]?.failure, "Couldn't read one block")
    }

    func testPostTurnNeverRunsOnAStoppedOrFailedTurn() async throws {
        var calls = 0
        let engine = makeEngine(spec: spec { calls += 1; return .identity($0) })
        engine.send("q")
        ai.emit(.text("partial directive"))
        expectTrue(await waitForCondition { engine.liveTurn?.fullText == "partial directive" })
        engine.stop()
        engine.send("q2")
        ai.finish(call: 1, throwing: WatchtowerAIError.exitCode(1, "x"))
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(calls, 0)
    }

    func testOnTurnFinishedReportsTheOutcome() async throws {
        var outcomes: [EmbeddedChatEngine.TurnOutcome] = []
        let engine = makeEngine()
        engine.onTurnFinished = { outcomes.append($0) }
        engine.send("q")
        ai.emit(.text("a"))
        ai.finish()
        expectTrue(await waitIdle(engine))
        guard case .completed = outcomes.first else { return XCTFail("\(outcomes)") }
    }

    // MARK: - Tool access

    func testActionSurfaceSendsItsToolMode() {
        let engine = makeEngine(spec: spec(toolAccess: .actions(surface: "target")))
        engine.send("q")
        let mode = ai.calls.first?.toolMode
        XCTAssertEqual(mode?.surface, "target")
        XCTAssertEqual(mode?.conversationID, conversationID)
        XCTAssertEqual(mode?.contextType, "idea")
    }

    // MARK: - Failures writing

    func testASendThatCannotBeSavedSendsNothingAndKeepsTheText() throws {
        let conv = conversationID
        let engine = makeEngine()
        try pool.write { db in try ChatConversationQueries.delete(db, id: conv) }
        engine.draft = "my words"
        XCTAssertTrue(engine.sendDraft())
        XCTAssertEqual(ai.calls.count, 0, "nothing goes out without the owner row")
        XCTAssertEqual(engine.draft, "my words")
        XCTAssertEqual(engine.bannerError, "This chat no longer exists.")
        XCTAssertFalse(engine.isBusy)
        XCTAssertEqual(gate.active.count, 0, "the slot is given back")
    }

    func testAFailedProgressWriteFailsTheTurnAndFreesTheSlot() async throws {
        let store = FlakyStore()
        var postTurnRan = false
        var outcome: EmbeddedChatEngine.TurnOutcome?
        let engine = makeEngine(spec: spec { postTurnRan = true; return .identity($0) }, store: store)
        engine.onTurnFinished = { outcome = $0 }
        engine.send("q")
        store.failProgress = true
        clock.advance(2)
        ai.emit(.text("lost"))
        expectTrue(await waitIdle(engine))
        let reply = try XCTUnwrap(engine.messages.last?.message)
        XCTAssertEqual(reply.status, "error")
        XCTAssertEqual(reply.errorCode, "internal")
        XCTAssertFalse(postTurnRan)
        guard case .failed = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(gate.active.count, 0)
        XCTAssertFalse(engine.canRetry, "a storage fault is not fixed by rerunning the AI turn")
        expectTrue(await waitForCondition { self.ai.terminated.first == true }, "the process is ended")
    }

    func testAFailedFinalWriteIsNotACompletedTurn() async throws {
        let store = FlakyStore()
        var outcome: EmbeddedChatEngine.TurnOutcome?
        let engine = makeEngine(store: store)
        engine.onTurnFinished = { outcome = $0 }
        engine.send("q")
        engine.sendFollowUp(prompt: "Action applied.")
        store.failFinalize = true
        ai.emit(.text("answer"))
        ai.finish()
        expectTrue(await waitIdle(engine))
        guard case .failed = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(engine.postTurnResults.isEmpty)
        XCTAssertEqual(ai.calls.count, 1, "no follow-up after a turn that was not saved")
        XCTAssertNotNil(engine.bannerError)
    }

    /// Actions applied for a reply that then cannot be saved are named in
    /// the error, which can be retried; the row is marked failed when the
    /// second write goes through.
    func testAnUnsavedReplyNamesWhatWasAlreadyApplied() async throws {
        let store = FlakyStore()
        var outcome: EmbeddedChatEngine.TurnOutcome?
        let engine = makeEngine(spec: spec { ChatPostTurnResult(displayText: $0.reply, applied: ["set status to done"]) },
                                store: store)
        engine.onTurnFinished = { outcome = $0 }
        engine.send("mark it done")
        store.failFinalizeOnce = true
        ai.emit(.text("Done."))
        ai.finish()
        expectTrue(await waitIdle(engine))
        guard case .failed(_, let message) = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(message.contains("Already applied: set status to done"))
        XCTAssertTrue(message.contains("Retry won't apply them again"))
        XCTAssertTrue(engine.canRetry)
        XCTAssertEqual(engine.messages.last?.message.status, "error", "the second write marked the row")
        XCTAssertEqual(engine.bannerError, message)
    }

    func testASessionIDThatCannotBeSavedFailsTheTurn() async throws {
        let store = FlakyStore()
        store.failSession = true
        let engine = makeEngine(store: store)
        engine.send("q")
        ai.emit(.sessionID("s1"))
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(engine.messages.last?.message.status, "error")
    }

    func testAFailedHistoryLoadBlocksSendingUntilItLoads() throws {
        let store = FlakyStore()
        store.failLoad = true
        let engine = makeEngine(store: store)
        XCTAssertNotNil(engine.bannerError)
        engine.draft = "hello"
        XCTAssertFalse(engine.sendDraft(), "a send would fork the stored provider session")
        XCTAssertEqual(engine.draft, "hello")
        XCTAssertTrue(ai.calls.isEmpty)
        store.failLoad = false
        XCTAssertTrue(engine.sendDraft())
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testBlankOrBusySendsAreRefused() {
        let engine = makeEngine()
        XCTAssertFalse(engine.send("   \n "))
        XCTAssertTrue(engine.send("first"))
        XCTAssertFalse(engine.send("second"), "one turn at a time")
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testAnInactiveTurnTimesOut() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.emit(.text("start"))
        expectTrue(await waitForCondition { engine.liveTurn?.fullText == "start" })
        clock.advance(601)
        engine.checkInactivity()
        XCTAssertFalse(engine.isStreaming)
        XCTAssertEqual(engine.messages.last?.message.status, "error")
        XCTAssertEqual(engine.messages.last?.message.text, "start")
        XCTAssertTrue(engine.canRetry)
        XCTAssertEqual(gate.active.count, 0)
    }

    func testAnActionSurfaceMayAnswerWithNoText() async throws {
        var seen: String?
        let engine = makeEngine(spec: spec(toolAccess: .actions(surface: "target")) {
            seen = $0.reply
            return ChatPostTurnResult(displayText: "(proposed 1 action(s))")
        })
        engine.send("do it")
        ai.finish()
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(seen, "")
        XCTAssertEqual(engine.messages.last?.message.status, "complete")
        XCTAssertEqual(engine.messages.last?.message.text, "(proposed 1 action(s))")
    }

    // MARK: - Queue

    func testTheFourthConcurrentTurnIsQueuedAndStartsWhenASlotFrees() async throws {
        var engines: [EmbeddedChatEngine] = []
        for index in 0..<4 {
            let conv = try await pool.write { db in try TestDatabase.insertChatConversation(db, contextType: "idea") }
            let engine = makeEngine(spec: spec(conversationID: conv))
            engines.append(engine)
            engine.send("q\(index)")
        }
        XCTAssertEqual(ai.calls.count, 3)
        let fourth = engines[3]
        XCTAssertTrue(fourth.isQueued)
        XCTAssertEqual(fourth.queuedText, "q3")
        XCTAssertTrue(try rows(fourth.spec.key.conversationID).isEmpty, "a queued turn writes nothing yet")

        ai.emit(.text("done"), call: 0)
        ai.finish(call: 0)
        expectTrue(await waitForCondition { self.ai.calls.count == 4 })
        XCTAssertFalse(fourth.isQueued)
        XCTAssertTrue(fourth.isStreaming)
        XCTAssertEqual(try rows(fourth.spec.key.conversationID).map(\.role), ["user", "assistant"])
    }

    func testStopOnAQueuedTurnPutsTheTextBackAndClearsTheMirror() throws {
        let mirror = MemoryDraftMirror()
        for _ in 0..<3 {
            let conv = try pool.write { db in try TestDatabase.insertChatConversation(db, contextType: "idea") }
            makeEngine(spec: spec(conversationID: conv)).send("busy")
        }
        let engine = makeEngine(mirror: mirror)
        engine.draft = "my question"
        engine.sendDraft()
        XCTAssertTrue(engine.isQueued)
        XCTAssertEqual(engine.draft, "")
        XCTAssertEqual(mirror.restore(for: engine.spec.key), "my question", "survives a restart as a draft")

        engine.stop()
        XCTAssertFalse(engine.isQueued)
        XCTAssertEqual(engine.draft, "my question")
        XCTAssertNil(mirror.restore(for: engine.spec.key))
        XCTAssertEqual(gate.waiting, 0)
    }

    func testAMirroredQueuedTextComesBackAsADraft() {
        let mirror = MemoryDraftMirror()
        mirror.save("left in the queue", for: spec().key)
        let engine = makeEngine(mirror: mirror)
        XCTAssertEqual(engine.draft, "left in the queue")
        XCTAssertNil(mirror.restore(for: engine.spec.key), "an ordinary draft from now on")
    }

    func testCancellingAQueuedTurnKeepsItsFollowUps() async throws {
        var fillers: [EmbeddedChatEngine] = []
        for _ in 0..<3 {
            let conv = try await pool.write { db in try TestDatabase.insertChatConversation(db, contextType: "idea") }
            let filler = makeEngine(spec: spec(conversationID: conv))
            filler.send("busy")
            fillers.append(filler)
        }
        let engine = makeEngine()
        engine.sendFollowUp(prompt: "Action applied: x.")
        XCTAssertTrue(engine.isQueued, "the follow-up waits for a slot")
        engine.stop()
        XCTAssertFalse(engine.isQueued)
        XCTAssertTrue(engine.hasPendingWork, "the follow-up is kept, never dropped")
        ai.finish(call: 0)
        expectTrue(await waitForCondition { !fillers[0].isStreaming })
        engine.send("next")
        XCTAssertEqual(ai.calls.last?.prompt, "Action applied: x.\n\nnext")
    }

    func testQuitNeverStartsAQueuedTurn() throws {
        let mirror = MemoryDraftMirror()
        gate = EmbeddedStreamGate(limit: 1)
        let pool = try XCTUnwrap(self.pool), ai = try XCTUnwrap(self.ai)
        let center = EmbeddedChatCenter(gate: gate) { spec, gate in
            let store = DatabaseEmbeddedChatStore(dbPool: pool, conversationID: spec.key.conversationID ?? 0)
            return EmbeddedChatEngine(spec: spec, store: store, aiService: ai, gate: gate, draftMirror: mirror)
        }
        let other = try pool.write { db in try TestDatabase.insertChatConversation(db, contextType: "idea") }
        let running = center.engine(for: spec(conversationID: other))
        running.send("running")
        let queued = center.engine(for: spec())
        queued.draft = "wait for me"
        queued.sendDraft()
        XCTAssertTrue(queued.isQueued)

        center.finishAllAsPartial()
        XCTAssertEqual(ai.calls.count, 1, "no process is started during termination")
        XCTAssertTrue(try rows().isEmpty, "no owner row for the queued text")
        XCTAssertEqual(mirror.restore(for: queued.spec.key), "wait for me", "it returns as a draft after restart")
    }

    // MARK: - Follow-ups and hidden prompts

    func testFollowUpWhileStreamingIsSentAfterTheTurnEnds() async throws {
        let engine = makeEngine()
        engine.send("q")
        engine.sendFollowUp(prompt: "Action applied: x.", notice: "Action applied: x")
        XCTAssertEqual(ai.calls.count, 1, "waits for the running turn")
        ai.emit(.sessionID("s1"), .text("ok"))
        ai.finish()
        expectTrue(await waitForCondition { self.ai.calls.count == 2 })
        XCTAssertEqual(ai.calls[1].prompt, "CONTEXT\n\nAction applied: x.")
        XCTAssertEqual(try rows().filter(\.isUser).count, 1, "a follow-up writes no owner row")
        XCTAssertTrue(try rows().contains { $0.role == "system" && $0.text == "Action applied: x" })
    }

    func testAFollowUpBehindAFailedTurnWaitsAndRetryStaysAvailable() async throws {
        let engine = makeEngine()
        engine.send("q")
        engine.sendFollowUp(prompt: "Action applied: x.")
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "boom"))
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(ai.calls.count, 1, "no follow-up on a session that just failed")
        XCTAssertTrue(engine.canRetry)
        XCTAssertTrue(engine.hasPendingWork)
        engine.retry()
        XCTAssertEqual(ai.calls[1].prompt, "Action applied: x.\n\nq", "Retry carries what waited")
        ai.emit(.text("ok"), call: 1)
        ai.finish(call: 1)
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(ai.calls.count, 2, "the follow-up went out once, with the retried turn")
        XCTAssertFalse(engine.hasPendingWork)
    }

    func testFollowUpsQueuedBehindAStoppedTurnRideTheNextOwnerTurn() async throws {
        let engine = makeEngine()
        engine.send("q")
        engine.sendFollowUp(prompt: "User rejected the action.")
        engine.stop()
        XCTAssertEqual(ai.calls.count, 1, "a stop never starts the queued follow-up")
        engine.send("next")
        XCTAssertEqual(ai.calls[1].prompt, "User rejected the action.\n\nnext")
    }

    func testHiddenPromptWritesNoOwnerRow() async throws {
        let engine = makeEngine(store: MemoryEmbeddedChatStore())
        engine.appendLocal(role: "assistant", text: "Do people report to you?")
        engine.sendHidden("The user completed the questionnaire.")
        XCTAssertEqual(engine.messages.map(\.message.role), ["assistant", "assistant"])
        XCTAssertNil(ai.calls.first?.dbPath, "a memory chat reads no workspace data")
    }

    // MARK: - Review round 2

    func testTheWatchdogEndsAnInactiveTurn() async throws {
        let engine = EmbeddedChatEngine(spec: spec(), store: MemoryEmbeddedChatStore(), aiService: ai, gate: gate,
                                        inactivityTimeout: 0.05) { self.clock.now }
        engine.send("q")
        clock.advance(10)
        expectTrue(await waitForCondition { !engine.isStreaming }, "the real watchdog task fires")
        XCTAssertEqual(engine.messages.last?.message.status, "error")
    }

    func testQuietShutdownStillShowsAnErrorThatIsNotContextGone() async throws {
        let store = FlakyStore()
        let engine = makeEngine(store: store)
        engine.send("q")
        store.failFinalize = true
        engine.shutdown(quietly: true)
        XCTAssertNotNil(engine.bannerError, "only \"not found\" is swallowed")
    }

    func testFollowUpsComeBackWhenTheirTurnCannotBeSaved() throws {
        let store = FlakyStore()
        let engine = makeEngine(store: store)
        store.failBegin = true
        engine.sendFollowUp(prompt: "Action applied: x.")
        XCTAssertTrue(engine.hasPendingWork)
        store.failBegin = false
        engine.send("next")
        XCTAssertEqual(ai.calls.last?.prompt, "Action applied: x.\n\nnext")
    }

    func testFollowUpsOfAFailedTurnRideItsRetry() async throws {
        let engine = makeEngine()
        engine.sendFollowUp(prompt: "Action applied: x.")
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "boom"))
        expectTrue(await waitIdle(engine))
        engine.sendFollowUp(prompt: "Action applied: y.")
        XCTAssertEqual(ai.calls.count, 1, "nothing runs on the session that just failed")
        engine.retry()
        XCTAssertEqual(ai.calls.last?.prompt, "Action applied: x.\nAction applied: y.")
    }

    func testAFailedSessionSaveIsRetriedOnTheNextEvent() async throws {
        let store = FlakyStore()
        store.failSession = true
        let engine = makeEngine(store: store)
        engine.send("q")
        ai.emit(.sessionID("s1"))
        expectTrue(await waitIdle(engine))
        store.failSession = false
        XCTAssertFalse(engine.canRetry, "a storage fault is not retried")
        engine.send("again")
        XCTAssertEqual(ai.calls.count, 2)
        XCTAssertNil(ai.calls.last?.sessionID, "the unsaved session is not resumed")
        ai.emit(.sessionID("s1"), call: 1)
        ai.emit(.text("ok"), call: 1)
        ai.finish(call: 1)
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(try store.loadSessionID(), "s1")
    }

    func testANoticeThatCannotBeSavedKeepsItsBanner() async throws {
        let store = FlakyStore()
        let engine = makeEngine(spec: spec { _ in ChatPostTurnResult(displayText: "a", notices: ["Applied: x"]) },
                                store: store)
        engine.send("q")
        store.failAppend = true
        ai.emit(.text("a"))
        ai.finish()
        expectTrue(await waitIdle(engine))
        XCTAssertNotNil(engine.bannerError, "not wiped by the completed turn it belongs to")
    }

    func testABannerRaisedDuringATurnSurvivesItsCompletion() async throws {
        let store = FlakyStore()
        let engine = makeEngine(store: store)
        engine.send("q")
        store.failAppend = true
        engine.sendFollowUp(prompt: "Action applied.", notice: "Applied: x")
        XCTAssertNotNil(engine.bannerError)
        store.failAppend = false
        ai.emit(.text("ok"))
        ai.finish()
        expectTrue(await waitForCondition { self.ai.calls.count == 2 })
        XCTAssertNotNil(engine.bannerError, "the unsaved notice belongs to this turn")
    }

    func testAStoppedTurnDoesNotSendItsFollowUpsAgain() async throws {
        let engine = makeEngine()
        engine.sendFollowUp(prompt: "Action applied: x.")
        engine.stop()
        engine.send("next")
        XCTAssertEqual(ai.calls.last?.prompt, "next", "the provider already has it")
    }

    func testAStopAfterAFailureLetsFollowUpsRunAgain() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "boom"))
        expectTrue(await waitIdle(engine))
        engine.send("again")
        engine.stop()
        engine.sendFollowUp(prompt: "Action applied: y.")
        XCTAssertEqual(ai.calls.last?.prompt, "Action applied: y.")
    }

    // MARK: - Lifecycle

    func testQuietShutdownMidStreamShowsNothing() async throws {
        let engine = makeEngine()
        engine.send("q")
        let conv = conversationID
        try await pool.write { db in try ChatConversationQueries.delete(db, id: conv) }
        engine.shutdown(quietly: true)
        XCTAssertFalse(engine.isBusy)
        XCTAssertNil(engine.bannerError)
        XCTAssertEqual(gate.active.count, 0)
    }

    func testFinishAsPartialKeepsTheStreamedText() async throws {
        let engine = makeEngine()
        engine.send("q")
        ai.emit(.text("so far"))
        expectTrue(await waitForCondition { engine.liveTurn?.fullText == "so far" })
        engine.finishAsPartial()
        XCTAssertEqual(try rows().last?.status, "partial")
        XCTAssertEqual(try rows().last?.text, "so far")
    }

    func testMemoryStoreRunsTheSameTurn() async throws {
        let engine = makeEngine(store: MemoryEmbeddedChatStore())
        engine.send("hello")
        ai.emit(.text("hi there"))
        ai.finish()
        expectTrue(await waitIdle(engine))
        XCTAssertEqual(engine.messages.map(\.message.text), ["hello", "hi there"])
        XCTAssertEqual(engine.messages.last?.message.status, "complete")
        XCTAssertTrue(try rows().isEmpty, "nothing reaches the database")
    }
}

@MainActor
final class MemoryDraftMirror: EmbeddedDraftMirror {
    private var drafts: [EmbeddedChatKey: String] = [:]
    func save(_ text: String, for key: EmbeddedChatKey) { drafts[key] = text }
    func clear(for key: EmbeddedChatKey) { drafts[key] = nil }
    func restore(for key: EmbeddedChatKey) -> String? { drafts[key] }
}

/// `XCTAssertTrue` for an awaited verdict — XCTest's autoclosures cannot await.
@MainActor
private func expectTrue(_ verdict: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(verdict, message, file: file, line: line)
}

/// A memory store whose reads and writes fail on demand.
@MainActor
private final class FlakyStore: EmbeddedChatStore {
    struct Failure: LocalizedError {
        var errorDescription: String? { "disk I/O error" }
    }

    private let base = MemoryEmbeddedChatStore()
    var failLoad = false
    var failBegin = false
    var failProgress = false
    var failFinalize = false
    /// Fails the next finalize only (a transient lock).
    var failFinalizeOnce = false
    var failSession = false
    var failAppend = false

    var dbPath: String? { nil }

    func loadMessages() throws -> [ChatMessageRecord] {
        if failLoad { throw Failure() }
        return try base.loadMessages()
    }

    func loadSessionID() throws -> String? {
        if failLoad { throw Failure() }
        return try base.loadSessionID()
    }

    func beginTurn(ownerText: String?, turnID: String, provider: String?) throws -> (ownerID: Int64?, assistantID: Int64) {
        if failBegin { throw Failure() }
        return try base.beginTurn(ownerText: ownerText, turnID: turnID, provider: provider)
    }

    func saveProgress(messageID: Int64, text: String) throws {
        if failProgress { throw Failure() }
        try base.saveProgress(messageID: messageID, text: text)
    }

    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) throws {
        if failFinalize { throw Failure() }
        if failFinalizeOnce {
            failFinalizeOnce = false
            throw Failure()
        }
        try base.finalize(messageID: messageID, text: text, status: status, errorCode: errorCode, errorMessage: errorMessage)
    }

    func append(role: String, text: String) throws -> Int64 {
        if failAppend { throw Failure() }
        return try base.append(role: role, text: text)
    }

    func saveSessionID(_ sessionID: String) throws {
        if failSession { throw Failure() }
        try base.saveSessionID(sessionID)
    }
}

@MainActor
final class EmbeddedChatEngineWillSendTests: XCTestCase {
    func testARefusedSendKeepsTheDraftAndStartsNothing() {
        let ai = ScriptedAIService()
        var allow = false
        var seen: [String] = []
        let spec = ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "target", contextID: "1", conversationID: nil),
            persistence: .memory, toolAccess: .draftOnly, systemPrompt: { "S" },
            willSend: { seen.append($0); return allow }, emptyHint: "")
        let engine = EmbeddedChatEngine(spec: spec, store: MemoryEmbeddedChatStore(), aiService: ai,
                                        gate: EmbeddedStreamGate())
        engine.draft = "  do it  "
        XCTAssertFalse(engine.sendDraft())
        XCTAssertEqual(engine.draft, "  do it  ")
        XCTAssertTrue(ai.calls.isEmpty)
        XCTAssertTrue(engine.messages.isEmpty)
        allow = true
        XCTAssertTrue(engine.sendDraft())
        XCTAssertEqual(seen, ["do it", "do it"], "the trimmed owner text")
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testAnActionSurfaceReplyWithNothingToShowIsAnError() async {
        let ai = ScriptedAIService()
        let spec = ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "target", contextID: "1", conversationID: nil),
            persistence: .memory, toolAccess: .actions(surface: "target"), systemPrompt: { "S" }, emptyHint: "")
        let engine = EmbeddedChatEngine(spec: spec, store: MemoryEmbeddedChatStore(), aiService: ai,
                                        gate: EmbeddedStreamGate())
        engine.send("q")
        ai.finish()
        let done = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(engine.messages.last?.message.status, "error")
    }
}

@MainActor
final class EmbeddedChatEngineSurfaceHookTests: XCTestCase {
    private func spec(mayContinue: @escaping @MainActor () -> Bool) -> ChatSurfaceSpec {
        ChatSurfaceSpec(key: EmbeddedChatKey(contextType: "target", contextID: "1", conversationID: nil),
                        persistence: .memory, toolAccess: .draftOnly, systemPrompt: { "S" },
                        mayContinue: mayContinue, emptyHint: "")
    }

    func testFollowUpsStopOnceTheSurfaceSaysItsContextIsGone() async {
        let ai = ScriptedAIService()
        var alive = true
        let engine = EmbeddedChatEngine(spec: spec { alive }, store: MemoryEmbeddedChatStore(), aiService: ai,
                                        gate: EmbeddedStreamGate())
        engine.send("q")
        engine.sendFollowUp(prompt: "Action applied.")
        alive = false
        ai.emit(.text("ok"))
        ai.finish()
        let done = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(ai.calls.count, 1, "no turn about a context that is gone")
        XCTAssertFalse(engine.hasPendingWork)
    }
}

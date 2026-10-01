import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class EmbeddedChatCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var ai: ScriptedAIService!
    private var clock = ChatTestClock()
    private var center: EmbeddedChatCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        ai = ScriptedAIService()
        clock = ChatTestClock(now: Date())
        let pool = try XCTUnwrap(self.pool), ai = try XCTUnwrap(self.ai), clock = self.clock
        center = EmbeddedChatCenter(idleTTL: 300, clock: { clock.now }, makeEngine: { spec, gate in
            let store: EmbeddedChatStore = spec.key.conversationID.map {
                DatabaseEmbeddedChatStore(dbPool: pool, conversationID: $0)
            } ?? MemoryEmbeddedChatStore()
            return EmbeddedChatEngine(spec: spec, store: store, aiService: ai, gate: gate) { clock.now }
        })
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func trackSpec(_ trackID: Int = 1) throws -> ChatSurfaceSpec {
        let conv = try pool.write { db in try TestDatabase.insertChatConversation(db, contextType: "track") }
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "track", contextID: String(trackID), conversationID: conv),
            persistence: .database(conversationID: conv), toolAccess: .draftOnly,
            systemPrompt: { "S" }, emptyHint: "")
    }

    func testTheSameKeyGivesTheSameEngine() throws {
        let spec = try trackSpec()
        let first = center.engine(for: spec)
        XCTAssertTrue(first === center.engine(for: spec))
        XCTAssertEqual(center.count, 1)
    }

    /// review-rules "Lifecycle & state": start → navigate away → return.
    func testAStreamSurvivesTheViewGoingAwayAndComingBack() async throws {
        let spec = try trackSpec()
        center.markShown(spec.key)
        let engine = center.engine(for: spec)
        engine.send("What changed?")
        center.markHidden(spec.key)
        clock.advance(3600)
        center.sweep()
        XCTAssertTrue(center.loaded(spec.key) === engine, "a busy engine is never released")

        ai.emit(.text("Two things."))
        ai.finish()
        center.markShown(spec.key)
        let back = center.engine(for: spec)
        XCTAssertTrue(back === engine)
        expectTrue(await waitForCondition { !back.isStreaming })
        XCTAssertEqual(back.messages.last?.message.text, "Two things.")
    }

    func testSweepReleasesOnlyIdleHiddenEnginesPastTheTTL() throws {
        let hidden = try trackSpec(1), shown = try trackSpec(2), recent = try trackSpec(3)
        _ = center.engine(for: hidden)
        _ = center.engine(for: shown)
        center.markShown(shown.key)
        clock.advance(301)
        _ = center.engine(for: recent)
        center.sweep()
        XCTAssertNil(center.loaded(hidden.key))
        XCTAssertNotNil(center.loaded(shown.key), "a shown engine stays")
        XCTAssertNotNil(center.loaded(recent.key), "hidden for less than the TTL")
    }

    func testTwoViewsShowingOneEngineKeepItUntilBothHide() throws {
        let spec = try trackSpec()
        _ = center.engine(for: spec)
        center.markShown(spec.key)
        center.markShown(spec.key)
        center.markHidden(spec.key)
        clock.advance(1000)
        center.sweep()
        XCTAssertNotNil(center.loaded(spec.key))
    }

    func testDropContextStopsQuietly() throws {
        let spec = try trackSpec(9)
        let engine = center.engine(for: spec)
        engine.send("q")
        let conv = try XCTUnwrap(spec.key.conversationID)
        try pool.write { db in try ChatConversationQueries.delete(db, id: conv) }
        center.dropContext(type: "track", id: "9")
        XCTAssertNil(center.loaded(spec.key))
        XCTAssertFalse(engine.isBusy)
        XCTAssertNil(engine.bannerError)
        XCTAssertEqual(center.gate.active.count, 0)
    }

    func testReleaseDropsAMemoryChat() {
        let key = EmbeddedChatKey(contextType: "setup", contextID: "calendar", conversationID: nil)
        let spec = ChatSurfaceSpec(key: key, persistence: .memory, toolAccess: .draftOnly,
                                   systemPrompt: { "S" }, emptyHint: "")
        _ = center.engine(for: spec)
        center.release(key)
        XCTAssertNil(center.loaded(key))
    }

    func testFinishAllAsPartialKeepsRunningText() async throws {
        let spec = try trackSpec()
        let engine = center.engine(for: spec)
        engine.send("q")
        ai.emit(.text("streamed"))
        expectTrue(await waitForCondition { engine.liveTurn?.fullText == "streamed" })
        center.finishAllAsPartial()
        XCTAssertFalse(engine.isStreaming)
        XCTAssertEqual(engine.messages.last?.message.status, "partial")
        XCTAssertEqual(engine.messages.last?.message.text, "streamed")
    }
}

/// `XCTAssertTrue` for an awaited verdict — XCTest's autoclosures cannot await.
@MainActor
private func expectTrue(_ verdict: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(verdict, message, file: file, line: line)
}

@MainActor
final class EmbeddedChatCenterSpecTests: XCTestCase {
    private func spec(_ id: String, hint: String) -> ChatSurfaceSpec {
        ChatSurfaceSpec(key: EmbeddedChatKey(contextType: "track", contextID: id, conversationID: nil),
                        persistence: .memory, toolAccess: .draftOnly, systemPrompt: { "S" },
                        turnPrompt: { "\(hint): \($0.text)" }, emptyHint: hint)
    }

    private func center(ai: ScriptedAIService) -> EmbeddedChatCenter {
        EmbeddedChatCenter { spec, gate in
            EmbeddedChatEngine(spec: spec, store: MemoryEmbeddedChatStore(), aiService: ai, gate: gate)
        }
    }

    /// A surface asking again gets the same engine with its fresh closures —
    /// never the first screen's snapshot.
    func testAskingAgainRefreshesTheSpec() {
        let ai = ScriptedAIService()
        let center = center(ai: ai)
        let first = center.engine(for: spec("1", hint: "old"))
        let again = center.engine(for: spec("1", hint: "new"))
        XCTAssertTrue(first === again)
        again.send("q")
        XCTAssertEqual(ai.calls.first?.prompt, "new: q", "the latest spec's closures build the turn")
    }

    func testDropContextSparesOtherContexts() {
        let center = center(ai: ScriptedAIService())
        _ = center.engine(for: spec("1", hint: ""))
        _ = center.engine(for: spec("2", hint: ""))
        center.dropContext(type: "track", id: "1")
        XCTAssertEqual(center.count, 1)
        XCTAssertNotNil(center.loaded(spec("2", hint: "").key))
    }

    func testSweepKeepsAnEngineHoldingFollowUps() async {
        let ai = ScriptedAIService()
        let center = EmbeddedChatCenter(idleTTL: 0) { spec, gate in
            EmbeddedChatEngine(spec: spec, store: MemoryEmbeddedChatStore(), aiService: ai, gate: gate)
        }
        let key = spec("1", hint: "").key
        let engine = center.engine(for: spec("1", hint: ""))
        engine.send("q")
        engine.sendFollowUp(prompt: "Action applied.")
        engine.stop()
        center.sweep(now: Date().addingTimeInterval(3600))
        XCTAssertNotNil(center.loaded(key), "its follow-up still has to reach the assistant")
    }
}

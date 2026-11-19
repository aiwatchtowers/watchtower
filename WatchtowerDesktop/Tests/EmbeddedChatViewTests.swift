import XCTest
import SwiftUI
import ViewInspector
import ChatUI
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class EmbeddedChatViewTests: XCTestCase {
    private var ai: ScriptedAIService!
    private var gate: EmbeddedStreamGate!

    override func setUp() {
        ai = ScriptedAIService()
        gate = EmbeddedStreamGate(limit: 1)
    }

    private func engine(prompts: [ChatStarterPrompt] = []) -> EmbeddedChatEngine {
        let spec = ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "test", contextID: UUID().uuidString, conversationID: nil),
            persistence: .memory, toolAccess: .draftOnly, ownerInstructions: false, systemPrompt: { "S" },
            emptyHint: "Ask about this meeting", starterPrompts: prompts)
        return EmbeddedChatEngine(spec: spec, store: MemoryEmbeddedChatStore(), aiService: ai, gate: gate)
    }

    func testEmptyChatShowsTheHintAndStarterPrompts() async throws {
        let prompt = ChatStarterPrompt(title: "What was decided?", text: "What was decided?", sendsImmediately: true)
        let engine = engine(prompts: [prompt])
        let view = EmbeddedChatRows(engine: engine)
        XCTAssertNoThrow(try view.inspect().find(text: "Ask about this meeting"))
        try view.inspect().find(button: "What was decided?").tap()
        await engine.finished()
        XCTAssertEqual(ai.calls.first?.prompt, "What was decided?")
        XCTAssertTrue(engine.isStreaming)
    }

    func testAFillPromptOnlyFillsTheComposer() throws {
        let prompt = ChatStarterPrompt(title: "Draft a follow-up…", text: "Draft a follow-up to ", sendsImmediately: false)
        let engine = engine(prompts: [prompt])
        try EmbeddedChatRows(engine: engine).inspect().find(button: "Draft a follow-up…").tap()
        XCTAssertEqual(engine.draft, "Draft a follow-up to ")
        XCTAssertTrue(ai.calls.isEmpty)
    }

    func testRetrySitsOnTheLastFailedReplyOnly() async throws {
        let engine = engine()
        engine.send("first")
        await engine.finished()
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "first failure"))
        let firstDone = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(firstDone)
        XCTAssertEqual(try EmbeddedChatRows(engine: engine).inspect().findAll(ViewType.Button.self) {
            (try? $0.labelView().text().string()) == "Retry"
        }.count, 1)

        engine.send("second")
        await engine.finished()
        ai.finish(call: 1, throwing: WatchtowerAIError.exitCode(1, "second failure"))
        let secondDone = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(secondDone)
        XCTAssertEqual(try EmbeddedChatRows(engine: engine).inspect().findAll(ViewType.Button.self) {
            (try? $0.labelView().text().string()) == "Retry"
        }.count, 1, "the earlier failure loses its Retry")
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "AI query failed (exit 1): first failure"))
    }

    func testRetryHidesWhileATurnWaits() async throws {
        let engine = engine()
        engine.send("first")
        await engine.finished()
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "boom"))
        let done = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(button: "Retry"), "visible while idle")
        let filler = self.engine()
        filler.send("takes the only slot")
        await filler.finished()
        engine.retry()
        await engine.finished()
        XCTAssertTrue(engine.isQueued)
        XCTAssertThrowsError(try EmbeddedChatRows(engine: engine).inspect().find(button: "Retry"))
    }

    func testAQueuedMessageShowsAsQueued() async throws {
        let busy = engine()
        busy.send("holds the only slot")
        await busy.finished()
        let engine = engine()
        engine.send("waiting")
        await engine.finished()
        XCTAssertTrue(engine.isQueued)
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "Queued"))
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "waiting"))
    }

    func testComposerShowsQueuedStatusWithCancel() async throws {
        let busy = engine()
        busy.send("holds the only slot")
        await busy.finished()
        let engine = engine()
        engine.draft = "waiting"
        engine.sendDraft()
        await engine.finished()
        let composer = EmbeddedChatComposer(engine: engine, placeholder: "Ask")
        try composer.inspect().find(button: "Cancel").tap()
        XCTAssertFalse(engine.isQueued)
        XCTAssertEqual(engine.draft, "waiting")
    }

    func testAPostTurnFailureShowsUnderItsMessage() async throws {
        let store = MemoryEmbeddedChatStore()
        let engine = EmbeddedChatEngine(
            spec: ChatSurfaceSpec(key: EmbeddedChatKey(contextType: "t", contextID: "1", conversationID: nil),
                                  persistence: .memory, toolAccess: .draftOnly, ownerInstructions: false, systemPrompt: { "S" },
                                  postTurn: { _ in ChatPostTurnResult(displayText: "x", failure: "Couldn't read the action") },
                                  emptyHint: ""),
            store: store, aiService: ai, gate: gate)
        engine.send("q")
        await engine.finished()
        ai.emit(.text("reply"))
        ai.finish()
        let done = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "Couldn't read the action"),
                         "a postTurn failure shows under its message")
    }

    /// An engine over stored rows (the memory store), as a reopened chat shows them.
    private func engine(rows: [(String, String)], finalizeLast status: String? = nil) async throws -> EmbeddedChatEngine {
        let store = MemoryEmbeddedChatStore()
        for (role, text) in rows { _ = try await store.append(role: role, text: text) }
        if let status {
            let ids = try await store.beginTurn(ownerText: nil, turnID: "t", provider: nil)
            try await store.finalize(messageID: ids.assistantID, text: "Half an answer", status: status, errorCode: nil,
                                     errorMessage: nil)
        }
        let spec = ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: "test", contextID: UUID().uuidString, conversationID: nil),
            persistence: .memory, toolAccess: .draftOnly, ownerInstructions: false, systemPrompt: { "S" }, emptyHint: "")
        return EmbeddedChatEngine(spec: spec, store: store, aiService: ai, gate: gate)
    }

    /// The rows are ChatUI's (unified chat T12): an artifact block and a question block in a stored reply become the
    /// shared artifact card and question card, and answering the card is an ordinary owner turn.
    func testEmbeddedArtifactsAndQuestionsComeFromSharedParser() async throws {
        let reply = """
        Here is the plan.
        :::artifact key="plan" kind="document" title="Rollout plan"
        # Plan
        :::
        ```watchtower-question
        {"questions":[{"id":"q","question":"Ship it?","options":[{"label":"Yes"},{"label":"No"}]}]}
        ```
        """
        let engine = try await engine(rows: [("user", "Plan the rollout"), ("assistant", reply)])
        let rows = try EmbeddedChatRows(engine: engine).inspect()
        XCTAssertNoThrow(try rows.find(text: "Rollout plan"), "the artifact card")
        XCTAssertNoThrow(try rows.find(QuestionPartView.self), "the question card")
        XCTAssertThrowsError(try rows.find(text: "Ship it?\n- Yes\n- No"), "the block is not shown as text")

        XCTAssertTrue(try rows.find(button: QuestionPartView.sendLabel).isDisabled(), "answerable, nothing picked yet")

        let feed = EmbeddedChatFeed(engine: engine, density: .compact, accessory: { _ in EmptyView() }, openArtifact: { _ in })
        feed.context(follows: false).partActions.sendFixedText("Ship it?\n- Yes")
        await engine.finished()
        XCTAssertEqual(ai.calls.count, 1, "the answers are the owner's next turn")
        XCTAssertTrue(engine.isStreaming)
    }

    /// Copy only: an embedded chat's rows offer no Edit or Regenerate, and a stored reply that ended part-way says
    /// Stopped with no Continue.
    func testEmbeddedRowsOfferCopyOnlyAndAStoppedReplyHasNoContinue() async throws {
        let engine = try await engine(rows: [("user", "Hi"), ("assistant", "Hello")], finalizeLast: "partial")
        let rows = try EmbeddedChatRows(engine: engine).inspect()
        XCTAssertFalse(try rows.findAll(ViewType.Button.self) { (try? $0.accessibilityLabel().string()) == "Copy message" }.isEmpty,
                       "the icon Copy the embedded chats had")
        XCTAssertThrowsError(try rows.find(button: "Regenerate"))
        XCTAssertThrowsError(try rows.find(button: "Edit"))
        XCTAssertNoThrow(try rows.find(text: "Stopped"))
        XCTAssertThrowsError(try rows.find(button: "Continue"))
    }

    func testComposerShowsAnErrorStatus() throws {
        let bar = ChatComposerBar(status: .error("Couldn't send: disk full"),
                                  input: ChatComposerField(text: .constant(""), isStreaming: false,
                                                           config: ChatComposerFieldConfig(placeholder: "Ask…")) {})
        XCTAssertNoThrow(try bar.inspect().find(text: "Couldn't send: disk full"))
    }
}

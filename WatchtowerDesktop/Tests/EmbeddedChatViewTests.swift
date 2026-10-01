import XCTest
import SwiftUI
import ViewInspector
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
            persistence: .memory, toolAccess: .draftOnly, systemPrompt: { "S" },
            emptyHint: "Ask about this meeting", starterPrompts: prompts)
        return EmbeddedChatEngine(spec: spec, store: MemoryEmbeddedChatStore(), aiService: ai, gate: gate)
    }

    func testEmptyChatShowsTheHintAndStarterPrompts() throws {
        let prompt = ChatStarterPrompt(title: "What was decided?", text: "What was decided?", sendsImmediately: true)
        let engine = engine(prompts: [prompt])
        let view = EmbeddedChatRows(engine: engine)
        XCTAssertNoThrow(try view.inspect().find(text: "Ask about this meeting"))
        try view.inspect().find(button: "What was decided?").tap()
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
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "first failure"))
        let firstDone = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(firstDone)
        XCTAssertEqual(try EmbeddedChatRows(engine: engine).inspect().findAll(ViewType.Button.self) {
            (try? $0.labelView().text().string()) == "Retry"
        }.count, 1)

        engine.send("second")
        ai.finish(call: 1, throwing: WatchtowerAIError.exitCode(1, "second failure"))
        let secondDone = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(secondDone)
        XCTAssertEqual(try EmbeddedChatRows(engine: engine).inspect().findAll(ViewType.Button.self) {
            (try? $0.labelView().text().string()) == "Retry"
        }.count, 1, "the earlier failure loses its Retry")
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "first failure"))
    }

    func testAQueuedMessageShowsAsQueued() throws {
        let busy = engine()
        busy.send("holds the only slot")
        let engine = engine()
        engine.send("waiting")
        XCTAssertTrue(engine.isQueued)
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "Queued"))
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "waiting"))
    }

    func testComposerShowsQueuedStatusWithCancel() throws {
        let busy = engine()
        busy.send("holds the only slot")
        let engine = engine()
        engine.draft = "waiting"
        engine.sendDraft()
        let bar = ChatComposerBar(status: .queued, onCancelQueued: { engine.cancelQueued() },
                                  input: ChatInput(text: .constant(""), isStreaming: true) {})
        try bar.inspect().find(button: "Cancel").tap()
        XCTAssertFalse(engine.isQueued)
        XCTAssertEqual(engine.draft, "waiting")
    }

    func testComposerShowsAnErrorStatus() throws {
        let bar = ChatComposerBar(status: .error("Couldn't send: disk full"),
                                  input: ChatInput(text: .constant(""), isStreaming: false) {})
        XCTAssertNoThrow(try bar.inspect().find(text: "Couldn't send: disk full"))
    }
}

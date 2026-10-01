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
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "AI query failed (exit 1): first failure"))
    }

    func testRetryHidesWhileATurnWaits() async throws {
        let engine = engine()
        engine.send("first")
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "boom"))
        let done = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(button: "Retry"), "visible while idle")
        let filler = self.engine()
        filler.send("takes the only slot")
        engine.retry()
        XCTAssertTrue(engine.isQueued)
        XCTAssertThrowsError(try EmbeddedChatRows(engine: engine).inspect().find(button: "Retry"))
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
        let composer = EmbeddedChatComposer(engine: engine, placeholder: "Ask")
        try composer.inspect().find(button: "Cancel").tap()
        XCTAssertFalse(engine.isQueued)
        XCTAssertEqual(engine.draft, "waiting")
    }

    func testAPostTurnFailureShowsUnderItsMessage() async throws {
        let store = MemoryEmbeddedChatStore()
        let engine = EmbeddedChatEngine(
            spec: ChatSurfaceSpec(key: EmbeddedChatKey(contextType: "t", contextID: "1", conversationID: nil),
                                  persistence: .memory, toolAccess: .draftOnly, systemPrompt: { "S" },
                                  postTurn: { _ in ChatPostTurnResult(displayText: "x", failure: "Couldn't read the action") },
                                  emptyHint: ""),
            store: store, aiService: ai, gate: gate)
        engine.send("q")
        ai.emit(.text("reply"))
        ai.finish()
        let done = await waitForCondition { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertNoThrow(try EmbeddedChatRows(engine: engine).inspect().find(text: "Couldn't read the action"),
                         "a postTurn failure shows under its message")
    }

    func testComposerShowsAnErrorStatus() throws {
        let bar = ChatComposerBar(status: .error("Couldn't send: disk full"),
                                  input: ChatInput(text: .constant(""), isStreaming: false) {})
        XCTAssertNoThrow(try bar.inspect().find(text: "Couldn't send: disk full"))
    }
}

@MainActor
final class UserDefaultsDraftMirrorTests: XCTestCase {
    func testSaveRestoreClearPerKey() throws {
        let suite = "embedded-draft-mirror-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mirror = UserDefaultsDraftMirror(defaults: defaults)
        let first = EmbeddedChatKey(contextType: "track", contextID: "1", conversationID: 10)
        let second = EmbeddedChatKey(contextType: "track", contextID: "1", conversationID: 11)
        mirror.save("queued words", for: first)
        XCTAssertEqual(mirror.restore(for: first), "queued words")
        XCTAssertNil(mirror.restore(for: second))
        XCTAssertEqual(UserDefaultsDraftMirror(defaults: defaults).restore(for: first), "queued words",
                       "survives a new process")
        mirror.clear(for: first)
        XCTAssertNil(mirror.restore(for: first))
    }
}

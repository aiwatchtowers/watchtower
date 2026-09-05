import XCTest
@testable import WatchtowerCore

/// Covers `WatchtowerAIService.buildArgs` — the CLI-flag mapping used to
/// invoke `watchtower ai query`. In particular, the `--provider` flag is what
/// lets the chat provider picker actually switch the backend (previously the
/// provider argument was dropped, so the Go CLI always fell back to whatever
/// `ai.provider` was set in config.yaml).
final class WatchtowerAIServiceTests: XCTestCase {
    func testBuildArgsIncludesProviderFlagWhenSet() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: nil,
            provider: "codex",
            toolMode: nil
        )

        XCTAssertEqual(args, ["ai", "query", "hello", "--provider", "codex"])
    }

    func testBuildArgsOmitsProviderFlagWhenNil() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: nil,
            provider: nil,
            toolMode: nil
        )

        XCTAssertFalse(args.contains("--provider"))
    }

    func testBuildArgsOmitsProviderFlagWhenEmpty() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: nil,
            provider: "",
            toolMode: nil
        )

        XCTAssertFalse(args.contains("--provider"))
    }

    func testBuildArgsIncludesModelAndProviderTogether() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: "gpt-5.4",
            provider: "codex",
            toolMode: nil
        )

        XCTAssertEqual(args, ["ai", "query", "hello", "--model", "gpt-5.4", "--provider", "codex"])
    }

    func testBuildArgsEmitsChatToolModeFlags() {
        let mode = ChatToolMode(surface: "target", conversationID: 7, turnID: "t1", contextType: "target", contextID: "42")
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: nil, sessionID: nil, dbPath: "/tmp/w.db", model: nil, provider: nil, toolMode: mode
        )
        XCTAssertEqual(args, ["ai", "query", "hi", "--db-path", "/tmp/w.db",
                              "--tools", "chat", "--surface", "target", "--conversation", "7", "--turn", "t1",
                              "--context-type", "target", "--context-id", "42"])
    }

    /// AGENT-04: no toolMode → no --tools flag, ever. And the retired
    /// --allowed-tools flag is gone for good.
    func testBuildArgsWithoutToolModeNeverEmitsToolsFlag() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: "s", sessionID: "sid", dbPath: "/tmp/w.db", model: "m", provider: "claude", toolMode: nil
        )
        XCTAssertFalse(args.contains("--tools"))
        XCTAssertFalse(args.contains("--allowed-tools"))
    }

    func testChatToolModeMainOmitsContext() {
        let mode = ChatToolMode(surface: "main", conversationID: 3, turnID: "x")
        XCTAssertEqual(mode.cliArgs, ["--tools", "chat", "--surface", "main", "--conversation", "3", "--turn", "x"])
    }

    // MARK: - parseLine reset contract (the pre-tool preamble fix)

    /// A "reset" event clears the accumulator and surfaces `.reset`, so the
    /// pre-tool preamble ("I need to check…first.") is dropped and never glues
    /// onto the post-tool answer streamed after it.
    func testParseLineResetClearsAccumulatorAndEmitsReset() {
        let service = WatchtowerAIService()
        var acc = ""

        _ = service.parseLine(#"{"type":"text","text":"I need to check first."}"#, accumulatedText: &acc)
        XCTAssertEqual(acc, "I need to check first.")

        let ev = service.parseLine(#"{"type":"reset"}"#, accumulatedText: &acc)
        guard case .reset = ev else {
            return XCTFail("expected .reset, got \(String(describing: ev))")
        }
        XCTAssertEqual(acc, "", "the preamble must be discarded on reset")

        // Text after the reset rebuilds the answer from scratch.
        _ = service.parseLine(#"{"type":"text","text":"Here is the answer."}"#, accumulatedText: &acc)
        XCTAssertEqual(acc, "Here is the answer.")
    }
}

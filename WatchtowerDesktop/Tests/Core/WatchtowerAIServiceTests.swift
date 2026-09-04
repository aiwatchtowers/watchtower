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
}

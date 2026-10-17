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

        XCTAssertEqual(args, ["ai", "query", "--provider", "codex", "--", "hello"])
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

        XCTAssertEqual(args, ["ai", "query", "--model", "gpt-5.4", "--provider", "codex", "--", "hello"])
    }

    func testBuildArgsEmitsChatToolModeFlags() {
        let mode = ChatToolMode(surface: "target", conversationID: 7, turnID: "t1", contextType: "target", contextID: "42")
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: nil, sessionID: nil, dbPath: "/tmp/w.db", model: nil, provider: nil, toolMode: mode
        )
        XCTAssertEqual(args, ["ai", "query", "--db-path", "/tmp/w.db",
                              "--tools", "chat", "--surface", "target", "--conversation", "7", "--turn", "t1",
                              "--context-type", "target", "--context-id", "42", "--", "hi"])
    }

    /// An unconditional `--` separator: a prompt that looks like a flag
    /// ("-v looks wrong") must still parse as the positional prompt, not as
    /// `-v` plus a stray "looks"/"wrong". The separator is emitted for every
    /// call, never only when the prompt starts with a dash — a conditional
    /// separator would be a second path to get wrong. Flags must land BEFORE
    /// `--`, so this asserts the whole array rather than merely
    /// `args.contains("--")`, which would pass even for the broken ordering
    /// (`--` before the flags).
    func testBuildArgsPassesALeadingDashPromptAfterASeparator() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "-v looks wrong",
            systemPrompt: "S",
            sessionID: nil,
            dbPath: nil,
            model: nil,
            provider: "codex",
            toolMode: nil
        )

        XCTAssertEqual(args, ["ai", "query", "--system-prompt-stdin", "--provider", "codex", "--", "-v looks wrong"])
    }

    /// The system prompt carries the chat's private context: it travels on
    /// stdin, never as an argv value.
    func testSystemPromptNeverOnArgv() {
        let secret = "PRIVATE-CONTEXT-7c1e"
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: secret, sessionID: nil, dbPath: nil, model: nil, provider: nil, toolMode: nil
        )
        XCTAssertFalse(args.contains { $0.contains(secret) })
        XCTAssertFalse(args.contains("--system-prompt"))
        XCTAssertTrue(args.contains("--system-prompt-stdin"))
        XCTAssertEqual(WatchtowerAIService.stdinPayload(systemPrompt: secret), Data(secret.utf8))
    }

    /// The payload reaches the reader and the pipe is closed (the CLI's
    /// io.ReadAll would otherwise wait forever).
    func testFeedStdinWritesPayloadAndCloses() {
        let pipe = Pipe()
        WatchtowerAIService.feedStdin(pipe, payload: Data("system prompt".utf8))
        let read = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(data: read, encoding: .utf8), "system prompt")
    }

    /// A CLI that exited before reading must not take the app down: the
    /// write fails with EPIPE (no SIGPIPE) and is dropped.
    func testFeedStdinSurvivesAClosedReader() {
        let pipe = Pipe()
        try? pipe.fileHandleForReading.close()
        WatchtowerAIService.feedStdin(pipe, payload: Data(repeating: 0x61, count: 1 << 20))
    }

    func testNoSystemPromptMeansNoStdinFlagOrPayload() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: "", sessionID: nil, dbPath: nil, model: nil, provider: nil, toolMode: nil
        )
        XCTAssertFalse(args.contains("--system-prompt-stdin"))
        XCTAssertNil(WatchtowerAIService.stdinPayload(systemPrompt: ""))
        XCTAssertNil(WatchtowerAIService.stdinPayload(systemPrompt: nil))
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

    /// A code question runs `ai query --read-folder DIR` (spec 2026-10-02
    /// §9.1): the folder rides ahead of the `--` separator, with no tool mode.
    func testBuildArgsReadFolderGoesBeforeTheSeparator() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "-what is this?", systemPrompt: "s", sessionID: nil, dbPath: "/tmp/w.db", model: nil,
            provider: "codex", toolMode: nil, readFolder: "/work/acme"
        )
        XCTAssertEqual(args, ["ai", "query", "--system-prompt-stdin", "--db-path", "/tmp/w.db", "--provider", "codex",
                              "--read-folder", "/work/acme", "--", "-what is this?"])
        XCTAssertFalse(args.contains("--tools"))
    }

    /// Without a folder (every other chat) the argv is what it was.
    func testBuildArgsWithoutReadFolderIsUnchanged() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: nil, sessionID: "sid", dbPath: "/tmp/w.db", model: "m", provider: "claude",
            toolMode: nil
        )
        XCTAssertEqual(args, ["ai", "query", "--session-id", "sid", "--db-path", "/tmp/w.db", "--model", "m",
                              "--provider", "claude", "--", "hi"])
        XCTAssertEqual(WatchtowerAIService.buildArgs(
            prompt: "hi", systemPrompt: nil, sessionID: "sid", dbPath: "/tmp/w.db", model: "m", provider: "claude",
            toolMode: nil, readFolder: ""
        ), args)
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

    // MARK: - parseLine error line

    /// `ai query` reports a provider failure as a v1 `error` line and exits 0:
    /// it surfaces as `.error` with the provider's own text, never as reply text.
    func testParseLineErrorEmitsErrorEvent() {
        let service = WatchtowerAIService()
        var acc = "partial answer"

        let ev = service.parseLine(#"{"type":"error","error":"claude: not logged in"}"#, accumulatedText: &acc)
        guard case .error(let message) = ev else {
            return XCTFail("expected .error, got \(String(describing: ev))")
        }
        XCTAssertEqual(message, "claude: not logged in")
        XCTAssertEqual(acc, "partial answer", "the error line never touches the turn's text")
    }

    /// Chats not yet on the embedded engine keep rendering `[Error] …` text.
    func testFoldingErrorIntoTextKeepsTheLegacyRendering() {
        guard case .text(let text) = StreamEvent.error("boom").foldingErrorIntoText else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(text, "[Error] boom")
        guard case .reset = StreamEvent.reset.foldingErrorIntoText else { return XCTFail("expected .reset") }
    }
}

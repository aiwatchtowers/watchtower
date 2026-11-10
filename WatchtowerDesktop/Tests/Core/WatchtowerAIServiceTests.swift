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
            dbPath: nil,
            model: nil,
            provider: "codex",
            toolMode: nil
        )

        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--provider", "codex"])
    }

    func testBuildArgsAddsTheBareOwnerInstructionsFlagOnlyWhenAsked() {
        let on = WatchtowerAIService.buildArgs(
            dbPath: nil, model: nil, provider: nil, toolMode: nil, ownerInstructions: true
        )
        XCTAssertEqual(on, ["ai", "query", "--prompt-stdin", "--events", "v2", "--owner-instructions"])
        let off = WatchtowerAIService.buildArgs(
            dbPath: nil, model: nil, provider: nil, toolMode: nil, ownerInstructions: false
        )
        XCTAssertFalse(off.contains("--owner-instructions"))
    }

    func testBuildArgsPurpose() {
        let tagged = WatchtowerAIService.buildArgs(
            dbPath: nil, model: nil, provider: nil, toolMode: nil, purpose: "spec_review.discuss"
        )
        XCTAssertEqual(tagged, ["ai", "query", "--prompt-stdin", "--events", "v2", "--purpose", "spec_review.discuss"])
        for none in [nil, ""] as [String?] {
            let args = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil, purpose: none)
            XCTAssertFalse(args.contains("--purpose"))
        }
    }

    func testBuildArgsReadFolderAsk() {
        let args = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil, readFolderAskID: 42)
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--read-folder-ask", "42"])
        let both = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil,
                                                 readFolder: "/work/acme", readFolderAskID: 42)
        XCTAssertFalse(both.contains("--read-folder-ask"), "never with --read-folder: the CLI refuses the pair")
        XCTAssertTrue(both.contains("--read-folder"))
        let none = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil)
        XCTAssertFalse(none.contains("--read-folder-ask"))
    }

    /// The branch-review reviewer names its folder by the round (owner, ask
    /// #611): `--read-folder-round N`, never with another folder flag.
    func testBuildArgsReadFolderRound() {
        let args = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil,
                                                 purpose: "review.reviewer", readFolderRoundID: 7)
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--read-folder-round", "7",
                              "--purpose", "review.reviewer"])
        let withFolder = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil,
                                                       readFolder: "/work/acme", readFolderRoundID: 7)
        XCTAssertFalse(withFolder.contains("--read-folder-round"), "the CLI refuses the pair")
        let withAsk = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil,
                                                    readFolderAskID: 42, readFolderRoundID: 7)
        XCTAssertEqual(Array(withAsk.suffix(2)), ["--read-folder-ask", "42"])
        XCTAssertFalse(withAsk.contains("--read-folder-round"), "the CLI refuses the pair")
        let none = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil)
        XCTAssertFalse(none.contains("--read-folder-round"))
    }

    func testBuildArgsOmitsProviderFlagWhenNil() {
        let args = WatchtowerAIService.buildArgs(
            dbPath: nil,
            model: nil,
            provider: nil,
            toolMode: nil
        )

        XCTAssertFalse(args.contains("--provider"))
    }

    func testBuildArgsOmitsProviderFlagWhenEmpty() {
        let args = WatchtowerAIService.buildArgs(
            dbPath: nil,
            model: nil,
            provider: "",
            toolMode: nil
        )

        XCTAssertFalse(args.contains("--provider"))
    }

    func testBuildArgsIncludesModelAndProviderTogether() {
        let args = WatchtowerAIService.buildArgs(
            dbPath: nil,
            model: "gpt-5.4",
            provider: "codex",
            toolMode: nil
        )

        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--model", "gpt-5.4", "--provider", "codex"])
    }

    func testBuildArgsEmitsChatToolModeFlags() {
        let mode = ChatToolMode(surface: "target", conversationID: 7, turnID: "t1", contextType: "target", contextID: "42")
        let args = WatchtowerAIService.buildArgs(
            dbPath: "/tmp/w.db", model: nil, provider: nil, toolMode: mode
        )
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--db-path", "/tmp/w.db",
                              "--tools", "chat", "--surface", "target", "--conversation", "7", "--turn", "t1",
                              "--context-type", "target", "--context-id", "42"])
    }

    /// Board #566: the owner's message and the chat's private system prompt
    /// travel on stdin as one JSON object (`--prompt-stdin`), never on argv —
    /// any local process could read argv through `ps`. A message that looks
    /// like a flag ("-v looks wrong") is plain JSON data there.
    func testPromptAndSystemPromptNeverOnArgv() throws {
        let secret = "PRIVATE-CONTEXT-7c1e"
        let message = "-v OWNER-TEXT-3d2a"
        let args = WatchtowerAIService.buildArgs(
            dbPath: nil, model: nil, provider: "codex", toolMode: nil
        )
        XCTAssertFalse(args.contains { $0.contains(secret) || $0.contains("OWNER-TEXT") })
        XCTAssertFalse(args.contains("--system-prompt"))
        XCTAssertFalse(args.contains("--"))
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--provider", "codex"])

        let payload = WatchtowerAIService.stdinPayload(prompt: message, systemPrompt: secret)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
        XCTAssertEqual(object, ["prompt": message, "system_prompt": secret])
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

    /// No system prompt: the payload carries the prompt alone (the CLI then
    /// runs without one, as before).
    func testNoSystemPromptLeavesItOutOfThePayload() throws {
        for system in [nil, ""] as [String?] {
            let payload = WatchtowerAIService.stdinPayload(prompt: "hi", systemPrompt: system)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
            XCTAssertEqual(object, ["prompt": "hi"])
        }
    }

    /// AGENT-04: no toolMode → no --tools flag, ever. And the retired
    /// --allowed-tools flag is gone for good.
    func testBuildArgsWithoutToolModeNeverEmitsToolsFlag() {
        let args = WatchtowerAIService.buildArgs(
            dbPath: "/tmp/w.db", model: "m", provider: "claude", toolMode: nil
        )
        XCTAssertFalse(args.contains("--tools"))
        XCTAssertFalse(args.contains("--allowed-tools"))
    }

    /// A code question runs `ai query --read-folder DIR` (spec 2026-10-02
    /// §9.1), with no tool mode.
    func testBuildArgsReadFolder() {
        let args = WatchtowerAIService.buildArgs(
            dbPath: "/tmp/w.db", model: nil,
            provider: "codex", toolMode: nil, readFolder: "/work/acme"
        )
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--db-path", "/tmp/w.db", "--provider", "codex",
                              "--read-folder", "/work/acme"])
        XCTAssertFalse(args.contains("--tools"))
    }

    /// Without a folder (every other chat) the argv is what it was.
    func testBuildArgsWithoutReadFolderIsUnchanged() {
        let args = WatchtowerAIService.buildArgs(
            dbPath: "/tmp/w.db", model: "m", provider: "claude",
            toolMode: nil
        )
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--db-path", "/tmp/w.db",
                              "--model", "m", "--provider", "claude"])
        XCTAssertEqual(WatchtowerAIService.buildArgs(
            dbPath: "/tmp/w.db", model: "m", provider: "claude",
            toolMode: nil, readFolder: ""
        ), args)
    }

    func testChatToolModeMainOmitsContext() {
        let mode = ChatToolMode(surface: "main", conversationID: 3, turnID: "x")
        XCTAssertEqual(mode.cliArgs, ["--tools", "chat", "--surface", "main", "--conversation", "3", "--turn", "x"])
    }

    // MARK: - parseLine: `ai query --events v2`

    /// Every embedded chat asks for protocol v2 — the main chat's events, so
    /// claude and codex tool calls reach it as steps, with the turn's usage.
    func testBuildArgsAlwaysAsksForTheV2Events() {
        let args = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: nil, toolMode: nil)
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2"])
    }

    /// A tool call between two messages: both texts stay (no reset in v2,
    /// CHAT-02), the call becomes a start and an end, and the usage arrives.
    func testParseLineMapsTheV2TurnOntoStreamEvents() {
        let lines = [
            #"{"type":"turn_start","turn_id":"query"}"#,
            #"{"type":"text_delta","turn_id":"query","text":"Let me check."}"#,
            #"{"type":"tool_start","turn_id":"query","id":"t1","name":"list_targets","args":{"limit":3}}"#,
            #"{"type":"tool_end","turn_id":"query","id":"t1","ok":true,"summary":"3 targets"}"#,
            #"{"type":"text_delta","turn_id":"query","text":"\n\nFound it."}"#,
            #"{"type":"usage","turn_id":"query","model":"gpt-x","tokens_in":50,"tokens_out":7}"#,
            #"{"type":"turn_done","turn_id":"query","status":"complete"}"#
        ]
        let events = lines.compactMap(WatchtowerAIService.parseLine)
        XCTAssertEqual(events.count, 5, "turn_start and turn_done carry nothing an embedded chat keeps")
        var reducer = EmbeddedStreamReducer()
        for event in events { _ = reducer.apply(event) }
        XCTAssertEqual(reducer.text, "Let me check.\n\nFound it.", "text streamed before the tool call is kept")
        guard case .toolStart(let start) = events[1] else { return XCTFail("expected .toolStart, got \(events[1])") }
        XCTAssertEqual(start, ChatToolStart(turnID: "query", id: "t1", name: "list_targets", argsJSON: #"{"limit":3}"#))
        guard case .toolEnd(let end) = events[2] else { return XCTFail("expected .toolEnd, got \(events[2])") }
        XCTAssertEqual(end, ChatToolEnd(turnID: "query", id: "t1", ok: true, summary: "3 targets", sources: []))
        guard case .usage(let usage) = events[4] else { return XCTFail("expected .usage, got \(events[4])") }
        XCTAssertEqual(usage, ChatUsage(turnID: "query", tokensIn: 50, tokensOut: 7, model: "gpt-x"))
    }

    /// A v1 `reset` line means nothing in v2: it never wipes the text.
    func testParseLineIgnoresTheV1Shapes() {
        XCTAssertNil(WatchtowerAIService.parseLine(#"{"type":"reset"}"#))
        XCTAssertNil(WatchtowerAIService.parseLine(#"{"type":"text","text":"x"}"#))
        XCTAssertNil(WatchtowerAIService.parseLine("not json"))
    }

    /// The provider's failure is a typed `.failure` with its own text and
    /// code, never reply text.
    func testParseLineErrorIsATypedFailure() {
        guard case .failure(let failure) = WatchtowerAIService.parseLine(
            #"{"type":"error","turn_id":"query","code":"auth","message":"claude: not logged in","retryable":false}"#
        ) else { return XCTFail("expected .failure") }
        XCTAssertEqual(failure.code, .auth)
        XCTAssertEqual(failure.message, "claude: not logged in")
        XCTAssertFalse(failure.retryable)
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

extension WatchtowerAIServiceTests {
    func testTypedQuotaAndActualRoutingAreNotDiscarded() throws {
        guard case .failure(let failure) = WatchtowerAIService.parseLine("""
            {"type":"error","turn_id":"query","message":"Quota reached","code":"rate_limit","reason":"quota_exhausted","retryable":false}
            """) else { return XCTFail("typed failure was discarded") }
        XCTAssertEqual(failure.persistenceCode, "quota_exhausted")
        XCTAssertFalse(EmbeddedChatErrorClassifier.classify(failure).retryable)
        guard case let .routing(provider, model, routing) = WatchtowerAIService.parseLine("""
            {"type":"session_ready","provider":"codex","model":"actual-model","preferred_provider":"claude",
             "routing_mode":"preferred_reserve","reason":"quota_exhausted"}
            """) else { return XCTFail("actual metadata was discarded") }
        XCTAssertEqual(provider, "codex")
        XCTAssertEqual(model, "actual-model")
        XCTAssertEqual(routing?.preferredProvider, "claude")
    }

    // MARK: - testResult / which decoding (#1521)

    private func out(_ stdout: String, exit: Int32 = 0, stderr: String = "") -> ProcessOutput {
        ProcessOutput(exitCode: exit, stdout: stdout, stderr: stderr)
    }

    func testTestResultDecodesErrorCode() {
        let result = WatchtowerAIService.decodeTestResult(out(
            #"{"ok":false,"provider":"claude","model":"m","error":"x","error_code":"auth"}"#, exit: 1
        ))
        XCTAssertEqual(result, OnboardingAgentTestResult(ok: false, errorCode: "auth", error: "x"))
    }

    func testTestResultOk() {
        let result = WatchtowerAIService.decodeTestResult(out(#"{"ok":true,"provider":"codex","model":"m"}"#))
        XCTAssertEqual(result, OnboardingAgentTestResult(ok: true))
    }

    func testTestResultLaunchFailure() {
        let result = WatchtowerAIService.decodeTestResult(out("", exit: -1, stderr: "no such file"))
        XCTAssertEqual(result.errorCode, "launch")
        XCTAssertFalse(result.ok)
    }

    func testWhichDecodes() {
        XCTAssertEqual(WatchtowerAIService.decodeWhich(#"{"provider":"codex","path":"/x/codex","found":true}"#), "/x/codex")
        XCTAssertNil(WatchtowerAIService.decodeWhich(#"{"provider":"codex","path":"","found":false}"#))
        XCTAssertNil(WatchtowerAIService.decodeWhich("not json"))
    }
}

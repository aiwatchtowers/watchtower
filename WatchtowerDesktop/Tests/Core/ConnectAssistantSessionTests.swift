import Foundation
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The connect assistant's session (agent connect spec §5.2, §8): the argv
/// and environment of a connect turn, the S1 probe and mid-run fallback,
/// failures, run ends (close, quit, switch, retry) and resuming from status.
@MainActor
final class ConnectAssistantSessionTests: XCTestCase {
    private let browserHarness = ConnectHarness(id: "harness-b", name: "Agent B", capability: .browser)
    private let wordsHarness = ConnectHarness(id: "harness-w", name: "Agent W", capability: .words)
    private var ai = ScriptedAIService()
    private var driver = FakeConnectDriver()

    override func setUp() async throws {
        ai = ScriptedAIService()
        driver = FakeConnectDriver()
    }

    // MARK: - Fixtures

    private func make(_ initial: ConnectHarness) -> ConnectAssistantSession {
        let session = ConnectAssistantSession(
            service: "slack", displayName: "Slack", harnesses: [browserHarness, wordsHarness], initial: initial,
            driver: driver, aiService: ai, probe: ConnectBrowserProbe(aiService: ai), gate: EmbeddedStreamGate())
        addTeardownBlock { @MainActor in session.close() }
        return session
    }

    /// Starts a run and returns the index of its first turn's call. A
    /// browser run's probe (the call before it) answers `probe`.
    private func startRun(_ session: ConnectAssistantSession, probe: String? = nil) async -> Int {
        let before = ai.calls.count
        session.start()
        if let probe {
            await ai.untilCalls(before + 1)
            ai.emit(.toolStart(ChatToolStart(turnID: "p", id: "probe",
                                             name: "claude-in-chrome:list_connected_browsers", argsJSON: "{}")),
                    .toolEnd(ChatToolEnd(turnID: "p", id: "probe", ok: true, summary: probe, sources: [])),
                    call: before)
        }
        await session.prepared()
        await session.engine?.started()
        return ai.calls.count - 1
    }

    private func request(_ tool: String, _ args: String = "{}") -> ConnectWireRequest {
        ConnectWireRequest(id: 3, tool: tool, args: Data(args.utf8))
    }

    private func socket(_ turn: Int) -> String {
        ai.calls[turn].extraEnvironment[ConnectWire.socketEnv] ?? ""
    }

    // MARK: - The connect turn

    func testConnectSurfaceArgv() async throws {
        let words = make(wordsHarness)
        let turn = await startRun(words)
        let call = ai.calls[turn]
        XCTAssertEqual(call.connectArgs, ["--tools", "connect", "--connect-service", "slack", "--connect-mode", "words"])
        XCTAssertEqual(call.provider, "harness-w", "a connect turn always names its harness: never routed")
        XCTAssertNil(call.toolMode)

        let env = call.extraEnvironment
        XCTAssertEqual(Set(env.keys), [ConnectWire.socketEnv, ConnectWire.tokenEnv])
        let socketPath = try XCTUnwrap(env[ConnectWire.socketEnv])
        let token = try XCTUnwrap(env[ConnectWire.tokenEnv])
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertEqual(token.count, 64)

        let args = WatchtowerAIService.buildArgs(dbPath: nil, model: nil, provider: call.provider, toolMode: nil,
                                                 connectArgs: call.connectArgs)
        XCTAssertEqual(args, ["ai", "query", "--prompt-stdin", "--events", "v2", "--tools", "connect",
                              "--connect-service", "slack", "--connect-mode", "words", "--provider", "harness-w"])
        XCTAssertFalse(args.contains("chat"), "no --tools chat")
        XCTAssertFalse(args.contains("--tool-mode"))
        XCTAssertFalse(args.contains("--system-prompt-stdin"), "both prompts go in the --prompt-stdin JSON")
        XCTAssertFalse(args.contains { $0.contains(token) || $0.contains(socketPath) }, "never in argv")

        let merged = WatchtowerAIService.environment(merging: env)
        XCTAssertEqual(merged[ConnectWire.socketEnv], socketPath)
        XCTAssertEqual(merged[ConnectWire.tokenEnv], token)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: WatchtowerAIService.stdinPayload(prompt: call.prompt, systemPrompt: call.systemPrompt)) as? [String: String])
        XCTAssertEqual(Set(payload.keys), ["prompt", "system_prompt"])

        // A browser harness whose probe finds a browser runs in browser mode.
        let browser = ConnectAssistantSession(
            service: "jira", displayName: "Jira", harnesses: [browserHarness], initial: browserHarness,
            driver: FakeConnectDriver(service: "jira", secretKinds: []), aiService: ai,
            probe: ConnectBrowserProbe(aiService: ai), gate: EmbeddedStreamGate())
        addTeardownBlock { @MainActor in browser.close() }
        let browserTurn = await startRun(browser, probe: #"[{"id":"b1","name":"Chrome"}]"#)
        XCTAssertEqual(ai.calls[browserTurn - 1].prompt, ConnectBrowserProbe.prompt)
        XCTAssertEqual(ai.calls[browserTurn - 1].connectArgs,
                       ["--tools", "connect", "--connect-service", "jira", "--connect-mode", "probe"])
        XCTAssertEqual(ai.calls[browserTurn - 1].extraEnvironment, [:], "the probe gets no socket and no token")
        XCTAssertEqual(ai.calls[browserTurn].connectArgs,
                       ["--tools", "connect", "--connect-service", "jira", "--connect-mode", "browser"])
        XCTAssertEqual(browser.presentation.modeLine, "Using Agent B in Chrome")
    }

    func testPersistenceIsMemoryAndNoOwnerInstructions() async throws {
        let session = make(wordsHarness)
        let turn = await startRun(session)
        let spec = try XCTUnwrap(session.engine?.spec)
        XCTAssertEqual(spec.persistence, .memory)
        XCTAssertFalse(spec.ownerInstructions)
        XCTAssertNil(spec.key.conversationID)
        XCTAssertEqual(spec.toolAccess, .connect(service: "slack", mode: .words))
        XCTAssertFalse(spec.toolAccess.readsChatHistory)
        XCTAssertEqual(spec.runOptions().provider, "harness-w")
        XCTAssertFalse(ai.calls[turn].ownerInstructions)
        let conversation = EmbeddedChatKey(contextType: "connect", contextID: "slack", conversationID: 42)
        XCTAssertNil(spec.toolAccess.toolMode(key: conversation, turnID: "t"), "connect is no chat surface (AGENT-04)")
        XCTAssertEqual(ai.calls[turn].prompt, ConnectAssistantSession.startPrompt)
    }

    // MARK: - Browser

    func testBrowserToolErrorSwitchesToWords() async {
        let session = make(browserHarness)
        let turn = await startRun(session, probe: #"[{"id":"b1"}]"#)
        XCTAssertEqual(session.mode, .browser)

        // A refused navigation is no lost extension.
        ai.emit(.toolStart(ChatToolStart(turnID: "t", id: "n0", name: "claude-in-chrome:navigate", argsJSON: "{}")),
                .toolEnd(ChatToolEnd(turnID: "t", id: "n0", ok: false, summary: "hook error: host not allowed",
                                     sources: [])),
                .toolStart(ChatToolStart(turnID: "t", id: "n1", name: "claude-in-chrome:navigate", argsJSON: "{}")),
                .toolEnd(ChatToolEnd(turnID: "t", id: "n1", ok: true,
                                     summary: "Browser extension is not connected. Ask the user to connect it.",
                                     sources: [])),
                call: turn)
        await untilObserved { session.mode == .words }
        XCTAssertEqual(session.presentation.modeLine, "I'll tell you each step")
        XCTAssertTrue(session.presentation.wordsOnly)

        ai.emit(.text("The browser is gone; let's continue in words."), call: turn)
        ai.finish(call: turn)
        await ai.untilCalls(turn + 2)
        let followUp = ai.calls[turn + 1]
        XCTAssertTrue(followUp.prompt.contains(ConnectBrowserProbe.lostFollowUp))
        XCTAssertEqual(followUp.connectArgs?.last, "words")
        XCTAssertEqual(session.state, .thinking, "not an error state")
    }

    func testProbeWithNoBrowserRunsInWords() async {
        let session = make(browserHarness)
        let turn = await startRun(session, probe: "[]")
        XCTAssertEqual(session.mode, .words)
        XCTAssertFalse(session.browserAvailable)
        XCTAssertEqual(ai.calls[turn].connectArgs?.last, "words")
        XCTAssertTrue(ai.terminated[turn - 1], "the probe's process ends once it answered")

        // A words harness and Guide me in words never probe.
        let words = make(wordsHarness)
        let wordsTurn = await startRun(words)
        XCTAssertEqual(ai.calls[wordsTurn].prompt, ConnectAssistantSession.startPrompt)
        let chosen = make(browserHarness)
        let before = ai.calls.count
        chosen.guideInWords()
        await chosen.prepared()
        await chosen.engine?.started()
        XCTAssertEqual(ai.calls.count, before + 1)
        XCTAssertEqual(ai.calls[before].connectArgs?.last, "words")
        XCTAssertTrue(chosen.browserAvailable)
    }

    /// Defence in depth behind `--connect-mode probe`: a connect tool call
    /// that reaches the socket while the probe runs never gets to the controller.
    func testProbeNeverReachesTheController() async {
        let session = make(browserHarness)
        session.start()
        await ai.untilCalls(1)
        XCTAssertEqual(ai.calls[0].connectArgs, ConnectBrowserProbe.connectArgs(service: "slack"))
        XCTAssertEqual(ai.calls[0].extraEnvironment, [:])

        for tool in ["connect_start", "request_secret", "connect_status"] {
            let answer = await session.handle(request(tool, #"{"kind":"slack_config_token","label":"Token"}"#))
            XCTAssertEqual(answer.error?.code, .closed, tool)
            XCTAssertEqual(answer.error?.message, ConnectAssistantSession.probingMessage, tool)
        }
        XCTAssertTrue(driver.starts.isEmpty)
        XCTAssertNil(session.controller?.pendingCard)
        XCTAssertEqual(session.state, .thinking)

        ai.emit(.toolStart(ChatToolStart(turnID: "p", id: "probe", name: "claude-in-chrome:list_connected_browsers",
                                         argsJSON: "{}")),
                .toolEnd(ChatToolEnd(turnID: "p", id: "probe", ok: true, summary: "[]", sources: [])), call: 0)
        await session.prepared()
        let status = await session.handle(request("connect_status"))
        XCTAssertNil(status.error, "after the probe the run's calls reach the controller")
    }

    /// The probe's answer holds for one run only: closed with no browser,
    /// reopened once the extension is connected, the run drives the browser.
    func testEveryRunProbesAgain() async {
        let session = make(browserHarness)
        let first = await startRun(session, probe: "[]")
        XCTAssertEqual(session.mode, .words)
        XCTAssertEqual(ai.calls[first].connectArgs?.last, "words")

        session.close()
        XCTAssertTrue(session.browserAvailable)
        let second = await startRun(session, probe: #"[{"id":"b1"}]"#)
        XCTAssertEqual(ai.calls[second - 1].prompt, ConnectBrowserProbe.prompt, "the reopened run probed")
        XCTAssertEqual(session.mode, .browser)
        XCTAssertEqual(ai.calls[second].connectArgs?.last, "browser")

        // Retry probes again too.
        session.retry()
        await ai.untilCalls(second + 2)
        XCTAssertEqual(ai.calls[second + 1].prompt, ConnectBrowserProbe.prompt)
    }

    func testProbeReadsResultDefensively() {
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: "[]"), .words)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: " [ ] "), .words)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: #"[{"id":"b1","name":"Chrome"}]"#), .browser)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: #"{"browsers":[{"id":"b1"}]}"#), .browser)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: #"{"browsers":[]}"#), .words)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: #"[{"id":"b1","name":"Chr"#), .browser, "a cut summary")
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: "["), .words)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: "Browser extension is not connected."), .words)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: "No browsers found"), .words)
        XCTAssertEqual(ConnectBrowserProbe.mode(fromResult: ""), .words)
        XCTAssertTrue(ConnectBrowserProbe.isBrowserTool("mcp__claude-in-chrome__navigate"))
        XCTAssertTrue(ConnectBrowserProbe.isBrowserTool("claude-in-chrome:list_connected_browsers",
                                                        named: ConnectBrowserProbe.listTool))
        XCTAssertFalse(ConnectBrowserProbe.isBrowserTool("claude-in-chrome:navigate", named: ConnectBrowserProbe.listTool))
        XCTAssertFalse(ConnectBrowserProbe.isBrowserTool("connect_start"))
    }

    func testProbeFailureIsWords() async {
        let session = make(browserHarness)
        session.start()
        await ai.untilCalls(1)
        ai.finish(call: 0, throwing: WatchtowerAIError.exitCode(1, "probe failed"))
        await session.prepared()
        await session.engine?.started()
        XCTAssertEqual(session.mode, .words)
        XCTAssertEqual(ai.calls[1].connectArgs?.last, "words")
    }

    // MARK: - Failures

    func testQuotaIsErrorWithRetryAndHand() async {
        let session = make(wordsHarness)
        let turn = await startRun(session)
        let firstController = session.controller
        ai.emit(.failure(ChatSessionError(turnID: "t", code: .rateLimit, message: "You've hit your usage limit",
                                          retryable: false, reason: "quota_exhausted")), call: turn)
        ai.finish(call: turn)
        await untilObserved { session.state == .failed(.quota) }
        XCTAssertEqual(session.presentation.actions, [.retry, .setUpByHand])
        XCTAssertEqual(session.harness, wordsHarness, "no fallback to another harness")
        XCTAssertEqual(ai.calls.count, turn + 1, "no automatic rerun")

        session.retry()
        await session.prepared()
        await session.engine?.started()
        XCTAssertFalse(session.controller === firstController, "Retry builds a fresh controller")
        XCTAssertEqual(ai.calls.count, turn + 2)
        XCTAssertEqual(session.state, .thinking)
        XCTAssertNotEqual(socket(turn + 1), socket(turn), "and a fresh socket")

        // The CLI missing.
        ai.finish(call: turn + 1, throwing: WatchtowerAIError.cliNotFound)
        await untilObserved { session.state == .failed(.harnessMissing) }
        XCTAssertEqual(session.presentation.actions, [.retry, .setUpByHand])
    }

    func testFailureMapping() {
        typealias Failure = EmbeddedChatErrorClassifier.Failure
        XCTAssertEqual(ConnectAssistantSession.failure(Failure(code: .quotaExhausted, message: "limit")), .quota)
        XCTAssertEqual(ConnectAssistantSession.failure(EmbeddedChatErrorClassifier.classify(WatchtowerAIError.cliNotFound)),
                       .harnessMissing)
        XCTAssertEqual(ConnectAssistantSession.failure(Failure(code: .providerUnavailable,
                                                               message: #"exec: "agent": executable file not found in $PATH"#)),
                       .harnessMissing)
        XCTAssertEqual(ConnectAssistantSession.failure(Failure(code: .providerUnavailable, message: "timed out")),
                       .agent(reason: "timed out"))
        XCTAssertEqual(ConnectAssistantSession.failure(Failure(code: nil, message: "boom")), .agent(reason: "boom"))
        XCTAssertEqual(ConnectAssistantSession.failure(nil), .agent(reason: nil))
    }

    // MARK: - Run ends

    func testSwitchHarnessEndsRunAndKeepsNoFallback() async throws {
        let session = make(wordsHarness)
        let turn = await startRun(session)
        let controller = try XCTUnwrap(session.controller)
        let engine = try XCTUnwrap(session.engine)
        let socketPath = socket(turn)

        session.switchHarness(browserHarness)
        XCTAssertEqual(session.harness, browserHarness)
        XCTAssertEqual(session.state, .empty)
        XCTAssertEqual(session.presentation.actions, [.start, .guideInWords, .setUpByHand])
        XCTAssertNil(session.controller)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        let late = await controller.handle(request("connect_status"))
        XCTAssertEqual(late.error?.code, .closed)
        await engine.finished()
        XCTAssertTrue(ai.terminated[turn], "the run's turn is stopped")
        XCTAssertEqual(ai.calls.count, turn + 1, "nothing starts by itself on the new harness")

        session.switchHarness(ConnectHarness(id: "other", name: "Other", capability: .browser))
        XCTAssertEqual(session.harness, browserHarness, "only an offered harness")
    }

    /// The panel closed mid-turn, with a call held behind a card.
    func testCloseStopsServerAndEngine() async throws {
        let session = make(wordsHarness)
        let turn = await startRun(session)
        let controller = try XCTUnwrap(session.controller)
        let engine = try XCTUnwrap(session.engine)
        let socketPath = socket(turn)
        let held = Task { await controller.handle(request("request_secret", #"{"kind":"slack_config_token","label":"Token"}"#)) }
        await untilObserved { session.state == .secret(label: "Token") }

        session.close()
        let answer = await held.value
        XCTAssertEqual(answer.error?.code, .closed)
        XCTAssertNil(session.engine)
        XCTAssertNil(session.controller)
        XCTAssertEqual(session.state, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (socketPath as NSString).deletingLastPathComponent))
        await engine.finished()
        XCTAssertTrue(ai.terminated[turn])
        XCTAssertTrue(driver.cancels.isEmpty, "a flow on the driver keeps today's behaviour")
    }

    /// App quit: the center ends every run.
    func testAppQuitEndsEveryRun() async {
        let session = make(wordsHarness)
        let center = ConnectAssistantCenter { _ in session }
        let turn = await startRun(center.session(for: "slack") ?? session)
        let socketPath = socket(turn)
        center.closeAll()
        XCTAssertEqual(session.state, .empty)
        XCTAssertNil(session.controller)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testCancelEndsRunAndKeepsTheChat() async throws {
        let session = make(wordsHarness)
        let turn = await startRun(session)
        let socketPath = socket(turn)
        XCTAssertEqual(session.presentation.actions, [.cancel])
        session.cancel()
        XCTAssertEqual(session.state, .empty)
        XCTAssertNotNil(session.engine, "the chat stays in view")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testReopenResumesFromStatus() async throws {
        let session = make(wordsHarness)
        let first = await startRun(session)
        XCTAssertEqual(ai.calls[first].systemPrompt, ConnectAssistantSession.systemPrompt(
            status: #"{"accounts":[],"flow":null,"policy_locked":false,"service":"slack","setup":null}"#))

        // Mid-flow the Slack app was created; the panel closes and reopens.
        driver.currentStatus = ConnectStatus(service: "slack", setup: .init(stage: "pending_create"))
        session.close()
        let second = await startRun(session)
        let prompt = try XCTUnwrap(ai.calls[second].systemPrompt)
        XCTAssertTrue(prompt.contains(#""setup":{"stage":"pending_create"}"#), prompt)
        XCTAssertNotEqual(socket(second), socket(first))
    }

    /// Each run's socket is bound to that run's controller: after Retry, a
    /// late call of the old run answers `closed` and never opens a card on
    /// the new one.
    func testLateCallOfAnEndedRunNeverReachesTheNext() async throws {
        let session = make(wordsHarness)
        _ = await startRun(session)
        let first = try XCTUnwrap(session.controller)
        let firstSocket = session.handler(for: first)
        session.retry()
        await session.prepared()
        await session.engine?.started()
        let second = try XCTUnwrap(session.controller)
        XCTAssertFalse(first === second)

        let late = await firstSocket(request("request_secret", #"{"kind":"slack_config_token","label":"Token"}"#))
        XCTAssertEqual(late.error?.code, .closed)
        XCTAssertNil(second.pendingCard, "the new run never saw the old run's call")
        let current = await session.handler(for: second)(request("connect_status"))
        XCTAssertNil(current.error, "the new run's own socket still serves")
    }

    func testOneSessionPerService() {
        var made: [String] = []
        let center = ConnectAssistantCenter { [self] service in
            made.append(service)
            guard service != "none" else { return nil }
            return ConnectAssistantSession(
                service: service, displayName: service, harnesses: [wordsHarness], initial: wordsHarness,
                driver: FakeConnectDriver(service: service, secretKinds: []), aiService: ai,
                probe: ConnectBrowserProbe(aiService: ai), gate: EmbeddedStreamGate())
        }
        let slack = center.session(for: "slack")
        XCTAssertNotNil(slack)
        XCTAssertTrue(center.session(for: "slack") === slack, "a second panel is the same session")
        XCTAssertFalse(center.session(for: "jira") === slack)
        XCTAssertNil(center.session(for: "none"))
        XCTAssertEqual(made, ["slack", "jira", "none"])
    }

    func testSecretNeverInEngineRows() async throws {
        let secret = "s3cret-value-for-the-test"
        let session = make(wordsHarness)
        let turn = await startRun(session)
        let controller = try XCTUnwrap(session.controller)
        let args = #"{"kind":"slack_config_token","label":"Token"}"#
        ai.emit(.toolStart(ChatToolStart(turnID: "t", id: "s1", name: "request_secret", argsJSON: args)), call: turn)
        let held = Task { await controller.handle(request("request_secret", args)) }
        await untilObserved { session.state == .secret(label: "Token") }

        session.controller?.sendSecret(secret)
        let response = await held.value
        XCTAssertEqual(driver.secrets.map(\.value), [secret])
        let answer = try XCTUnwrap(String(bytes: JSONEncoder().encode(response), encoding: .utf8))
        XCTAssertFalse(answer.contains(secret))

        ai.emit(.toolEnd(ChatToolEnd(turnID: "t", id: "s1", ok: true, summary: answer, sources: [])),
                .text("Thanks, the token is in."), call: turn)
        ai.finish(call: turn)
        await untilObserved { session.state == .listening }
        let engine = try XCTUnwrap(session.engine)
        XCTAssertFalse(engine.messages.isEmpty)
        for item in engine.messages {
            XCTAssertFalse(item.message.text.contains(secret))
            XCTAssertFalse(item.steps.contains { "\($0)".contains(secret) })
        }
        XCTAssertFalse("\(session.presentation)".contains(secret))
        XCTAssertEqual(session.presentation.actions, [.cancel])
        XCTAssertNil(session.presentation.status)
    }
}

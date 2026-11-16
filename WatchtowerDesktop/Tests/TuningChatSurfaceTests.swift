import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Analytics' tuning chat surface (spec 2026-11-03 §4.1): `--surface tuning`
/// on a CLI provider, draft-only on an HTTP one or an unread catalog (AGENT-04,
/// ask #1132, D52), the `tuning.chat` purpose on every turn (D53), the pane's
/// workbench and period in each turn, and conversations kept out of the
/// Chats panel (ask #1123). The provider ids below are data for the seeded
/// catalog, never compared in Sources (LLMTRANSPORT-01).
@MainActor
final class TuningChatSurfaceTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { ProviderCatalogFixture.seedShared() }
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        await MainActor.run { ProviderCatalogFixture.seedShared() }
        TestDatabase.cleanup(path: dbPath)
        try await super.tearDown()
    }

    private var pool: DatabasePool { dbManager.dbPool }

    private func spec(
        provider: String = "claude",
        conversationID: Int64? = nil,
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period = { .week }
    ) async throws -> ChatSurfaceSpec {
        let conv: Int64
        if let conversationID {
            conv = conversationID
        } else {
            conv = try await TuningChatSurface.latestOrNewConversation(dbPool: pool, workbenchID: 3)
        }
        return TuningChatSurface.spec(workbenchID: 3, conversationID: conv, provider: provider,
                                      period: period) {}
    }

    private func turn(_ engine: EmbeddedChatEngine, _ ai: ScriptedAIService, _ text: String) async {
        let before = ai.calls.count
        XCTAssertTrue(engine.send(text))
        await engine.finished()
        let started = await eventually { ai.calls.count == before + 1 }
        XCTAssertTrue(started)
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        await engine.finished()
    }

    // MARK: - Tool access and purpose

    func testSpecIsActionsTuningWithContext() async throws {
        let spec = try await spec()
        let conv = try XCTUnwrap(spec.key.conversationID)
        XCTAssertEqual(spec.toolAccess, .actions(surface: "tuning"))
        XCTAssertTrue(spec.ownerInstructions)
        XCTAssertEqual(spec.persistence, .database(conversationID: conv))

        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec, dbPool: pool, ai: ai)
        await turn(engine, ai, "Why did cost grow?")
        let call = try XCTUnwrap(ai.calls.first)
        let args = try XCTUnwrap(call.toolMode).cliArgs
        XCTAssertEqual(Array(args.prefix(4)), ["--tools", "chat", "--surface", "tuning"])
        XCTAssertEqual(Array(args.suffix(4)), ["--context-type", "analytics_tuning", "--context-id", "3"])
        let flag = try XCTUnwrap(args.firstIndex(of: "--conversation"))
        XCTAssertEqual(args[flag + 1], String(conv))
        XCTAssertTrue(call.ownerInstructions)
        XCTAssertEqual(call.purpose, "tuning.chat")
        let system = try XCTUnwrap(call.systemPrompt)
        XCTAssertTrue(system.contains(AgentToolsContract.promptBlock(surface: .tuning)))
        XCTAssertTrue(system.contains(ChatQuestionsContract.promptBlock))
    }

    func testDraftOnlyTurnKeepsThePurpose() async throws {
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(try await spec(provider: "ollama"), dbPool: pool, ai: ai)
        await turn(engine, ai, "hello")
        let call = try XCTUnwrap(ai.calls.first)
        XCTAssertNil(call.toolMode)
        XCTAssertEqual(call.purpose, "tuning.chat")
    }

    func testOllamaIsDraftOnly() async throws {
        XCTAssertFalse(TuningChatSurface.toolsAvailable(provider: "ollama"))
        XCTAssertTrue(TuningChatSurface.toolsAvailable(provider: "claude"))
        XCTAssertTrue(TuningChatSurface.toolsAvailable(provider: "codex"))

        let spec = try await spec(provider: "ollama")
        XCTAssertEqual(spec.toolAccess, .draftOnly)
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let engine = makeSurfaceEngine(spec, dbPool: pool, ai: mock)
        engine.send("hello")
        await engine.finished()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(mock.toolModes, [nil])
        let system = spec.systemPrompt()
        XCTAssertTrue(system.contains("Tuning tools are not available for this turn — say so in one line and answer "
            + "from what the owner pastes."))
        XCTAssertFalse(system.contains("=== TUNING TOOLS ==="))
    }

    func testCatalogNotReadYetIsDraftOnly() async throws {
        AIModelCatalog.shared.replaceProviders([])
        defer { ProviderCatalogFixture.seedShared() }
        XCTAssertFalse(TuningChatSurface.toolsAvailable(provider: "claude"))
        let unread = try await spec(provider: "claude")
        XCTAssertEqual(unread.toolAccess, .draftOnly)
        // The model text is neutral about the cause; only the panel names it.
        XCTAssertFalse(unread.systemPrompt().contains("Claude or Codex"))
        XCTAssertFalse(unread.systemPrompt().contains("pick one"))
        XCTAssertEqual(TuningChatSurface.unavailableHelp(),
                       "Tuning tools need Claude or Codex — pick one in Settings → System → AI")

        let failing = AIModelCatalog { nil }
        await failing.loadRetrying(retryDelays: []) { _ in }
        XCTAssertEqual(TuningChatSurface.unavailableHelp(catalog: failing), AIModelCatalog.unreadNotice)
    }

    // MARK: - Prompts

    func testTurnPromptCarriesPeriodAndWorkbench() async throws {
        XCTAssertEqual(TuningChatSurface.turnContext(workbenchID: 3, period: .week, tools: true),
                       "=== ANALYTICS PANE ===\nWorkbench: 3 (pass workbench_id: 3)\nPeriod: the last 7 days (pass days: 7)")
        var period = AgentAnalyticsCenter.Period.week
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(try await spec { period }, dbPool: pool, ai: ai)
        await turn(engine, ai, "first")
        period = .month
        await turn(engine, ai, "second")
        XCTAssertEqual(ai.calls.count, 2)
        XCTAssertTrue(ai.calls[0].prompt.contains(TuningChatSurface.turnContext(workbenchID: 3, period: .week, tools: true)))
        XCTAssertTrue(ai.calls[0].prompt.contains("first"))
        XCTAssertTrue(ai.calls[1].prompt.contains("(pass days: 30)"))
        XCTAssertTrue(TuningChatSurface.turnContext(workbenchID: 3, period: .day, tools: true).contains("(pass days: 1)"))
    }

    func testDraftOnlyTurnContextHasNoToolHint() async throws {
        XCTAssertEqual(TuningChatSurface.turnContext(workbenchID: 3, period: .week, tools: false),
                       "=== ANALYTICS PANE ===\nWorkbench: 3\nPeriod: the last 7 days")
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(try await spec(provider: "ollama"), dbPool: pool, ai: ai)
        await turn(engine, ai, "hello")
        let prompt = try XCTUnwrap(ai.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("Workbench: 3\nPeriod: the last 7 days"))
        XCTAssertFalse(prompt.contains("pass "))
    }

    /// The tool contract's rules are said once: the surface's own rules
    /// never repeat them.
    func testToolsOnSaysTheContractRulesOnce() {
        let system = TuningChatSurface.systemPrompt(tools: true)
        let staleLine = "If no tuning tool is in your tool list, answer only \"Tuning tools are not available in this "
            + "Watchtower build — update Watchtower.\" and propose nothing."
        for line in [staleLine, "list_coach_proposals", "never change anything yourself", "propose_tuning_edit —"] {
            XCTAssertEqual(system.components(separatedBy: line).count - 1, 1, line)
        }
        XCTAssertEqual(system.components(separatedBy: "propose_tuning_edit").count - 1,
                       AgentToolsContract.promptBlock(surface: .tuning)
                           .components(separatedBy: "propose_tuning_edit").count - 1,
                       "the tool is named only by the contract")
    }

    func testRulesSayAcceptWritesTheFolderFile() {
        XCTAssertTrue(TuningChatSurface.rulesBlock(tools: true).contains(
            "A workbench folder file is written by Accept on its card, and the owner commits it."))
        for prompt in [TuningChatSurface.systemPrompt(tools: true), TuningChatSurface.systemPrompt(tools: false)] {
            XCTAssertFalse(prompt.contains("replay"))
            XCTAssertFalse(prompt.contains("captured"))
        }
    }

    func testWillSendRunsTheHook() async throws {
        var calls = 0
        let conv = try await TuningChatSurface.latestOrNewConversation(dbPool: pool, workbenchID: 3)
        let spec = TuningChatSurface.spec(workbenchID: 3, conversationID: conv, provider: "claude",
                                          period: { .week }, onWillSend: { calls += 1 })
        XCTAssertTrue(spec.willSend("hi"))
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Conversations

    func testRecentListsTenNewestOfThisWorkbenchOnly() async throws {
        let ids = try await pool.write { db -> [Int64] in
            var ids: [Int64] = []
            for index in 0..<12 {
                let row = try ChatConversationQueries.create(db, contextType: "analytics_tuning", contextID: "3")
                try db.execute(sql: "UPDATE chat_conversations SET updated_at = ? WHERE id = ?",
                               arguments: [1000 + index, row.id])
                ids.append(row.id)
            }
            let other = try ChatConversationQueries.create(db, contextType: "analytics_tuning", contextID: "30")
            try db.execute(sql: "UPDATE chat_conversations SET updated_at = ? WHERE id = ?",
                           arguments: [5000, other.id])
            return ids
        }
        let recent = try await pool.read { try TuningChatSurface.recent($0, workbenchID: 3) }.map(\.id)
        XCTAssertEqual(recent, Array(ids.reversed().prefix(10)))
    }

    func testNewConversationIsAnotherRow() async throws {
        let first = try await TuningChatSurface.newConversation(dbPool: pool, workbenchID: 3)
        let second = try await TuningChatSurface.newConversation(dbPool: pool, workbenchID: 3)
        XCTAssertNotEqual(first, second)
        for id in [first, second] {
            let row = try await pool.read { try ChatConversationQueries.fetchByID($0, id: id) }
            XCTAssertEqual(row?.contextType, "analytics_tuning")
            XCTAssertEqual(row?.contextID, "3")
        }
        try await pool.write { db in
            try db.execute(sql: "UPDATE chat_conversations SET updated_at = 2000 WHERE id = ?", arguments: [first])
            try db.execute(sql: "UPDATE chat_conversations SET updated_at = 1000 WHERE id = ?", arguments: [second])
        }
        let latest = try await TuningChatSurface.latestOrNewConversation(dbPool: pool, workbenchID: 3)
        XCTAssertEqual(latest, first, "the most recently updated conversation is reused")
    }

    func testNoKnowledgePrefixInTuning() {
        XCTAssertFalse(EmbeddedChatEngineFactory.savesKnowledge(contextType: "analytics_tuning"))
        XCTAssertFalse(EmbeddedChatEngineFactory.savesKnowledge(contextType: CodeQuestionList.contextType))
        XCTAssertFalse(EmbeddedChatEngineFactory.savesKnowledge(contextType: SpecReviewThreadKey.contextType))
        XCTAssertTrue(EmbeddedChatEngineFactory.savesKnowledge(contextType: "meeting"))
    }

    func testTuningConversationNotInMainChatHistory() async throws {
        let conv = try await TuningChatSurface.latestOrNewConversation(dbPool: pool, workbenchID: 3)
        let standalone = try await pool.read { try ChatConversationQueries.fetchStandalone($0) }.map(\.id)
        XCTAssertFalse(standalone.contains(conv))
        let panel = try await pool.read { try ChatHistoryQueries.panelRows($0, projectID: nil) }
        XCTAssertFalse(panel.contains { $0.conversation.id == conv })
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The tuning panel's controller (spec 2026-11-03 §4.1): one engine per
/// conversation in the app-wide center, shown while the panel is open,
/// AGENT-04's tool access decided again before each turn and after a catalog
/// read (ollama stays draft-only, ask #1132, D52), the conversation's title
/// and its proposal cards after each turn. The provider ids below are data
/// for the seeded catalog, never compared in Sources (LLMTRANSPORT-01).
@MainActor
final class TuningChatTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var chats: [TuningChat] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { ProviderCatalogFixture.seedShared() }
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        chats.forEach { $0.close() }
        chats = []
        await MainActor.run { ProviderCatalogFixture.seedShared() }
        TestDatabase.cleanup(path: dbPath)
        try await super.tearDown()
    }

    private var pool: DatabasePool { dbManager.dbPool }

    private func center(
        _ ai: any AIServiceProtocol,
        idleTTL: TimeInterval = 300,
        clock: @escaping () -> Date = Date.init
    ) -> EmbeddedChatCenter {
        let pool = self.pool
        return EmbeddedChatCenter(idleTTL: idleTTL, clock: clock) { spec, gate in
            makeSurfaceEngine(spec, dbPool: pool, ai: ai, gate: gate)
        }
    }

    private func chat(
        _ center: EmbeddedChatCenter,
        conversationID: Int64? = nil,
        coach: CoachCenter? = nil,
        decideTools: @escaping @MainActor () -> Bool = { TuningChatSurface.toolsAvailable(provider: "claude") },
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period = { .week }
    ) async throws -> TuningChat {
        let conv: Int64
        if let conversationID {
            conv = conversationID
        } else {
            conv = try await TuningChatSurface.latestOrNewConversation(dbPool: pool, workbenchID: 3)
        }
        let chat = TuningChat(workbenchID: 3, conversationID: conv, dbPool: pool, center: center, coach: coach,
                              decideTools: decideTools, period: period)
        chats.append(chat)
        return chat
    }

    /// One owner turn answered with "ok"; `before` lets the caller write
    /// rows while the turn streams (an action the tool call made).
    private func turn(
        _ chat: TuningChat,
        _ ai: ScriptedAIService,
        _ text: String,
        while before: (() throws -> Void)? = nil
    ) async throws {
        let calls = ai.calls.count
        XCTAssertTrue(chat.engine.send(text))
        await chat.engine.finished()
        let started = await eventually { ai.calls.count == calls + 1 }
        XCTAssertTrue(started)
        try before?()
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
        let done = await eventually { !chat.engine.isStreaming }
        XCTAssertTrue(done)
        await chat.engine.finished()
    }

    private func title(_ conversationID: Int64) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM chat_conversations WHERE id = ?",
                                arguments: [conversationID])
        }
    }

    // MARK: - Shown / hidden

    func testShownWhileOpenHiddenAfterClose() async throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let center = center(ScriptedAIService(), idleTTL: 300) { now }
        let chat = try await chat(center)
        let key = chat.engine.spec.key
        now += 301
        center.sweep(now: now)
        XCTAssertNotNil(center.loaded(key), "an open panel keeps its engine")

        chat.close()
        now += 301
        center.sweep(now: now)
        XCTAssertNil(center.loaded(key), "a closed panel's engine is let go after the idle time")
    }

    func testSecondScreenAttachesToTheSameEngine() async throws {
        let center = center(ScriptedAIService())
        let first = try await chat(center)
        let second = try await chat(center, conversationID: first.conversationID)
        XCTAssertTrue(first.engine === second.engine)
    }

    /// Both panels on one engine hear its turn end (the engine has one
    /// `onTurnFinished` slot).
    func testBothPanelsRefreshAfterATurn() async throws {
        let ai = ScriptedAIService()
        let center = center(ai)
        let first = try await chat(center)
        let second = try await chat(center, conversationID: first.conversationID)
        let conv = first.conversationID
        try await turn(second, ai, "Make it shorter") {
            try self.insertProposal(21, conversationID: conv)
        }
        let both = await eventually { first.cards.trailing == [.proposal(21)] && second.cards.trailing == [.proposal(21)] }
        XCTAssertTrue(both)
    }

    /// AGENT-04 holds after the panel whose spec the engine carries closed:
    /// the other panel on the conversation still decides before the turn.
    func testProviderSwitchAfterTheLastPanelClosed() async throws {
        let ai = ScriptedAIService()
        let center = center(ai)
        var provider = "claude"
        let decide = { @MainActor in TuningChatSurface.toolsAvailable(provider: provider) }
        let first = try await chat(center, decideTools: decide)
        let second = try await chat(center, conversationID: first.conversationID, decideTools: decide)
        second.close()
        provider = "ollama"
        try await turn(first, ai, "hello")
        XCTAssertNil(ai.calls.first?.toolMode)
        XCTAssertFalse(first.toolsAvailable)
    }

    /// The title is the engine's, not the panel's: a panel closed and gone
    /// mid-turn still leaves a titled conversation.
    func testTitleWrittenWhenThePanelWentMidTurn() async throws {
        let ai = ScriptedAIService()
        let center = center(ai)
        var panel: TuningChat? = try await chat(center)
        let engine = try XCTUnwrap(panel?.engine)
        let conv = try XCTUnwrap(panel?.conversationID)
        XCTAssertTrue(engine.send("Why did cost grow?"))
        await engine.finished()
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        panel?.close()
        chats.removeAll()
        panel = nil
        XCTAssertNil(panel)
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
        _ = await eventually { !engine.isStreaming }
        await engine.finished()
        let titled = await eventually { (try? self.title(conv)) == "Why did cost grow?" }
        XCTAssertTrue(titled)
    }

    private func insertProposal(_ id: Int64, conversationID: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO coach_proposals (id, fingerprint, kind, destination, title, why, metric, after_text,
                                             sources, created_at, origin, conversation_id)
                VALUES (?, ?, 'replace', 'session', 'Shorter', 'why', 'corrections', 'Be brief.',
                        1, '2026-11-01T00:00:00Z', 'chat', ?)
                """, arguments: [id, "fp-\(id)", conversationID])
        }
    }

    func testDeletedWorkbenchDropsTheEngine() async throws {
        let center = center(ScriptedAIService())
        let chat = try await chat(center)
        let key = chat.engine.spec.key
        center.dropContext(type: "analytics_tuning", id: "3")
        XCTAssertNil(center.loaded(key))
    }

    // MARK: - Turns

    func testPeriodCarriedIntoTurns() async throws {
        let ai = ScriptedAIService()
        var period = AgentAnalyticsCenter.Period.day
        let chat = try await chat(center(ai)) { period }
        try await turn(chat, ai, "first")
        period = .month
        try await turn(chat, ai, "second")
        XCTAssertEqual(ai.calls.count, 2)
        XCTAssertTrue(ai.calls[0].prompt.contains("days: 1"))
        XCTAssertTrue(ai.calls[1].prompt.contains("days: 30"))
    }

    func testProviderSwitchMakesTheNextTurnDraftOnly() async throws {
        let ai = ScriptedAIService()
        let runner = FakeCLIRunner()
        let coach = CoachCenter(runner: runner)
        var provider = "claude"
        let decide = { @MainActor in TuningChatSurface.toolsAvailable(provider: provider) }
        let chat = try await chat(center(ai), coach: coach, decideTools: decide)
        try await turn(chat, ai, "first")
        provider = "ollama"
        try await turn(chat, ai, "second")

        XCTAssertEqual(ai.calls.count, 2)
        let tools = try XCTUnwrap(ai.calls[0].toolMode).cliArgs
        XCTAssertEqual(Array(tools.prefix(4)), ["--tools", "chat", "--surface", "tuning"])
        XCTAssertNil(ai.calls[1].toolMode)
        XCTAssertFalse(chat.toolsAvailable)
        XCTAssertEqual(chat.engine.spec.toolAccess, .draftOnly)
        XCTAssertEqual(ai.calls.map(\.purpose), ["tuning.chat", "tuning.chat"])

        // Accept is the CLI's, not gated on the provider.
        await coach.accept(21, editedText: nil)
        XCTAssertTrue(runner.invocations.contains(["coach", "accept", "21", "--json"]))
    }

    func testToolAccessDecidedAgainWhenTheCatalogLoads() async throws {
        defer { ProviderCatalogFixture.seedShared() }
        for (provider, tools) in [("claude", true), ("codex", true), ("ollama", false)] {
            AIModelCatalog.shared.replaceProviders([])
            let decide = { @MainActor in TuningChatSurface.toolsAvailable(provider: provider) }
            let chat = try await chat(center(MockClaudeService()), decideTools: decide)
            XCTAssertFalse(chat.toolsAvailable, "\(provider): draft-only before the catalog is read")
            XCTAssertEqual(chat.engine.spec.toolAccess, .draftOnly)

            ProviderCatalogFixture.seedShared()
            XCTAssertEqual(chat.toolsAvailable, tools, provider)
            XCTAssertEqual(chat.engine.spec.toolAccess, tools ? .actions(surface: "tuning") : .draftOnly, provider)
            chat.close()
        }
    }

    /// §5's stale CLI row: an older CLI refuses the surface at start.
    func testStartErrorShowsRetry() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(center(ai))
        XCTAssertTrue(chat.engine.send("hello"))
        await chat.engine.finished()
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        ai.finish(throwing: WatchtowerAIError.exitCode(1, "unknown surface \"tuning\""))
        let done = await eventually { !chat.engine.isStreaming }
        XCTAssertTrue(done)
        await chat.engine.finished()
        XCTAssertEqual(chat.engine.messages.last?.message.status, "error")
        XCTAssertTrue(chat.engine.canRetry)
    }

    // MARK: - Conversations

    func testNewStartsAnotherConversation() async throws {
        let ai = ScriptedAIService()
        var now = Date()
        let center = center(ai, idleTTL: 300) { now }
        let chat = try await chat(center)
        let oldKey = chat.engine.spec.key
        let old = chat.conversationID

        await chat.startNew()
        XCTAssertNotEqual(chat.conversationID, old)
        XCTAssertNotEqual(chat.engine.spec.key, oldKey)
        now += 301
        center.sweep(now: now)
        XCTAssertNil(center.loaded(oldKey), "the old conversation is hidden")
        XCTAssertNotNil(center.loaded(chat.engine.spec.key))

        try await turn(chat, ai, "a new question")
        let listed = await eventually { chat.recent.first?.id == chat.conversationID }
        XCTAssertTrue(listed)
    }

    func testTitleFromFirstOwnerMessage() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(center(ai))
        let first = String(repeating: "Why did the cost of this workbench grow ", count: 3)
        // 60 characters, the cut's trailing space trimmed.
        let expected = String(first.prefix(60)).trimmingCharacters(in: .whitespaces)
        try await turn(chat, ai, first)
        let titled = await eventually { (try? self.title(chat.conversationID)) == expected }
        XCTAssertTrue(titled)

        try await turn(chat, ai, "Something else entirely")
        await chat.refreshCards()
        XCTAssertEqual(try title(chat.conversationID), expected)
    }

    // MARK: - Cards

    func testCardsAfterTurn() async throws {
        let ai = ScriptedAIService()
        let runner = FakeCLIRunner()
        let coach = CoachCenter(runner: runner)
        let chat = try await chat(center(ai), coach: coach)
        let conv = chat.conversationID
        try await turn(chat, ai, "Make the session instructions shorter") {
            let turnID = try XCTUnwrap(chat.engine.messages.last { $0.message.isUser }?.message.turnID)
            try self.insertProposal(21, conversationID: conv)
            try self.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO agent_actions (tool, args_json, conversation_id, turn_id, status, result_json)
                    VALUES ('propose_tuning_edit', '{}', ?, ?, 'applied', '{"proposal_id":21}')
                    """, arguments: [conv, turnID])
            }
        }
        let turnID = try XCTUnwrap(chat.engine.messages.last { $0.message.isUser }?.message.turnID)
        let carded = await eventually { chat.cards.byTurn[turnID] == [.proposal(21)] }
        XCTAssertTrue(carded)
        XCTAssertEqual(chat.cards.trailing, [])
        let refreshed = await eventually {
            runner.invocations.contains { Array($0.prefix(4)) == ["coach", "proposals", "--status", "all"] }
        }
        XCTAssertTrue(refreshed, "\(runner.invocations)")
    }

    func testStarterSendsOrFillsTheComposer() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(center(ai))
        chat.send(starter: ChatStarterPrompt(title: "Fill", text: "Look at PROJ-", sendsImmediately: false))
        XCTAssertEqual(chat.engine.draft, "Look at PROJ-")
        XCTAssertEqual(ai.calls.count, 0)
        chat.send(starter: ChatStarterPrompt(title: "Send", text: "Why did cost grow?", sendsImmediately: true))
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        ai.emit(.text("ok"), .turnComplete("ok"), .done)
        ai.finish()
        _ = await eventually { !chat.engine.isStreaming }
        await chat.engine.finished()
    }
}

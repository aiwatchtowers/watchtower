import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The code question surface (spec 2026-10-02 §9.1, §9.4): draft-only, on
/// the database, the owner's model kept per conversation, the workbench
/// folder handed to `ai query --read-folder` — and never in the main chat.
@MainActor
final class CodeQuestionSurfaceTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var workbench: Workbench!
    private let origin = CodeQuestionOrigin(
        path: "Sources/App.swift", line: 2,
        selection: CodeQuestionSelection(startLine: 2, endLine: 2, text: "load(config)")
    )

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
            workbench = try dbManager.dbPool.write { db -> Workbench in
                let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/work/acme")
                return try XCTUnwrap(Workbench.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id]))
            }
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private var context: CodeQuestionContext {
        CodeQuestionContext.build(folderName: "acme", origin: origin, language: "swift",
                                  fileText: "import Foundation\nload(config)\n") { _ in [] }
    }

    private func conversation(_ choice: CodeQuestionSurface.ModelChoice) throws -> Int64 {
        try CodeQuestionSurface.createConversation(workbenchID: workbench.id, origin: origin, choice: choice,
                                                   dbPool: dbManager.dbPool)
    }

    private func spec(_ conversationID: Int64) -> ChatSurfaceSpec {
        CodeQuestionSurface.spec(workbench: workbench, origin: origin, conversationID: conversationID,
                                 dbPool: dbManager.dbPool, context: context)
    }

    /// Sends `text` and completes the turn with `reply` (and `sessionID`).
    private func turn(
        _ engine: EmbeddedChatEngine,
        _ ai: ScriptedAIService,
        _ text: String,
        reply: String = "It loads the config.",
        sessionID: String? = nil
    ) async {
        let before = ai.calls.count
        engine.send(text)
        let started = await eventually { ai.calls.count == before + 1 }
        XCTAssertTrue(started)
        if let sessionID { ai.emit(.sessionID(sessionID)) }
        ai.emit(.text(reply), .turnComplete(reply), .done)
        ai.finish()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
    }

    // MARK: - Contract

    func testSpecIsDraftOnlyOnTheDatabase() throws {
        let conv = try conversation(.init(provider: .claude, model: ""))
        let spec = spec(conv)
        XCTAssertEqual(spec.toolAccess, .draftOnly, "a code question never acts (AGENT-04)")
        XCTAssertEqual(spec.persistence, .database(conversationID: conv))
        XCTAssertEqual(spec.key, EmbeddedChatKey(contextType: "code_question",
                                                 contextID: "\(workbench.id):Sources/App.swift:2",
                                                 conversationID: conv))
    }

    func testCreateConversationStoresContextAndModel() throws {
        let conv = try conversation(.init(provider: .codex, model: "gpt-5.4"))
        let row = try XCTUnwrap(dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: conv) })
        XCTAssertEqual(row.contextType, "code_question")
        XCTAssertEqual(row.contextID, "\(workbench.id):Sources/App.swift:2")
        XCTAssertEqual(row.provider, "codex")
        XCTAssertEqual(row.model, "gpt-5.4")
        XCTAssertEqual(try CodeQuestionSurface.modelChoice(conversationID: conv, dbPool: dbManager.dbPool),
                       .init(provider: .codex, model: "gpt-5.4"))
    }

    /// The default tier is preselected: the configured provider, "Auto".
    func testDefaultChoiceIsTheConfiguredProviderOnAuto() {
        XCTAssertEqual(CodeQuestionSurface.defaultModelChoice(configProvider: "codex"), .init(provider: .codex, model: ""))
        XCTAssertEqual(CodeQuestionSurface.defaultModelChoice(configProvider: nil), .init(provider: .claude, model: ""))
        XCTAssertEqual(CodeQuestionSurface.ModelChoice(provider: .codex, model: "gpt-5.4").switching(to: .claude),
                       .init(provider: .claude, model: ""), "a provider switch goes back to Auto, as in the main chat")
    }

    // MARK: - Turns

    func testTurnRunsInTheFolderWithTheStoredModel() async throws {
        let conv = try conversation(.init(provider: .claude, model: "claude-sonnet-4-6"))
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec(conv), dbPool: dbManager.dbPool, ai: ai)

        await turn(engine, ai, "Explain this.")
        let call = try XCTUnwrap(ai.calls.first)
        XCTAssertEqual(call.provider, "claude")
        XCTAssertEqual(call.model, "claude-sonnet-4-6")
        XCTAssertEqual(call.readFolder, "/work/acme")
        XCTAssertNil(call.toolMode, "draft-only (AGENT-04)")
        let system = try XCTUnwrap(call.systemPrompt)
        XCTAssertTrue(system.contains("load(config)"))
        XCTAssertTrue(system.contains("Sources/App.swift"))
        XCTAssertTrue(system.contains("wt-edit"))
        XCTAssertTrue(system.contains("read-only file tools Read, Grep, Glob and LS"), "Claude reads the folder (ruling R55)")
        XCTAssertEqual(engine.messages.map(\.message.text), ["Explain this.", "It loads the config."])
        let provider = try await dbManager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT provider FROM chat_messages WHERE role = 'assistant'")
        }
        XCTAssertEqual(provider, "claude", "the reply row names the provider that wrote it")
    }

    /// A follow-up keeps the conversation's model; a new choice applies from
    /// the next turn and is stored.
    func testFollowUpKeepsTheModelAndAChangeIsStored() async throws {
        let conv = try conversation(.init(provider: .claude, model: "claude-sonnet-4-6"))
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec(conv), dbPool: dbManager.dbPool, ai: ai)

        await turn(engine, ai, "Explain this.", sessionID: "s1")
        await turn(engine, ai, "And the caller?")
        XCTAssertEqual(ai.calls.map(\.model), ["claude-sonnet-4-6", "claude-sonnet-4-6"])
        XCTAssertEqual(ai.calls[1].sessionID, "s1")
        XCTAssertNil(ai.calls[1].systemPrompt, "a resumed Claude session already holds the context")

        try CodeQuestionSurface.setModelChoice(.init(provider: .codex, model: "gpt-5.4"), conversationID: conv,
                                               dbPool: dbManager.dbPool)
        await turn(engine, ai, "Any problems?")
        XCTAssertEqual(ai.calls[2].provider, "codex")
        XCTAssertEqual(ai.calls[2].model, "gpt-5.4")
        XCTAssertEqual(ai.calls[2].readFolder, "/work/acme", "codex reads the folder too (ruling R55)")
        XCTAssertNil(ai.calls[2].sessionID, "codex cannot resume a Claude session")
        let codexPrompt = try XCTUnwrap(ai.calls[2].systemPrompt, "so it gets the context again")
        // Codex reads only through its shell: the prompt allows read-only
        // commands and never says it cannot run any.
        XCTAssertTrue(codexPrompt.contains("Read-only shell commands that inspect files of the folder"), codexPrompt)
        XCTAssertTrue(codexPrompt.contains("Never modify, create or delete anything"))
        XCTAssertFalse(codexPrompt.contains("run commands"), "codex is not told it cannot run commands")
        XCTAssertFalse(codexPrompt.contains("Read, Grep, Glob and LS"), "Claude's tool names are not codex's")
        XCTAssertTrue(codexPrompt.contains("load(config)"))
        XCTAssertTrue(engine.messages.allSatisfy { $0.message.role != "system" }, "no notice for a provider that reads")
        let stored = try await dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: conv) }
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row.provider, "codex")
        XCTAssertEqual(row.model, "gpt-5.4")
    }

    /// Ollama has no file tools: no folder, a prompt that says so, and the
    /// notice once per conversation.
    func testOllamaReadsNoFolderAndSaysSoOnce() async throws {
        let conv = try conversation(.init(provider: .ollama, model: "llama3"))
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec(conv), dbPool: dbManager.dbPool, ai: ai)

        await turn(engine, ai, "Explain this.")
        await turn(engine, ai, "More?")
        XCTAssertEqual(ai.calls.map(\.readFolder), [nil, nil])
        XCTAssertTrue(try XCTUnwrap(ai.calls[0].systemPrompt).contains("cannot read"))
        let notices = engine.messages.filter { $0.message.role == "system" }.map(\.message.text)
        XCTAssertEqual(notices, [CodeQuestionSurface.cannotReadFilesNotice])
    }

    /// Board #361: a turn that resumes no provider session carries the
    /// earlier turns; a resumed Claude turn does not (its session has them).
    func testAFollowUpWithoutASessionReplaysTheEarlierTurns() async throws {
        let conv = try conversation(.init(provider: .ollama, model: "llama3"))
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec(conv), dbPool: dbManager.dbPool, ai: ai)

        await turn(engine, ai, "Explain this.", reply: "It loads the config.")
        XCTAssertEqual(ai.calls[0].prompt, "Explain this.", "nothing to replay on the first turn")
        await turn(engine, ai, "And the caller?", reply: "main.swift calls it.")
        let second = ai.calls[1].prompt
        XCTAssertTrue(second.hasPrefix(EmbeddedChatReplay.header), second)
        XCTAssertTrue(second.contains("Owner: Explain this.\nAssistant: It loads the config.\n"), second)
        XCTAssertTrue(second.hasSuffix(EmbeddedChatReplay.footer + "\n\nAnd the caller?"), second)
        XCTAssertFalse(second.contains(CodeQuestionSurface.cannotReadFilesNotice), "notices are not replayed")

        try CodeQuestionSurface.setModelChoice(.init(provider: .claude, model: ""), conversationID: conv,
                                               dbPool: dbManager.dbPool)
        await turn(engine, ai, "Any problems?", sessionID: "s1")
        XCTAssertTrue(ai.calls[2].prompt.contains("Assistant: main.swift calls it."),
                      "a Claude turn with no session yet replays too")
        await turn(engine, ai, "Thanks?")
        XCTAssertEqual(ai.calls[3].sessionID, "s1")
        XCTAssertEqual(ai.calls[3].prompt, "Thanks?", "a resumed session already holds the turns")
    }

    /// Claude reads the folder (ruling R55): no "cannot read" notice.
    func testClaudeGetsNoNotice() async throws {
        let conv = try conversation(.init(provider: .claude, model: ""))
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec(conv), dbPool: dbManager.dbPool, ai: ai)
        await turn(engine, ai, "Explain this.", sessionID: "s1")
        await turn(engine, ai, "More?")
        XCTAssertNil(ai.calls.first?.model, "Auto: the provider's default tier")
        XCTAssertFalse(try XCTUnwrap(ai.calls.first?.systemPrompt).contains("cannot read"))
        XCTAssertTrue(engine.messages.allSatisfy { $0.message.role != "system" })
    }

    // MARK: - Guard (spec §9.4, Review Focus 5)

    /// A code question with messages never shows in the main AI Chat: not in
    /// its list, its title search, nor its full-text search. A main-chat
    /// conversation with the same words is found by each, so the guard
    /// cannot pass on a broken search.
    func testCodeQuestionGuard_NeverInTheMainChat() async throws {
        let conv = try conversation(.init(provider: .claude, model: ""))
        try await dbManager.dbPool.write { db in
            try ChatConversationQueries.rename(db, id: conv, title: "zephyrquux question")
        }
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec(conv), dbPool: dbManager.dbPool, ai: ai)
        await turn(engine, ai, "What is zephyrquux?", reply: "zephyrquux loads the config.")

        let main = try await dbManager.dbPool.write { db -> Int64 in
            let row = try ChatConversationQueries.create(db, title: "zephyrquux in the main chat")
            _ = try ChatMessageQueries.insert(db, conversationID: row.id, role: "user", text: "zephyrquux again")
            return row.id
        }

        try await dbManager.dbPool.read { db in
            let list = try ChatConversationQueries.fetchStandalone(db).map(\.id)
            XCTAssertTrue(list.contains(main))
            XCTAssertFalse(list.contains(conv), "the main chat's list")

            let titles = try ChatConversationQueries.search(db, query: "zephyrquux").map(\.id)
            XCTAssertTrue(titles.contains(main))
            XCTAssertFalse(titles.contains(conv), "the main chat's title search")

            let hits = try ChatSearchQueries.search(db, query: "zephyrquux")
            XCTAssertTrue(hits.contains { $0.conversationID == main && $0.messageID != nil })
            XCTAssertTrue(hits.contains { $0.conversationID == main && $0.messageID == nil })
            XCTAssertFalse(hits.contains { $0.conversationID == conv }, "the main chat's search (titles and FTS)")
        }
    }
}

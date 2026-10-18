import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// "Change it in words" and the "New automation" chat (spec §11, §12.2).
/// AGENT-04 as amended (spec §14.5): `automation_editor` is an action
/// surface; under ollama it is draft-only.
@MainActor
final class AutomationEditorChatSurfaceTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: dbPath)
        try await super.tearDown()
    }

    private var pool: DatabasePool { dbManager.dbPool }

    private func makeAutomation(recipe: String = "---\nname: \"Digest\"\n---\nfirst text\n") throws -> Automation {
        try pool.write { db in
            let id = try TestDatabase.insertAutomation(db, slug: "digest", name: "Digest")
            try db.execute(sql: "UPDATE automations SET recipe_text = ? WHERE id = ?", arguments: [recipe, id])
            return try XCTUnwrap(try AutomationQueries.fetchAutomation(db, id: id))
        }
    }

    private func spec(_ automation: Automation, provider: String = "claude") async throws -> ChatSurfaceSpec {
        let conversationID = try await AutomationEditorChatSurface.conversationID(for: automation, dbPool: pool)
        return AutomationEditorChatSurface.spec(automation: automation, provider: provider,
                                                conversationID: conversationID, dbPool: pool, skillsDir: nil)
    }

    private func newSpec(draftID: String = "draft-1", provider: String = "claude") async throws -> ChatSurfaceSpec {
        let conversationID = try await AutomationEditorChatSurface.newConversationID(draftID: draftID, dbPool: pool)
        return AutomationEditorChatSurface.newSpec(provider: provider, draftID: draftID,
                                                   conversationID: conversationID, skillsDir: nil)
    }

    private func center(_ ai: any AIServiceProtocol) -> EmbeddedChatCenter {
        let pool = self.pool
        return EmbeddedChatCenter { spec, gate in makeSurfaceEngine(spec, dbPool: pool, ai: ai, gate: gate) }
    }

    private func controller(
        _ center: EmbeddedChatCenter,
        spec: ChatSurfaceSpec,
        onSaved: @escaping () -> Void = {}
    ) -> AutomationEditorChat {
        AutomationEditorChat(conversationID: spec.key.conversationID ?? 0, dbPool: pool, toolsAvailable: true,
                             center: center, cliRunner: FakeCLIRunner(), onSaved: onSaved) { _ in spec }
    }

    // MARK: - AGENT-04 (amended)

    func testSpecIsActionsAutomationEditor() async throws {
        let spec = try await spec(try makeAutomation())
        XCTAssertEqual(spec.toolAccess, .actions(surface: "automation_editor"))
        XCTAssertEqual(spec.key.contextType, "automation")
        XCTAssertEqual(spec.persistence, .database(conversationID: try XCTUnwrap(spec.key.conversationID)))
        let prompt = spec.systemPrompt()
        XCTAssertTrue(prompt.contains(AgentToolsContract.promptBlock(surface: .automationEditor)))
        XCTAssertTrue(prompt.contains("Load the `create-automation` skill with `load_skill` before drafting."))
        XCTAssertTrue(prompt.contains("Always pass `slug: \"digest\"` to `draft_automation`"))
        XCTAssertTrue(prompt.contains("Scope: personal"))
    }

    func testToolModeCarriesAutomationEditorSurfaceAndContext() async throws {
        let automation = try makeAutomation()
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let spec = try await spec(automation)
        let engine = makeSurfaceEngine(spec, dbPool: pool, ai: mock)
        engine.send("make it run at 10")
        await engine.finished()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        let args = try XCTUnwrap(mock.toolModes.first.flatMap { $0 }).cliArgs
        let conversation = String(try XCTUnwrap(spec.key.conversationID))
        XCTAssertEqual(Array(args.prefix(4)), ["--tools", "chat", "--surface", "automation_editor"])
        XCTAssertEqual(Array(args.suffix(4)), ["--context-type", "automation", "--context-id", String(automation.id)])
        let flag = try XCTUnwrap(args.firstIndex(of: "--conversation"))
        XCTAssertEqual(args[flag + 1], conversation)
    }

    func testOllamaIsDraftOnly() async throws {
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let spec = try await spec(try makeAutomation(), provider: "ollama")
        XCTAssertEqual(spec.toolAccess, .draftOnly)
        let engine = makeSurfaceEngine(spec, dbPool: pool, ai: mock)
        engine.send("hello")
        await engine.finished()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(mock.toolModes, [nil])
        XCTAssertFalse(spec.systemPrompt().contains("=== AGENT ACTIONS ==="))
    }

    func testNewSpecHasNoAutomationContext() async throws {
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let spec = try await newSpec()
        XCTAssertEqual(spec.key.contextType, "automation_draft")
        let engine = makeSurfaceEngine(spec, dbPool: pool, ai: mock)
        engine.send("every weekday at 9, digest my mail")
        await engine.finished()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        let args = try XCTUnwrap(mock.toolModes.first.flatMap { $0 }).cliArgs
        XCTAssertEqual(Array(args.prefix(4)), ["--tools", "chat", "--surface", "automation_editor"])
        XCTAssertFalse(args.contains("--context-type"))
        XCTAssertFalse(args.contains("--context-id"))
        XCTAssertTrue(args.contains("--conversation"))
    }

    // MARK: - Prompts

    func testPerTurnPromptCarriesCurrentRecipeText() async throws {
        let automation = try makeAutomation()
        let mock = MockClaudeService(eventSequence: [[.text("one"), .done], [.text("two"), .done]])
        let engine = makeSurfaceEngine(try await spec(automation), dbPool: pool, ai: mock)

        engine.send("first")
        await engine.finished()
        var done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertTrue(mock.prompts[0].contains("first text"))

        try await pool.write { db in
            try db.execute(sql: "UPDATE automations SET recipe_text = ? WHERE id = ?",
                           arguments: ["---\nname: \"Digest\"\n---\nedited on disk\n", automation.id])
        }
        engine.send("second")
        await engine.finished()
        done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(mock.prompts.count, 2)
        XCTAssertTrue(mock.prompts[1].contains("edited on disk"), "the second turn re-reads the index")
        XCTAssertFalse(mock.prompts[1].contains("first text"))
        XCTAssertTrue(mock.prompts[1].hasSuffix("second"))
    }

    func testConversationNotInMainChatHistory() async throws {
        let automation = try makeAutomation()
        let editor = try await AutomationEditorChatSurface.conversationID(for: automation, dbPool: pool)
        let draft = try await AutomationEditorChatSurface.newConversationID(draftID: "draft-1", dbPool: pool)
        let history = try await pool.read { db in try ChatConversationQueries.fetchStandalone(db) }.map(\.id)
        XCTAssertFalse(history.contains(editor))
        XCTAssertFalse(history.contains(draft))
    }

    // MARK: - Lifetime

    func testNewDraftSurvivesClosingTheSheet() async throws {
        let center = center(MockClaudeService())
        let first = controller(center, spec: try await newSpec(draftID: "draft-1"))
        first.close()
        let again = controller(center, spec: try await newSpec(draftID: "draft-1"))
        XCTAssertTrue(first.engine === again.engine, "the same draft id reopens the same chat")
        XCTAssertEqual(first.conversationID, again.conversationID)
        let other = controller(center, spec: try await newSpec(draftID: "draft-2"))
        XCTAssertFalse(other.engine === again.engine)
    }

    func testEditorChatSurvivesNavigation() async throws {
        let mock = MockClaudeService(events: [.text("drafting…")], thenAwaitsRelease: true)
        let center = center(mock)
        let spec = try await spec(try makeAutomation())
        let open = controller(center, spec: spec)
        open.engine.send("add 14:00")
        await open.engine.finished()
        let streaming = await eventually { open.engine.isStreaming }
        XCTAssertTrue(streaming)

        open.close()
        let reopened = controller(center, spec: spec)
        XCTAssertTrue(reopened.engine === open.engine, "the engine lives in embeddedChatCenter")
        XCTAssertTrue(reopened.engine.isStreaming, "closing the sheet never stops the turn")

        mock.release()
        let finished = await eventually { !reopened.engine.isStreaming }
        XCTAssertTrue(finished)
        reopened.close()
    }

    func testDraftPanelReloadsAfterATurn() async throws {
        let mock = MockClaudeService(events: [.text("drafted"), .done])
        let spec = try await newSpec()
        let chat = controller(center(mock), spec: spec)
        XCTAssertTrue(chat.draft.isEmpty)
        let url = AutomationDraftEntry.cacheURL(databasePath: pool.path, conversationID: chat.conversationID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = #"{"recipe_text":"r","result":{"ok":true,"errors":[],"widening":[],"manifest":{"name":"Mail","#
            + #""slug":"","scope":"personal","trigger_kind":"manual","trigger":"manual","permissions":[],"#
            + #""outputs":[],"budget_tokens":1000,"budget_minutes":1,"approval_hash":"h"},"dry_run":null},"at":"x"}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        chat.dryRunAgain()
        let reloaded = await eventually { chat.draft.name == "Mail" }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(mock.prompts.last, AutomationEditorChatSurface.dryRunAgainText)
        chat.close()
    }

    func testAppliedSaveRefreshesTheList() async throws {
        let spec = try await newSpec()
        var saves = 0
        let chat = controller(center(MockClaudeService()), spec: spec) { saves += 1 }
        let conversationID = chat.conversationID
        let id = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: "save_automation", argsJSON: #"{"is_new":true}"#,
                                               surface: "automation_editor", conversationID: conversationID,
                                               status: "applied")
        }
        XCTAssertNil(chat.savedNote)
        await chat.actionFeed.retry(id)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(chat.savedNote, SaveAutomationCardModel.appliedNewNote)
        chat.close()
    }

    /// J12: a recipe gone from the index and a failed read are told apart.
    func testCurrentRecipeBlockTellsGoneFromUnreadable() async throws {
        let automation = try makeAutomation()
        XCTAssertTrue(AutomationEditorChatSurface.currentRecipeBlock(automationID: automation.id, dbPool: pool)
            .contains("first text"))
        XCTAssertEqual(AutomationEditorChatSurface.currentRecipeBlock(automationID: 999_999, dbPool: pool),
                       AutomationEditorChatSurface.goneRecipeBlock)
        try await pool.write { db in try db.execute(sql: "ALTER TABLE automations RENAME TO automations_away") }
        let unreadable = AutomationEditorChatSurface.currentRecipeBlock(automationID: automation.id, dbPool: pool)
        XCTAssertNotEqual(unreadable, AutomationEditorChatSurface.goneRecipeBlock)
        XCTAssertTrue(unreadable.contains("could not be read"), unreadable)
        try await pool.write { db in try db.execute(sql: "ALTER TABLE automations_away RENAME TO automations") }
    }

    /// J13: Save… while a turn is still running is refused by the engine —
    /// the panel says so instead of dropping the click.
    func testRefusedSendIsSaid() async throws {
        let mock = MockClaudeService(events: [.text("drafting…")], thenAwaitsRelease: true)
        let chat = controller(center(mock), spec: try await newSpec())
        chat.engine.send("a digest of my mail")
        await chat.engine.finished()
        let streaming = await eventually { chat.engine.isStreaming }
        XCTAssertTrue(streaming)

        chat.askToSave()
        XCTAssertEqual(chat.sendNote, AutomationEditorChatSurface.sendRefusedNote)

        mock.release()
        let finished = await eventually { !chat.engine.isStreaming }
        XCTAssertTrue(finished)
        chat.dryRunAgain()
        XCTAssertNil(chat.sendNote, "a sent action clears the note")
        chat.close()
    }

    /// J9: the owner leaves while a turn drafts; the draft cached meanwhile
    /// is what the reopened chat's panel shows.
    func testReturnShowsTheDraftCachedWhileAway() async throws {
        let mock = MockClaudeService(events: [.text("drafting…")], thenAwaitsRelease: true)
        let center = center(mock)
        let spec = try await newSpec()
        let open = controller(center, spec: spec)
        open.engine.send("a digest of my mail")
        await open.engine.finished()
        let streaming = await eventually { open.engine.isStreaming }
        XCTAssertTrue(streaming)
        open.close()

        let url = AutomationDraftEntry.cacheURL(databasePath: pool.path, conversationID: open.conversationID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = #"{"recipe_text":"r","result":{"ok":true,"errors":[],"widening":[],"manifest":{"name":"Away","#
            + #""slug":"","scope":"personal","trigger_kind":"manual","trigger":"manual","permissions":[],"#
            + #""outputs":[],"budget_tokens":1000,"budget_minutes":1,"approval_hash":"h"},"dry_run":null},"at":"x"}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        mock.release()
        let finished = await eventually { !open.engine.isStreaming }
        XCTAssertTrue(finished)

        let reopened = controller(center, spec: spec)
        XCTAssertTrue(reopened.engine === open.engine)
        XCTAssertEqual(reopened.draft.name, "Away")
        reopened.close()
    }
}

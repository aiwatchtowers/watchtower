import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// A CLI double answering by subcommand (`args[1]`).
private final class DraftSaveRunner: CLIRunnerProtocol, @unchecked Sendable {
    typealias Handler = @Sendable ([String]) throws -> Data

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func on(_ subcommand: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[subcommand] = handler }
    }

    func run(args: [String]) async throws -> Data {
        let sub = args.count > 1 ? args[1] : ""
        let handler = lock.withLock { handlers[sub] }
        return try handler?(args) ?? Data()
    }
}

/// Spec 2026-10-24 §4 (ask #528): a new draft's landed save takes its row
/// off the list, and its conversation becomes the saved automation's chat.
@MainActor
final class AutomationDraftSaveTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var runner: DraftSaveRunner!

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        runner = DraftSaveRunner()
    }

    override func tearDown() async throws {
        pool = nil
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private func makeViewModel() -> AutomationsViewModel {
        AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner))
    }

    /// An editor whose debounced checks never fire: the tests check by hand.
    private func makeEditor() throws -> AutomationEditorCenter {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }
        let sleep: (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
        return AutomationEditorCenter(cli: AutomationsCLI(runner: runner), grants: { _ in [] },
                                      refresh: { _ in }, tempDirectory: tempDir, sleep: sleep)
    }

    /// One `automation_draft` conversation keyed `contextID`, with a cache
    /// file (so it is a list row) and `messages` owner lines.
    private func insertDraft(_ contextID: String = "d1", messages: [String] = []) throws -> Int64 {
        let id = try pool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                VALUES ('New automation', 'automation_draft', ?, 0, 0)
                """, arguments: [contextID])
            let id = db.lastInsertedRowID
            for text in messages {
                try TestDatabase.insertChatMessage(db, conversationID: id, role: "user", text: text)
            }
            return id
        }
        let url = AutomationDraftEntry.cacheURL(databasePath: path, conversationID: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"recipe_text":"x","result":null,"error":"boom"}"# + "\n").write(to: url, atomically: true,
                                                                                encoding: .utf8)
        return id
    }

    private func contextOf(_ conversationID: Int64) throws -> (String?, String?) {
        try pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT context_type, context_id FROM chat_conversations WHERE id = ?",
                                       arguments: [conversationID])
            return (row?["context_type"], row?["context_id"])
        }
    }

    /// The bug: the save landed, yet the draft stayed listed (its cache
    /// file was never removed). The panel stays where it is: no `select(nil)`.
    func testSavedDraftRowLeavesTheList() async throws {
        let draft = try insertDraft()
        let vm = makeViewModel()
        vm.refresh()
        XCTAssertEqual(vm.draftRows.map(\.conversationID), [draft])
        let target = AutomationEditorTarget.newDraft(contextID: "d1", scope: .personal, startText: nil)
        vm.showEditor(target)

        await vm.draftSaved(contextID: "d1", conversationID: draft, automationID: 7)

        XCTAssertEqual(vm.draftRows, [])
        let url = AutomationDraftEntry.cacheURL(databasePath: path, conversationID: draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the draft cache is removed")
        XCTAssertEqual(vm.panel, .editor(target), "the panel is the caller's to move, never emptied here")
        vm.refresh()
        XCTAssertEqual(vm.draftRows, [], "a re-read does not bring it back")
        XCTAssertNil(vm.lastError)
    }

    func testSavedDraftConversationBecomesAutomationChat() async throws {
        let draft = try insertDraft(messages: ["Every Friday, sum up the week", "Make it 4 pm"])
        let vm = makeViewModel()
        vm.refresh()

        await vm.draftSaved(contextID: "d1", conversationID: draft, automationID: 7)

        let found = try await DatabaseEmbeddedChatStore.conversationID(
            dbPool: pool, contextType: "automation", contextID: "7", title: "Automation: Digest")
        XCTAssertEqual(found, draft, "the automation's chat is the draft's conversation")
        let texts = try await pool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: draft).map(\.text)
        }
        XCTAssertEqual(texts, ["Every Friday, sum up the week", "Make it 4 pm"])
        XCTAssertNil(vm.lastError)
    }

    /// The automation already has a chat with messages: it wins, nothing is
    /// merged or deleted, and the draft is only unlisted.
    func testRekeyKeepsExistingNonEmptyAutomationChat() async throws {
        let draft = try insertDraft(messages: ["draft line"])
        let existing = try await pool.write { db -> Int64 in
            let id = try ChatConversationQueries.create(db, title: "Automation: Digest", contextType: "automation",
                                                        contextID: "7").id
            try TestDatabase.insertChatMessage(db, conversationID: id, role: "user", text: "older line")
            return id
        }
        let moved = try await DatabaseEmbeddedChatStore.rekeyConversation(
            dbPool: pool, conversationID: draft, toContextType: "automation", contextID: "7")
        XCTAssertFalse(moved)

        let vm = makeViewModel()
        vm.refresh()
        await vm.draftSaved(contextID: "d1", conversationID: draft, automationID: 7)
        XCTAssertEqual(vm.draftRows, [])
        let draftContext = try contextOf(draft)
        XCTAssertEqual(draftContext.0, "automation_draft")
        XCTAssertEqual(draftContext.1, "d1")
        let found = try await DatabaseEmbeddedChatStore.conversationID(
            dbPool: pool, contextType: "automation", contextID: "7", title: "x")
        XCTAssertEqual(found, existing)
    }

    /// An empty automation chat gives way, in the same write.
    func testRekeyReplacesAnEmptyAutomationChat() async throws {
        let draft = try insertDraft(messages: ["draft line"])
        let empty = try await pool.write { db in
            try ChatConversationQueries.create(db, title: "Automation: Digest", contextType: "automation",
                                               contextID: "7").id
        }
        let moved = try await DatabaseEmbeddedChatStore.rekeyConversation(
            dbPool: pool, conversationID: draft, toContextType: "automation", contextID: "7")
        XCTAssertTrue(moved)
        let gone = try await pool.read { db in try ChatConversationQueries.fetchByID(db, id: empty) }
        XCTAssertNil(gone)
        XCTAssertEqual(try contextOf(draft).1, "7")

        let again = try await DatabaseEmbeddedChatStore.rekeyConversation(
            dbPool: pool, conversationID: draft, toContextType: "automation", contextID: "8")
        XCTAssertFalse(again, "only a draft conversation moves")
    }

    /// A save approved while the draft's reply still streams: the engine is
    /// let go of only once that turn ended and its writes landed.
    func testReleaseWaitsForStreamingTurn() async throws {
        let ai = ScriptedAIService()
        let pool = try XCTUnwrap(self.pool)
        let center = EmbeddedChatCenter { spec, gate in
            EmbeddedChatEngine(spec: spec, store: DatabaseEmbeddedChatStore(dbPool: pool,
                                                                            conversationID: spec.key.conversationID ?? 0),
                               aiService: ai, gate: gate)
        }
        let draft = try insertDraft()
        let key = EmbeddedChatKey(contextType: "automation_draft", contextID: "d1", conversationID: draft)
        let engine = center.engine(for: ChatSurfaceSpec(
            key: key, persistence: .database(conversationID: draft), toolAccess: .draftOnly,
            systemPrompt: { "S" }, emptyHint: ""))
        XCTAssertTrue(engine.send("Draft it"))
        await engine.started()
        XCTAssertTrue(engine.isStreaming)

        var released = false
        let release = Task {
            await center.release(key: key)
            released = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(released, "a streaming turn holds the release")
        XCTAssertTrue(center.loaded(key) === engine)

        ai.emit(.text("Drafted."))
        ai.finish()
        await release.value
        XCTAssertTrue(released)
        XCTAssertNil(center.loaded(key))
        let reply = try await pool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: draft).last
        }
        XCTAssertEqual(reply?.text, "Drafted.")
        XCTAssertEqual(reply?.status, "complete", "the turn ended by itself, never cut short")
    }

    /// A refused save leaves nothing to unlist: the editor names no saved
    /// automation, so `draftSaved` is never called and the row stays.
    func testFailedSaveKeepsDraft() async throws {
        let draft = try insertDraft()
        runner.on("validate") { _ in try AutomationEditFixtures.validateJSON(approval: "hn") }
        runner.on("save") { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "could not write the recipe")
        }
        let editor = try makeEditor()
        let key = AutomationEditorCenter.newDraftKey(conversationID: draft)
        editor.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations",
                        startText: AutomationEditFixtures.recipe)
        await editor.check(key)
        guard case let .review(plan) = editor.saving[key] else {
            return XCTFail("expected a checked plan, got \(String(describing: editor.saving[key]))")
        }
        await editor.commit(key, plan: plan, turnOn: true)
        guard case .failed = editor.saving[key] else {
            return XCTFail("expected a failed save, got \(String(describing: editor.saving[key]))")
        }
        XCTAssertNil(editor.savedIDs[key])
        XCTAssertNil(editor.settleUnwatched(key), "a failed save names no automation to unlist")

        let vm = makeViewModel()
        vm.refresh()
        XCTAssertEqual(vm.draftRows.map(\.conversationID), [draft])
        XCTAssertEqual(try contextOf(draft).0, "automation_draft", "the conversation stays a draft's")
        editor.discard(key)
    }

    /// A new draft's save that landed with its panel away: settling names
    /// the automation it wrote, so the caller unlists the draft.
    func testSettleUnwatchedNamesALandedNewDraftSave() async throws {
        let draft = try insertDraft()
        runner.on("validate") { _ in try AutomationEditFixtures.validateJSON(approval: "hn") }
        runner.on("save") { _ in
            Data(#"{"automation_id":7,"path":"/acme/automations/digest.md","approval_hash":"hn","confirmed":true}"#.utf8)
        }
        let editor = try makeEditor()
        let key = AutomationEditorCenter.newDraftKey(conversationID: draft)
        editor.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations",
                        startText: AutomationEditFixtures.recipe)
        await editor.check(key)
        guard case let .review(plan) = editor.saving[key] else {
            return XCTFail("expected a checked plan, got \(String(describing: editor.saving[key]))")
        }
        await editor.commit(key, plan: plan, turnOn: false)
        XCTAssertEqual(editor.saving[key], .done)
        XCTAssertEqual(editor.settleUnwatched(key), 7)
        XCTAssertNil(editor.saving[key])
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A workbench with one ask, the app's embedded chat center over a scripted
/// AI service, and the asks view model wired to both (spec 2026-11-24).
@MainActor
final class AskExplainFixture {
    let pool: DatabasePool
    let path: String
    let ai = ScriptedAIService()
    let tower: FakeChatTower
    let writes: ChatWrites
    let center: EmbeddedChatCenter
    let vm: OwnerAsksViewModel
    let projectID: Int64
    let defaults: UserDefaults

    /// `defaults`: preferences shared with another fixture (another
    /// workspace's database on the same Mac); nil: a suite of its own.
    init(defaults shared: UserDefaults? = nil) throws {
        (pool, path) = try TestDatabase.createPool()
        (writes, tower) = FakeChatTower.writes(pool)
        projectID = try pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: "/tmp/acme-explain") }
        let pool = pool
        let writes = writes
        let ai = ai
        let hooks = hooks
        center = EmbeddedChatCenter(gate: EmbeddedStreamGate(limit: 3)) { spec, gate in
            hooks.beforeEngine?(spec)
            return EmbeddedChatEngine(spec: spec,
                                      store: DatabaseEmbeddedChatStore(dbPool: pool, writes: writes,
                                                                       conversationID: spec.key.conversationID ?? 0),
                                      aiService: ai, gate: gate)
        }
        defaults = try shared ?? XCTUnwrap(UserDefaults(suiteName: "AskExplain-\(UUID().uuidString)"))
        vm = OwnerAsksViewModel(dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil),
                                defaults: defaults)
        vm.chats = center
        vm.chatWrites = writes
        catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        vm.explainCatalog = catalog
        vm.explainConfigProvider = { [weak self] in self?.configProvider }
    }

    /// Runs as the center makes an engine, before it reads its history: an
    /// open's last step after its lookup (no await lies between them), so a
    /// test changes the database there as if the open were held.
    var beforeEngine: ((ChatSurfaceSpec) -> Void)? {
        get { hooks.beforeEngine }
        set { hooks.beforeEngine = newValue }
    }

    @MainActor private final class Hooks {
        var beforeEngine: ((ChatSurfaceSpec) -> Void)?
    }

    private let hooks = Hooks()

    /// The fixture catalog's rows (claude reads folders, ollama none).
    let catalog: AIModelCatalog
    /// config.yaml's `ai.provider` as the explain turns read it.
    var configProvider: String? = "claude"

    func cleanup() {
        TestDatabase.cleanup(path: path)
    }

    /// Three questions: the legacy lookup (spec D4) never runs on it.
    static let threeQuestions = """
        {"questions":[\
        {"id":"q1","question":"Which store?","options":[{"label":"Postgres","recommended":true},{"label":"SQLite"}]},\
        {"id":"q2","question":"Which cache?","options":[{"label":"Redis"},{"label":"None"}]},\
        {"id":"q3","question":"Ship when?","options":[{"label":"Now"},{"label":"Later"}]}]}
        """
    static let oneQuestion = #"{"questions":[{"id":"q1","question":"Which store?","options":[{"label":"A"},{"label":"B"}]}]}"#
    static let threeSteps = #"{"checklist":[{"text":"Open it"},{"text":"Sign in","hint":"top right"},{"text":"Close it"}]}"#
    static let oneStep = #"{"checklist":[{"text":"Open it"}]}"#

    /// `payload` nil: three steps for a check, three questions otherwise
    /// (a review ask carries them too: it still opens nothing).
    func insertAsk(
        kind: String = "question",
        title: String = "Which way?",
        targetID: Int64? = nil,
        sessionID: Int64? = nil,
        payload: String? = nil
    ) throws -> OwnerAsk {
        let projectID = projectID
        let docPath = kind == "review" ? "docs/spec.md" : ""
        let payload = payload ?? (kind == "check" ? Self.threeSteps : Self.threeQuestions)
        let id = try pool.write {
            try TestDatabase.insertOwnerAsk($0, projectID: projectID, sessionID: sessionID, targetID: targetID,
                                            kind: kind, title: title, payload: payload, docPath: docPath)
        }
        return try XCTUnwrap(try pool.read { try OwnerAskQueries.ask($0, id: id, projectID: projectID) })
    }

    /// The hidden first turns asked of the AI so far, of any item.
    /// A call counts when it has no owner row and its prompt ends with the
    /// first turn of the item it names, whatever the item's number. The item
    /// is read from the prompt's last naming, the one in its trailing first
    /// turn — an earlier part of the prompt may name another item.
    var hiddenTurns: [ScriptedAIService.Call] {
        ai.calls.filter { call in
            guard call.persist?.ownerText == nil,
                  let named = call.prompt.matches(of: #/Explain (question|step) (\d+) of this/#).last,
                  let number = Int(named.output.2) else { return false }
            let item: AskExplainItem = named.output.1 == "step" ? .step(number) : .question(number)
            return call.prompt.hasSuffix(AskExplainPrompt.firstTurn(item))
        }
    }

    /// The hidden first turns of `item`'s chat.
    func hiddenTurns(_ item: AskExplainItem) -> [ScriptedAIService.Call] {
        ai.calls.filter { $0.persist?.ownerText == nil && $0.prompt.hasSuffix(AskExplainPrompt.firstTurn(item)) }
    }

    /// The conversation `chat.new` would make for `item`, made now.
    func conversation(_ ask: OwnerAsk, _ item: AskExplainItem = .question(1)) async throws -> Int64 {
        try await AskExplainSurface.conversationID(ask: ask, item: item, dbPool: pool, writes: writes)
    }

    /// A 0.29.5 whole-ask chat (`<wb>:<ask>`), as that build's `chat.new`
    /// made it, holding `explanation` when given.
    func insertLegacyChat(_ ask: OwnerAsk, explanation: String? = nil) throws -> Int64 {
        try pool.write { db in
            let conversation = try ChatConversationQueries.create(
                db, title: "Ask #\(ask.id)", contextType: AskExplainKey.contextType,
                contextID: AskExplainKey.legacyContextID(workbenchID: ask.projectID, askID: ask.id), projectID: nil)
            if let explanation {
                _ = try TestDatabase.insertChatMessage(db, conversationID: conversation.id, role: "assistant",
                                                       text: explanation)
            }
            return conversation.id
        }
    }

    func conversationCount() throws -> Int {
        try pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations WHERE context_type = ?",
                             arguments: [AskExplainKey.contextType]) ?? 0
        }
    }

    /// What Go's `DeleteWorkbench` removes for this feature: the
    /// workbench's explain chats of both shapes, its asks, folders and row.
    func deleteWorkbench(_ projectID: Int64? = nil) throws {
        let projectID = projectID ?? self.projectID
        try pool.write { db in
            try db.execute(sql: "DELETE FROM chat_conversations WHERE context_type = ? AND context_id LIKE ?",
                           arguments: [AskExplainKey.contextType, "\(projectID):%"])
            try Self.dropWorkbenchRows(db, projectID)
        }
    }

    /// The workbench's own rows only: its explain chats stay.
    func dropWorkbenchRows() throws {
        let projectID = projectID
        try pool.write { try Self.dropWorkbenchRows($0, projectID) }
    }

    nonisolated private static func dropWorkbenchRows(_ db: Database, _ projectID: Int64) throws {
        try db.execute(sql: "DELETE FROM owner_asks WHERE project_id = ?", arguments: [projectID])
        try db.execute(sql: "DELETE FROM workbench_folders WHERE workbench_id = ?", arguments: [projectID])
        try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [projectID])
    }

    func rows(_ conversationID: Int64) throws -> [ChatMessageRecord] {
        try pool.read { try ChatMessageQueries.fetchByConversation($0, conversationID: conversationID) }
    }
}

@MainActor
final class AskExplainSurfaceTests: XCTestCase {
    private var fx: AskExplainFixture!

    override func setUpWithError() throws {
        fx = try AskExplainFixture()
    }

    override func tearDown() {
        fx.cleanup()
    }

    func testSpecShape() throws {
        let ask = try fx.insertAsk()
        let contextID = AskExplainKey.contextID(workbenchID: fx.projectID, askID: ask.id, item: .question(2))
        let spec = AskExplainSurface.spec(ask: ask, item: .question(2), contextID: contextID, conversationID: 7,
                                          folder: "/tmp/acme-explain", target: (title: "Feature", intent: "Ship it"),
                                          configProvider: { "claude" }, catalog: fx.catalog)
        XCTAssertEqual(spec.key.contextType, "owner_ask_explain")
        XCTAssertEqual(spec.key.contextID, "\(fx.projectID):\(ask.id):q2")
        XCTAssertEqual(spec.key.conversationID, 7)
        XCTAssertEqual(spec.persistence, .database(conversationID: 7))
        XCTAssertEqual(spec.toolAccess, .draftOnly, "the assistant never changes anything (D6)")
        let options = spec.runOptions()
        XCTAssertEqual(options.readFolder, "/tmp/acme-explain")
        XCTAssertEqual(options.purpose, "ask.explain")
        XCTAssertNil(options.model, "the strong tier")
        XCTAssertNil(options.provider, "the config's provider")
        XCTAssertEqual(spec.systemPrompt(),
                       AskExplainPrompt.system(ask: ask, item: .question(2), target: (title: "Feature", intent: "Ship it")))
        XCTAssertEqual(spec.emptyHint, AskExplainCopy.emptyHint)
    }

    /// `ai query` refuses `--read-folder` for a provider without file tools:
    /// ollama answers from the ask alone; an unread catalog gives no folder.
    func testFolderlessProviderGetsNoReadFolder() throws {
        let ask = try fx.insertAsk()
        func spec(_ provider: String, _ catalog: AIModelCatalog) -> ChatSurfaceSpec {
            AskExplainSurface.spec(ask: ask, item: .question(1), contextID: "1:1:q1", conversationID: 7,
                                   folder: "/tmp/acme-explain", target: nil, configProvider: { provider }, catalog: catalog)
        }
        let ollama = spec("ollama", fx.catalog)
        XCTAssertNil(ollama.runOptions().readFolder)
        XCTAssertEqual(ollama.runOptions().purpose, AskExplainKey.purpose)
        XCTAssertEqual(spec("codex", fx.catalog).runOptions().readFolder, "/tmp/acme-explain")
        XCTAssertNil(spec("claude", AIModelCatalog(providers: [])).runOptions().readFolder)
    }

    func testOllamaTurnRunsWithoutAFolder() async throws {
        let ask = try fx.insertAsk()
        fx.configProvider = "ollama"
        await fx.vm.openExplain(ask, item: .question(1))
        await fx.vm.explainEngine(for: ask, item: .question(1))?.started()
        XCTAssertEqual(fx.ai.calls.count, 1)
        XCTAssertNil(fx.ai.calls.first?.readFolder)
    }

    func testSameKeySameConversation() async throws {
        let ask = try fx.insertAsk()
        async let first = fx.conversation(ask)
        async let second = fx.conversation(ask)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one, two)
        let stored = try await fx.pool.read { try ChatConversationQueries.fetchByID($0, id: one) }
        let conversation = try XCTUnwrap(stored)
        XCTAssertEqual(conversation.contextType, AskExplainKey.contextType)
        XCTAssertEqual(conversation.contextID, "\(fx.projectID):\(ask.id):q1")
        XCTAssertEqual(conversation.title, "Ask #\(ask.id) · Question 1")
        XCTAssertTrue(fx.tower.calls(.chatNew).allSatisfy { ($0["context"] as? [String: Any])?["reuse"] as? Bool == true })
    }

    /// Two clicks or two windows on one step: one conversation.
    func testSameItemSameConversation() async throws {
        let check = try fx.insertAsk(kind: "check")
        async let first = fx.conversation(check, .step(2))
        async let second = fx.conversation(check, .step(2))
        let (one, two) = try await (first, second)
        XCTAssertEqual(one, two)
        XCTAssertEqual(try fx.conversationCount(), 1)
        let stored = try await fx.pool.read { try ChatConversationQueries.fetchByID($0, id: one) }
        XCTAssertEqual(stored?.contextID, "\(fx.projectID):\(check.id):s2")
        XCTAssertEqual(stored?.title, "Ask #\(check.id) · Step 2")
    }

    /// Spec D3: each item of an ask is its own conversation.
    func testItemsGetTheirOwnConversations() async throws {
        let ask = try fx.insertAsk()
        let first = try await fx.conversation(ask, .question(1))
        let second = try await fx.conversation(ask, .question(2))
        XCTAssertNotEqual(first, second)
        let again = try await fx.conversation(ask, .question(1))
        XCTAssertEqual(again, first)
        XCTAssertEqual(try fx.conversationCount(), 2)
    }

    /// The fake tower refuses as Go does: a malformed or non-canonical
    /// context id is a bad request (not a gone workbench), and nothing is made.
    func testMalformedContextIDIsABadRequest() async throws {
        for contextID in ["x:9", "04:9", "\(fx.projectID)"] {
            try await assertBadRequest(contextID)
        }
        XCTAssertEqual(try fx.conversationCount(), 0)
    }

    /// Review Focus 5: an item id is exactly `q` or `s` and a canonical
    /// positive number, in a third and last part; the legacy 2-part id is
    /// still accepted.
    func testMalformedItemContextIDIsABadRequest() async throws {
        let bench = fx.projectID
        for item in ["q02", "x1", "q1:s1", "Q1", "q0", "q+1", "q", "", "s-1"] {
            try await assertBadRequest("\(bench):9:\(item)")
        }
        XCTAssertEqual(try fx.conversationCount(), 0)
        for contextID in ["\(bench):9:q2", "\(bench):9:s10", "\(bench):9"] {
            _ = try await DatabaseEmbeddedChatStore.conversationID(
                dbPool: fx.pool, writes: fx.writes, contextType: AskExplainKey.contextType,
                contextID: contextID, title: "Ask #9")
        }
        XCTAssertEqual(try fx.conversationCount(), 3)
        XCTAssertEqual(FakeChatTower.askExplainWorkbenchID("4:9:q02"), nil)
        XCTAssertEqual(FakeChatTower.askExplainWorkbenchID("4:9:q2"), 4)
        XCTAssertEqual(FakeChatTower.askExplainWorkbenchID("4:9"), 4)
    }

    private func assertBadRequest(_ contextID: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await DatabaseEmbeddedChatStore.conversationID(
                dbPool: fx.pool, writes: fx.writes, contextType: AskExplainKey.contextType,
                contextID: contextID, title: "Ask #9")
            XCTFail("\(contextID) was accepted", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("the request is incomplete"),
                          "\(contextID): \(error.localizedDescription)", file: file, line: line)
        }
    }

    func testItemTurnOutlivesDrawer() async throws {
        let ask = try fx.insertAsk()
        fx.vm.openDrawer(ask)
        await fx.vm.openExplain(ask, item: .question(2))
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask, item: .question(2)))
        await engine.started()
        XCTAssertTrue(engine.isBusy)

        fx.vm.closeExplain(ask.id)
        fx.vm.closeDrawer(projectID: ask.projectID)
        XCTAssertTrue(engine.isBusy, "the turn keeps running in the center")
        let key = engine.spec.key
        XCTAssertEqual(key.contextID, "\(fx.projectID):\(ask.id):q2")
        XCTAssertTrue(fx.center.loaded(key) === engine)

        fx.ai.emit(.text("It decides the cache."), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        let conversationID = try XCTUnwrap(key.conversationID)
        XCTAssertEqual(try fx.rows(conversationID).last?.status, "complete")

        await fx.vm.openExplain(ask, item: .question(2))
        XCTAssertTrue(fx.vm.explainEngine(for: ask, item: .question(2)) === engine, "reopening shows the same chat")
        XCTAssertEqual(fx.hiddenTurns.count, 1)
    }
}

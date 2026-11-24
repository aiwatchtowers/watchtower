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

    init() throws {
        (pool, path) = try TestDatabase.createPool()
        (writes, tower) = FakeChatTower.writes(pool)
        projectID = try pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: "/tmp/acme-explain") }
        let pool = pool
        let writes = writes
        let ai = ai
        center = EmbeddedChatCenter(gate: EmbeddedStreamGate(limit: 3)) { spec, gate in
            EmbeddedChatEngine(spec: spec,
                               store: DatabaseEmbeddedChatStore(dbPool: pool, writes: writes,
                                                                conversationID: spec.key.conversationID ?? 0),
                               aiService: ai, gate: gate)
        }
        defaults = try XCTUnwrap(UserDefaults(suiteName: "AskExplain-\(UUID().uuidString)"))
        vm = OwnerAsksViewModel(dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil),
                                defaults: defaults)
        vm.chats = center
        vm.chatWrites = writes
        catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        vm.explainCatalog = catalog
        vm.explainConfigProvider = { [weak self] in self?.configProvider }
    }

    /// The fixture catalog's rows (claude reads folders, ollama none).
    let catalog: AIModelCatalog
    /// config.yaml's `ai.provider` as the explain turns read it.
    var configProvider: String? = "claude"

    func cleanup() {
        TestDatabase.cleanup(path: path)
    }

    func insertAsk(
        kind: String = "question",
        title: String = "Which way?",
        targetID: Int64? = nil,
        sessionID: Int64? = nil
    ) throws -> OwnerAsk {
        let projectID = projectID
        let docPath = kind == "review" ? "docs/spec.md" : ""
        let id = try pool.write {
            try TestDatabase.insertOwnerAsk($0, projectID: projectID, sessionID: sessionID, targetID: targetID,
                                            kind: kind, title: title, docPath: docPath)
        }
        return try XCTUnwrap(try pool.read { try OwnerAskQueries.ask($0, id: id, projectID: projectID) })
    }

    /// The hidden turns asked of the AI so far.
    var hiddenTurns: [ScriptedAIService.Call] {
        ai.calls.filter { $0.persist?.ownerText == nil && $0.prompt.hasSuffix(AskExplainPrompt.firstTurn) }
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
        let spec = AskExplainSurface.spec(ask: ask, conversationID: 7, folder: "/tmp/acme-explain",
                                          target: (title: "Feature", intent: "Ship it"),
                                          configProvider: { "claude" }, catalog: fx.catalog)
        XCTAssertEqual(spec.key.contextType, "owner_ask_explain")
        XCTAssertEqual(spec.key.contextID, "\(fx.projectID):\(ask.id)")
        XCTAssertEqual(spec.key.conversationID, 7)
        XCTAssertEqual(spec.persistence, .database(conversationID: 7))
        XCTAssertEqual(spec.toolAccess, .draftOnly, "the assistant never changes anything (D6)")
        let options = spec.runOptions()
        XCTAssertEqual(options.readFolder, "/tmp/acme-explain")
        XCTAssertEqual(options.purpose, "ask.explain")
        XCTAssertNil(options.model, "the strong tier")
        XCTAssertNil(options.provider, "the config's provider")
        XCTAssertEqual(spec.systemPrompt(),
                       AskExplainPrompt.system(ask: ask, target: (title: "Feature", intent: "Ship it")))
        XCTAssertEqual(spec.emptyHint, AskExplainCopy.emptyHint)
    }

    /// `ai query` refuses `--read-folder` for a provider without file tools:
    /// ollama answers from the ask alone; an unread catalog gives no folder.
    func testFolderlessProviderGetsNoReadFolder() throws {
        let ask = try fx.insertAsk()
        let ollama = AskExplainSurface.spec(ask: ask, conversationID: 7, folder: "/tmp/acme-explain", target: nil,
                                            configProvider: { "ollama" }, catalog: fx.catalog)
        XCTAssertNil(ollama.runOptions().readFolder)
        XCTAssertEqual(ollama.runOptions().purpose, AskExplainKey.purpose)
        let codex = AskExplainSurface.spec(ask: ask, conversationID: 7, folder: "/tmp/acme-explain", target: nil,
                                           configProvider: { "codex" }, catalog: fx.catalog)
        XCTAssertEqual(codex.runOptions().readFolder, "/tmp/acme-explain")
        let unread = AskExplainSurface.spec(ask: ask, conversationID: 7, folder: "/tmp/acme-explain", target: nil,
                                            configProvider: { "claude" }, catalog: AIModelCatalog(providers: []))
        XCTAssertNil(unread.runOptions().readFolder)
    }

    func testOllamaTurnRunsWithoutAFolder() async throws {
        let ask = try fx.insertAsk()
        fx.configProvider = "ollama"
        await fx.vm.openExplain(ask)
        await fx.vm.explainEngine(for: ask)?.started()
        XCTAssertEqual(fx.ai.calls.count, 1)
        XCTAssertNil(fx.ai.calls.first?.readFolder)
    }

    func testSameKeySameConversation() async throws {
        let ask = try fx.insertAsk()
        let pool = fx.pool
        let writes = fx.writes
        async let first = AskExplainSurface.conversationID(ask: ask, dbPool: pool, writes: writes)
        async let second = AskExplainSurface.conversationID(ask: ask, dbPool: pool, writes: writes)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one, two)
        let stored = try await pool.read { try ChatConversationQueries.fetchByID($0, id: one) }
        let conversation = try XCTUnwrap(stored)
        XCTAssertEqual(conversation.contextType, AskExplainKey.contextType)
        XCTAssertEqual(conversation.contextID, AskExplainKey.contextID(workbenchID: fx.projectID, askID: ask.id))
        XCTAssertEqual(conversation.title, "Ask #\(ask.id)")
        XCTAssertTrue(fx.tower.calls(.chatNew).allSatisfy { ($0["context"] as? [String: Any])?["reuse"] as? Bool == true })
    }

    func testTurnOutlivesDrawer() async throws {
        let ask = try fx.insertAsk()
        fx.vm.openDrawer(ask)
        await fx.vm.openExplain(ask)
        let engine = try XCTUnwrap(fx.vm.explainEngine(for: ask))
        await engine.started()
        XCTAssertTrue(engine.isBusy)

        fx.vm.closeExplain(ask.id)
        fx.vm.closeDrawer(projectID: ask.projectID)
        XCTAssertTrue(engine.isBusy, "the turn keeps running in the center")
        let key = engine.spec.key
        XCTAssertTrue(fx.center.loaded(key) === engine)

        fx.ai.emit(.text("It decides the flag."), .done)
        fx.ai.finish()
        await waitForCondition { !engine.isBusy }
        await engine.finished()
        let conversationID = try XCTUnwrap(key.conversationID)
        XCTAssertEqual(try fx.rows(conversationID).last?.status, "complete")

        await fx.vm.openExplain(ask)
        XCTAssertTrue(fx.vm.explainEngine(for: ask) === engine, "reopening shows the same chat")
        XCTAssertEqual(fx.hiddenTurns.count, 1)
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A Discuss thread on a spec review item (spec 2026-11-08 §3): draft-only
/// (AGENT-04), the reviewer's folder and the `spec_review.discuss` purpose on
/// every turn, a reply's blocks handed over, and an orphaned item readable
/// only.
@MainActor
final class SpecReviewThreadSurfaceTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        ProviderCatalogFixture.seedShared() // folder reading is the provider's capability row
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        ProviderCatalogFixture.seedShared()
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func context(
        provider: AIProvider = .claude,
        orphaned: Bool = false,
        onReply: @escaping @MainActor (String?, SpecReviewProposedFinding?) -> Void = { _, _ in }
    ) -> SpecReviewThreadContext {
        SpecReviewThreadContext(workbenchID: 3, rootAskID: 7, askID: 9, itemKey: "da:abc",
                                data: "```document\nMuting lasts a day.\n```",
                                provider: provider, isOrphaned: { orphaned }, onReply: onReply)
    }

    private func conversation() async throws -> Int64 {
        try await SpecReviewThreadSurface.conversationID(workbenchID: 3, rootAskID: 7, itemKey: "da:abc",
                                                         title: "Stored per channel", dbPool: dbManager.dbPool)
    }

    private func turn(_ engine: EmbeddedChatEngine, _ ai: ScriptedAIService, _ text: String, reply: String) async {
        let before = ai.calls.count
        XCTAssertTrue(engine.send(text))
        await engine.finished()
        let started = await eventually { ai.calls.count == before + 1 }
        XCTAssertTrue(started)
        ai.emit(.text(reply), .turnComplete(reply), .done)
        ai.finish()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        await engine.finished()
    }

    func testDraftOnlyAndPurpose() async throws {
        let conv = try await conversation()
        let spec = SpecReviewThreadSurface.spec(context: context(), conversationID: conv, dbPool: dbManager.dbPool)
        XCTAssertEqual(spec.toolAccess, .draftOnly, "a thread never acts (AGENT-04)")
        XCTAssertTrue(spec.ownerInstructions)
        XCTAssertEqual(spec.key, EmbeddedChatKey(contextType: "spec_review_thread", contextID: "3:7:da:abc",
                                                 conversationID: conv))
        XCTAssertEqual(spec.runOptions(), ChatRunOptions(provider: "claude", purpose: "spec_review.discuss",
                                                         readFolderAskID: 9))

        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec, dbPool: dbManager.dbPool, ai: ai)
        await turn(engine, ai, "Why?", reply: "Because.")
        let call = try XCTUnwrap(ai.calls.first)
        XCTAssertNil(call.toolMode, "draft-only (AGENT-04)")
        XCTAssertEqual(call.purpose, "spec_review.discuss")
        XCTAssertNil(call.readFolder, "the CLI finds the reviewer's folder")
        XCTAssertEqual(call.readFolderAskID, 9)
        XCTAssertNil(call.model, "the provider's strong tier")
        let system = try XCTUnwrap(call.systemPrompt)
        XCTAssertTrue(system.contains("You did not write this item"))
        XCTAssertTrue(system.contains("inside the folder the reviewer read with the read-only file tools"),
                      "file tools, worded for the reviewer's folder")
        XCTAssertTrue(system.contains("Muting lasts a day."), "the review's data is in the prompt")
        XCTAssertTrue(system.contains("```watchtower-ask-author"))
        XCTAssertTrue(system.contains("```watchtower-finding"))
        let stored = try await dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: conv) }
        XCTAssertEqual(stored?.contextType, "spec_review_thread")
        XCTAssertEqual(stored?.contextID, "3:7:da:abc")
    }

    /// A provider whose capability row reads no folder (ollama's, in the
    /// Go-written table) runs without one, its prompt says so, and the thread
    /// says so once (LLMTRANSPORT-01: the row decides, not the name).
    func testAProviderThatReadsNoFolderRunsWithoutItAndSaysSoOnce() async throws {
        XCTAssertFalse(AIModelCatalog.shared.capabilities(for: "ollama").readsFolder)
        let conv = try await conversation()
        let spec = SpecReviewThreadSurface.spec(context: context(provider: .ollama), conversationID: conv,
                                                dbPool: dbManager.dbPool)
        XCTAssertNil(spec.runOptions().readFolderAskID)
        XCTAssertNil(spec.runOptions().readFolder)
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec, dbPool: dbManager.dbPool, ai: ai)
        await turn(engine, ai, "Why?", reply: "Because.")
        await turn(engine, ai, "And?", reply: "That's all.")
        XCTAssertNil(ai.calls.first?.readFolderAskID)
        XCTAssertTrue(ai.calls.first?.systemPrompt?.contains("You cannot read any file") ?? false)
        let notices = engine.messages.filter { $0.message.role == "system" }.map(\.message.text)
        XCTAssertEqual(notices, [SpecReviewThreadSurface.cannotReadFilesNotice])
    }

    /// The row decides, not the name: claude with a row that reads no folder
    /// runs without `--read-folder-ask` (the CLI would refuse the turn,
    /// cmd/ai.go), its prompt says so, and the thread says so once.
    func testANonOllamaProviderWithoutFolderReadingRunsFromTheDataAlone() async throws {
        AIModelCatalog.shared.replaceProviders(ProviderCatalogFixture.providers().map { row in
            var row = row
            if row.id == "claude" { row.capabilities = ProviderCapabilities(tools: "watchtower", readFolder: "none") }
            return row
        })
        let conv = try await conversation()
        let spec = SpecReviewThreadSurface.spec(context: context(provider: .claude), conversationID: conv,
                                                dbPool: dbManager.dbPool)
        XCTAssertNil(spec.runOptions().readFolderAskID)
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec, dbPool: dbManager.dbPool, ai: ai)
        await turn(engine, ai, "Why?", reply: "Because.")
        await turn(engine, ai, "And?", reply: "That's all.")
        XCTAssertEqual(ai.calls.map(\.readFolderAskID), [nil, nil])
        XCTAssertNil(ai.calls.first?.readFolder)
        let system = try XCTUnwrap(ai.calls.first?.systemPrompt)
        XCTAssertTrue(system.contains("You cannot read any file"))
        XCTAssertFalse(system.contains("Read, Grep, Glob and LS"))
        let notices = engine.messages.filter { $0.message.role == "system" }.map(\.message.text)
        XCTAssertEqual(notices, [SpecReviewThreadSurface.cannotReadFilesNotice])
    }

    /// A read-only shell sandbox row (codex's) gets the folder and the
    /// sandbox wording for the reviewer's folder.
    func testAShellSandboxProviderReadsTheReviewersFolder() async throws {
        let conv = try await conversation()
        let spec = SpecReviewThreadSurface.spec(context: context(provider: .codex), conversationID: conv,
                                                dbPool: dbManager.dbPool)
        XCTAssertEqual(spec.runOptions().readFolderAskID, 9)
        let system = spec.systemPrompt()
        XCTAssertTrue(system.contains("inside the folder the reviewer read under a read-only sandbox"))
        XCTAssertFalse(system.contains("workbench folder"))
    }

    /// The turn's folder access follows the catalog: a failed read gives no
    /// folder and names it, a read not finished gives no folder and no
    /// notice it cannot back.
    func testFolderAccessFollowsTheCatalog() async {
        let read = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        XCTAssertEqual(SpecReviewThreadSurface.FolderAccess.of(provider: .claude, catalog: read), .reads)
        XCTAssertEqual(SpecReviewThreadSurface.FolderAccess.of(provider: .ollama, catalog: read), .cannotRead)
        XCTAssertEqual(SpecReviewThreadSurface.FolderAccess.of(provider: .claude, catalog: AIModelCatalog { nil }),
                       .unknown)
        let failed = AIModelCatalog { nil }
        await failed.load()
        XCTAssertEqual(SpecReviewThreadSurface.FolderAccess.of(provider: .claude, catalog: failed), .catalogUnread)
        XCTAssertEqual(SpecReviewThreadSurface.FolderAccess.catalogUnread.notice,
                       SpecReviewThreadSurface.capabilitiesUnreadNotice)
        XCTAssertNil(SpecReviewThreadSurface.FolderAccess.unknown.notice)
        XCTAssertNil(SpecReviewThreadSurface.FolderAccess.reads.notice)

        AIModelCatalog.shared.replaceProviders([])
        let spec = SpecReviewThreadSurface.spec(context: context(), conversationID: 1, dbPool: dbManager.dbPool)
        XCTAssertNil(spec.runOptions().readFolderAskID, "no row read yet: no folder")
        XCTAssertTrue(spec.systemPrompt().contains("You cannot read any file"), "the prompt says what the turn had")
    }

    func testOrphanRefusesNewTurns() async throws {
        let conv = try await conversation()
        let spec = SpecReviewThreadSurface.spec(context: context(orphaned: true), conversationID: conv,
                                                dbPool: dbManager.dbPool)
        XCTAssertFalse(spec.willSend("Still there?"))
        XCTAssertFalse(spec.mayContinue())
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec, dbPool: dbManager.dbPool, ai: ai)
        XCTAssertFalse(engine.send("Still there?"))
        await engine.finished()
        XCTAssertTrue(ai.calls.isEmpty, "an orphaned item's thread takes no new turns")
    }

    /// A completed reply hands its blocks over; the stored text keeps them,
    /// so a proposal still shows after the thread is reopened.
    func testReplyHandsItsBlocksOver() async throws {
        let conv = try await conversation()
        var handed: [(String?, SpecReviewProposedFinding?)] = []
        let spec = SpecReviewThreadSurface.spec(context: context { handed.append(($0, $1)) },
                                                conversationID: conv, dbPool: dbManager.dbPool)
        let ai = ScriptedAIService()
        let engine = makeSurfaceEngine(spec, dbPool: dbManager.dbPool, ai: ai)
        await turn(engine, ai, "Plain?", reply: "Plain answer.")
        XCTAssertTrue(handed.isEmpty, "a reply with no block hands nothing over")

        let reply = "Only the author knows.\n\n```watchtower-ask-author\n{\"question\": \"Calendar day?\"}\n```"
        await turn(engine, ai, "Which day?", reply: reply)
        XCTAssertEqual(handed.count, 1)
        XCTAssertEqual(handed.first?.0, "Calendar day?")
        XCTAssertNil(handed.first?.1)
        XCTAssertEqual(engine.messages.last?.message.text, reply)
    }
}

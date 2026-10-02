import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class IdeaChatSurfaceTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeIdea(
        title: String = "Ship a weekly digest email",
        essence: String = "Send a Friday digest email to stakeholders"
    ) throws -> Idea {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, title: title, essence: essence)
        }
        let idea = try dbManager.dbPool.read { db in
            try Idea.fetchOne(db, sql: "SELECT * FROM ideas WHERE id = ?", arguments: [id])
        }
        return try XCTUnwrap(idea)
    }

    /// Looks up the persisted `chat_conversations.id` for an idea's conversation.
    private func conversationID(for idea: Idea) throws -> Int64 {
        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "idea", id: String(idea.id))
        }
        return try XCTUnwrap(conv).id
    }

    private func engine(for idea: Idea, ai: any AIServiceProtocol, mentions: [IdeaMention] = []) throws -> EmbeddedChatEngine {
        let conv = try IdeaChatSurface.conversationID(for: idea, dbPool: dbManager.dbPool)
        return makeSurfaceEngine(IdeaChatSurface.spec(idea: idea, mentions: mentions, conversationID: conv,
                                                      dbPool: dbManager.dbPool),
                                 dbPool: dbManager.dbPool, ai: ai)
    }

    // MARK: - Conversation lifecycle

    func testCreatesConversationWithIdeaContext() throws {
        let idea = try makeIdea()
        _ = try IdeaChatSurface.conversationID(for: idea, dbPool: dbManager.dbPool)

        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "idea", id: String(idea.id))
        }
        let unwrapped = try XCTUnwrap(conv)
        XCTAssertTrue(unwrapped.title.hasPrefix("Idea:"))
    }

    func testReopensExistingConversationWithHistory() throws {
        let idea = try makeIdea()
        let first = try IdeaChatSurface.conversationID(for: idea, dbPool: dbManager.dbPool)
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: first, role: "user", text: "earlier question")
        }

        XCTAssertEqual(try IdeaChatSurface.conversationID(for: idea, dbPool: dbManager.dbPool), first)
        let engine = try engine(for: idea, ai: MockClaudeService())
        XCTAssertEqual(engine.messages.map(\.message.text), ["earlier question"])
    }

    // MARK: - Sending

    func testSendStreamsUserIntentVerbatim() async throws {
        let idea = try makeIdea()
        let mock = MockClaudeService(events: [.text("Draft reply"), .done])
        let engine = try engine(for: idea, ai: mock)

        engine.draft = "what's the risk here?"
        engine.sendDraft()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        XCTAssertEqual(mock.prompts.first, "what's the risk here?")
        XCTAssertEqual(engine.messages.last?.message.text, "Draft reply")
        XCTAssertEqual(engine.messages.first?.message.text, "what's the risk here?")
        // AGENT-04: draft-only surfaces never send a tool mode.
        XCTAssertEqual(mock.toolModes, [nil])
    }

    /// A resumed turn drops the system prompt (the CLI uses --resume), so the
    /// per-turn prompt must itself carry the idea context block (mirrors
    /// TargetChatViewModelTests.testResumedTurnCarriesTaskContextAndActionContract).
    func testResumedTurnCarriesIdeaContext() async throws {
        let idea = try makeIdea()
        try await dbManager.dbPool.write { db in
            let conv = try ChatConversationQueries.create(
                db, title: "Idea: seed", contextType: "idea", contextID: String(idea.id))
            try ChatConversationQueries.updateSessionID(db, id: conv.id, sessionID: "s1")
        }
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let engine = try engine(for: idea, ai: mock)

        engine.send("again")
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("=== IDEA ==="))
        XCTAssertTrue(prompt.contains(idea.title))
        XCTAssertTrue(prompt.hasSuffix("again"), "user text must follow the carried context")
        XCTAssertEqual(mock.systemPrompts, [nil])
    }

    func testFirstTurnSendsTheSystemPrompt() async throws {
        let idea = try makeIdea()
        let mock = MockClaudeService(events: [.sessionID("s9"), .text("ok"), .done])
        let engine = try engine(for: idea, ai: mock)
        engine.send("hello")
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertTrue(try XCTUnwrap(mock.systemPrompts.first.flatMap { $0 }).contains("=== IDEA ==="))
        let conv = try IdeaChatSurface.conversationID(for: idea, dbPool: dbManager.dbPool)
        let sessionID = try await dbManager.dbPool.read { try ChatConversationQueries.fetchByID($0, id: conv)?.sessionID }
        XCTAssertEqual(sessionID, "s9")
    }

    /// The Go prompt (internal/ai/prompt.go) and this Swift copy are a
    /// deliberate dual path: the tool list must mention search_knowledge.
    func testSystemPromptBriefsSearchKnowledge() throws {
        let idea = try makeIdea()
        let prompt = IdeaChatSurface.buildSystemPrompt(idea: idea, mentions: [], dbPool: dbManager.dbPool)
        XCTAssertTrue(prompt.contains("search_knowledge"))
        XCTAssertTrue(prompt.contains("Slack, mail, Jira, Confluence, calendar"), "Confluence is an indexed source")
    }

    func testStreamErrorSurfacesInline() async throws {
        let idea = try makeIdea()
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let engine = try engine(for: idea, ai: MockClaudeService(error: Boom()))

        engine.send("hello")
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        let reply = try XCTUnwrap(engine.messages.last?.message)
        XCTAssertEqual(reply.status, "error", "the failure renders as the error card under the reply")
        XCTAssertEqual(reply.errorMessage, "boom")
    }

    func testStopKeepsThePartialReply() async throws {
        let idea = try makeIdea()
        let engine = try engine(for: idea, ai: MockClaudeService(events: [.text("half")], thenHangs: true))
        engine.send("q")
        let streamed = await eventually { engine.liveTurn?.fullText == "half" }
        XCTAssertTrue(streamed)
        engine.stop()
        XCTAssertEqual(engine.messages.last?.message.status, "partial")
        XCTAssertEqual(engine.messages.last?.message.text, "half")
    }

    func testPersistedMessageCount() throws {
        let idea = try makeIdea()
        XCTAssertEqual(try dbManager.dbPool.read { try IdeaChatSurface.persistedMessageCount($0, ideaID: idea.id) }, 0)

        let convID = try IdeaChatSurface.conversationID(for: idea, dbPool: dbManager.dbPool)
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: convID, role: "user", text: "hi")
        }
        XCTAssertEqual(try dbManager.dbPool.read { try IdeaChatSurface.persistedMessageCount($0, ideaID: idea.id) }, 1)
    }

    /// Collapsing the Discuss section only hides the rows: the center keeps
    /// the engine and the reply completes (review-rules "Lifecycle & state").
    func testCollapsingDiscussNeverStopsTheReply() async throws {
        let idea = try makeIdea()
        let mock = MockClaudeService(events: [.text("still coming")], thenAwaitsRelease: true)
        let pool = dbManager.dbPool
        let center = EmbeddedChatCenter { spec, _ in makeSurfaceEngine(spec, dbPool: pool, ai: mock) }
        var state = IdeaDiscussState(isExpanded: true,
                                     conversationID: try IdeaChatSurface.conversationID(for: idea, dbPool: pool))
        let engine = try XCTUnwrap(state.engine(idea: idea, mentions: [], dbManager: dbManager, center: center))
        center.markShown(engine.spec.key)
        engine.send("q")
        state.isExpanded = false
        center.markHidden(engine.spec.key)
        XCTAssertNil(state.engine(idea: idea, mentions: [], dbManager: dbManager, center: center))
        mock.release()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        state.isExpanded = true
        let reopened = try XCTUnwrap(state.engine(idea: idea, mentions: [], dbManager: dbManager, center: center))
        XCTAssertTrue(reopened === engine)
        XCTAssertEqual(reopened.messages.last?.message.text, "still coming")
    }

    // MARK: - Context block

    func testIdeaContextBlockContainsEssenceAndMentionQuote() throws {
        let idea = try makeIdea(essence: "Automate weekly stakeholder updates")
        let mention = try makeMention(ideaID: Int64(idea.id), quote: "we should really automate this")

        let block = IdeaChatSurface.ideaContextBlock(idea, mentions: [mention])

        XCTAssertTrue(block.contains("=== IDEA ==="))
        XCTAssertTrue(block.contains("=== MENTIONS ==="))
        XCTAssertTrue(block.contains("Automate weekly stakeholder updates"))
        XCTAssertTrue(block.contains("we should really automate this"))
    }

    // MARK: - Helpers

    private func makeMention(ideaID: Int64, quote: String) throws -> IdeaMention {
        let mentionID = try dbManager.dbPool.write { db in
            try TestDatabase.insertIdeaMention(db, ideaID: ideaID, quote: quote, author: "alice")
        }
        let mention = try dbManager.dbPool.read { db in
            try IdeaMention.fetchOne(db, sql: "SELECT * FROM idea_mentions WHERE id = ?", arguments: [mentionID])
        }
        return try XCTUnwrap(mention)
    }

    /// The question card is taught on this surface too (spec 2026-10-02).
    func testSystemPromptTeachesTheQuestionCard() throws {
        let idea = try makeIdea()
        let prompt = IdeaChatSurface.buildSystemPrompt(idea: idea, mentions: [], dbPool: dbManager.dbPool)
        XCTAssertTrue(prompt.hasSuffix(ChatQuestionsContract.promptBlock))
    }
}

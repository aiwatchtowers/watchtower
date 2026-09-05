import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class IdeaChatViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.ensureTable(db)
                try ChatMessageQueries.ensureTable(db)
            }
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

    // MARK: - Conversation lifecycle

    func testCreatesConversationWithIdeaContext() throws {
        let idea = try makeIdea()
        _ = IdeaChatViewModel(idea: idea, mentions: [], dbManager: dbManager, aiService: MockClaudeService())

        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "idea", id: String(idea.id))
        }
        let unwrapped = try XCTUnwrap(conv)
        XCTAssertTrue(unwrapped.title.hasPrefix("Idea:"))
    }

    func testReopensExistingConversationWithHistory() throws {
        let idea = try makeIdea()
        let vm1 = IdeaChatViewModel(idea: idea, mentions: [], dbManager: dbManager, aiService: MockClaudeService())
        _ = vm1 // conversation created
        let convID = try conversationID(for: idea)
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: convID, role: "user", text: "earlier question")
        }

        let vm2 = IdeaChatViewModel(idea: idea, mentions: [], dbManager: dbManager, aiService: MockClaudeService())

        XCTAssertEqual(vm2.messages.map(\.text), ["earlier question"])
    }

    // MARK: - Sending

    func testSendStreamsUserIntentVerbatim() async throws {
        let idea = try makeIdea()
        let mock = MockClaudeService(events: [.text("Draft reply"), .done])
        let vm = IdeaChatViewModel(idea: idea, mentions: [], dbManager: dbManager, aiService: mock)

        vm.inputText = "what's the risk here?"
        vm.send()
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(mock.prompts.first, "what's the risk here?")
        XCTAssertEqual(vm.messages.last?.text, "Draft reply")
        XCTAssertEqual(vm.messages.first?.text, "what's the risk here?")
        // AGENT-04: draft-only surfaces never send a tool mode.
        XCTAssertEqual(mock.toolModes, [nil])
    }

    /// A resumed turn drops the system prompt (the CLI uses --resume), so the
    /// per-turn prompt must itself carry the idea context block (mirrors
    /// SituationChatViewModelTests.testResumedTurnCarriesSituationContext).
    func testResumedTurnCarriesIdeaContext() async throws {
        let idea = try makeIdea()
        try await dbManager.dbPool.write { db in
            let conv = try ChatConversationQueries.create(
                db, title: "Idea: seed", contextType: "idea", contextID: String(idea.id))
            try ChatConversationQueries.updateSessionID(db, id: conv.id, sessionID: "s1")
        }
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let vm = IdeaChatViewModel(idea: idea, mentions: [], dbManager: dbManager, aiService: mock)

        vm.inputText = "again"
        vm.send()
        try await waitUntil { !vm.isStreaming }

        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("=== IDEA ==="))
        XCTAssertTrue(prompt.contains(idea.title))
        XCTAssertTrue(prompt.hasSuffix("again"), "user text must follow the carried context")
    }

    func testStreamErrorSurfacesInline() async throws {
        let idea = try makeIdea()
        struct Boom: Error {}
        let vm = IdeaChatViewModel(idea: idea, mentions: [], dbManager: dbManager, aiService: MockClaudeService(error: Boom()))

        vm.inputText = "hello"
        vm.send()
        try await waitUntil { !vm.isStreaming }

        XCTAssertNotNil(vm.errorMessage)
    }

    func testPersistedMessageCount() throws {
        let idea = try makeIdea()
        XCTAssertEqual(try dbManager.dbPool.read { try IdeaChatViewModel.persistedMessageCount($0, ideaID: idea.id) }, 0)

        let vm = IdeaChatViewModel(idea: idea, mentions: [], dbManager: dbManager, aiService: MockClaudeService())
        _ = vm
        let convID = try conversationID(for: idea)
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: convID, role: "user", text: "hi")
        }
        XCTAssertEqual(try dbManager.dbPool.read { try IdeaChatViewModel.persistedMessageCount($0, ideaID: idea.id) }, 1)
    }

    // MARK: - Context block

    func testIdeaContextBlockContainsEssenceAndMentionQuote() throws {
        let idea = try makeIdea(essence: "Automate weekly stakeholder updates")
        let mention = try makeMention(ideaID: Int64(idea.id), quote: "we should really automate this")

        let block = IdeaChatViewModel.ideaContextBlock(idea, mentions: [mention])

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

    private func waitUntil(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !cond() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(cond(), "condition not met within 2s")
    }
}

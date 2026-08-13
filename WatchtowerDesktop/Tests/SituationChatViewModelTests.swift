import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class SituationChatViewModelTests: XCTestCase {
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

    private func makeSituation(title: String = "Cloudflare follow-up") throws -> Situation {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertSituation(
                db, title: title, summary: "second follow-up",
                whyMatters: "ball is on you", chronology: "day 1 ... day 13")
        }
        let situation = try dbManager.dbPool.read { db in
            try Situation.fetchOne(db, sql: "SELECT * FROM situations WHERE id = ?", arguments: [id])
        }
        return try XCTUnwrap(situation)
    }

    /// Looks up the persisted `chat_conversations.id` for a situation's conversation.
    private func conversationID(for situation: Situation) throws -> Int64 {
        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "situation", id: String(situation.id))
        }
        return try XCTUnwrap(conv).id
    }

    // MARK: - Conversation lifecycle

    func testCreatesConversationWithSituationContext() throws {
        let situation = try makeSituation()
        _ = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())

        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "situation", id: String(situation.id))
        }
        let unwrapped = try XCTUnwrap(conv)
        XCTAssertTrue(unwrapped.title.hasPrefix("Situation:"))
    }

    func testReopensExistingConversationWithHistory() throws {
        let situation = try makeSituation()
        let vm1 = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())
        _ = vm1 // conversation created
        let convID = try conversationID(for: situation)
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: convID, role: "user", text: "earlier question")
        }

        let vm2 = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())

        XCTAssertEqual(vm2.messages.map(\.text), ["earlier question"])
    }

    // MARK: - Sending (intent-driven draft flow: the user's text IS the intent)

    func testSendStreamsUserIntentVerbatim() async throws {
        let situation = try makeSituation()
        let mock = MockClaudeService(events: [.text("Черновик ответа"), .done])
        let vm = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: mock)

        vm.inputText = "скажи им, что откатим завтра"
        vm.send()
        try await waitUntil { !vm.isStreaming }

        XCTAssertEqual(mock.prompts.first, "скажи им, что откатим завтра")
        XCTAssertEqual(vm.messages.last?.text, "Черновик ответа")
        XCTAssertEqual(vm.messages.first?.text, "скажи им, что откатим завтра")
    }

    /// A resumed turn drops the system prompt (the CLI uses --resume), so the
    /// per-turn prompt must itself carry the situation context block — otherwise
    /// a post-restart expired session has no idea what is being discussed
    /// (mirrors TargetChatViewModelTests.testResumedTurnCarriesTaskContextAndActionContract).
    func testResumedTurnCarriesSituationContext() async throws {
        let situation = try makeSituation()
        let signals = try arrangeResumedSession(for: situation)
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let vm = SituationChatViewModel(situation: situation, memberSignals: signals, dbManager: dbManager, aiService: mock)

        vm.inputText = "again"
        vm.send()
        try await waitUntil { !vm.isStreaming }

        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("=== SITUATION ==="))
        XCTAssertTrue(prompt.contains("Cloudflare follow-up"))
        XCTAssertTrue(prompt.contains("please respond"), "resumed turn must carry member signals too")
        XCTAssertTrue(prompt.hasSuffix("again"), "user text must follow the carried context")
    }

    func testStreamErrorSurfacesInline() async throws {
        let situation = try makeSituation()
        struct Boom: Error {}
        let vm = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService(error: Boom()))

        vm.inputText = "hello"
        vm.send()
        try await waitUntil { !vm.isStreaming }

        XCTAssertNotNil(vm.errorMessage)
    }

    func testPersistedMessageCount() throws {
        let situation = try makeSituation()
        XCTAssertEqual(try dbManager.dbPool.read { try SituationChatViewModel.persistedMessageCount($0, situationID: situation.id) }, 0)

        let vm = SituationChatViewModel(situation: situation, memberSignals: [], dbManager: dbManager, aiService: MockClaudeService())
        _ = vm
        let convID = try conversationID(for: situation)
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: convID, role: "user", text: "hi")
        }
        XCTAssertEqual(try dbManager.dbPool.read { try SituationChatViewModel.persistedMessageCount($0, situationID: situation.id) }, 1)
    }

    // MARK: - Helpers

    /// Seeds a conversation that already has a persisted session id (so the VM
    /// loads it on init and its very first send() is a resumed turn) plus one
    /// member signal; returns the signals. Sync helper: keeps GRDB's sync
    /// `write`/`read` overloads unambiguous inside async test bodies.
    private func arrangeResumedSession(for situation: Situation) throws -> [InboxItem] {
        let itemID = try dbManager.dbPool.write { db -> Int64 in
            let conv = try ChatConversationQueries.create(
                db, title: "Situation: seed", contextType: "situation", contextID: String(situation.id))
            try ChatConversationQueries.updateSessionID(db, id: conv.id, sessionID: "s1")
            return try TestDatabase.insertInboxItem(
                db, channelID: "C1", messageTS: "1700000100.000000", snippet: "please respond")
        }
        return try dbManager.dbPool.read { db in
            try InboxItem.fetchAll(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [itemID])
        }
    }

    private func waitUntil(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !cond() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(cond(), "condition not met within 2s")
    }
}

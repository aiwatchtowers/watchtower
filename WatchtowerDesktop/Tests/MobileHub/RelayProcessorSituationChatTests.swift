import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

/// A mobile chat turn carrying a `situation` context joins the DESKTOP's own
/// Discuss conversation for that situation (`SituationChatRelay`): one
/// conversation row for both surfaces, its CLI session reused across devices,
/// both turns persisted into `chat_messages` — which is also what makes the
/// Phase-4 memory chat ingest see phone-authored owner turns.
///
/// The context-less path (the generic secretary chat) must stay exactly as it
/// was; that is pinned here too.
final class RelayProcessorSituationChatTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var transport: InMemoryCloudTransport!

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        sidecar = try HubSyncState.inMemory()
        transport = InMemoryCloudTransport()
    }

    override func tearDownWithError() throws {
        transport = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeProcessor(aiService: any AIServiceProtocol) -> RelayProcessor {
        RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: aiService,
            chunkInterval: .milliseconds(10)
        )
    }

    /// A situation with one member signal — the shape Discuss is built from.
    @discardableResult
    private func seedSituation(title: String = "Renewal deal stalling") throws -> Int64 {
        try dbPool.write { db in
            let situationID = try TestDatabase.insertSituation(db, title: title, whyMatters: "revenue at risk")
            let itemID = try TestDatabase.insertInboxItem(db, snippet: "can we get an answer today?")
            try TestDatabase.linkSituationSignal(db, situationID: situationID, inboxItemID: itemID)
            return situationID
        }
    }

    private func enqueueChat(
        id: String,
        sessionID: String,
        text: String = "tell them we roll back tomorrow",
        context: ChatContext?
    ) async throws {
        let message = ChatMessagePayload(
            id: id, sessionID: sessionID, text: text, createdAt: Date(), context: context
        )
        try await transport.save([try CloudRecordFactory.record(for: message, modifiedAt: Date())])
    }

    private func chunks(messageID: String) async throws -> [ChatChunkPayload] {
        let batch = try await transport.changes(in: .relay, since: nil)
        return try batch.changed
            .filter { $0.kind == RelayRecordKind.chatChunk.rawValue }
            .map { try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: $0.payload) }
            .filter { $0.messageID == messageID }
            .sorted { $0.seq < $1.seq }
    }

    private func conversation(situationID: Int64) throws -> ChatConversation? {
        try dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "situation", id: String(situationID))
        }
    }

    private func messages(conversationID: Int64) throws -> [ChatMessageRecord] {
        try dbPool.read { db in
            try ChatMessageQueries.fetchByConversation(db, conversationID: conversationID)
        }
    }

    /// Synchronous on purpose (like `SlicePublisher.fetchSliceRows`): inside an
    /// async test the `read`/`write` calls would otherwise resolve to the async
    /// overloads, which require Sendable results.
    /// The chat tables are created lazily by `ensureTable` (the desktop's own
    /// pattern), so "no table" and "no rows" are the same answer here: nothing
    /// was persisted.
    private func conversationCount() throws -> Int {
        try dbPool.read { db in
            guard try db.tableExists("chat_conversations") else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_conversations") ?? 0
        }
    }

    /// A conversation the user started in the desktop's Discuss pane.
    private func seedDesktopConversation(situationID: Int64, title: String) throws -> Int64 {
        try dbPool.write { db -> Int64 in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            let conversation = try ChatConversationQueries.create(
                db, title: title, contextType: "situation", contextID: String(situationID)
            )
            try ChatConversationQueries.updateSessionID(db, id: conversation.id, sessionID: "cli-desktop")
            _ = try ChatMessageQueries.insert(
                db, conversationID: conversation.id, role: "user", text: "typed on the Mac"
            )
            return conversation.id
        }
    }

    // MARK: - First turn

    func testFirstTurnCreatesConversationAndPersistsBothTurns() async throws {
        let situationID = try seedSituation()
        let mock = MockClaudeService(events: [.text("Rolling back "), .text("tomorrow."), .done])
        try await enqueueChat(id: "m1", sessionID: "s1", context: .situation(Int(situationID)))

        _ = try await makeProcessor(aiService: mock).processOnce()

        let conversation = try XCTUnwrap(try conversation(situationID: situationID))
        XCTAssertEqual(conversation.contextType, "situation")
        XCTAssertEqual(conversation.title, "Situation: Renewal deal stalling")

        let rows = try messages(conversationID: conversation.id)
        XCTAssertEqual(rows.map(\.role), ["user", "assistant"])
        XCTAssertEqual(rows[0].text, "tell them we roll back tomorrow")
        XCTAssertEqual(rows[1].text, "Rolling back tomorrow.")

        // The phone still gets its stream.
        let chunks = try await chunks(messageID: "m1")
        XCTAssertEqual(chunks.last?.done, true)
        XCTAssertEqual(chunks.map(\.text).joined(), "Rolling back tomorrow.")
    }

    func testFirstTurnUsesTheSituationSystemPromptAndBareText() async throws {
        let situationID = try seedSituation()
        let mock = MockClaudeService()
        try await enqueueChat(id: "m1", sessionID: "s1", context: .situation(Int(situationID)))

        _ = try await makeProcessor(aiService: mock).processOnce()

        let systemPrompt = try XCTUnwrap(XCTUnwrap(mock.systemPrompts.first))
        XCTAssertTrue(systemPrompt.contains("DRAFT CONTRACT"), "the situation draft contract must be in force")
        XCTAssertTrue(systemPrompt.contains("Renewal deal stalling"))
        XCTAssertTrue(systemPrompt.contains("can we get an answer today?"), "member signals belong in the prompt")
        // The context lives in the system prompt on the first turn, so the
        // user message is sent as typed.
        XCTAssertEqual(mock.prompts.first, "tell them we roll back tomorrow")
    }

    // MARK: - Resumed turns

    func testSecondTurnResumesTheConversationSessionAndCarriesContextBlock() async throws {
        let situationID = try seedSituation()
        let mock = MockClaudeService(eventSequence: [
            [.sessionID("cli-1"), .text("first answer"), .done],
            [.text("second answer"), .done]
        ])
        let processor = makeProcessor(aiService: mock)

        try await enqueueChat(id: "m1", sessionID: "s1", context: .situation(Int(situationID)))
        _ = try await processor.processOnce()
        try await enqueueChat(id: "m2", sessionID: "s1", text: "and add a deadline", context: .situation(Int(situationID)))
        _ = try await processor.processOnce()

        // The CLI session is stored on the CONVERSATION (not the sidecar map),
        // so the desktop's own next turn resumes the same session too.
        let conversation = try XCTUnwrap(try conversation(situationID: situationID))
        XCTAssertEqual(conversation.sessionID, "cli-1")
        XCTAssertEqual(mock.sessionIDs, [nil, "cli-1"])
        XCTAssertNil(try sidecar.cliSessionID(forMobileSession: "s1"), "the sidecar map stays the generic chat's")

        // A resumed session drops the system prompt and carries the situation
        // block with the message instead.
        XCTAssertNil(try XCTUnwrap(mock.systemPrompts.last))
        let secondPrompt = try XCTUnwrap(mock.prompts.last)
        XCTAssertTrue(secondPrompt.contains("=== SITUATION ==="))
        XCTAssertTrue(secondPrompt.hasSuffix("and add a deadline"))

        XCTAssertEqual(try messages(conversationID: conversation.id).count, 4)
    }

    /// A conversation the DESKTOP already started is joined, never duplicated.
    func testExistingDesktopConversationIsReused() async throws {
        let situationID = try seedSituation()
        let existingID = try seedDesktopConversation(
            situationID: situationID, title: "Situation: Renewal deal stalling"
        )
        let mock = MockClaudeService()
        try await enqueueChat(id: "m1", sessionID: "s1", context: .situation(Int(situationID)))

        _ = try await makeProcessor(aiService: mock).processOnce()

        XCTAssertEqual(try conversationCount(), 1, "the phone must join the desktop's thread, not open a second one")
        XCTAssertEqual(mock.sessionIDs, ["cli-desktop"], "the desktop's CLI session is resumed")
        XCTAssertEqual(try messages(conversationID: existingID).map(\.role), ["user", "user", "assistant"])
    }

    // MARK: - Failure paths

    func testUnknownSituationFailsTheTurnWithoutTouchingConversations() async throws {
        let mock = MockClaudeService()
        try await enqueueChat(id: "m1", sessionID: "s1", context: .situation(9_999))

        _ = try await makeProcessor(aiService: mock).processOnce()

        let chunks = try await chunks(messageID: "m1")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].done, true)
        XCTAssertEqual(chunks[0].isError, true)
        XCTAssertTrue(try XCTUnwrap(chunks[0].text).contains("no longer open"))
        XCTAssertTrue(mock.prompts.isEmpty, "an unknown situation must never reach the model")
        XCTAssertEqual(try conversationCount(), 0)
    }

    func testUnknownContextTypeIsRefused() async throws {
        let mock = MockClaudeService()
        try await enqueueChat(id: "m1", sessionID: "s1", context: ChatContext(type: "sprint", id: "1"))

        _ = try await makeProcessor(aiService: mock).processOnce()

        let chunks = try await chunks(messageID: "m1")
        XCTAssertEqual(chunks.first?.isError, true)
        XCTAssertTrue(try XCTUnwrap(chunks.first?.text).contains("sprint"))
        XCTAssertTrue(mock.prompts.isEmpty, "an unknown context must not be answered as the generic chat")
    }

    /// A failed stream leaves the user turn recorded (the half the memory
    /// ingest reads) but writes no assistant row: the shared thread must not
    /// show an error the desktop cannot retry.
    func testStreamFailurePersistsTheUserTurnOnly() async throws {
        let situationID = try seedSituation()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "provider exploded" } }
        try await enqueueChat(id: "m1", sessionID: "s1", context: .situation(Int(situationID)))

        _ = try await makeProcessor(aiService: MockClaudeService(error: Boom())).processOnce()

        let conversation = try XCTUnwrap(try conversation(situationID: situationID))
        XCTAssertEqual(try messages(conversationID: conversation.id).map(\.role), ["user"])
        let chunks = try await chunks(messageID: "m1")
        XCTAssertEqual(chunks.first?.isError, true)
    }

    // MARK: - The generic path is untouched

    func testContextLessTurnStillUsesTheGenericPathAndSidecarSession() async throws {
        let mock = MockClaudeService(eventSequence: [
            [.sessionID("cli-generic"), .text("answer"), .done]
        ])
        try await enqueueChat(id: "m1", sessionID: "s1", text: "what's on today?", context: nil)

        _ = try await makeProcessor(aiService: mock).processOnce()

        XCTAssertEqual(try sidecar.cliSessionID(forMobileSession: "s1"), "cli-generic")
        XCTAssertEqual(try conversationCount(), 0, "the generic chat persists nothing on the desktop")
        XCTAssertEqual(mock.prompts, ["what's on today?"])
    }
}

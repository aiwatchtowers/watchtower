import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class MeetingChatSurfaceTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
            try dbManager.dbPool.write { db in
                try TestDatabase.insertMeetingTranscript(
                    db, id: 7, title: "Weekly Sync",
                    transcriptText: "we agreed to ship v2 on friday")
            }
        } catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func loadTranscript() throws -> MeetingTranscript {
        try XCTUnwrap(dbManager.dbPool.read { db in
            try MeetingTranscriptQueries.fetch(db, id: 7)
        })
    }

    private func engine(for transcript: MeetingTranscript, ai: any AIServiceProtocol) throws -> EmbeddedChatEngine {
        let conv = try XCTUnwrap(MeetingChatSurface.conversationID(for: transcript, dbPool: dbManager.dbPool))
        return makeSurfaceEngine(MeetingChatSurface.spec(transcript: transcript, recapContent: nil,
                                                         conversationID: conv, dbPool: dbManager.dbPool),
                                 dbPool: dbManager.dbPool, ai: ai)
    }

    func testCreatesConversationWithMeetingContext() throws {
        let transcript = try loadTranscript()
        _ = try MeetingChatSurface.conversationID(for: transcript, dbPool: dbManager.dbPool)

        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        }
        let unwrapped = try XCTUnwrap(conv)
        XCTAssertTrue(unwrapped.title.hasPrefix("Meeting:"))
    }

    func testReopensExistingConversationWithHistory() throws {
        let transcript = try loadTranscript()
        _ = try MeetingChatSurface.conversationID(for: transcript, dbPool: dbManager.dbPool)
        let conv = try XCTUnwrap(dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        })
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "earlier question")
        }

        let engine = try engine(for: transcript, ai: MockClaudeService())
        XCTAssertEqual(engine.messages.map(\.message.text), ["earlier question"])
    }

    func testSystemPromptCarriesMeetingContextAndCapsTranscript() throws {
        let long = String(repeating: "слово ", count: 5_000) // ~30k chars
        let transcript = MeetingTranscript(
            id: 7, eventID: nil, title: "Big meeting", audioPath: nil,
            durationSec: 3600, langStats: "{}", transcriptText: long,
            summaryJSON: nil, notesMD: nil, segmentsJSON: nil, speakersJSON: nil, chaptersJSON: nil,
            createdAt: "2026-07-15T10:00:00Z",
            updatedAt: "2026-07-15T10:00:00Z")
        let recap = MeetingRecap.Content(
            summary: "shipped v2", keyDecisions: ["ship"], actionItems: [], openQuestions: [])

        // Hermetic: the defaults read the developer's real config and skills
        // directory, which made the size bound depend on the machine.
        let prompt = MeetingChatSurface.buildSystemPrompt(
            transcript: transcript, recapContent: recap, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil)

        XCTAssertTrue(prompt.contains("Big meeting"))
        XCTAssertTrue(prompt.contains("shipped v2"))
        XCTAssertTrue(prompt.contains("get_transcript"),
                      "prompt must point the model at the MCP tool for the full text")
        XCTAssertTrue(prompt.contains("search_knowledge"),
                      "the Go prompt and this Swift copy are a deliberate dual path")
        XCTAssertTrue(prompt.contains("Slack, mail, Jira, Confluence, calendar"), "Confluence is an indexed source")
        XCTAssertLessThan(prompt.count, 16_000,
                          "transcript excerpt must be capped so the interactive CLI prompt stays clear of ARG_MAX")
    }

    func testPersistedMessageCount() throws {
        let transcript = try loadTranscript()
        _ = try MeetingChatSurface.conversationID(for: transcript, dbPool: dbManager.dbPool)
        let conv = try XCTUnwrap(dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        })
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "q")
        }
        let count = try dbManager.dbPool.read { db in
            try MeetingChatSurface.persistedMessageCount(db, transcriptID: 7)
        }
        XCTAssertEqual(count, 1)
    }

    /// AGENT-04: the meeting chat is draft-only — it must never carry a tool mode.
    func testSendPassesNoToolMode() async throws {
        let transcript = try loadTranscript()
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let engine = try engine(for: transcript, ai: mock)

        engine.send("what did we decide?")
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        // AGENT-04: draft-only surfaces never send a tool mode.
        XCTAssertEqual(mock.toolModes, [nil])
    }

    /// A resumed session drops the system prompt, so the turn carries the
    /// meeting block itself.
    func testResumedTurnCarriesTheMeetingContext() async throws {
        let transcript = try loadTranscript()
        let conv = try XCTUnwrap(MeetingChatSurface.conversationID(for: transcript, dbPool: dbManager.dbPool))
        try await dbManager.dbPool.write { db in try ChatConversationQueries.updateSessionID(db, id: conv, sessionID: "s1") }
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let engine = try engine(for: transcript, ai: mock)
        engine.send("who owns the launch?")
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        let prompt = try XCTUnwrap(mock.prompts.first)
        XCTAssertTrue(prompt.contains("=== MEETING RECORDING ==="))
        XCTAssertTrue(prompt.hasSuffix("who owns the launch?"))
    }

    /// Switching to another recording no longer cancels this one's reply:
    /// the engine lives in the center, keyed by the transcript.
    func testAnotherRecordingNeverStopsThisReply() async throws {
        let transcript = try loadTranscript()
        let mock = MockClaudeService(events: [.text("answer")], thenAwaitsRelease: true)
        let pool = dbManager.dbPool
        let center = EmbeddedChatCenter { spec, _ in makeSurfaceEngine(spec, dbPool: pool, ai: mock) }
        let conv = try XCTUnwrap(MeetingChatSurface.conversationID(for: transcript, dbPool: pool))
        let engine = center.engine(for: MeetingChatSurface.spec(transcript: transcript, recapContent: nil,
                                                                conversationID: conv, dbPool: pool))
        center.markShown(engine.spec.key)
        engine.send("q")
        center.markHidden(engine.spec.key)
        mock.release()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(engine.messages.last?.message.text, "answer")
        XCTAssertEqual(engine.messages.last?.message.status, "complete")
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class MeetingChatViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.ensureTable(db)
                try ChatMessageQueries.ensureTable(db)
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

    func testCreatesConversationWithMeetingContext() throws {
        let transcript = try loadTranscript()
        _ = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())

        let conv = try dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        }
        let unwrapped = try XCTUnwrap(conv)
        XCTAssertTrue(unwrapped.title.hasPrefix("Meeting:"))
    }

    func testReopensExistingConversationWithHistory() throws {
        let transcript = try loadTranscript()
        _ = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())
        let conv = try XCTUnwrap(dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        })
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "earlier question")
        }

        let vm2 = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())
        XCTAssertEqual(vm2.messages.map(\.text), ["earlier question"])
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

        let prompt = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: recap, dbPool: dbManager.dbPool)

        XCTAssertTrue(prompt.contains("Big meeting"))
        XCTAssertTrue(prompt.contains("shipped v2"))
        XCTAssertTrue(prompt.contains("get_transcript"),
                      "prompt must point the model at the MCP tool for the full text")
        XCTAssertLessThan(prompt.count, 16_000,
                          "transcript excerpt must be capped so the interactive CLI prompt stays clear of ARG_MAX")
    }

    func testPersistedMessageCount() throws {
        let transcript = try loadTranscript()
        let vm = MeetingChatViewModel(
            transcript: transcript, recapContent: nil,
            dbManager: dbManager, aiService: MockClaudeService())
        _ = vm
        let conv = try XCTUnwrap(dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        })
        try dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "q")
        }
        let count = try dbManager.dbPool.read { db in
            try MeetingChatViewModel.persistedMessageCount(db, transcriptID: 7)
        }
        XCTAssertEqual(count, 1)
    }
}

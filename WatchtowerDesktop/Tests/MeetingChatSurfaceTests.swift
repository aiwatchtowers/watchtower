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

    private func engine(for transcript: MeetingTranscript, ai: any AIServiceProtocol) async throws -> EmbeddedChatEngine {
        let conv = try await MeetingChatSurface.conversationID(transcriptID: 7, title: transcript.title, dbPool: dbManager.dbPool)
        let spec = try XCTUnwrap(MeetingChatSurface.spec(transcript: transcript, transcriptID: 7, recapContent: nil,
                                                         conversationID: conv, dbPool: dbManager.dbPool))
        return makeSurfaceEngine(spec, dbPool: dbManager.dbPool, ai: ai)
    }

    /// MEETPRIV-01: a private recording never gets a chat surface.
    func testMeetPriv01_NoSpecForAPrivateRecording() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 8, title: "Private 1:1", isPrivate: true)
        }
        let row = try await dbManager.dbPool.read { db in try MeetingTranscriptQueries.fetch(db, id: 8) }
        let transcript = try XCTUnwrap(row)
        XCTAssertNil(MeetingChatSurface.spec(transcript: transcript, transcriptID: 8, recapContent: nil,
                                             conversationID: 1, dbPool: dbManager.dbPool))
    }

    /// MEETPRIV-01: a recording turned private (header toggle or a reload
    /// that finds it private) loses its chat engine, and the row on screen is
    /// private by then, so the Chat tab's next render builds no new engine.
    /// Another recording's engine and a pane showing another recording are
    /// left alone.
    func testMeetPriv01_TurnedPrivateDropsTheChatAndNoSpecIsBuiltAgain() async throws {
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 9, title: "Other")
        }
        let pool = dbManager.dbPool
        let chats = EmbeddedChatCenter { spec, gate in
            makeSurfaceEngine(spec, dbPool: pool, ai: MockClaudeService(), gate: gate)
        }
        let transcript = try loadTranscript()
        let conv = try await MeetingChatSurface.conversationID(transcriptID: 7, title: transcript.title, dbPool: pool)
        let spec = try XCTUnwrap(MeetingChatSurface.spec(transcript: transcript, transcriptID: 7, recapContent: nil,
                                                         conversationID: conv, dbPool: pool))
        _ = chats.engine(for: spec)
        let fetched = try await pool.read { db in try MeetingTranscriptQueries.fetch(db, id: 9) }
        let other = try XCTUnwrap(fetched)
        let otherConv = try await MeetingChatSurface.conversationID(transcriptID: 9, title: "Other", dbPool: pool)
        let otherSpec = try XCTUnwrap(MeetingChatSurface.spec(transcript: other, transcriptID: 9, recapContent: nil,
                                                              conversationID: otherConv, dbPool: pool))
        _ = chats.engine(for: otherSpec)

        var shown: MeetingTranscript? = transcript
        MeetingChatSurface.recordingTurnedPrivate(7, shownRow: &shown, chats: chats)

        XCTAssertNil(chats.loaded(spec.key))
        XCTAssertNotNil(chats.loaded(otherSpec.key), "another recording keeps its chat")
        let row = try XCTUnwrap(shown)
        XCTAssertTrue(row.isPrivate)
        XCTAssertNil(MeetingChatSurface.spec(transcript: row, transcriptID: 7, recapContent: nil,
                                             conversationID: conv, dbPool: pool))

        // A pane already showing recording 9 keeps its row as it is.
        var paneOnOther: MeetingTranscript? = other
        MeetingChatSurface.recordingTurnedPrivate(7, shownRow: &paneOnOther, chats: chats)
        XCTAssertEqual(paneOnOther?.isPrivate, false)
    }

    /// MEETPRIV-02: a public recording B on event E never sends the recap
    /// a private recording A owns on E (Go's `GetMeetingRecapForAI`); a
    /// pasted recap (no owning recording) still reaches the prompt.
    func testMeetPriv02_ChatPromptSkipsTheEventRecapAPrivateRecordingOwns() async throws {
        let secret = #"{"summary":"PRIVATE-A-RECAP","key_decisions":["PRIVATE-A-DECISION"],"action_items":[],"open_questions":[]}"#
        try await dbManager.dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-e")
            try TestDatabase.insertMeetingTranscript(db, id: 20, eventID: "evt-e", title: "A", isPrivate: true)
            try TestDatabase.insertMeetingTranscript(db, id: 21, eventID: "evt-e", title: "B")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-e", transcriptID: 20,
                                                sourceText: "a's transcript", recapJSON: secret)
        }
        let (aiRecap, content, transcript) = try await dbManager.dbPool.read { db in
            let row = try XCTUnwrap(try MeetingTranscriptQueries.fetch(db, id: 21))
            return (try MeetingRecapQueries.fetchForRecordingForAI(db, transcriptID: 21, eventID: "evt-e"),
                    try MeetingChatSurface.recapContent(db, transcript: row, transcriptID: 21), row)
        }
        XCTAssertNil(aiRecap)
        XCTAssertNil(content)
        let prompt = MeetingChatSurface.buildSystemPrompt(
            transcript: transcript, recapContent: content, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil)
        XCTAssertFalse(prompt.contains("PRIVATE-A"))
        // The owner's own Recap tab still shows it locally.
        let shown = try await dbManager.dbPool.read { db in
            try MeetingRecapQueries.fetchForRecording(db, transcriptID: 21, eventID: "evt-e")
        }
        XCTAssertEqual(shown?.recap.parsed?.summary, "PRIVATE-A-RECAP")

        // A pasted recap (NULL transcript_id) on the event reaches the prompt.
        let pasted = #"{"summary":"PASTED-RECAP","key_decisions":[],"action_items":[],"open_questions":[]}"#
        try await dbManager.dbPool.write { db in
            try db.execute(sql: "DELETE FROM meeting_recaps")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-e", sourceText: "pasted", recapJSON: pasted)
        }
        let pastedContent = try await dbManager.dbPool.read { db in
            try MeetingChatSurface.recapContent(db, transcript: transcript, transcriptID: 21)
        }
        XCTAssertTrue(MeetingChatSurface.meetingContextBlock(transcript, recapContent: pastedContent)
            .contains("PASTED-RECAP"))
    }

    func testCreatesConversationWithMeetingContext() async throws {
        let transcript = try loadTranscript()
        _ = try await MeetingChatSurface.conversationID(transcriptID: 7, title: transcript.title, dbPool: dbManager.dbPool)

        let conv = try await dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        }
        let unwrapped = try XCTUnwrap(conv)
        XCTAssertTrue(unwrapped.title.hasPrefix("Meeting:"))
    }

    func testReopensExistingConversationWithHistory() async throws {
        let transcript = try loadTranscript()
        _ = try await MeetingChatSurface.conversationID(transcriptID: 7, title: transcript.title, dbPool: dbManager.dbPool)
        let found = try await dbManager.dbPool.read { db in
            try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "7")
        }
        let conv = try XCTUnwrap(found)
        try await dbManager.dbPool.write { db in
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "earlier question")
        }

        let engine = try await engine(for: transcript, ai: MockClaudeService())
        XCTAssertEqual(engine.messages.map(\.message.text), ["earlier question"])
    }

    func testSystemPromptCarriesMeetingContextAndCapsTranscript() async throws {
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

    /// AGENT-04: the meeting chat is draft-only — it must never carry a tool mode.
    func testSendPassesNoToolMode() async throws {
        let transcript = try loadTranscript()
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let engine = try await engine(for: transcript, ai: mock)

        engine.send("what did we decide?")
        await engine.finished()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)

        // AGENT-04: draft-only surfaces never send a tool mode.
        XCTAssertEqual(mock.toolModes, [nil])
    }

    /// A stored session id is never resumed (#604 G11): the turn sends the
    /// system prompt, which carries the meeting block.
    func testAStoredSessionIsNotResumedAndTheTurnCarriesTheSystemPrompt() async throws {
        let transcript = try loadTranscript()
        let conv = try await MeetingChatSurface.conversationID(transcriptID: 7, title: transcript.title, dbPool: dbManager.dbPool)
        try await dbManager.dbPool.write { db in try ChatConversationQueries.updateSessionID(db, id: conv, sessionID: "s1") }
        let mock = MockClaudeService(events: [.text("ok"), .done])
        let engine = try await engine(for: transcript, ai: mock)
        engine.send("who owns the launch?")
        await engine.finished()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(mock.prompts, ["who owns the launch?"])
        let system = try XCTUnwrap(mock.systemPrompts.first.flatMap { $0 })
        XCTAssertTrue(system.contains("=== MEETING RECORDING ==="))
    }

    /// Switching to another recording no longer cancels this one's reply:
    /// the engine lives in the center, keyed by the transcript.
    func testAnotherRecordingNeverStopsThisReply() async throws {
        let transcript = try loadTranscript()
        let mock = MockClaudeService(events: [.text("answer")], thenAwaitsRelease: true)
        let pool = dbManager.dbPool
        let center = EmbeddedChatCenter { spec, _ in makeSurfaceEngine(spec, dbPool: pool, ai: mock) }
        let conv = try await MeetingChatSurface.conversationID(transcriptID: 7, title: transcript.title, dbPool: pool)
        let engine = center.engine(for: try XCTUnwrap(MeetingChatSurface.spec(
            transcript: transcript, transcriptID: 7, recapContent: nil, conversationID: conv, dbPool: pool)))
        center.markShown(engine.spec.key)
        engine.send("q")
        await engine.finished()
        center.markHidden(engine.spec.key)
        mock.release()
        let done = await eventually { !engine.isStreaming }
        XCTAssertTrue(done)
        XCTAssertEqual(engine.messages.last?.message.text, "answer")
        XCTAssertEqual(engine.messages.last?.message.status, "complete")
    }

    /// The question card is taught on this surface too (spec 2026-10-02).
    func testSystemPromptTeachesTheQuestionCard() async throws {
        let transcript = try loadTranscript()
        let prompt = MeetingChatSurface.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil, skillsDir: nil)
        XCTAssertTrue(prompt.hasSuffix(ChatQuestionsContract.promptBlock))
    }
}

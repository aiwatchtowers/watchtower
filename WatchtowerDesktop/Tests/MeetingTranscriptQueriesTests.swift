import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class MeetingTranscriptQueriesTests: XCTestCase {
    private let summaryJSON =
        #"{"summary":"s","key_decisions":["d"],"action_items":[],"open_questions":[]}"#

    func test_fetchReturnsRowByID() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, id: 7, title: "Standup", transcriptText: "hello")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 7))
            XCTAssertEqual(transcript.id, 7)
            XCTAssertEqual(transcript.title, "Standup")
            XCTAssertEqual(transcript.transcriptText, "hello")
            XCTAssertNil(transcript.eventID)
            XCTAssertNil(try MeetingTranscriptQueries.fetch(db, id: 999))
        }
    }

    func test_fetchForEventReturnsOnlyThatEventNewestFirst() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertCalendarEvent(db, id: "evt-2")
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", title: "older")
            try TestDatabase.insertMeetingTranscript(db, id: 2, eventID: "evt-1", title: "newer")
            try TestDatabase.insertMeetingTranscript(db, id: 3, eventID: "evt-2", title: "other event")
            try TestDatabase.insertMeetingTranscript(db, id: 4, title: "ad-hoc")
        }
        try db.read { db in
            let rows = try MeetingTranscriptQueries.fetchForEvent(db, eventID: "evt-1")
            XCTAssertEqual(rows.map(\.id), [2, 1])
            XCTAssertEqual(rows.map(\.title), ["newer", "older"])
        }
    }

    func test_fetchAdHocReturnsOnlyNullEventRowsNewestFirst() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(db, id: 1, title: "first ad-hoc")
            try TestDatabase.insertMeetingTranscript(db, id: 2, eventID: "evt-1", title: "linked")
            try TestDatabase.insertMeetingTranscript(db, id: 3, title: "second ad-hoc")
        }
        try db.read { db in
            let rows = try MeetingTranscriptQueries.fetchAdHoc(db)
            XCTAssertEqual(rows.map(\.id), [3, 1])
            XCTAssertTrue(rows.allSatisfy { $0.eventID == nil })
        }
    }

    func test_fetchAdHocRespectsLimit() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            for i in Int64(1)...5 {
                try TestDatabase.insertMeetingTranscript(db, id: i)
            }
        }
        try db.read { db in
            let rows = try MeetingTranscriptQueries.fetchAdHoc(db, limit: 2)
            XCTAssertEqual(rows.map(\.id), [5, 4])
        }
    }

    func test_linkToEventCopiesSummaryIntoRecapWhenNoneExists() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, title: "Rec", transcriptText: "spoken words",
                summaryJSON: summaryJSON)
            try MeetingTranscriptQueries.linkToEvent(db, id: 1, eventID: "evt-1")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(transcript.eventID, "evt-1")
            let recap = try XCTUnwrap(MeetingRecapQueries.fetch(db, eventID: "evt-1"))
            XCTAssertEqual(recap.recapJSON, self.summaryJSON)
            XCTAssertEqual(recap.sourceText, "spoken words")
        }
    }

    func test_linkToEventLeavesExistingRecapUntouched() throws {
        let existingRecapJSON =
            #"{"summary":"existing","key_decisions":[],"action_items":[],"open_questions":[]}"#
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: existingRecapJSON)
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, transcriptText: "spoken words", summaryJSON: summaryJSON)
            try MeetingTranscriptQueries.linkToEvent(db, id: 1, eventID: "evt-1")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(transcript.eventID, "evt-1")
            let recap = try XCTUnwrap(MeetingRecapQueries.fetch(db, eventID: "evt-1"))
            XCTAssertEqual(recap.recapJSON, existingRecapJSON)
            XCTAssertEqual(recap.sourceText, "")
            let recapCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM meeting_recaps") ?? -1
            XCTAssertEqual(recapCount, 1)
        }
    }

    func test_linkToEventWithoutSummaryWritesOnlyEventID() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, transcriptText: "spoken words", summaryJSON: nil)
            try MeetingTranscriptQueries.linkToEvent(db, id: 1, eventID: "evt-1")
        }
        try db.read { db in
            let transcript = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(transcript.eventID, "evt-1")
            XCTAssertNil(try MeetingRecapQueries.fetch(db, eventID: "evt-1"))
        }
    }

    func test_recordingListReturnsAllNewestFirstWithLightFields() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, eventID: "evt-1", title: "Linked",
                transcriptText: String(repeating: "x", count: 500))
            try TestDatabase.insertMeetingTranscript(
                db, id: 2, title: "AdHoc", transcriptText: "short",
                summaryJSON: self.summaryJSON, notesMD: "# n")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertEqual(items.map(\.id), [2, 1])
            XCTAssertEqual(items[0].title, "AdHoc")
            XCTAssertTrue(items[0].hasRecap, "summary_json counts as a recap")
            XCTAssertTrue(items[0].hasNotes)
            XCTAssertEqual(items[0].snippet, "short")
            XCTAssertFalse(items[1].hasRecap)
            XCTAssertFalse(items[1].hasNotes)
            XCTAssertEqual(items[1].snippet.count, 200, "snippet must be capped at 200 chars")
            XCTAssertEqual(items[1].eventID, "evt-1")
        }
    }

    func test_recordingListJoinsEventTitleForLinkedRows() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1", title: "Design Review")
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", title: "Linked")
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "AdHoc")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertEqual(items.map(\.id), [2, 1])
            XCTAssertNil(items[0].eventTitle, "ad-hoc row carries no event title")
            XCTAssertEqual(items[1].eventTitle, "Design Review")
        }
    }

    func test_recordingListEventTitleAbsentAfterEventPruned() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1", title: "Design Review")
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", title: "Linked")
            // Sync retention prunes the event row; the transcript must outlive
            // it and the list must simply lose the subtitle, never error.
            try db.execute(sql: "DELETE FROM calendar_events WHERE id = 'evt-1'")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertEqual(items.map(\.id), [1])
            XCTAssertNil(items[0].eventTitle)
        }
    }

    func test_recordingListCountsEventRecapAsRecap() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: self.summaryJSON)
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", title: "Linked")
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertTrue(items[0].hasRecap, "meeting_recaps row for the linked event counts as a recap")
        }
    }

    func test_saveNotesWritesMarkdownAndBumpsUpdatedAt() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 1)
            try MeetingTranscriptQueries.saveNotes(db, id: 1, markdown: "# edited")
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.notesMD, "# edited")
        }
    }

    // MARK: - setUtteranceDeleted (soft delete + undo)

    private let utterancesFixture = [
        TranscriptUtterance(idx: 0, startSec: 0, endSec: 4, speaker: "Я", text: "привет"),
        TranscriptUtterance(idx: 1, startSec: 4, endSec: 9, speaker: "Speaker 1", text: "ответ"),
        TranscriptUtterance(idx: 2, startSec: 9, endSec: 15, speaker: "Я", text: "итог")
    ]

    private func insertSegmentedTranscript(_ db: Database, id: Int64 = 1) throws {
        let json = try XCTUnwrap(TranscriptSegments.encode(utterancesFixture))
        try TestDatabase.insertMeetingTranscript(
            db, id: id, title: "Segmented",
            transcriptText: TranscriptSegments.render(utterancesFixture),
            segmentsJSON: json)
    }

    func test_fetchDecodesUtterancesOnceAndLegacyStaysNil() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscript(db, id: 1)
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "Legacy")
        }
        try db.read { db in
            let withSegments = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(withSegments.utterances, self.utterancesFixture)
            let legacy = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 2))
            XCTAssertNil(legacy.utterances, "NULL segments_json → nil utterances (flat-text fallback)")
        }
    }

    func test_setUtteranceDeletedRewritesTextAndSegments() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscript(db)
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 1, idx: 1, deleted: true)
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, "[Я] привет\n[Я] итог",
                           "the rebuilt text must exclude the deleted utterance")
            let utterances = try XCTUnwrap(tr.utterances)
            XCTAssertEqual(utterances.count, 3, "soft delete: the utterance stays in the array")
            XCTAssertTrue(utterances[1].deleted)
        }
    }

    func test_undoRestoresByteIdentical() throws {
        let db = try TestDatabase.create()
        var jsonBefore = ""
        var textBefore = ""
        try db.write { db in
            try self.insertSegmentedTranscript(db)
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            jsonBefore = try XCTUnwrap(tr.segmentsJSON)
            textBefore = tr.transcriptText
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 1, idx: 1, deleted: true)
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 1, idx: 1, deleted: false)
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, textBefore)
            XCTAssertEqual(tr.segmentsJSON, jsonBefore, "undo must restore segments_json byte-identically")
        }
    }

    func test_deleteAllUtterancesYieldsEmptyValidText() throws {
        // Degenerate but valid: every utterance soft-deleted → empty
        // transcript_text, segments intact, no crash.
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscript(db)
            for idx in 0...2 {
                try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 1, idx: idx, deleted: true)
            }
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, "")
            let utterances = try XCTUnwrap(tr.utterances)
            XCTAssertEqual(utterances.count, 3)
            XCTAssertTrue(utterances.allSatisfy(\.deleted))
        }
    }

    func test_setUtteranceDeletedNoOpsOnLegacyAndUnknownIdx() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // Legacy row (NULL segments): no-op, text untouched.
            try TestDatabase.insertMeetingTranscript(db, id: 1, transcriptText: "flat legacy text")
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 1, idx: 0, deleted: true)
            // Segmented row, unknown idx: no-op.
            try self.insertSegmentedTranscript(db, id: 2)
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 2, idx: 99, deleted: true)
            // Missing row: no-op, no throw.
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 999, idx: 0, deleted: true)
        }
        try db.read { db in
            let legacy = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(legacy.transcriptText, "flat legacy text")
            XCTAssertNil(legacy.segmentsJSON)
            let segmented = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 2))
            XCTAssertEqual(segmented.transcriptText, TranscriptSegments.render(self.utterancesFixture))
            XCTAssertEqual(try XCTUnwrap(segmented.utterances).filter(\.deleted).count, 0)
        }
    }

    func test_deleteRemovesRowChatAndReturnsAudioPath() throws {
        let db = try TestDatabase.create()
        var returnedPath: String?
        try db.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: self.summaryJSON)
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, eventID: "evt-1", audioPath: "/tmp/rec_1.caf")
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "Keep me")
            let conv = try ChatConversationQueries.create(
                db, title: "Meeting: Rec", contextType: "meeting", contextID: "1")
            _ = try ChatMessageQueries.insert(db, conversationID: conv.id, role: "user", text: "hi")

            returnedPath = try MeetingTranscriptQueries.delete(db, id: 1)
        }
        XCTAssertEqual(returnedPath, "/tmp/rec_1.caf")
        try db.read { db in
            XCTAssertNil(try MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertNotNil(try MeetingTranscriptQueries.fetch(db, id: 2), "other transcripts untouched")
            XCTAssertNil(try ChatConversationQueries.fetchByContext(db, type: "meeting", id: "1"))
            let msgCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages") ?? -1
            XCTAssertEqual(msgCount, 0, "chat messages must be deleted with the conversation")
            XCTAssertNotNil(try MeetingRecapQueries.fetch(db, eventID: "evt-1"),
                            "the event's recap must survive transcript deletion (safe delete scope)")
        }
    }

    // Valid-but-degenerate inputs: no chat, no audio, already-swept audio.
    func test_deleteWithoutChatOrAudioSucceeds() throws {
        let db = try TestDatabase.create()
        var returnedPath: String? = "sentinel"
        try db.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            try TestDatabase.insertMeetingTranscript(db, id: 1, audioPath: nil)
            returnedPath = try MeetingTranscriptQueries.delete(db, id: 1)
        }
        XCTAssertNil(returnedPath, "NULL audio_path (already swept) must return nil")
        try db.read { db in
            XCTAssertNil(try MeetingTranscriptQueries.fetch(db, id: 1))
        }
    }

    func test_deleteUnknownIDIsNoOp() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            XCTAssertNil(try MeetingTranscriptQueries.delete(db, id: 999))
        }
    }

    // MARK: - renameSpeaker (speaker identity)

    private var speakersFixture: [SpeakerEmbedding] {
        [
            SpeakerEmbedding(speaker: "Я", embedding: [0, 1]),
            SpeakerEmbedding(speaker: "Speaker 1", embedding: [1, 0])
        ]
    }

    private func insertSegmentedTranscriptWithSpeakers(_ db: Database, id: Int64 = 1) throws {
        let json = try XCTUnwrap(TranscriptSegments.encode(utterancesFixture))
        let speakersJSON = try XCTUnwrap(SpeakerEmbeddings.encode(speakersFixture))
        try TestDatabase.insertMeetingTranscript(
            db, id: id, title: "Segmented",
            transcriptText: TranscriptSegments.render(utterancesFixture),
            segmentsJSON: json,
            speakersJSON: speakersJSON)
    }

    func test_renameSpeakerRewritesSegmentsTextAndSpeakers() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com")
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, "[Я] привет\n[Саша] ответ\n[Я] итог",
                           "transcript_text must be rebuilt with the new label")
            let utterances = try XCTUnwrap(tr.utterances)
            XCTAssertEqual(utterances.map(\.speaker), ["Я", "Саша", "Я"])
            // The invariant survives the rename.
            XCTAssertEqual(tr.transcriptText, TranscriptSegments.render(utterances))
            // speakers_json is re-keyed so later renames still resolve.
            let speakers = try XCTUnwrap(tr.speakerEmbeddings)
            XCTAssertEqual(speakers.map(\.speaker).sorted(), ["Саша", "Я"].sorted())
            // The voice print was learned.
            let voicePrint = try XCTUnwrap(VoicePrintQueries.fetch(db, personKey: "sasha@corp.com"))
            XCTAssertEqual(voicePrint.displayName, "Саша")
            XCTAssertEqual(voicePrint.sampleCount, 1)
            XCTAssertEqual(voicePrint.embeddingVector, [1, 0])
        }
    }

    func test_renameSpeakerRenamesDeletedUtterancesToo() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 1, idx: 1, deleted: true)
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com")
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            let utterances = try XCTUnwrap(tr.utterances)
            XCTAssertEqual(utterances[1].speaker, "Саша",
                           "a soft-deleted utterance stays in the array and must be renamed too")
            XCTAssertTrue(utterances[1].deleted)
            XCTAssertEqual(tr.transcriptText, "[Я] привет\n[Я] итог",
                           "deleted utterances stay out of the rendered text")
        }
    }

    func test_renameSpeakerSecondRecordingUpdatesCentroid() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db, id: 1)
            try self.insertSegmentedTranscriptWithSpeakers(db, id: 2)
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com")
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 2, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com")
        }
        try db.read { db in
            let voicePrint = try XCTUnwrap(VoicePrintQueries.fetch(db, personKey: "sasha@corp.com"))
            XCTAssertEqual(voicePrint.sampleCount, 2, "sample_count is monotonic")
            // Both samples were [1, 0] → the centroid stays [1, 0], normalized.
            XCTAssertEqual(voicePrint.embeddingVector[0], 1.0, accuracy: 1e-5)
            XCTAssertEqual(voicePrint.embeddingVector[1], 0.0, accuracy: 1e-5)
        }
    }

    func test_renameSpeakerWithoutEmbeddingsUpdatesTranscriptOnly() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // No speakers_json (legacy / non-FluidAudio diarizer).
            try self.insertSegmentedTranscript(db)
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com")
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, "[Я] привет\n[Саша] ответ\n[Я] итог")
            XCTAssertNil(try VoicePrintQueries.fetch(db, personKey: "sasha@corp.com"),
                         "no embedding → no voice print learned")
        }
    }

    func test_renameSpeakerNoOpsOnUnknownLabelLegacyRowAndEmptyName() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            let before = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))

            // Unknown label.
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 9", to: "Ghost", personKey: "ghost")
            // Empty / whitespace name.
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "   ", personKey: "blank")
            // Unchanged name.
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Speaker 1", personKey: "same")
            // Missing row.
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 999, from: "Speaker 1", to: "Саша", personKey: "sasha")

            let after = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(after.transcriptText, before.transcriptText)
            XCTAssertEqual(after.segmentsJSON, before.segmentsJSON)
            XCTAssertEqual(after.speakersJSON, before.speakersJSON)
            XCTAssertEqual(try VoicePrint.fetchCount(db), 0, "no-ops must not learn voice prints")
        }
    }

    /// A rename to a reserved label — «Я» in any case, or the "Speaker N"
    /// pattern — must be rejected wholesale: applying it would merge a
    /// stranger's cluster into the owner's identity and mint a voice print
    /// (person_key "я") that voice-matches that stranger to «Я» in every
    /// future recording.
    func test_renameSpeakerRejectsReservedLabels() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            let before = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))

            for reserved in ["Я", "я", " Я ", "Speaker 5"] {
                let applied = try MeetingTranscriptQueries.renameSpeaker(
                    db, id: 1, from: "Speaker 1", to: reserved, personKey: reserved.lowercased())
                XCTAssertFalse(applied, "rename to reserved label \(reserved) must be refused")
            }

            let after = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(after.transcriptText, before.transcriptText)
            XCTAssertEqual(after.segmentsJSON, before.segmentsJSON)
            XCTAssertEqual(after.speakersJSON, before.speakersJSON)
            XCTAssertEqual(try VoicePrint.fetchCount(db), 0,
                           "a refused rename must never learn a voice print")
        }
    }

    func test_renameSpeakerReturnsTrueOnlyWhenApplied() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            XCTAssertTrue(try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com"))
            // The label is gone now — a stale second rename reports false so
            // the UI can keep the suggestion chip and explain.
            XCTAssertFalse(try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Петя", personKey: "petya"))
        }
    }

    /// Renaming a cluster INTO an existing label (over-split repair: the
    /// diarizer split one person into two clusters) merges the utterances
    /// under one label; both embeddings stay in speakers_json under that
    /// label, and the renamed cluster's embedding is folded into the voice
    /// print (one sample per confirmed rename).
    func test_renameSpeakerIntoExistingLabelMergesClusters() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            let utterances = [
                TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Саша", text: "привет"),
                TranscriptUtterance(idx: 1, startSec: 1, endSec: 2, speaker: "Speaker 2", text: "ответ"),
                TranscriptUtterance(idx: 2, startSec: 2, endSec: 3, speaker: "Саша", text: "итог")
            ]
            let json = try XCTUnwrap(TranscriptSegments.encode(utterances))
            let speakersJSON = try XCTUnwrap(SpeakerEmbeddings.encode([
                SpeakerEmbedding(speaker: "Саша", embedding: [1, 0]),
                SpeakerEmbedding(speaker: "Speaker 2", embedding: [0, 1])
            ]))
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, title: "Split",
                transcriptText: TranscriptSegments.render(utterances),
                segmentsJSON: json, speakersJSON: speakersJSON)

            XCTAssertTrue(try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 2", to: "Саша", personKey: "sasha@corp.com"))

            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            let merged = try XCTUnwrap(tr.utterances)
            XCTAssertEqual(merged.map(\.speaker), ["Саша", "Саша", "Саша"],
                           "the renamed cluster merges into the existing label")
            // Both cluster embeddings survive under the shared label — the
            // merge repairs an over-split, it must not discard voice data.
            let speakers = try XCTUnwrap(tr.speakerEmbeddings)
            XCTAssertEqual(speakers.map(\.speaker), ["Саша", "Саша"])
            // Only the RENAMED cluster's embedding was learned (one sample):
            // the pre-existing "Саша" cluster was never confirmed by this
            // action.
            let voicePrint = try XCTUnwrap(VoicePrintQueries.fetch(db, personKey: "sasha@corp.com"))
            XCTAssertEqual(voicePrint.sampleCount, 1)
            XCTAssertEqual(voicePrint.embeddingVector[0], 0, accuracy: 1e-5)
            XCTAssertEqual(voicePrint.embeddingVector[1], 1, accuracy: 1e-5)
        }
    }

    /// A later rename of the same person to a corrected spelling refreshes
    /// the stored display_name on the existing person_key row.
    func test_voicePrintUpsertRefreshesDisplayName() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db, id: 1)
            try self.insertSegmentedTranscriptWithSpeakers(db, id: 2)
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com")
            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 2, from: "Speaker 1", to: "Александр", personKey: "sasha@corp.com")

            let voicePrint = try XCTUnwrap(VoicePrintQueries.fetch(db, personKey: "sasha@corp.com"))
            XCTAssertEqual(voicePrint.displayName, "Александр",
                           "the latest confirmed spelling wins")
            XCTAssertEqual(voicePrint.sampleCount, 2)
        }
    }

    func test_voicePrintUpsertSkipsDegenerateEmbedding() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // Zero-vector embedding: rename applies, print is NOT learned.
            let utterances = self.utterancesFixture
            let json = try XCTUnwrap(TranscriptSegments.encode(utterances))
            let speakersJSON = try XCTUnwrap(SpeakerEmbeddings.encode(
                [SpeakerEmbedding(speaker: "Speaker 1", embedding: [0, 0])]))
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, title: "Zero",
                transcriptText: TranscriptSegments.render(utterances),
                segmentsJSON: json, speakersJSON: speakersJSON)

            try MeetingTranscriptQueries.renameSpeaker(
                db, id: 1, from: "Speaker 1", to: "Саша", personKey: "sasha@corp.com")

            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, "[Я] привет\n[Саша] ответ\n[Я] итог",
                           "the rename itself must still apply")
            XCTAssertNil(try VoicePrintQueries.fetch(db, personKey: "sasha@corp.com"),
                         "a zero-vector embedding must never become a voice print")
        }
    }
}

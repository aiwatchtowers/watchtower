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

    /// The durable link: a recap whose event was deleted (event_id NULL,
    /// migration 00056 SET NULL) still resolves via its transcript_id, so an
    /// event-deleted recording keeps showing its recap.
    func test_fetchByTranscriptIDResolvesRecapWithDeletedEvent() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 5, title: "Rec")
            try TestDatabase.insertMeetingRecap(
                db, eventID: nil, transcriptID: 5, recapJSON: summaryJSON)
        }
        try db.read { db in
            let recap = try XCTUnwrap(MeetingRecapQueries.fetch(db, transcriptID: 5))
            XCTAssertNil(recap.eventID)
            XCTAssertEqual(recap.recapJSON, self.summaryJSON)
            XCTAssertNil(try MeetingRecapQueries.fetch(db, transcriptID: 999))
        }
    }

    /// The Swift dual-path writer stamps `transcript_id`, so a recap it creates
    /// resolves by the durable link too (not only by event_id).
    func test_linkToEventStampsTranscriptIDOnRecap() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try TestDatabase.insertMeetingTranscript(
                db, id: 8, transcriptText: "spoken words", summaryJSON: summaryJSON)
            try MeetingTranscriptQueries.linkToEvent(db, id: 8, eventID: "evt-1")
        }
        try db.read { db in
            let recap = try XCTUnwrap(MeetingRecapQueries.fetch(db, transcriptID: 8))
            XCTAssertEqual(recap.eventID, "evt-1")
            XCTAssertEqual(recap.recapJSON, self.summaryJSON)
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

    /// Ad-hoc transcript (event_id NULL) whose recap links back by
    /// transcript_id only (also event_id NULL): `r.event_id = t.event_id`
    /// is NULL = NULL, which SQL never treats as a match, so before the
    /// `OR r.transcript_id = t.id` clause the list badge showed "no recap"
    /// for a recording the detail view rendered a recap for fine.
    func test_recordingListCountsTranscriptLinkedRecapOnAdHocRow() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 1, title: "AdHoc")
            try TestDatabase.insertMeetingRecap(db, transcriptID: 1, recapJSON: self.summaryJSON)
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            XCTAssertTrue(items[0].hasRecap, "meeting_recaps row linked by transcript_id counts as a recap")
        }
    }

    /// An unrelated recap (different transcript_id, no shared event) must
    /// not make this ad-hoc row look like it has a recap.
    func test_recordingListDoesNotCountUnrelatedRecapAsRecap() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 1, title: "AdHoc")
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "Other")
            try TestDatabase.insertMeetingRecap(db, transcriptID: 2, recapJSON: self.summaryJSON)
        }
        try db.read { db in
            let items = try MeetingTranscriptQueries.fetchRecordingList(db)
            let adHoc = try XCTUnwrap(items.first { $0.id == 1 })
            XCTAssertFalse(adHoc.hasRecap, "a recap linked to a different transcript must not count")
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
            XCTAssertNil(try MeetingTranscriptQueries.delete(db, id: 999))
        }
    }

    // MARK: - relabelCluster (speaker identity)

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

    func test_relabelClusterRewritesSegmentsTextAndSpeakers() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша"))
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, "[Я] привет\n[Саша] ответ\n[Я] итог",
                           "transcript_text must be rebuilt with the new label")
            let utterances = try XCTUnwrap(tr.utterances)
            XCTAssertEqual(utterances.map(\.speaker), ["Я", "Саша", "Я"])
            // The invariant survives the relabel.
            XCTAssertEqual(tr.transcriptText, TranscriptSegments.render(utterances))
            // speakers_json is re-keyed so later relabels still resolve, and
            // the first relabel remembers the original label.
            let speakers = try XCTUnwrap(tr.speakerEmbeddings)
            XCTAssertEqual(speakers.map(\.speaker).sorted(), ["Саша", "Я"].sorted())
            XCTAssertEqual(speakers.first { $0.speaker == "Саша" }?.originalLabel, "Speaker 1")
            XCTAssertNotNil(tr.speakerNamesChangedAt)
            XCTAssertEqual(try VoiceSample.fetchCount(db), 0, "a relabel alone never learns a voice")
        }
    }

    /// The recap-refresh hint on the REAL row a relabel writes: the relabel
    /// stamps `speaker_names_changed_at` and `updated_at` in one UPDATE, so
    /// the hint must compare against the recap's own generation stamp — this
    /// pins that the relabel turns it on and a later recap turns it off.
    func test_relabelMakesRecapHintAppearUntilTheRecapIsRegenerated() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            try db.execute(sql: """
                UPDATE meeting_transcripts
                SET summary_json = '{"summary":"s"}', summary_updated_at = '2020-01-01T00:00:00Z'
                WHERE id = 1
                """)
        }
        let before = try XCTUnwrap(try db.read { try MeetingTranscriptQueries.fetch($0, id: 1) })
        XCTAssertFalse(before.recapPredatesSpeakerNames(shownRecap: nil), "no relabel yet")

        try db.write { db in
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша"))
        }
        let relabeled = try XCTUnwrap(try db.read { try MeetingTranscriptQueries.fetch($0, id: 1) })
        XCTAssertEqual(relabeled.updatedAt, relabeled.speakerNamesChangedAt, "the relabel bumps both in one UPDATE")
        XCTAssertTrue(relabeled.recapPredatesSpeakerNames(shownRecap: nil), "ad-hoc recap is now stale")

        // Go's recap writer stamps summary_updated_at on regeneration.
        try db.write { db in
            try db.execute(sql: "UPDATE meeting_transcripts SET summary_updated_at = '2999-01-01T00:00:00Z' WHERE id = 1")
        }
        let regenerated = try XCTUnwrap(try db.read { try MeetingTranscriptQueries.fetch($0, id: 1) })
        XCTAssertFalse(regenerated.recapPredatesSpeakerNames(shownRecap: nil))
    }

    /// N7: `linkToEvent` copies the summary into `meeting_recaps` with the
    /// LINK time as `updated_at`. A relabel made before the link must still
    /// show the hint — the copy is compared by the summary's own generation
    /// stamp — and Go's regenerate (row + summary copy refreshed together)
    /// clears it.
    func test_relabelBeforeLinkToEventStillHintsUntilRegenerated() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1")
            try self.insertSegmentedTranscriptWithSpeakers(db)
            try db.execute(sql: """
                UPDATE meeting_transcripts
                SET summary_json = '{"summary":"s","key_decisions":[],"action_items":[],"open_questions":[]}',
                    summary_updated_at = '2020-01-01T00:00:00Z'
                WHERE id = 1
                """)
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша"))
            try MeetingTranscriptQueries.linkToEvent(db, id: 1, eventID: "evt-1")
        }
        func hint() throws -> Bool {
            try db.read { db in
                let row = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
                let shown = try MeetingRecapQueries.fetchForRecording(db, transcriptID: 1, eventID: row.eventID)
                XCTAssertEqual(shown?.ownedByRecording, true, "the copied row is this recording's own")
                return row.recapPredatesSpeakerNames(shownRecap: shown)
            }
        }
        XCTAssertTrue(try hint(), "the copied recap still predates the relabel")

        // What Go's storeTranscriptRecap writes on `transcript recap 1`.
        try db.write { db in
            try db.execute(sql: "UPDATE meeting_recaps SET updated_at = '2999-01-01T00:00:00Z' WHERE transcript_id = 1")
            try db.execute(sql: "UPDATE meeting_transcripts SET summary_updated_at = '2999-01-01T00:00:00Z' WHERE id = 1")
        }
        XCTAssertFalse(try hint())
    }

    /// Two clusters are never merged under one label: a target another
    /// speaker of the transcript already carries is refused, nothing written.
    func test_relabelClusterRefusesALabelAnotherSpeakerCarries() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша"))
            XCTAssertFalse(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Я", to: "Саша"),
                           "«Я»'s cluster must not merge into Саша's")
            // Renaming a cluster onto itself stays allowed (a re-confirm).
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Саша", to: "Саша"))
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(try XCTUnwrap(tr.utterances).map(\.speaker), ["Я", "Саша", "Я"])
            XCTAssertEqual(Set(try XCTUnwrap(tr.speakerEmbeddings).map(\.speaker)), ["Саша", "Я"])
        }
    }

    func test_relabelClusterRenamesDeletedUtterancesToo() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            try MeetingTranscriptQueries.setUtteranceDeleted(db, id: 1, idx: 1, deleted: true)
            try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша")
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

    func test_relabelClusterWithoutEmbeddingsUpdatesTranscriptOnly() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            // No speakers_json (legacy / non-FluidAudio diarizer).
            try self.insertSegmentedTranscript(db)
            try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша")
        }
        try db.read { db in
            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(tr.transcriptText, "[Я] привет\n[Саша] ответ\n[Я] итог")
            XCTAssertNil(tr.speakersJSON)
        }
    }

    func test_relabelClusterNoOpsOnUnknownLabelMissingRowAndEmptyName() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            let before = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))

            XCTAssertFalse(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 9", to: "Ghost"))
            XCTAssertFalse(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "   "))
            XCTAssertFalse(try MeetingTranscriptQueries.relabelCluster(db, id: 999, from: "Speaker 1", to: "Саша"))

            let after = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(after.transcriptText, before.transcriptText)
            XCTAssertEqual(after.segmentsJSON, before.segmentsJSON)
            XCTAssertEqual(after.speakersJSON, before.speakersJSON)
            XCTAssertNil(after.speakerNamesChangedAt, "a refused relabel must not stamp a change")
        }
    }

    /// «Я» (any case) is the role pass's alone — a relabel to it would merge
    /// a stranger's cluster into the owner's identity. "Speaker N" stays a
    /// valid target: rollback restores it.
    func test_relabelClusterRejectsOwnerLabelButAllowsSpeakerN() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            let before = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))

            for reserved in ["Я", "я", " Я "] {
                let applied = try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: reserved)
                XCTAssertFalse(applied, "relabel to «Я» (\(reserved)) must be refused")
            }
            let after = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(after.transcriptText, before.transcriptText)
            XCTAssertEqual(after.segmentsJSON, before.segmentsJSON)
            XCTAssertEqual(after.speakersJSON, before.speakersJSON)

            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша"))
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Саша", to: "Speaker 1") {
                $0.labelSource = VoiceLabelSource.none
            }, "a rollback to Speaker N must apply")
            let rolledBack = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(rolledBack.transcriptText, before.transcriptText)
            let cluster = try XCTUnwrap(rolledBack.speakerEmbeddings?.first { $0.speaker == "Speaker 1" })
            XCTAssertEqual(cluster.originalLabel, "Speaker 1", "the first relabel's original label is kept")
            XCTAssertEqual(cluster.labelSource, VoiceLabelSource.none)
        }
    }

    func test_relabelClusterReturnsTrueOnlyWhenApplied() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try self.insertSegmentedTranscriptWithSpeakers(db)
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Саша"))
            // The label is gone now — a stale second relabel reports false so
            // the UI can keep the suggestion chip and explain.
            XCTAssertFalse(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 1", to: "Петя"))
        }
    }

    /// Relabeling a cluster INTO an existing label is refused: two
    /// `speakers_json` entries under one label would make every label-keyed
    /// registry operation (rollback, relabel, patch) hit both clusters. This
    /// used to merge them (the pre-registry over-split repair).
    func test_relabelClusterIntoExistingLabelIsRefused() throws {
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

            XCTAssertFalse(try MeetingTranscriptQueries.relabelCluster(db, id: 1, from: "Speaker 2", to: "Саша") {
                $0.labelSource = .owner
            })

            let tr = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(try XCTUnwrap(tr.utterances).map(\.speaker), ["Саша", "Speaker 2", "Саша"], "nothing written")
            let speakers = try XCTUnwrap(tr.speakerEmbeddings)
            XCTAssertEqual(speakers.map(\.speaker), ["Саша", "Speaker 2"])
            XCTAssertEqual(speakers.map(\.labelSource), [nil, nil])
            XCTAssertNil(tr.speakerNamesChangedAt)
        }
    }
}

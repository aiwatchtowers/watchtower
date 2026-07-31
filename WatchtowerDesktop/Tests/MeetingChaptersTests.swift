import GRDB
import XCTest
@testable import WatchtowerDesktop

final class MeetingChaptersTests: XCTestCase {

    /// Full payload in the persisted (Go-written) shape.
    private let fullJSON = """
    {"overall_summary":"Roadmap sync.","chapters":[
      {"title":"Rollout","start_sec":0,"end_sec":300,
       "participants":["Я","Speaker 1"],"summary":"Rollout order agreed.",
       "decisions":["Ship v2 on Friday"],
       "action_items":[{"text":"Alice preps changelog"},{"text":"Bob books review","converted_target_id":42}],
       "open_questions":[]},
      {"title":"Budget","start_sec":300,"end_sec":900,
       "participants":["Speaker 1"],"summary":"Carry-over.",
       "decisions":[],"action_items":[],"open_questions":["Who signs off Q3?"]}
    ]}
    """

    // MARK: - Decoding

    func testDecodeFullPayload() throws {
        let chapters = try XCTUnwrap(MeetingChapters.decode(fullJSON))
        XCTAssertEqual(chapters.overallSummary, "Roadmap sync.")
        XCTAssertEqual(chapters.chapters.count, 2)
        let first = chapters.chapters[0]
        XCTAssertEqual(first.title, "Rollout")
        XCTAssertEqual(first.participants, ["Я", "Speaker 1"])
        XCTAssertEqual(first.decisions, ["Ship v2 on Friday"])
        XCTAssertEqual(first.actionItems.count, 2)
        XCTAssertNil(first.actionItems[0].convertedTargetID)
        XCTAssertEqual(first.actionItems[1].convertedTargetID, 42)
        XCTAssertEqual(chapters.chapters[1].openQuestions, ["Who signs off Q3?"])
    }

    func testDecodeMissingFieldsDefaultsToEmpty() throws {
        // Partial chapter — only a title and times; every group defaults.
        let json = #"{"chapters":[{"title":"Only title","start_sec":5,"end_sec":10}]}"#
        let chapters = try XCTUnwrap(MeetingChapters.decode(json))
        XCTAssertEqual(chapters.overallSummary, "")
        let ch = chapters.chapters[0]
        XCTAssertEqual(ch.title, "Only title")
        XCTAssertEqual(ch.startSec, 5)
        XCTAssertTrue(ch.participants.isEmpty)
        XCTAssertTrue(ch.decisions.isEmpty)
        XCTAssertTrue(ch.actionItems.isEmpty)
        XCTAssertTrue(ch.openQuestions.isEmpty)
    }

    func testDecodeBareStringActionItems() throws {
        // The model may emit action items as bare strings (mirrors the Go
        // ChapterActionItem.UnmarshalJSON tolerance).
        let json = #"{"chapters":[{"title":"t","start_sec":0,"end_sec":1,"action_items":["do it","then this"]}]}"#
        let chapters = try XCTUnwrap(MeetingChapters.decode(json))
        XCTAssertEqual(chapters.chapters[0].actionItems.map(\.text), ["do it", "then this"])
        XCTAssertNil(chapters.chapters[0].actionItems[0].convertedTargetID)
    }

    func testDecodeMalformedOrEmptyReturnsNil() {
        XCTAssertNil(MeetingChapters.decode("not json"))
        XCTAssertNil(MeetingChapters.decode(#"{"overall_summary":"s","chapters":[]}"#))
        XCTAssertNil(MeetingChapters.decode(#"{"overall_summary":"s"}"#))
    }

    func testEncodeDecodeRoundTripPreservesConvertedTargetID() throws {
        var chapters = try XCTUnwrap(MeetingChapters.decode(fullJSON))
        chapters.chapters[0].actionItems[0].convertedTargetID = 7
        let encoded = try XCTUnwrap(MeetingChapters.encode(chapters))
        let back = try XCTUnwrap(MeetingChapters.decode(encoded))
        XCTAssertEqual(back, chapters)
        XCTAssertEqual(back.chapters[0].actionItems[0].convertedTargetID, 7)
        XCTAssertEqual(back.chapters[0].actionItems[1].convertedTargetID, 42)
    }

    func testEncodeIsDeterministic() throws {
        let chapters = try XCTUnwrap(MeetingChapters.decode(fullJSON))
        XCTAssertEqual(MeetingChapters.encode(chapters), MeetingChapters.encode(chapters))
    }

    // MARK: - Chapter → transcript index resolution

    private let utterances = [
        TranscriptUtterance(idx: 0, startSec: 0, endSec: 10, speaker: "Я", text: "a"),
        TranscriptUtterance(idx: 1, startSec: 10, endSec: 20, speaker: "Speaker 1", text: "b"),
        TranscriptUtterance(idx: 2, startSec: 20, endSec: 30, speaker: "Я", text: "c")
    ]

    func testFirstUtteranceIdxExactAndBetween() {
        XCTAssertEqual(MeetingChapters.firstUtteranceIdx(in: utterances, atOrAfter: 0), 0)
        XCTAssertEqual(MeetingChapters.firstUtteranceIdx(in: utterances, atOrAfter: 10), 1)
        // A chapter starting mid-utterance resolves to the NEXT utterance
        // (first with startSec >= chapter start).
        XCTAssertEqual(MeetingChapters.firstUtteranceIdx(in: utterances, atOrAfter: 12), 2)
    }

    func testFirstUtteranceIdxSkipsDeleted() {
        var withDeleted = utterances
        withDeleted[1].deleted = true
        XCTAssertEqual(MeetingChapters.firstUtteranceIdx(in: withDeleted, atOrAfter: 10), 2)
    }

    func testFirstUtteranceIdxAfterLastFallsBackToLast() {
        // Chapter starting after the final utterance still lands somewhere.
        XCTAssertEqual(MeetingChapters.firstUtteranceIdx(in: utterances, atOrAfter: 999), 2)
    }

    func testFirstUtteranceIdxAllDeletedReturnsNil() {
        // Degenerate but valid: everything soft-deleted → nowhere to jump.
        var allDeleted = utterances
        for i in allDeleted.indices { allDeleted[i].deleted = true }
        XCTAssertNil(MeetingChapters.firstUtteranceIdx(in: allDeleted, atOrAfter: 0))
        XCTAssertNil(MeetingChapters.firstUtteranceIdx(in: [], atOrAfter: 0))
    }

    // MARK: - Converted-item write round-trip

    func testSetActionItemConvertedRoundTrip() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertMeetingTranscript(
                conn, id: 5, transcriptText: "text", chaptersJSON: fullJSON)
            try MeetingTranscriptQueries.setActionItemConverted(
                conn, id: 5, chapterIdx: 0, itemIdx: 0, targetID: 101)
        }
        try db.read { conn in
            let row = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: 5))
            let chapters = try XCTUnwrap(row.parsedChapters)
            XCTAssertEqual(chapters.chapters[0].actionItems[0].convertedTargetID, 101)
            // The sibling item's pre-existing conversion is untouched, and the
            // item itself stays in the chapter (link, not delete).
            XCTAssertEqual(chapters.chapters[0].actionItems[1].convertedTargetID, 42)
            XCTAssertEqual(chapters.chapters[0].actionItems.count, 2)
        }
    }

    func testSetActionItemConvertedUnknownIndicesIsNoOp() throws {
        // Degenerate but valid: stale UI indices must never corrupt the JSON.
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertMeetingTranscript(
                conn, id: 6, transcriptText: "text", chaptersJSON: fullJSON)
            try MeetingTranscriptQueries.setActionItemConverted(
                conn, id: 6, chapterIdx: 9, itemIdx: 0, targetID: 101)
            try MeetingTranscriptQueries.setActionItemConverted(
                conn, id: 6, chapterIdx: 0, itemIdx: 9, targetID: 101)
            try MeetingTranscriptQueries.setActionItemConverted(
                conn, id: 999, chapterIdx: 0, itemIdx: 0, targetID: 101)
        }
        try db.read { conn in
            let row = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: 6))
            XCTAssertEqual(row.chaptersJSON, self.fullJSON, "unknown indices must leave the JSON untouched")
        }
    }

    func testSetActionItemConvertedWithoutChaptersIsNoOp() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertMeetingTranscript(conn, id: 7, transcriptText: "text")
            try MeetingTranscriptQueries.setActionItemConverted(
                conn, id: 7, chapterIdx: 0, itemIdx: 0, targetID: 101)
        }
        try db.read { conn in
            let row = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: 7))
            XCTAssertNil(row.chaptersJSON)
        }
    }
}

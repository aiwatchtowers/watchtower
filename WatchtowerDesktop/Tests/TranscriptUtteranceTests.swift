import XCTest
@testable import WatchtowerDesktop

final class TranscriptUtteranceTests: XCTestCase {

    /// Shared cross-side fixture: Go's `internal/meeting/segments_test.go`
    /// uses the same input and expects the same rendered string, pinning the
    /// Go↔Swift canonical-renderer equivalence (the
    /// transcript_text = render(segments) dual-path).
    private let fixture = [
        TranscriptUtterance(idx: 0, startSec: 0, endSec: 4.2, speaker: "Я", text: "привет как дела"),
        TranscriptUtterance(idx: 1, startSec: 4.2, endSec: 7.5, speaker: "Speaker 1", text: "нормально"),
        TranscriptUtterance(idx: 2, startSec: 8.1, endSec: 12.9, speaker: "Я", text: "отлично")
    ]

    private let fixtureRendered = "[Я] привет как дела\n[Speaker 1] нормально\n[Я] отлично"

    func testRenderMatchesGoFixture() {
        XCTAssertEqual(TranscriptSegments.render(fixture), fixtureRendered)
    }

    func testRenderSkipsDeleted() {
        var utterances = fixture
        utterances[1].deleted = true
        XCTAssertEqual(TranscriptSegments.render(utterances), "[Я] привет как дела\n[Я] отлично")
    }

    func testRenderAllDeletedIsEmpty() {
        // Degenerate but valid: every utterance soft-deleted → empty text.
        var utterances = fixture
        for i in utterances.indices { utterances[i].deleted = true }
        XCTAssertEqual(TranscriptSegments.render(utterances), "")
    }

    func testEncodeDecodeRoundTrip() throws {
        let json = try XCTUnwrap(TranscriptSegments.encode(fixture))
        XCTAssertEqual(TranscriptSegments.decode(json), fixture)
    }

    func testEncodeIsDeterministic() throws {
        // Sorted keys → a delete + undo cycle re-encodes byte-identically.
        let first = try XCTUnwrap(TranscriptSegments.encode(fixture))
        let second = try XCTUnwrap(TranscriptSegments.encode(fixture))
        XCTAssertEqual(first, second)
    }

    func testDecodeSnakeCaseKeys() throws {
        let json = """
        [{"idx":0,"start_sec":1.5,"end_sec":3.25,"speaker":"Speaker 1","text":"hi","deleted":true}]
        """
        let utterances = try XCTUnwrap(TranscriptSegments.decode(json))
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances[0].startSec, 1.5)
        XCTAssertEqual(utterances[0].endSec, 3.25)
        XCTAssertEqual(utterances[0].speaker, "Speaker 1")
        XCTAssertTrue(utterances[0].deleted)
    }

    func testDecodeDefaultsMissingDeletedToFalse() throws {
        let json = """
        [{"idx":0,"start_sec":0,"end_sec":1,"speaker":"Я","text":"hi"}]
        """
        let utterances = try XCTUnwrap(TranscriptSegments.decode(json))
        XCTAssertFalse(utterances[0].deleted)
    }

    func testDecodeRejectsMalformedAndEmpty() {
        XCTAssertNil(TranscriptSegments.decode("not json"))
        XCTAssertNil(TranscriptSegments.decode("{\"idx\":0}"))
        XCTAssertNil(TranscriptSegments.decode("[]"), "an empty array must fall back to the flat text")
    }

    func testMeetingTranscriptUtterancesDecodeOnce() throws {
        let json = try XCTUnwrap(TranscriptSegments.encode(fixture))
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, transcriptText: self.fixtureRendered, segmentsJSON: json)
            try TestDatabase.insertMeetingTranscript(db, id: 2, title: "Legacy")
        }
        try db.read { db in
            let withSegments = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 1))
            XCTAssertEqual(withSegments.utterances, self.fixture)
            let legacy = try XCTUnwrap(MeetingTranscriptQueries.fetch(db, id: 2))
            XCTAssertNil(legacy.utterances, "NULL segments_json → nil utterances (flat-text fallback)")
        }
    }
}

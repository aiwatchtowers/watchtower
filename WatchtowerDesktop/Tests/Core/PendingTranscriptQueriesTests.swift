import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `pending_transcripts` (#604 S3/S4): the recorder's rows replacing the
/// `rec_*` sidecars.
final class PendingTranscriptQueriesTests: XCTestCase {
    private func store() throws -> DatabasePendingTranscriptStore {
        DatabasePendingTranscriptStore(writer: try TestDatabase.create())
    }

    func testBeginThenTranscriptThenRemove() throws {
        let store = try store()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.begin(recording: "rec_1.caf", eventID: "evt", title: "Standup", at: at)
        try store.saveTranscript(recording: "rec_1.caf", text: "hello", metaJSON: #"{"durationSec":5,"langStats":{}}"#,
                                 at: at.addingTimeInterval(60))
        // A later begin (a legacy pointer) keeps the kept transcript.
        try store.begin(recording: "rec_1.caf", eventID: "evt", title: "Standup", at: at)
        let row = try XCTUnwrap(try store.transcript(recording: "rec_1.caf"))
        XCTAssertEqual(row.title, "Standup")
        XCTAssertEqual(row.transcript, "hello")
        XCTAssertEqual(row.startedAt, at)
        XCTAssertFalse(row.dismissed)

        try store.clearTranscript(recording: "rec_1.caf")
        XCTAssertNil(try store.transcript(recording: "rec_1.caf")?.transcript)
        try store.remove(recording: "rec_1.caf")
        XCTAssertEqual(try store.pending(), [])
    }

    func testReserveIsExclusive() throws {
        let store = try store()
        XCTAssertTrue(try store.reserve(recording: "rec_2.m4a", eventID: nil, title: "A", at: Date()))
        XCTAssertFalse(try store.reserve(recording: "rec_2.m4a", eventID: nil, title: "B", at: Date()))
        XCTAssertEqual(try store.transcript(recording: "rec_2.m4a")?.title, "A", "the first reservation stands")
    }

    func testDismissWritesATombstoneEvenWithoutARow() throws {
        let store = try store()
        try store.dismiss(recording: "rec_3.caf", at: Date())
        XCTAssertEqual(try store.transcript(recording: "rec_3.caf")?.dismissed, true)
    }

    func testSavedAudioPaths() throws {
        let db = try TestDatabase.create()
        try db.write { try TestDatabase.insertMeetingTranscript($0, audioPath: "/r/rec_4.caf") }
        XCTAssertEqual(try DatabasePendingTranscriptStore(writer: db).savedAudioPaths(), ["/r/rec_4.caf"])
    }
}

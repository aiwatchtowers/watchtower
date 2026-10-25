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

    func testBeginThenTranscriptThenRemove() async throws {
        let store = try store()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.begin(recording: "rec_1.caf", eventID: "evt", title: "Standup", at: at)
        try await store.saveTranscript(recording: "rec_1.caf", text: "hello", metaJSON: #"{"durationSec":5,"langStats":{}}"#,
                                       at: at.addingTimeInterval(60))
        // A later begin (a legacy pointer) keeps the kept transcript.
        try await store.begin(recording: "rec_1.caf", eventID: "evt", title: "Standup", at: at)
        let row = try XCTUnwrap(try store.transcript(recording: "rec_1.caf"))
        XCTAssertEqual(row.title, "Standup")
        XCTAssertEqual(row.transcript, "hello")
        XCTAssertEqual(row.startedAt, at)
        XCTAssertFalse(row.dismissed)

        try await store.clearTranscript(recording: "rec_1.caf")
        XCTAssertNil(try store.transcript(recording: "rec_1.caf")?.transcript)
        try await store.remove(recording: "rec_1.caf")
        XCTAssertEqual(try store.pending(), [])
    }

    func testReserveIsExclusive() async throws {
        let store = try store()
        let first = try await store.reserve(recording: "rec_2.m4a", eventID: nil, title: "A", at: Date())
        let second = try await store.reserve(recording: "rec_2.m4a", eventID: nil, title: "B", at: Date())
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(try store.transcript(recording: "rec_2.m4a")?.title, "A", "the first reservation stands")
    }

    func testDismissWritesATombstoneEvenWithoutARow() async throws {
        let store = try store()
        try await store.dismiss(recording: "rec_3.caf", at: Date())
        XCTAssertEqual(try store.transcript(recording: "rec_3.caf")?.dismissed, true)
    }

    func testSavedAudioPaths() throws {
        let db = try TestDatabase.create()
        try db.write { try TestDatabase.insertMeetingTranscript($0, audioPath: "/r/rec_4.caf") }
        XCTAssertEqual(try DatabasePendingTranscriptStore(writer: db).savedAudioPaths(), ["/r/rec_4.caf"])
    }
}

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
        try await store.begin(recording: "rec_1.caf", eventID: "evt", title: "Standup", isPrivate: false, at: at)
        try await store.saveTranscript(recording: "rec_1.caf", text: "hello", metaJSON: #"{"durationSec":5,"langStats":{}}"#,
                                       isPrivate: false, at: at.addingTimeInterval(60))
        // A later begin (a legacy pointer) keeps the kept transcript.
        try await store.begin(recording: "rec_1.caf", eventID: "evt", title: "Standup", isPrivate: false, at: at)
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
        let first = try await store.reserve(recording: "rec_2.m4a", eventID: nil, title: "A", isPrivate: false, at: Date())
        let second = try await store.reserve(recording: "rec_2.m4a", eventID: nil, title: "B", isPrivate: false, at: Date())
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(try store.transcript(recording: "rec_2.m4a")?.title, "A", "the first reservation stands")
    }

    func testPrivateFlagRoundTrips() async throws {
        let store = try store()
        try await store.begin(recording: "rec_5.caf", eventID: nil, title: "Locked", isPrivate: true, at: Date())
        XCTAssertEqual(try store.transcript(recording: "rec_5.caf")?.isPrivate, true)

        try await store.setPrivate(recording: "rec_5.caf", false)
        XCTAssertEqual(try store.transcript(recording: "rec_5.caf")?.isPrivate, false)
        try await store.saveTranscript(recording: "rec_5.caf", text: "t", metaJSON: "{}", isPrivate: false, at: Date())
        try await store.setPrivate(recording: "rec_5.caf", true)
        let row = try XCTUnwrap(try store.transcript(recording: "rec_5.caf"))
        XCTAssertTrue(row.isPrivate, "a kept transcript keeps the flag")
        XCTAssertEqual(row.transcript, "t")

        let reserved = try await store.reserve(recording: "rec_6.m4a", eventID: nil, title: nil, isPrivate: true, at: Date())
        XCTAssertTrue(reserved)
        XCTAssertEqual(try store.transcript(recording: "rec_6.m4a")?.isPrivate, true)
    }

    func testRowsWithoutAChoiceAreNotPrivate() async throws {
        let store = try store()
        try await store.begin(recording: "rec_7.caf", eventID: nil, title: nil, isPrivate: false, at: Date())
        try await store.dismiss(recording: "rec_8.caf", at: Date())
        XCTAssertEqual(try store.pending().map(\.isPrivate), [false, false])
        // A row that is gone stays gone: setPrivate writes nothing, and says so.
        let wrote = try await store.setPrivate(recording: "rec_9.caf", true)
        XCTAssertFalse(wrote)
        XCTAssertNil(try store.transcript(recording: "rec_9.caf"))
    }

    /// MEETPRIV-01: the kept transcript carries the job's flag, on insert (a
    /// recording whose `begin` never landed) and on conflict (a row whose
    /// lock flip never landed).
    func testSaveTranscriptWritesTheJobsPrivateFlag() async throws {
        let store = try store()
        try await store.saveTranscript(recording: "rec_10.caf", text: "t", metaJSON: "{}", isPrivate: true, at: Date())
        XCTAssertEqual(try store.transcript(recording: "rec_10.caf")?.isPrivate, true)

        try await store.begin(recording: "rec_11.caf", eventID: nil, title: nil, isPrivate: false, at: Date())
        try await store.saveTranscript(recording: "rec_11.caf", text: "t", metaJSON: "{}", isPrivate: true, at: Date())
        XCTAssertEqual(try store.transcript(recording: "rec_11.caf")?.isPrivate, true)
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

import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Older versions' `rec_*.meta`/`.txt`/`.json` sidecars become one
/// `pending_transcripts` row each and are deleted (#604 S3/S4, Review Focus 4).
final class LegacyRecordingSidecarImportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    func testMetaTxtAndJSONBecomeOneRowAndAreDeleted() async throws {
        let store = DatabasePendingTranscriptStore(writer: try TestDatabase.create())
        try write("rec_20260801_090000.caf", "audio")
        try write("rec_20260801_090000.meta", #"{"eventID":"evt-1","title":"Standup"}"#)
        try write("rec_20260801_090000.txt", "[Я] привет")
        try write("rec_20260801_090000.json", #"{"durationSec":42,"langStats":{"ru":42}}"#)

        let imported = await LegacyRecordingSidecarImport.importAll(in: dir, into: store)
        XCTAssertEqual(imported, 1)

        let row = try XCTUnwrap(try store.transcript(recording: "rec_20260801_090000.caf"))
        XCTAssertEqual(row.eventID, "evt-1")
        XCTAssertEqual(row.title, "Standup")
        XCTAssertFalse(row.isPrivate, "a legacy sidecar has no private flag: the recording is not private")
        XCTAssertEqual(row.transcript, "[Я] привет")
        XCTAssertEqual(row.metaJSON, #"{"durationSec":42,"langStats":{"ru":42}}"#)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, ["rec_20260801_090000.caf"], "the sidecars are gone, the audio stays")
    }

    func testACorruptJSONKeepsItsFiles() async throws {
        let store = DatabasePendingTranscriptStore(writer: try TestDatabase.create())
        try write("rec_20260801_100000.m4a", "audio")
        try write("rec_20260801_100000.meta", #"{"title":"Phone"}"#)
        try write("rec_20260801_100000.txt", "text")
        try write("rec_20260801_100000.json", "not json{")

        let imported = await LegacyRecordingSidecarImport.importAll(in: dir, into: store)
        XCTAssertEqual(imported, 0)

        XCTAssertEqual(try store.pending(), [])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, ["rec_20260801_100000.m4a", "rec_20260801_100000.meta",
                              "rec_20260801_100000.txt", "rec_20260801_100000.json"])
    }

    private func files() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    /// Without a `.meta` the old build no longer held the recording pending
    /// (dismissed or saved): a tombstone, and the kept text is not imported.
    func testTxtAndJSONWithoutMetaBecomeATombstone() async throws {
        let store = DatabasePendingTranscriptStore(writer: try TestDatabase.create())
        try write("rec_20260801_110000.caf", "audio")
        try write("rec_20260801_110000.txt", "kept text")
        try write("rec_20260801_110000.json", #"{"durationSec":1,"langStats":{}}"#)

        let imported = await LegacyRecordingSidecarImport.importAll(in: dir, into: store)
        XCTAssertEqual(imported, 1)
        let row = try XCTUnwrap(try store.transcript(recording: "rec_20260801_110000.caf"))
        XCTAssertTrue(row.dismissed)
        XCTAssertNil(row.transcript, "the lone sidecars' text is not imported")
        XCTAssertEqual(try files(), ["rec_20260801_110000.caf"])
    }

    func testALoneTxtOrJSONBecomesATombstone() async throws {
        let store = DatabasePendingTranscriptStore(writer: try TestDatabase.create())
        try write("rec_20260801_120000.caf", "audio")
        try write("rec_20260801_120000.txt", "text")
        try write("rec_20260801_130000.m4a", "audio")
        try write("rec_20260801_130000.json", #"{"durationSec":1}"#)

        let imported = await LegacyRecordingSidecarImport.importAll(in: dir, into: store)
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(try store.transcript(recording: "rec_20260801_120000.caf")?.dismissed, true)
        XCTAssertEqual(try store.transcript(recording: "rec_20260801_130000.m4a")?.dismissed, true)
        XCTAssertEqual(try files(), ["rec_20260801_120000.caf", "rec_20260801_130000.m4a"])
    }

    /// A launch that wrote the row but lost its deletes after the `.txt`
    /// (the `.meta` still there) imports again: same row, kept transcript.
    func testAReRunAfterAPartialDeleteKeepsTheRow() async throws {
        let store = DatabasePendingTranscriptStore(writer: try TestDatabase.create())
        try write("rec_20260801_140000.caf", "audio")
        try write("rec_20260801_140000.meta", #"{"eventID":"evt-2","title":"Retro"}"#)
        try write("rec_20260801_140000.txt", "kept")
        try write("rec_20260801_140000.json", #"{"durationSec":3,"langStats":{}}"#)
        _ = await LegacyRecordingSidecarImport.importAll(in: dir, into: store)
        // As if the first run had stopped after deleting the .txt and .json.
        try write("rec_20260801_140000.meta", #"{"eventID":"evt-2","title":"Retro"}"#)

        let imported = await LegacyRecordingSidecarImport.importAll(in: dir, into: store)
        XCTAssertEqual(imported, 1)
        let row = try XCTUnwrap(try store.transcript(recording: "rec_20260801_140000.caf"))
        XCTAssertEqual(row.title, "Retro")
        XCTAssertEqual(row.transcript, "kept", "begin keeps the transcript the first run wrote")
        XCTAssertFalse(row.dismissed)
        XCTAssertEqual(try files(), ["rec_20260801_140000.caf"])
    }
}

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
}

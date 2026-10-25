import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// The staged slice assets keep their descriptors (with `K_asset`) in
/// `hubstate.db`'s `slice_assets`, never in a `.desc` file (#604 S12).
final class SliceAssetStoreTests: XCTestCase {
    private var dir: URL!
    private var sidecar: HubSyncState!
    private let record = "meeting_transcript-7"
    private let key = "meeting_transcript-7/segments.json"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slice-assets-\(UUID().uuidString)")
        sidecar = try HubSyncState.inMemory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> SliceAssetStore {
        SliceAssetStore(directory: dir, descriptors: sidecar)
    }

    private func files(of record: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(record).path).sorted()
    }

    func testStageWritesNoDescFile() throws {
        let store = store()
        let staged = try store.stage(Data("[1]".utf8), fileName: "segments.json", recordName: record)
        XCTAssertEqual(try files(of: record), ["segments.json"])
        XCTAssertEqual(try sidecar.descriptor(forFile: key), try staged.descriptor.encoded())
        XCTAssertEqual(store.stagedDescriptor(recordName: record, fileName: "segments.json"), staged.descriptor)
    }

    func testDescriptorSurvivesRestartFromRow() throws {
        let staged = try store().stage(Data("[1]".utf8), fileName: "segments.json", recordName: record)
        let relaunched = store()
        XCTAssertEqual(relaunched.stagedDescriptor(recordName: record, fileName: "segments.json"), staged.descriptor)
        XCTAssertEqual(relaunched.stagedDigest(recordName: record, fileName: "segments.json"),
                       SliceAsset.digest(of: Data("[1]".utf8)))
    }

    func testLegacyDescImportedAndDeleted() throws {
        let staged = try store().stage(Data("[1]".utf8), fileName: "segments.json", recordName: record)
        // What an earlier build left: the descriptor in a file beside the sealed one, no row.
        let file = dir.appendingPathComponent(record).appendingPathComponent("segments.json")
        try staged.descriptor.encoded().write(to: file.appendingPathExtension("desc"))
        try sidecar.removeDescriptor(forFile: key)

        let relaunched = store()
        XCTAssertEqual(try files(of: record), ["segments.json"], "the .desc is gone")
        XCTAssertEqual(try sidecar.descriptor(forFile: key), try staged.descriptor.encoded())
        XCTAssertEqual(relaunched.stagedDescriptor(recordName: record, fileName: "segments.json"), staged.descriptor)
    }

    /// A crash after the sealed file was written but before its row: the
    /// file reads as not staged, so it is staged again.
    func testCrashBetweenFileAndRowReadsNotStaged() throws {
        let store = store()
        _ = try store.stage(Data("[1]".utf8), fileName: "segments.json", recordName: record)
        try sidecar.removeDescriptor(forFile: key)
        XCTAssertNil(store.stagedDescriptor(recordName: record, fileName: "segments.json"))
        XCTAssertFalse(store.isStaged(recordName: record, fileName: "segments.json"))
    }

    func testCloseRemovesRows() throws {
        let store = store()
        _ = try store.stage(Data("[1]".utf8), fileName: "segments.json", recordName: record)
        _ = try store.stage(Data("[2]".utf8), fileName: "segments.json", recordName: "meeting_transcript-8")
        store.sweep(kind: .meetingTranscript, keeping: [record])
        XCTAssertNil(try sidecar.descriptor(forFile: "meeting_transcript-8/segments.json"), "a swept record's row goes")
        XCTAssertNotNil(try sidecar.descriptor(forFile: key), "a kept one stays")
        store.close()
        XCTAssertNil(try sidecar.descriptor(forFile: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// Record names hold `_`, a LIKE wildcard: removing one record's rows
    /// leaves a lookalike's.
    func testRemovingOneRecordLeavesALookalike() throws {
        try sidecar.setDescriptor(Data([1]), forFile: "meeting_transcript-1/segments.json")
        try sidecar.setDescriptor(Data([2]), forFile: "meetingXtranscript-1/segments.json")
        try sidecar.removeDescriptors(under: "meeting_transcript-1")
        XCTAssertNil(try sidecar.descriptor(forFile: "meeting_transcript-1/segments.json"))
        XCTAssertEqual(try sidecar.descriptor(forFile: "meetingXtranscript-1/segments.json"), Data([2]))
    }
}

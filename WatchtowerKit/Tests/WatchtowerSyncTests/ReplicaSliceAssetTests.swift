import Foundation
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// A data-zone record's CKAsset (the `meeting_transcript` `segments.json`,
/// spec §4.11) is copied into the replica on apply, so the phone reads it
/// after the transport's stash is gone. A file that cannot be read is kept
/// as a visible failure, never as a missing body.
final class ReplicaSliceAssetTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slice-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("segments.json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// The asset as the hub sends it: the sealed file, its descriptor riding in the record's frame.
    private func sealedFile(_ contents: String) throws -> (url: URL, descriptor: AssetDescriptor) {
        let (sealed, descriptor) = try ChunkedAssetCipher.encrypt(Data(contents.utf8))
        let url = try tempFile("")
        try sealed.write(to: url)
        return (url, descriptor)
    }

    /// Seqs of the records this test seals, in creation order: a rewrite is a newer version.
    private var nextSeq: UInt64 = 1

    /// A `meeting_transcript` record sealed by the test hub. `asset` is the file the record carries (sealed, or a
    /// path the test made unreadable); `descriptor` defaults to one of an unrelated asset.
    private func record(id: String, asset: URL?, descriptor: AssetDescriptor? = nil) throws -> CloudRecord {
        defer { nextSeq += 1 }
        let fallback = try asset.map { _ in try ChunkedAssetCipher.encrypt(Data()).descriptor }
        return try TestE2E.sealedDataRecord(
            CloudRecord(
                recordName: name(id),
                zone: .data,
                kind: SliceKind.meetingTranscript.rawValue,
                modifiedAt: Date(),
                payload: Data("{}".utf8),
                assetFileURL: asset,
                asset: descriptor ?? fallback
            ),
            seq: nextSeq
        )
    }

    private func name(_ id: String) -> String { SliceKind.meetingTranscript.recordName(id: id) }

    private func wireName(_ id: String) throws -> String {
        try TestE2E.hubTransport().wireName(plain: name(id), zone: .data)
    }

    private func apply(_ store: ReplicaStore, _ records: [CloudRecord], deleted: [String] = [], token: Int) throws {
        try store.apply(CloudChangeBatch(changed: records, deletedRecordNames: deleted, newToken: CloudChangeToken(value: token)))
        try store.indexPending()
    }

    func testAnAppliedAssetIsCopiedIntoTheReplica() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let file = try sealedFile("[1]")
        try apply(store, [record(id: "1", asset: file.url, descriptor: file.descriptor)], token: 1)
        // The transport's stash may be purged after apply.
        try FileManager.default.removeItem(at: file.url)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        XCTAssertEqual(asset, .data(Data("[1]".utf8)))
    }

    func testARewriteWithoutAnAssetDropsTheStoredOne() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let file = try sealedFile("[1]")
        try apply(store, [record(id: "1", asset: file.url, descriptor: file.descriptor)], token: 1)
        try apply(store, [record(id: "1", asset: nil)], token: 2)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        XCTAssertNil(try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) })
    }

    func testADeletedRecordTakesItsAssetWithIt() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let file = try sealedFile("[1]")
        try apply(store, [record(id: "1", asset: file.url, descriptor: file.descriptor)], token: 1)
        let name = SliceKind.meetingTranscript.recordName(id: "1")
        try apply(store, [], deleted: [wireName("1")], token: 2)

        XCTAssertNil(try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) })
        let rows = try store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_assets") }
        XCTAssertEqual(rows, 0)
    }

    func testAnUnreadableAssetIsKeptAsAFailureNotAsNoAsset() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        try apply(store, [record(id: "1", asset: gone)], token: 1)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        guard case let .unreadable(reason) = asset else {
            return XCTFail("expected an unreadable asset, got \(String(describing: asset))")
        }
        XCTAssertFalse(reason.isEmpty)
        // The record itself still lands.
        XCTAssertNotNil(try store.reader.read { db in try store.payload(forRecordName: name, from: db) })
    }

    func testAStaleBatchDoesNotTouchTheStoredAsset() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let file = try sealedFile("[2]")
        try apply(store, [record(id: "1", asset: file.url, descriptor: file.descriptor)], token: 5)
        try apply(store, [record(id: "1", asset: nil)], token: 3)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        XCTAssertEqual(asset, .data(Data("[2]".utf8)))
    }

    // MARK: - Size guard

    func testAnAssetOverTheCapIsUnreadableWithoutLoadingIt() throws {
        let file = try tempFile("")
        // A sparse file: the size is what counts, nothing is written.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ReplicaStore.maxAssetBytes + 1))
        try handle.close()
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        try apply(store, [record(id: "1", asset: file)], token: 1)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        XCTAssertEqual(asset, .unreadable("too large"))
    }
}

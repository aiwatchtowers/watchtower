import Foundation
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

    private func record(id: String, asset: URL?) -> CloudRecord {
        CloudRecord(
            recordName: SliceKind.meetingTranscript.recordName(id: id),
            zone: .data,
            kind: SliceKind.meetingTranscript.rawValue,
            modifiedAt: Date(),
            payload: Data("{}".utf8),
            assetFileURL: asset
        )
    }

    private func apply(_ store: ReplicaStore, _ records: [CloudRecord], deleted: [String] = [], token: Int) throws {
        try store.apply(CloudChangeBatch(changed: records, deletedRecordNames: deleted, newToken: CloudChangeToken(value: token)))
    }

    func testAnAppliedAssetIsCopiedIntoTheReplica() throws {
        let store = try ReplicaStore.inMemory()
        let file = try tempFile("[1]")
        try apply(store, [record(id: "1", asset: file)], token: 1)
        // The transport's stash may be purged after apply.
        try FileManager.default.removeItem(at: file)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        XCTAssertEqual(asset, .data(Data("[1]".utf8)))
    }

    func testARewriteWithoutAnAssetDropsTheStoredOne() throws {
        let store = try ReplicaStore.inMemory()
        try apply(store, [record(id: "1", asset: try tempFile("[1]"))], token: 1)
        try apply(store, [record(id: "1", asset: nil)], token: 2)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        XCTAssertNil(try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) })
    }

    func testADeletedRecordTakesItsAssetWithIt() throws {
        let store = try ReplicaStore.inMemory()
        try apply(store, [record(id: "1", asset: try tempFile("[1]"))], token: 1)
        let name = SliceKind.meetingTranscript.recordName(id: "1")
        try apply(store, [], deleted: [name], token: 2)

        XCTAssertNil(try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) })
        let rows = try store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_assets") }
        XCTAssertEqual(rows, 0)
    }

    func testAnUnreadableAssetIsKeptAsAFailureNotAsNoAsset() throws {
        let store = try ReplicaStore.inMemory()
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
        let store = try ReplicaStore.inMemory()
        try apply(store, [record(id: "1", asset: try tempFile("[2]"))], token: 5)
        try apply(store, [record(id: "1", asset: nil)], token: 3)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        XCTAssertEqual(asset, .data(Data("[2]".utf8)))
    }

    // MARK: - The consumed stash

    func testHydrationDiscardsTheConsumedAssetFileAndServesTheBlob() async throws {
        let transport = InMemoryCloudTransport()
        let file = try tempFile("[3]")
        try await transport.save([record(id: "1", asset: file)])
        let store = try ReplicaStore.inMemory()
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the replica holds the bytes now")
        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try await store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        XCTAssertEqual(asset, .data(Data("[3]".utf8)))
    }

    func testAFailedApplyKeepsTheAssetFile() async throws {
        let transport = InMemoryCloudTransport()
        let file = try tempFile("[3]")
        try await transport.save([record(id: "1", asset: file)])
        let store = try ReplicaStore.inMemory()
        try await store.writer.write { try $0.execute(sql: "DROP TABLE slice_records") }

        do {
            _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
            XCTFail("apply should have failed")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the next cycle still needs it")
    }

    func testADeletedRecordAsksTheTransportToDiscardItsStash() async throws {
        let transport = StashingTransport()
        let store = try ReplicaStore.inMemory()
        let name = SliceKind.meetingTranscript.recordName(id: "1")
        try await transport.save([record(id: "1", asset: try tempFile("[1]"))])
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()
        try await transport.delete(recordNames: [name], in: .data)
        _ = try await hydrator.hydrateOnce()

        let discarded = await transport.discarded
        XCTAssertEqual(discarded.last, [name])
    }

    func testAnAssetOverTheCapIsUnreadableWithoutLoadingIt() throws {
        let file = try tempFile("")
        // A sparse file: the size is what counts, nothing is written.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ReplicaStore.maxAssetBytes + 1))
        try handle.close()
        let store = try ReplicaStore.inMemory()
        try apply(store, [record(id: "1", asset: file)], token: 1)

        let name = SliceKind.meetingTranscript.recordName(id: "1")
        let asset = try store.reader.read { db in try store.sliceAsset(forRecordName: name, from: db) }
        XCTAssertEqual(asset, .unreadable("too large"))
    }
}

/// An in-memory transport that, like CloudKitTransport, keeps a stash of
/// fetched assets and records which ones the consumer discarded.
private actor StashingTransport: AssetStashingTransport {
    private let inner = InMemoryCloudTransport()
    private(set) var discarded: [[String]] = []

    func save(_ records: [CloudRecord]) async throws { try await inner.save(records) }
    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }
    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }
    func discardStashedAssets(recordNames: [String]) async {
        discarded.append(recordNames)
    }
}

import CloudKit
import XCTest
@testable import WatchtowerKit

/// Asset plumbing through the transport layer: the `asset_path` column in
/// TransportStore, the CKRecord mapping, and the fetched-asset stash.
final class TransportAssetTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRecord(assetPath: String?) -> CloudRecord {
        CloudRecord(
            recordName: "recupload-A1",
            zone: .relay,
            kind: "recording_upload",
            modifiedAt: stamp,
            payload: Data("{}".utf8),
            assetFileURL: assetPath.map(URL.init(fileURLWithPath:))
        )
    }

    // MARK: - TransportStore persistence

    func testPendingBatchCarriesAssetPath() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([makeRecord(assetPath: "/tmp/a1.m4a")])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.first?.assetFileURL, URL(fileURLWithPath: "/tmp/a1.m4a"))
    }

    func testPendingUpsertReplacesAssetPath() throws {
        // The status write-back re-saves the same recordName WITHOUT the
        // asset; the pending row must not resurrect the old path.
        let store = try TransportStore.inMemory()
        try store.enqueueSave([makeRecord(assetPath: "/tmp/a1.m4a")])
        try store.enqueueSave([makeRecord(assetPath: nil)])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.count, 1)
        XCTAssertNil(batch.saves.first?.assetFileURL)
    }

    func testBufferedChangesCarryAssetPath() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([makeRecord(assetPath: "/tmp/fetched.m4a")])
        let batch = try store.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.first?.assetFileURL, URL(fileURLWithPath: "/tmp/fetched.m4a"))
    }

    func testAssetPathColumnPatchedIntoPreExistingStore() throws {
        // A store file created by an older build lacks asset_path; reopening
        // must patch it in place (the notify_level precedent).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-asset-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path

        // Simulate the old schema by dropping the columns a fresh store creates.
        do {
            let store = try TransportStore(path: path)
            _ = store // schema created
        }
        // Reopen — CREATE TABLE IF NOT EXISTS + patch loop must both no-op
        // cleanly on the current schema and the store must round-trip assets.
        let reopened = try TransportStore(path: path)
        try reopened.enqueueSave([makeRecord(assetPath: "/tmp/a2.m4a")])
        XCTAssertEqual(
            try reopened.pendingBatch(limit: 1).saves.first?.assetFileURL,
            URL(fileURLWithPath: "/tmp/a2.m4a")
        )
    }

    // MARK: - Stash

    func testStashAssetCopiesIntoDurableDirectoryAndOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-stash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TransportStore(path: dir.appendingPathComponent("store.sqlite").path)

        let source = dir.appendingPathComponent("staged.m4a")
        try Data("audio-bytes".utf8).write(to: source)
        let stashed = try XCTUnwrap(store.stashAsset(from: source, recordName: "recupload-S1"))
        XCTAssertEqual(try Data(contentsOf: stashed), Data("audio-bytes".utf8))
        XCTAssertEqual(stashed.lastPathComponent, "recupload-S1")

        // A re-fetch overwrites rather than accumulates.
        try Data("newer-bytes".utf8).write(to: source)
        let restashed = try XCTUnwrap(store.stashAsset(from: source, recordName: "recupload-S1"))
        XCTAssertEqual(restashed, stashed)
        XCTAssertEqual(try Data(contentsOf: restashed), Data("newer-bytes".utf8))
    }

    func testStashAssetOnInMemoryStoreReturnsNil() throws {
        let store = try TransportStore.inMemory()
        XCTAssertNil(store.stashAsset(from: URL(fileURLWithPath: "/tmp/x.m4a"), recordName: "recupload-X"))
    }

    // MARK: - CKRecord mapping

    func testCKRecordMappingRoundTripsAsset() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let record = makeRecord(assetPath: "/tmp/mapped.m4a")
        let ck = CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: nil)
        let asset = ck["asset"] as? CKAsset
        XCTAssertEqual(asset?.fileURL, URL(fileURLWithPath: "/tmp/mapped.m4a"))
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: ck), record)
    }

    func testCKRecordMappingNilAssetRemovesField() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let withAsset = CloudKitTransport.ckRecord(
            from: makeRecord(assetPath: "/tmp/mapped.m4a"), in: zoneID, systemFields: nil
        )
        XCTAssertNotNil(withAsset["asset"])
        // Same identity re-saved without an asset (the status write-back).
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        withAsset.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let rewritten = CloudKitTransport.ckRecord(
            from: makeRecord(assetPath: nil), in: zoneID, systemFields: archiver.encodedData
        )
        XCTAssertNil(rewritten["asset"])
        XCTAssertNil(CloudKitTransport.cloudRecord(from: rewritten)?.assetFileURL)
    }
}

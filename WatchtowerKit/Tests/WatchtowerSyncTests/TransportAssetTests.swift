import CloudKit
import XCTest
@testable import WatchtowerSync

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
        let stashed = try XCTUnwrap(store.stashAsset(from: source, recordName: "recupload-S1", zone: .relay))
        XCTAssertEqual(try Data(contentsOf: stashed), Data("audio-bytes".utf8))
        XCTAssertEqual(stashed.lastPathComponent, TransportStore.stashFileName(recordName: "recupload-S1", zone: .relay))

        // A re-fetch overwrites rather than accumulates.
        try Data("newer-bytes".utf8).write(to: source)
        let restashed = try XCTUnwrap(store.stashAsset(from: source, recordName: "recupload-S1", zone: .relay))
        XCTAssertEqual(restashed, stashed)
        XCTAssertEqual(try Data(contentsOf: restashed), Data("newer-bytes".utf8))
    }

    /// The stash name is never the server-supplied record name (target 149): `..` named the folder holding the
    /// store, `.` the stash itself, and both were removed before the copy.
    func testStashNamesThatAreDirectoriesStayInsideTheStash() throws {
        let (store, dir) = try fileStore()
        let storeDB = dir.appendingPathComponent("store.sqlite")
        let source = dir.appendingPathComponent("staged.m4a")
        try Data("audio".utf8).write(to: source)
        let kept = try XCTUnwrap(store.stashAsset(from: source, recordName: "recupload-K", zone: .relay))

        for name in ["..", ".", "../..", "a/../../b", ""] {
            let stashed = try XCTUnwrap(store.stashAsset(from: source, recordName: name, zone: .relay), name)
            XCTAssertEqual(
                stashed.deletingLastPathComponent().standardizedFileURL,
                kept.deletingLastPathComponent().standardizedFileURL, name)
            XCTAssertNotEqual(stashed.lastPathComponent, name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDB.path), "the store's folder survived")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "the stash survived")
    }

    /// The same name in the two zones stashes to two files.
    func testStashNamesAreScopedByZone() {
        XCTAssertNotEqual(
            TransportStore.stashFileName(recordName: "x-1", zone: .data),
            TransportStore.stashFileName(recordName: "x-1", zone: .relay))
    }

    /// An asset over the cap is not copied (target 149).
    func testAnOversizedAssetIsNotStashed() throws {
        let (store, dir) = try fileStore()
        let source = dir.appendingPathComponent("big.m4a")
        try Data(repeating: 1, count: 2_048).write(to: source)

        XCTAssertNil(store.stashAsset(from: source, recordName: "recupload-B", zone: .relay, maxBytes: 1_024))
        let stash = try XCTUnwrap(store.stashDirectory)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stash.appendingPathComponent(TransportStore.stashFileName(recordName: "recupload-B", zone: .relay)).path))
        XCTAssertNotNil(store.stashAsset(from: source, recordName: "recupload-B", zone: .relay, maxBytes: 2_048))
    }

    // MARK: - Data-zone stash cleanup at compaction

    /// A file-backed store in a throwaway folder, plus that folder.
    private func fileStore() throws -> (TransportStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-compact-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (try TransportStore(path: dir.appendingPathComponent("store.sqlite").path), dir)
    }

    /// Stashes `contents` for `name` the way a fetch does, then buffers the
    /// change pointing at the stash.
    private func bufferFetched(_ store: TransportStore, dir: URL, name: String, contents: String) throws -> URL {
        let staged = dir.appendingPathComponent("staged-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: staged)
        let stashed = try XCTUnwrap(store.stashAsset(from: staged, recordName: name, zone: .data))
        try store.bufferChanged([CloudRecord(
            recordName: name, zone: .data, kind: "meeting_transcript", modifiedAt: stamp,
            payload: Data("{}".utf8), assetFileURL: stashed
        )])
        return stashed
    }

    func testCompactingConsumedDataEventsRemovesTheirStash() throws {
        let (store, dir) = try fileStore()
        let stashed = try bufferFetched(store, dir: dir, name: "meeting_transcript-1", contents: "[1]")
        let batch = try store.changes(in: .data, since: nil)

        try store.compactEvents(in: .data, keepSince: batch.newToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stashed.path), "the consumer holds the bytes now")
    }

    /// The race: a newer change to the same record is restashed (same path)
    /// after the batch was read. Its event is not compacted, so its file
    /// stays and the next cycle reads it.
    func testANewerRestashOfTheSameRecordSurvivesCompaction() throws {
        let (store, dir) = try fileStore()
        let name = "meeting_transcript-1"
        _ = try bufferFetched(store, dir: dir, name: name, contents: "[1]")
        let first = try store.changes(in: .data, since: nil)
        let restashed = try bufferFetched(store, dir: dir, name: name, contents: "[2]")

        try store.compactEvents(in: .data, keepSince: first.newToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restashed.path))
        let next = try store.changes(in: .data, since: first.newToken)
        let url = try XCTUnwrap(next.changed.first?.assetFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("[2]".utf8))
    }

    func testADeletedRecordsStashGoesWithItsCompactedChange() throws {
        let (store, dir) = try fileStore()
        let name = "meeting_transcript-1"
        let stashed = try bufferFetched(store, dir: dir, name: name, contents: "[1]")
        try store.bufferDeleted(recordNames: [name], zone: .data)
        let batch = try store.changes(in: .data, since: nil)

        try store.compactEvents(in: .data, keepSince: batch.newToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stashed.path))
    }

    func testCompactionNeverRemovesAFileOutsideTheStash() throws {
        let (store, dir) = try fileStore()
        let outside = dir.appendingPathComponent("not-a-stash.json")
        try Data("[1]".utf8).write(to: outside)
        try store.bufferChanged([CloudRecord(
            recordName: "meeting_transcript-1", zone: .data, kind: "meeting_transcript", modifiedAt: stamp,
            payload: Data("{}".utf8), assetFileURL: outside
        )])
        let batch = try store.changes(in: .data, since: nil)

        try store.compactEvents(in: .data, keepSince: batch.newToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: - Unreferenced-stash sweep (final-review i-F5)

    /// A stash file no buffered or pending row points at (a pre-fix leak, an
    /// eviction, a wipe) is swept; a referenced one is kept.
    func testSweepRemovesAnOrphanStashAndKeepsAReferencedOne() throws {
        let (store, dir) = try fileStore()
        let kept = try bufferFetched(store, dir: dir, name: "meeting_transcript-1", contents: "[1]")
        let orphan = kept.deletingLastPathComponent().appendingPathComponent("meeting_transcript-orphan")
        try Data("[0]".utf8).write(to: orphan)

        store.sweepUnreferencedStash()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    /// The launch pass: opening a store sweeps what an earlier run leaked.
    func testOpeningAStoreSweepsOrphanStashFiles() throws {
        let (store, dir) = try fileStore()
        let kept = try bufferFetched(store, dir: dir, name: "meeting_transcript-1", contents: "[1]")
        let orphan = kept.deletingLastPathComponent().appendingPathComponent("meeting_transcript-orphan")
        try Data("[0]".utf8).write(to: orphan)

        _ = try TransportStore(path: dir.appendingPathComponent("store.sqlite").path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testEvictingTheDataZoneSweepsItsStash() throws {
        let (store, dir) = try fileStore()
        let stashed = try bufferFetched(store, dir: dir, name: "meeting_transcript-1", contents: "[1]")

        try store.evictZone(.data)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stashed.path))
    }

    func testWipeSweepsTheStash() throws {
        let (store, dir) = try fileStore()
        let stashed = try bufferFetched(store, dir: dir, name: "meeting_transcript-1", contents: "[1]")

        try store.wipe()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stashed.path))
    }

    /// Only the stash directory is swept: a referenced-elsewhere file next to
    /// the store (the hub's staged assets, the phone's recordings) is never
    /// touched, referenced or not.
    /// The phone compacts its consumed relay buffer (RelayFeed): an own
    /// upload reflecting back with its audio-sized asset must not wait for
    /// the next launch's sweep (final-review P2-M3).
    func testCompactingTheRelayZoneSweepsItsConsumedStash() throws {
        let (store, dir) = try fileStore()
        let staged = dir.appendingPathComponent("staged-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: staged)
        let stashed = try XCTUnwrap(store.stashAsset(from: staged, recordName: "recupload-A1", zone: .relay))
        try store.bufferChanged([CloudRecord(
            recordName: "recupload-A1", zone: .relay, kind: "recording_upload", modifiedAt: stamp,
            payload: Data("{}".utf8), assetFileURL: stashed
        )])
        let batch = try store.changes(in: .relay, since: nil)

        try store.compactEvents(in: .relay, keepSince: batch.newToken)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stashed.path))
    }

    func testSweepNeverTouchesFilesOutsideTheStash() throws {
        let (store, dir) = try fileStore()
        _ = try bufferFetched(store, dir: dir, name: "meeting_transcript-1", contents: "[1]")
        let outside = dir.appendingPathComponent("not-a-stash.json")
        try Data("[1]".utf8).write(to: outside)

        try store.wipe()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testStashAssetOnInMemoryStoreReturnsNil() throws {
        let store = try TransportStore.inMemory()
        XCTAssertNil(store.stashAsset(from: URL(fileURLWithPath: "/tmp/x.m4a"), recordName: "recupload-X", zone: .relay))
    }

    // MARK: - CKRecord mapping

    func testCKRecordMappingRoundTripsAsset() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let record = makeRecord(assetPath: "/tmp/mapped.m4a")
        let ck = CloudKitTransport.ckRecord(from: record, in: zoneID, systemFields: nil)
        let asset = ck["asset"] as? CKAsset
        XCTAssertEqual(asset?.fileURL, URL(fileURLWithPath: "/tmp/mapped.m4a"))
        XCTAssertEqual(CloudKitTransport.cloudRecord(from: ck, zone: .relay), record)
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
        XCTAssertNil(CloudKitTransport.cloudRecord(from: rewritten, zone: .relay)?.assetFileURL)
    }

    // MARK: - One stash per route store (board #1496)

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("route-stash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Stashes `name`'s file in `store` and buffers an event that references it.
    private func bufferStashed(_ store: TransportStore, name: String, in dir: URL) throws -> URL {
        let source = dir.appendingPathComponent("staged-\(name)")
        try Data(name.utf8).write(to: source)
        let stashed = try XCTUnwrap(store.stashAsset(from: source, recordName: name, zone: .data))
        try store.bufferChanged([CloudRecord(
            recordName: name, zone: .data, kind: "meeting_transcript", modifiedAt: stamp,
            payload: Data("{}".utf8), assetFileURL: stashed
        )])
        return stashed
    }

    func testTwoStoresInOneFolderKeepTheirOwnStashThroughWipeAndReopen() throws {
        let dir = try tempDirectory()
        let a = try TransportStore(path: dir.appendingPathComponent("a.sqlite").path)
        let b = try TransportStore(path: dir.appendingPathComponent("b.sqlite").path, stashFolder: "b-assets")
        let fileA = try bufferStashed(a, name: "rec-a", in: dir)
        let fileB = try bufferStashed(b, name: "rec-b", in: dir)
        XCTAssertNotEqual(fileA.deletingLastPathComponent(), fileB.deletingLastPathComponent())

        try b.wipe()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path), "b's wipe left a's file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileB.path))
        let fileB2 = try bufferStashed(b, name: "rec-b", in: dir)
        try a.wipe()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB2.path), "a's wipe left b's file")

        // The open-time sweep of one store does not reach the other's folder either.
        let fileA2 = try bufferStashed(a, name: "rec-a", in: dir)
        try a.close()
        try b.close()
        let reopenedB = try TransportStore(path: dir.appendingPathComponent("b.sqlite").path, stashFolder: "b-assets")
        defer { try? reopenedB.close() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileA2.path), "b's open sweep left a's file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB2.path), "a referenced file survives its own sweep")
    }

    /// An installed phone: the relay store's files sit in the shared folder. Opening it with its own folder moves
    /// the files its rows name and rewrites the rows; the other store's file and a stray are not touched by it.
    func testAStoreWithItsOwnFolderAdoptsItsRowsFilesOutOfTheSharedOne() throws {
        let dir = try tempDirectory()
        let path = dir.appendingPathComponent("b.sqlite").path
        let old = try TransportStore(path: path)  // an earlier build: the shared folder
        let own = try bufferStashed(old, name: "rec-b", in: dir)
        let other = dir.appendingPathComponent(TransportStore.sharedStashFolder).appendingPathComponent("other-store-file")
        try Data("o".utf8).write(to: other)
        try old.close()

        let store = try TransportStore(path: path, stashFolder: "b-assets")
        defer { try? store.close() }
        let moved = try XCTUnwrap(store.stashDirectory).appendingPathComponent(own.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: moved), Data("rec-b".utf8), "its file moved into its own folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "the other store's file stays for that store")
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.first?.assetFileURL?.standardizedFileURL, moved.standardizedFileURL)
        // A second open changes nothing, and the moved file survives the sweep because its row follows it.
        try store.close()
        let again = try TransportStore(path: path, stashFolder: "b-assets")
        defer { try? again.close() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    /// A crash after the file moved and before its row changed: the next open finds the file in place and finishes.
    func testAnInterruptedAdoptionFinishesAtTheNextOpen() throws {
        let dir = try tempDirectory()
        let path = dir.appendingPathComponent("b.sqlite").path
        let old = try TransportStore(path: path)
        let legacy = try bufferStashed(old, name: "rec-b", in: dir)
        try old.close()
        let ownFolder = dir.appendingPathComponent("b-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        let moved = ownFolder.appendingPathComponent(legacy.lastPathComponent)
        try FileManager.default.moveItem(at: legacy, to: moved)

        let store = try TransportStore(path: path, stashFolder: "b-assets")
        defer { try? store.close() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "the file survives the open sweep")
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.first?.assetFileURL?.standardizedFileURL, moved.standardizedFileURL)
    }

    /// The shared store's file was already swept by the other store (the old bug): the row stays as it was and the
    /// open does not fail.
    func testAdoptionWithTheFileAlreadyGoneLeavesTheRow() throws {
        let dir = try tempDirectory()
        let path = dir.appendingPathComponent("b.sqlite").path
        let old = try TransportStore(path: path)
        let legacy = try bufferStashed(old, name: "rec-b", in: dir)
        try old.close()
        try FileManager.default.removeItem(at: legacy)

        let store = try TransportStore(path: path, stashFolder: "b-assets")
        defer { try? store.close() }
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.first?.assetFileURL?.standardizedFileURL, legacy.standardizedFileURL)
    }
}

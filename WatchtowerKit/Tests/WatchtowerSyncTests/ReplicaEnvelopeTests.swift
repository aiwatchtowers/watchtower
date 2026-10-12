import CryptoKit
import GRDB
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The phone replica keeps ciphertext (mobile E2E spec §2.6): the hub signature is verified once at apply (with
/// the public key, readable while locked), `(epoch, seq)` is stored as the rollback guard, payloads are opened on
/// read, and rows whose kind is unknown until opened are indexed after the first unlock (Review Focus 1, F15).
final class ReplicaEnvelopeTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let askTitle = "Approve the Acme rollout plan"

    // MARK: - Builders

    private func ask(id: String = "42", title: String? = nil, notifyLevel: String? = "urgent") -> CloudRecord {
        CloudRecord(
            recordName: SliceKind.ownerAsk.recordName(id: id), zone: .data, kind: SliceKind.ownerAsk.rawValue,
            modifiedAt: stamp, payload: Data("{\"id\":\(id),\"title\":\"\(title ?? askTitle)\"}".utf8),
            notifyLevel: notifyLevel)
    }

    private func seal(_ records: [CloudRecord], hub: TestHubKeyProvider = TestE2E.hub()) async throws -> [CloudRecord] {
        let transport = TestE2E.hubTransport(hub)
        var sealed: [CloudRecord] = []
        for record in records { sealed.append(try await transport.seal(record)) }
        return sealed
    }

    private func batch(_ records: [CloudRecord], deleted: [String] = [], token: Int) -> CloudChangeBatch {
        CloudChangeBatch(changed: records, deletedRecordNames: deleted, newToken: CloudChangeToken(value: token))
    }

    private func texts(_ store: ReplicaStore, _ kind: SliceKind) throws -> [String] {
        try read(store) { db in try store.payloads(of: kind, from: db) }.map { String(bytes: $0, encoding: .utf8) ?? "<not UTF-8>" }
    }

    /// A synchronous read: inside an async test GRDB would pick its async overload.
    private func read<T>(_ store: ReplicaStore, _ block: (Database) throws -> T) throws -> T {
        try store.reader.read(block)
    }

    private func rowCount(_ store: ReplicaStore) throws -> Int {
        try read(store) { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0 }
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("replica-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Review Focus 1

    func testApplyWhileLockedStoresCiphertextAndIndexesAfterUnlock() async throws {
        let dir = try tempDirectory()
        let keys = try TestE2E.phoneStore()
        keys.isLocked = true
        let store = try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path, opener: TestE2E.opener(store: keys))
        let sealed = try await seal([ask()])

        XCTAssertTrue(try store.apply(batch(sealed, token: 1)))
        XCTAssertEqual(try store.storedToken(), CloudChangeToken(value: 1), "the token advances while locked")
        XCTAssertTrue(try texts(store, .ownerAsk).isEmpty)
        XCTAssertTrue(try store.indexPending().isEmpty, "nothing opens while locked")
        XCTAssertEqual(store.corruptCount(), 0)
        XCTAssertEqual(store.rejectedCount(), 0)

        keys.isLocked = false
        let indexed = try store.indexPending()
        XCTAssertEqual(indexed, [AppliedSliceRecord(
            recordName: "owner_ask-42", kind: .ownerAsk, notifyLevel: "urgent", modifiedAt: stamp)])
        XCTAssertEqual(try texts(store, .ownerAsk), ["{\"id\":42,\"title\":\"\(askTitle)\"}"])
        XCTAssertTrue(try store.indexPending().isEmpty, "an indexed row is not reported twice")

        let stored = try read(store) { db in try Data.fetchOne(db, sql: "SELECT payload FROM slice_records") }
        XCTAssertEqual(stored, sealed.first?.payload, "the payload column holds the envelope")
        // Nothing of the plaintext reaches the database files (main file, WAL, shared memory).
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data(askTitle.utf8)), "plaintext found in \(file.lastPathComponent)")
        }
    }

    func testApplyBeforeFirstUnlockThrowsAndKeepsTheToken() async throws {
        let keys = try TestE2E.phoneStore()
        keys.isBeforeFirstUnlock = true
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let changes = batch(try await seal([ask()]), token: 1)

        XCTAssertThrowsError(try store.apply(changes)) { error in
            XCTAssertEqual(error as? KeyStoreError, .locked)
        }
        XCTAssertNil(try store.storedToken())
        XCTAssertEqual(try rowCount(store), 0)
        XCTAssertEqual(store.rejectedCount(), 0)

        keys.isBeforeFirstUnlock = false
        XCTAssertTrue(try store.apply(changes))
        XCTAssertEqual(try store.indexPending().map(\.recordName), ["owner_ask-42"])
    }

    func testALockedReadIsSkippedButNotCountedCorrupt() async throws {
        let keys = try TestE2E.phoneStore()
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        try store.apply(batch(try await seal([ask()]), token: 1))
        XCTAssertEqual(try store.indexPending().count, 1)

        keys.isLocked = true
        XCTAssertTrue(try texts(store, .ownerAsk).isEmpty)
        XCTAssertTrue(try store.fetchAll(ProbeRow.self, kind: .ownerAsk).isEmpty)
        XCTAssertEqual(store.corruptCount(), 0, "a locked read is not corruption")

        keys.isLocked = false
        XCTAssertEqual(try store.fetchAll(ProbeRow.self, kind: .ownerAsk), [ProbeRow(id: 42, text: nil)])
        XCTAssertEqual(store.corruptCount(), 0)
    }

    // MARK: - Apply-time verification

    func testASignatureByAnotherKeyIsRejectedAtApplyAndNeverStored() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let forged = try TestE2E.sealedDataRecord(ask(), seq: 1, signer: TestE2E.strangerIdentity.signing)

        XCTAssertTrue(try store.apply(batch([forged], token: 1)))
        XCTAssertEqual(try rowCount(store), 0)
        XCTAssertEqual(store.rejectedCount(), 1)
        XCTAssertEqual(try store.storedToken(), CloudChangeToken(value: 1), "a rejected record does not stall the token")
    }

    func testANewerFormatRowDoesNotLowerTheRollbackMark() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let ten = try TestE2E.sealedDataRecord(ask(title: "seq ten"), seq: 10)
        var unreadable = try TestE2E.sealedDataRecord(ask(title: "next format"), seq: 11).payload
        unreadable[3] = 2 // ver: stored unverified as (0, 0)
        let newer = CloudRecord(recordName: ten.recordName, zone: .data, kind: WireKind.envelope, modifiedAt: stamp, payload: unreadable)
        let nine = try TestE2E.sealedDataRecord(ask(title: "seq nine"), seq: 9)

        try store.apply(batch([ten], token: 1))
        try store.apply(batch([newer], token: 2))
        try store.apply(batch([nine], token: 3))
        XCTAssertEqual(store.rejectedCount(), 1, "the newer-format row never lowers the mark")
        let stored = try read(store) { db in try Data.fetchOne(db, sql: "SELECT payload FROM slice_records") }
        XCTAssertEqual(stored, unreadable)

        try store.apply(batch([try TestE2E.sealedDataRecord(ask(title: "seq twelve"), seq: 12)], token: 4))
        try store.indexPending()
        XCTAssertEqual(try texts(store, .ownerAsk), ["{\"id\":42,\"title\":\"seq twelve\"}"])
    }

    func testADeletedRecordCannotBeReplayedAtOrBelowItsLastVersion() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let ten = try TestE2E.sealedDataRecord(ask(title: "seq ten"), seq: 10)
        try store.apply(batch([ten], token: 1))
        try store.apply(batch([], deleted: [ten.recordName], token: 2))

        try store.apply(batch([try TestE2E.sealedDataRecord(ask(title: "seq nine"), seq: 9)], token: 3))
        XCTAssertEqual(try rowCount(store), 0)
        XCTAssertEqual(store.rejectedCount(), 1)
        try store.apply(batch([ten], token: 4))
        XCTAssertEqual(try rowCount(store), 0, "a replay of the deleted version is not a new record")

        try store.apply(batch([try TestE2E.sealedDataRecord(ask(title: "seq eleven"), seq: 11)], token: 5))
        try store.indexPending()
        XCTAssertEqual(try texts(store, .ownerAsk), ["{\"id\":42,\"title\":\"seq eleven\"}"])
    }

    func testARePairWithANewHubSigningKeyIsHonouredAtOnce() throws {
        let keys = try TestE2E.phoneStore()
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        try store.apply(batch([try TestE2E.sealedDataRecord(ask(id: "1"), seq: 1)], token: 1))

        // The same hub id re-paired with another signing key (test stand-in: the stranger's key).
        let newSigner = TestE2E.strangerIdentity.signing
        let link = try XCTUnwrap(keys.hubLink(TestE2E.hubID.uuidString))
        try keys.saveHubLink(HubLinkKeys(
            hubID: link.hubID, hubSigningKey: newSigner.publicKey.rawRepresentation, hubAgreementKey: link.hubAgreementKey,
            linkNonce: link.linkNonce, metaKey: link.metaKey, epochs: link.epochs))
        try store.apply(batch([try TestE2E.sealedDataRecord(ask(id: "2"), seq: 2, signer: newSigner)], token: 2))

        XCTAssertEqual(store.rejectedCount(), 0)
        XCTAssertEqual(try rowCount(store), 2)
        XCTAssertEqual(try store.indexPending().map(\.recordName), ["owner_ask-2"], "rows open under the new key")
    }

    func testARecordOfAnEpochAheadOfTheKeyboxWaitsUncountedUntilItsKeysLand() async throws {
        let keys = try TestE2E.phoneStore(epochs: [1])
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let sealed = try await seal([ask()], hub: TestE2E.hub(epoch: 2))

        XCTAssertTrue(try store.apply(batch(sealed, token: 1)))
        XCTAssertEqual(try rowCount(store), 1)
        XCTAssertTrue(try store.indexPending().isEmpty)
        XCTAssertEqual(store.corruptCount(), 0)
        XCTAssertEqual(store.rejectedCount(), 0)

        // The keybox for epoch 2 is processed.
        let link = try XCTUnwrap(keys.hubLink(TestE2E.hubID.uuidString))
        let raw = { (key: SymmetricKey) in key.withUnsafeBytes { Data($0) } }
        try keys.saveHubLink(HubLinkKeys(
            hubID: link.hubID, hubSigningKey: link.hubSigningKey, hubAgreementKey: link.hubAgreementKey,
            linkNonce: link.linkNonce, metaKey: link.metaKey,
            epochs: link.epochs + [EpochKeys(epoch: 2, dataKey: raw(TestE2E.dataKey(epoch: 2)), alertKey: raw(TestE2E.alertKey(epoch: 2)))]))
        XCTAssertEqual(try store.indexPending().map(\.recordName), ["owner_ask-42"])
        XCTAssertEqual(store.corruptCount(), 0)
    }

    func testAnEnvelopeOfAnotherHubIsRejected() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let otherHub = UUID(uuid: (0xE2, 0xE0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x02))
        let foreign = try TestE2E.sealedDataRecord(ask(), seq: 1, hubID: otherHub)

        XCTAssertTrue(try store.apply(batch([foreign], token: 1)))
        XCTAssertEqual(try rowCount(store), 0)
        XCTAssertEqual(store.rejectedCount(), 1)
    }

    func testAnOlderVersionOfARecordIsIgnoredAndTheNewerKept() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let newer = try TestE2E.sealedDataRecord(ask(title: "seq ten"), seq: 10)
        let older = try TestE2E.sealedDataRecord(ask(title: "seq nine"), seq: 9)
        XCTAssertEqual(newer.recordName, older.recordName)

        try store.apply(batch([newer], token: 1))
        try store.apply(batch([older], token: 2))
        try store.indexPending()
        XCTAssertEqual(try texts(store, .ownerAsk), ["{\"id\":42,\"title\":\"seq ten\"}"])
        XCTAssertEqual(store.rejectedCount(), 1)

        // The same version again is an idempotent re-delivery, not a rollback.
        try store.apply(batch([newer], token: 3))
        XCTAssertTrue(try store.indexPending().isEmpty, "a re-delivery is not a new version")
        XCTAssertEqual(try texts(store, .ownerAsk), ["{\"id\":42,\"title\":\"seq ten\"}"])
        XCTAssertEqual(store.rejectedCount(), 1)
        let version = try read(store) { db in try Row.fetchOne(db, sql: "SELECT epoch, seq FROM slice_records") }
        XCTAssertEqual(version?["seq"] as Int64?, 10)
        XCTAssertEqual(version?["epoch"] as Int64?, 1)
    }

    func testANewerFormatIsKeptUnindexedAndCounted() async throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let sealed = try await seal([ask(id: "1"), ask(id: "2")])
        var version = sealed[0].payload
        version[3] = 2 // ver
        var suite = sealed[1].payload
        suite[4] = 2 // suite 2 (hybrid wraps) is reserved and refused
        let newer = [
            CloudRecord(recordName: sealed[0].recordName, zone: .data, kind: WireKind.envelope, modifiedAt: stamp, payload: version),
            CloudRecord(recordName: sealed[1].recordName, zone: .data, kind: WireKind.envelope, modifiedAt: stamp, payload: suite)
        ]

        XCTAssertTrue(try store.apply(batch(newer, token: 1)))
        XCTAssertEqual(try rowCount(store), 2, "kept, so an updated app reads it without a refetch")
        XCTAssertEqual(store.newerFormatCount(), 2)
        XCTAssertEqual(store.rejectedCount(), 0)
        XCTAssertTrue(try store.indexPending().isEmpty)
        XCTAssertEqual(store.newerFormatCount(), 2, "counted once per record")
        XCTAssertEqual(store.corruptCount(), 0)
        let kinds = try read(store) { db in try String?.fetchAll(db, sql: "SELECT kind FROM slice_records") }
        XCTAssertEqual(kinds, [nil, nil])
    }

    func testSignalRecordsAreSkippedSilently() async throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let signal = CloudRecord(recordName: "sig-abc", zone: .data, kind: WireKind.signal, modifiedAt: stamp, payload: Data())

        let sealed = try await seal([ask()])
        XCTAssertTrue(try store.apply(batch([signal] + sealed, token: 1)))
        XCTAssertEqual(try rowCount(store), 1)
        XCTAssertEqual(store.rejectedCount(), 0)
        XCTAssertEqual(try store.indexPending().count, 1)
        XCTAssertEqual(store.corruptCount(), 0)
    }

    // MARK: - Fixed names and keyboxes

    func testHeartbeatAndKeyboxAreIndexedByNameWithoutOpening() async throws {
        let keys = try TestE2E.phoneStore()
        keys.isLocked = true
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let heartbeat = try CloudRecordFactory.record(for: HeartbeatFixtures.minimal(updatedAt: stamp), modifiedAt: stamp)
        let sealed = try await seal([heartbeat, try TestE2E.keyboxRecord(modifiedAt: stamp)])
        XCTAssertEqual(Set(sealed.map(\.recordName)), ["heartbeat", "keybox-\(TestE2E.deviceID.uuidString)"])

        try store.apply(batch(sealed, token: 1))
        let index = try read(store) { db in
            try Row.fetchAll(db, sql: "SELECT plain_name, kind FROM slice_records ORDER BY plain_name")
                .map { "\($0["plain_name"] as String? ?? "-")/\($0["kind"] as String? ?? "-")" }
        }
        let grantName = SliceKind.deviceGrant.recordName(id: TestE2E.deviceID.uuidString)
        XCTAssertEqual(index, ["\(grantName)/device_grant", "heartbeat/heartbeat"])
        XCTAssertThrowsError(try read(store) { db in try store.payload(forRecordName: grantName, from: db) }) { error in
            XCTAssertEqual(error as? KeyStoreError, .locked, "locked is its own state, never 'absent'")
        }

        keys.isLocked = false
        let grantJSON = try XCTUnwrap(try read(store) { db in try store.payload(forRecordName: grantName, from: db) })
        let grant = try RelayCoder.makeDecoder().decode(DeviceGrant.self, from: grantJSON)
        XCTAssertEqual(grant.deviceID, TestE2E.deviceID.uuidString)
        XCTAssertTrue(grant.linked)
        XCTAssertEqual(try read(store) { db in try store.payloads(of: .deviceGrant, from: db) }, [grantJSON])
        XCTAssertNotNil(try store.heartbeatAge(now: stamp))
    }

    func testAnotherPhonesKeyboxIsDroppedAtApply() async throws {
        let hub = TestE2E.hub()
        hub.link(TestE2E.strangerIdentity)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let sealed = try await seal([
            try TestE2E.keyboxRecord(deviceID: TestE2E.strangerDeviceID, modifiedAt: stamp),
            try TestE2E.keyboxRecord(modifiedAt: stamp)
        ], hub: hub)

        try store.apply(batch(sealed, token: 1))
        let names = try read(store) { db in try String.fetchAll(db, sql: "SELECT record_name FROM slice_records") }
        XCTAssertEqual(names, ["keybox-\(TestE2E.deviceID.uuidString)"])
        XCTAssertEqual(store.rejectedCount(), 0)
        XCTAssertEqual(try store.indexPending().count, 1)
        XCTAssertEqual(store.corruptCount(), 0)
    }

    // MARK: - Epochs and deletions

    func testRowsOfThePreviousEpochStayReadableUntilRepublished() async throws {
        let keys = try TestE2E.phoneStore(epochs: [1, 2])
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let hub = TestE2E.hub(epoch: 1)
        let old = try await seal([ask(id: "1", title: "old epoch")], hub: hub)
        hub.currentEpochValue = 2
        let new = try await seal([ask(id: "2", title: "new epoch")], hub: hub)

        try store.apply(batch(old + new, token: 1))
        XCTAssertEqual(try store.indexPending().count, 2)
        XCTAssertEqual(Set(try texts(store, .ownerAsk)), [
            "{\"id\":1,\"title\":\"old epoch\"}", "{\"id\":2,\"title\":\"new epoch\"}"
        ])

        // Republished under epoch 2: a newer version even with a lower seq (epoch first).
        let republished = try await seal([ask(id: "1", title: "republished")], hub: TestE2E.hub(epoch: 2))
        try store.apply(batch(republished, token: 2))
        XCTAssertEqual(store.rejectedCount(), 0)
        XCTAssertEqual(Set(try texts(store, .ownerAsk)), [
            "{\"id\":1,\"title\":\"republished\"}", "{\"id\":2,\"title\":\"new epoch\"}"
        ])
        XCTAssertEqual(try store.indexPending().map(\.recordName), ["owner_ask-1"], "an updated row is reported again")
    }

    func testDeletionsRemoveByWireName() async throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        let sealed = try await seal([ask()])
        try store.apply(batch(sealed, token: 1))
        try store.indexPending()

        try store.apply(batch([], deleted: ["owner_ask-42"], token: 2))
        XCTAssertEqual(try rowCount(store), 1, "a plain name is not a wire name")

        try store.apply(batch([], deleted: [sealed[0].recordName], token: 3))
        XCTAssertEqual(try rowCount(store), 0)
    }

    // MARK: - Assets

    func testAnAssetIsStoredSealedAndDecryptedOnRead() async throws {
        let dir = try tempDirectory()
        let plain = Data("[{\"text\":\"Acme standup notes\"}]".utf8)
        let (sealedAsset, descriptor) = try ChunkedAssetCipher.encrypt(plain)
        let file = dir.appendingPathComponent("segments.sealed")
        try sealedAsset.write(to: file)
        let record = CloudRecord(
            recordName: SliceKind.meetingTranscript.recordName(id: "1"), zone: .data,
            kind: SliceKind.meetingTranscript.rawValue, modifiedAt: stamp, payload: Data("{}".utf8),
            assetFileURL: file, asset: descriptor)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())

        try store.apply(batch(try await seal([record]), token: 1))
        try FileManager.default.removeItem(at: file)
        try store.indexPending()

        let stored = try read(store) { db in try Data.fetchOne(db, sql: "SELECT data FROM slice_assets") }
        XCTAssertEqual(stored, sealedAsset, "the replica keeps the sealed bytes")
        let asset = try read(store) { db in try store.sliceAsset(forRecordName: record.recordName, from: db) }
        XCTAssertEqual(asset, .data(plain))
    }

    func testAnAssetOverTheSealedCapIsRefusedUnread() async throws {
        XCTAssertEqual(ReplicaStore.maxAssetBytes, Int(ChunkedAssetCipher.sealedLength(forPlaintext: 20 * 1_024 * 1_024)))
        let dir = try tempDirectory()
        let file = dir.appendingPathComponent("segments.sealed")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ReplicaStore.maxAssetBytes + 1))
        try handle.close()
        let (_, descriptor) = try ChunkedAssetCipher.encrypt(Data("[]".utf8))
        let record = CloudRecord(
            recordName: SliceKind.meetingTranscript.recordName(id: "1"), zone: .data,
            kind: SliceKind.meetingTranscript.rawValue, modifiedAt: stamp, payload: Data("{}".utf8),
            assetFileURL: file, asset: descriptor)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())

        try store.apply(batch(try await seal([record]), token: 1))
        try store.indexPending()

        let asset = try read(store) { db in try store.sliceAsset(forRecordName: record.recordName, from: db) }
        XCTAssertEqual(asset, .unreadable("too large"))
    }

    // MARK: - Format and metadata

    func testTheEnvelopeSeqCeilingSurvivesTheFormatWipe() async throws {
        let path = try tempDirectory().appendingPathComponent("replica.sqlite").path
        do {
            let store = try ReplicaStore(path: path, opener: TestE2E.opener())
            XCTAssertEqual(try store.envelopeSeqCeiling(), 0)
            try store.setEnvelopeSeqCeiling(2_048)
            try store.apply(batch(try await seal([ask()]), token: 1))
        }
        try await DatabaseQueue(path: path).write { db in
            try db.execute(sql: "UPDATE replica_meta SET value = '1' WHERE key = 'replica_format'")
        }

        let reopened = try ReplicaStore(path: path, opener: TestE2E.opener())
        XCTAssertEqual(try rowCount(reopened), 0, "the format wipe ran")
        XCTAssertNil(try reopened.storedToken())
        XCTAssertEqual(try reopened.envelopeSeqCeiling(), 2_048)
    }

    func testAFormatOneStoreIsWipedOnOpenButKeepsTheRecordingLedger() throws {
        let path = try tempDirectory().appendingPathComponent("replica.sqlite").path
        let pending = try RelayCoder.makeEncoder().encode(
            ActionRequestPayload(id: "a1", kind: .targetDone, entityID: "1", createdAt: stamp))
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE slice_records (
                    record_name TEXT PRIMARY KEY, kind TEXT NOT NULL, payload BLOB NOT NULL, modified_at REAL NOT NULL
                );
                INSERT INTO slice_records VALUES ('target-1', 'target', X'7B7D', 1700000000);
                CREATE TABLE slice_assets (record_name TEXT PRIMARY KEY, data BLOB, error TEXT);
                INSERT INTO slice_assets VALUES ('target-1', X'00', NULL);
                CREATE TABLE replica_meta (key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO replica_meta VALUES ('data_change_token', '{"value":5}');
                INSERT INTO replica_meta VALUES ('relay_change_token', '{"value":6}');
                INSERT INTO replica_meta VALUES ('notify_alert_watermark', '1700000000');
                CREATE TABLE phone_recordings (
                    recording_id TEXT PRIMARY KEY, file_path TEXT NOT NULL,
                    started_at REAL NOT NULL, ended_at REAL NOT NULL, duration_sec INTEGER NOT NULL,
                    title_hint TEXT, sample_format TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('recording','waiting','uploading','delivered','failed')),
                    error_message TEXT, event_id TEXT, failure_kind TEXT
                );
                INSERT INTO phone_recordings VALUES
                    ('rec-1', 'rec-1.m4a', 0, 60, 60, NULL, 'aac-64k-mono', 'waiting', NULL, NULL, NULL);
                CREATE TABLE phone_recording_marks (
                    recording_id TEXT NOT NULL REFERENCES phone_recordings(recording_id) ON DELETE CASCADE,
                    offset_sec INTEGER NOT NULL CHECK(offset_sec >= 0),
                    PRIMARY KEY (recording_id, offset_sec)
                );
                INSERT INTO phone_recording_marks VALUES ('rec-1', 12);
                CREATE TABLE pending_actions (
                    action_id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_record_name TEXT,
                    payload BLOB NOT NULL, created_at REAL NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('pending','failed')), error_message TEXT,
                    reason TEXT, result BLOB, echo_status TEXT
                );
                """)
            try db.execute(
                sql: "INSERT INTO pending_actions VALUES ('a1', 'target_done', 'target-1', ?, 1700000000, 'pending', NULL, NULL, NULL, NULL)",
                arguments: [pending])
        }

        let store = try ReplicaStore(path: path, opener: TestE2E.opener())

        XCTAssertEqual(try rowCount(store), 0)
        XCTAssertEqual(try read(store) { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_assets") }, 0)
        let columns = try read(store) { db in try db.columns(in: "slice_records").map(\.name) }
        XCTAssertEqual(Set(columns), ["record_name", "plain_name", "kind", "epoch", "seq", "payload", "modified_at", "needs_index"])
        XCTAssertNil(try store.storedToken())
        XCTAssertNil(try store.relayToken())
        XCTAssertEqual(try store.lastAlertedWatermark(), stamp)
        XCTAssertEqual(try store.phoneRecordings().map(\.id), ["rec-1"])
        XCTAssertEqual(try store.phoneRecordingMarks(id: "rec-1"), [12])
        // Mobile E2E Task 9: a pre-E2E overlay row is a plaintext action for a hub the hard cut removed; it is
        // dropped when the overlay gains `wire_name` (rewritten from "kept").
        XCTAssertTrue(try store.pendingActions().isEmpty)
        let format = try read(store) { db in
            try String.fetchOne(db, sql: "SELECT value FROM replica_meta WHERE key = 'replica_format'")
        }
        XCTAssertEqual(format, "2")
    }

    // MARK: - Relay rollback guard (F3)

    func testTheRelayRollbackGuardPersistsPerSenderAndIsPruned() throws {
        let path = try tempDirectory().appendingPathComponent("replica.sqlite").path
        let store = try ReplicaStore(path: path, opener: TestE2E.opener())
        try store.record(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 5)
        XCTAssertEqual(try store.check(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 5), .same)
        XCTAssertEqual(try store.check(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 4), .older)
        XCTAssertEqual(try store.check(wireName: "w1", senderID: TestE2E.hubID, epoch: 2, seq: 1), .newer)
        XCTAssertEqual(try store.check(wireName: "w1", senderID: TestE2E.deviceID, epoch: 1, seq: 1), .newer)
        // Keeps the highest version seen.
        try store.record(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 3)
        XCTAssertEqual(try ReplicaStore(path: path, opener: TestE2E.opener())
            .check(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 5), .same)

        try store.pruneRelaySeen(before: Date().addingTimeInterval(60))
        XCTAssertEqual(try store.check(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 1), .newer)
    }

    func testSweepSilentPendingPrunesRelaySeenOlderThanEightDays() async throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener())
        try store.record(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 5)

        try await ActionOutbox(transport: TestE2E.phoneTransport(try TestE2E.phone()), store: store) { Date().addingTimeInterval(7 * 86_400) }
            .sweepSilentPending()
        XCTAssertEqual(try store.check(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 5), .same)

        try await ActionOutbox(transport: TestE2E.phoneTransport(try TestE2E.phone()), store: store) { Date().addingTimeInterval(9 * 86_400) }
            .sweepSilentPending()
        XCTAssertEqual(try store.check(wireName: "w1", senderID: TestE2E.hubID, epoch: 1, seq: 5), .newer)
    }
}

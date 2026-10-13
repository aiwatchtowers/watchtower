import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// The hub's key material (Task 10): the Keychain identity, `K_meta` and the epoch keys sealed in `hubstate.db`
/// (D3), the envelope seq, the pairwise relay keys (D10) and the relay rollback guard (F3). Unsigned tests use the
/// Kit's in-memory keychain store.
final class HubKeyringTests: XCTestCase {
    private let hubID = "e2e00000-0000-4000-8000-0000000000a1"
    private let hubUUID = UUID(uuid: (0xE2, 0xE0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0xA1))

    private func keyring(
        _ sidecar: HubSyncState, store: any HubKeyStore, clock: LinkTestClock = LinkTestClock()
    ) throws -> HubKeyring {
        try HubKeyring(hubID: hubID, sidecar: sidecar, store: store) { clock.now }
    }

    private static func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// A linked phone row with its key material, as Task 13's link writes it.
    private func linkPhone(
        _ sidecar: HubSyncState, identity: DeviceIdentityKeys, nonce: String = WireBytes.base64URL(Data(repeating: 0xA5, count: 32))
    ) throws {
        let device = HubSyncState.LinkedDevice(
            deviceID: identity.deviceID.uuidString, name: "Phone", scope: .private, userRecordName: "_owner",
            linkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try sidecar.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO devices (device_id, name, scope, user_record_name, linked_at, signing_key, agreement_key, link_nonce)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    device.deviceID, device.name, device.scope.rawValue, device.userRecordName,
                    device.linkedAt.timeIntervalSince1970, identity.signing.publicKey.rawRepresentation,
                    identity.agreement.publicKey.rawRepresentation, nonce
                ])
        }
    }

    private func newIdentity() -> DeviceIdentityKeys {
        DeviceIdentityKeys(signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey())
    }

    // MARK: - Group keys

    func testGroupKeysAreCreatedOnceAndSurviveANewKeyring() throws {
        let sidecar = try HubSyncState.inMemory()
        let store = InMemoryHubKeyStore()
        let first = try keyring(sidecar, store: store)
        try first.ensureGroupKeys()
        try first.ensureGroupKeys()
        let meta = try first.metaKey()
        let epoch1 = try first.epochKeys(1)
        XCTAssertEqual(try first.currentEpoch(), 1)
        XCTAssertEqual(epoch1.dataKey.count, 32)
        XCTAssertEqual(epoch1.alertKey.count, 32)
        XCTAssertNotEqual(epoch1.dataKey, epoch1.alertKey)

        let second = try keyring(sidecar, store: store)
        XCTAssertFalse(second.identityWasRecreated)
        try second.ensureGroupKeys()
        XCTAssertEqual(try second.metaKey(), meta)
        XCTAssertEqual(try second.epochKeys(1), epoch1)
        XCTAssertEqual(try second.currentEpoch(), 1)
        XCTAssertEqual(try second.dataKey(epoch: 1), SymmetricKey(data: epoch1.dataKey))
        XCTAssertEqual(try second.alertKey(epoch: 1), SymmetricKey(data: epoch1.alertKey))
        XCTAssertEqual(second.signingPublicKey.rawRepresentation, first.signingPublicKey.rawRepresentation)
        XCTAssertEqual(second.agreementPublicKey.rawRepresentation, first.agreementPublicKey.rawRepresentation)
        XCTAssertEqual(try second.hubSigner().publicKey.rawRepresentation, first.signingPublicKey.rawRepresentation)
        XCTAssertEqual(second.role, .hub(hubID: hubUUID))
    }

    func testKeysAreUnavailableBeforeEnsureGroupKeys() throws {
        let ring = try keyring(try HubSyncState.inMemory(), store: InMemoryHubKeyStore())
        XCTAssertThrowsError(try ring.metaKey()) { XCTAssertEqual($0 as? SecureTransportError, .keysUnavailable) }
        XCTAssertThrowsError(try ring.currentEpoch()) { XCTAssertEqual($0 as? SecureTransportError, .keysUnavailable) }
        XCTAssertFalse(try ring.rotationDue())
    }

    func testEpochKeysAreSealedAtRest() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let meta = Self.raw(try ring.metaKey())
        let keys = try ring.epochKeys(1)
        let sealedEpoch = try XCTUnwrap(try sidecar.queue.read {
            try Data.fetchOne($0, sql: "SELECT sealed_keys FROM hub_epochs WHERE epoch = 1")
        })
        let sealedMeta = try XCTUnwrap(try sidecar.metaValue(forKey: HubKeyring.metaKeySealedKey))
        for secret in [meta, keys.dataKey, keys.alertKey] {
            XCTAssertNil(sealedEpoch.range(of: secret))
            XCTAssertFalse(sealedMeta.contains(secret.base64EncodedString()))
            XCTAssertFalse(sealedMeta.contains(secret.map { String(format: "%02x", $0) }.joined()))
            XCTAssertNil(Data(sealedMeta.utf8).range(of: secret))
        }
        XCTAssertNil(sealedEpoch.range(of: keys.dataKey + keys.alertKey))

        // Sealed under the Keychain wrap key: another identity over the same sidecar cannot open them.
        let stranger = try keyring(sidecar, store: InMemoryHubKeyStore())
        XCTAssertTrue(stranger.identityWasRecreated)
        XCTAssertThrowsError(try stranger.epochKeys(1))
        XCTAssertThrowsError(try stranger.metaKey())
    }

    func testResetGroupKeysForgetsEveryEpochAndKMeta() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let meta = try ring.metaKey()
        let old = try ring.epochKeys(1)
        _ = try ring.beginNextEpoch()
        try ring.resetGroupKeys()

        XCTAssertNil(try sidecar.metaValue(forKey: HubKeyring.metaKeySealedKey))
        XCTAssertEqual(try sidecar.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hub_epochs") }, 0)
        XCTAssertThrowsError(try ring.metaKey()) { XCTAssertEqual($0 as? SecureTransportError, .keysUnavailable) }
        XCTAssertThrowsError(try ring.epochKeys(1))

        try ring.ensureGroupKeys()
        XCTAssertEqual(try ring.currentEpoch(), 1)
        XCTAssertNotEqual(try ring.metaKey(), meta)
        XCTAssertNotEqual(try ring.epochKeys(1), old)
    }

    // MARK: - Seq

    func testSeqIsMonotonicAcrossRestartsAndPersistedInHubMeta() throws {
        let sidecar = try HubSyncState.inMemory()
        let store = InMemoryHubKeyStore()
        let first = try keyring(sidecar, store: store)
        let a = try first.nextSeq()
        let b = try first.nextSeq()
        XCTAssertEqual(a, 1)
        XCTAssertGreaterThan(b, a)
        let ceiling = try XCTUnwrap(try sidecar.metaValue(forKey: HubKeyring.seqCeilingKey).flatMap(UInt64.init))
        XCTAssertGreaterThan(ceiling, b)

        let restarted = try keyring(sidecar, store: store)
        let c = try restarted.nextSeq()
        XCTAssertGreaterThanOrEqual(c, ceiling)
        XCTAssertGreaterThan(try restarted.nextSeq(), c)
    }

    func testAnUndecodableSeqCeilingIsAnErrorNotAReset() throws {
        let sidecar = try HubSyncState.inMemory()
        try sidecar.setMetaValue("not a number", forKey: HubKeyring.seqCeilingKey)
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        XCTAssertThrowsError(try ring.nextSeq())
    }

    // MARK: - Relay keys

    func testRelayKeysAgreeWithThePhonesDerivation() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let phone = newIdentity()
        let nonceBytes = Data(repeating: 0xA5, count: 32)
        try linkPhone(sidecar, identity: phone, nonce: WireBytes.base64URL(nonceBytes))

        XCTAssertEqual(try ring.relayDeviceIDs(), [phone.deviceID])
        for direction in RelayDirection.allCases {
            let phoneSide = try KeyDerivation.relayKey(
                agreementPrivate: phone.agreement, peerPublic: ring.agreementPublicKey, linkNonce: nonceBytes,
                hubID: hubUUID, deviceID: phone.deviceID, epoch: 1, direction: direction)
            XCTAssertEqual(try ring.relayKey(direction, deviceID: phone.deviceID, epoch: 1), phoneSide)
            // Cached: the same key again.
            XCTAssertEqual(try ring.relayKey(direction, deviceID: phone.deviceID, epoch: 1), phoneSide)
        }
        XCTAssertNotEqual(
            try ring.relayKey(.phoneToHub, deviceID: phone.deviceID, epoch: 1),
            try ring.relayKey(.phoneToHub, deviceID: phone.deviceID, epoch: 2))
        XCTAssertNotEqual(
            try ring.relayKey(.phoneToHub, deviceID: phone.deviceID, epoch: 1),
            try ring.relayKey(.hubToPhone, deviceID: phone.deviceID, epoch: 1))
    }

    func testARelinkWithANewNonceDerivesFreshRelayKeys() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let phone = newIdentity()
        try linkPhone(sidecar, identity: phone, nonce: WireBytes.base64URL(Data(repeating: 1, count: 32)))
        let before = try ring.relayKey(.phoneToHub, deviceID: phone.deviceID, epoch: 1)
        let newNonce = Data(repeating: 2, count: 32)
        try sidecar.queue.write {
            try $0.execute(sql: "UPDATE devices SET link_nonce = ?", arguments: [WireBytes.base64URL(newNonce)])
        }
        XCTAssertTrue(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
        let after = try ring.relayKey(.phoneToHub, deviceID: phone.deviceID, epoch: 1)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after, try KeyDerivation.relayKey(
            agreementPrivate: phone.agreement, peerPublic: ring.agreementPublicKey, linkNonce: newNonce,
            hubID: hubUUID, deviceID: phone.deviceID, epoch: 1, direction: .phoneToHub))
    }

    func testUnknownOrBrokenDevicesAreRefusedWithoutThrowing() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let good = newIdentity()
        try linkPhone(sidecar, identity: good)
        // A linked phone from before E2E (no key columns) and one whose stored key does not parse.
        let legacy = HubSyncState.LinkedDevice(
            deviceID: UUID().uuidString, name: "Old", scope: .private, userRecordName: "_owner", linkedAt: Date())
        try sidecar.queue.write { db in
            try db.execute(
                sql: "INSERT INTO devices (device_id, name, scope, user_record_name, linked_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [legacy.deviceID, legacy.name, legacy.scope.rawValue, legacy.userRecordName, 0])
        }
        let broken = newIdentity()
        try linkPhone(sidecar, identity: broken)
        try sidecar.queue.write {
            try $0.execute(
                sql: "UPDATE devices SET agreement_key = ? WHERE device_id = ?",
                arguments: [Data([1, 2, 3]), broken.deviceID.uuidString])
        }

        XCTAssertEqual(try ring.relayDeviceIDs(), [good.deviceID])
        for id in [UUID(), try XCTUnwrap(UUID(uuidString: legacy.deviceID)), broken.deviceID] {
            XCTAssertFalse(try ring.acceptsRelayEpoch(1, deviceID: id))
        }
        XCTAssertTrue(try ring.acceptsRelayEpoch(1, deviceID: good.deviceID))
        // Every id relayDeviceIDs returns has a key, even after its row went away (Task 14 drops the cache).
        let ids = try ring.relayDeviceIDs()
        _ = try sidecar.removeLinkedDevice(good.deviceID.uuidString)
        for id in ids { XCTAssertNoThrow(try ring.relayKey(.hubToPhone, deviceID: id, epoch: 1)) }
        ring.forgetRelayKeys(deviceID: good.deviceID)
        XCTAssertThrowsError(try ring.relayKey(.hubToPhone, deviceID: good.deviceID, epoch: 1))
    }

    func testThePreviousEpochIsAcceptedForSevenDaysThenRefused() throws {
        let sidecar = try HubSyncState.inMemory()
        let clock = LinkTestClock()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore(), clock: clock)
        try ring.ensureGroupKeys()
        let phone = newIdentity()
        try linkPhone(sidecar, identity: phone)
        XCTAssertTrue(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
        XCTAssertFalse(try ring.acceptsRelayEpoch(2, deviceID: phone.deviceID))

        clock.advance(86_400)
        let next = try ring.beginNextEpoch()
        XCTAssertEqual(next.epoch, 2)
        XCTAssertEqual(try ring.currentEpoch(), 2)
        XCTAssertNotEqual(try ring.epochKeys(2), try ring.epochKeys(1))
        XCTAssertTrue(try ring.acceptsRelayEpoch(2, deviceID: phone.deviceID))
        XCTAssertTrue(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
        XCTAssertFalse(try ring.acceptsRelayEpoch(3, deviceID: phone.deviceID))
        XCTAssertFalse(try ring.acceptsRelayEpoch(0, deviceID: phone.deviceID))

        clock.advance(7 * 86_400 - 1)
        XCTAssertTrue(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
        clock.advance(1)
        XCTAssertFalse(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
        XCTAssertTrue(try ring.acceptsRelayEpoch(2, deviceID: phone.deviceID))

        // Two epochs back is never accepted, even right after the rotation.
        _ = try ring.beginNextEpoch()
        XCTAssertTrue(try ring.acceptsRelayEpoch(2, deviceID: phone.deviceID))
        XCTAssertFalse(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
    }

    func testBeginNextEpochRunsTheCallersWorkInTheSameTransaction() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        try sidecar.setHash("h", for: "workbench-1")
        struct Abort: Error {}
        XCTAssertThrowsError(try ring.beginNextEpoch { db in
            try db.execute(sql: "DELETE FROM slice_state")
            throw Abort()
        })
        XCTAssertEqual(try ring.currentEpoch(), 1)
        XCTAssertEqual(try sidecar.hashes(forKind: .workbench).count, 1)

        _ = try ring.beginNextEpoch { try $0.execute(sql: "DELETE FROM slice_state") }
        XCTAssertEqual(try ring.currentEpoch(), 2)
        XCTAssertTrue(try sidecar.hashes(forKind: .workbench).isEmpty)
    }

    func testRotationIsDueAtNinetyDaysOrTheSeqCap() throws {
        let sidecar = try HubSyncState.inMemory()
        let clock = LinkTestClock()
        let store = InMemoryHubKeyStore()
        let ring = try keyring(sidecar, store: store, clock: clock)
        try ring.ensureGroupKeys()
        XCTAssertFalse(try ring.rotationDue())
        clock.advance(90 * 86_400 - 1)
        XCTAssertFalse(try ring.rotationDue())
        clock.advance(1)
        XCTAssertTrue(try ring.rotationDue())

        _ = try ring.beginNextEpoch()
        XCTAssertFalse(try ring.rotationDue())
        // The epoch's seqs reach 2^28: the persisted ceiling is past first_seq + 2^28.
        let firstSeq = try XCTUnwrap(try sidecar.queue.read {
            try Int64.fetchOne($0, sql: "SELECT first_seq FROM hub_epochs WHERE epoch = 2")
        })
        try sidecar.setMetaValue(String(firstSeq + (1 << 28) - 1), forKey: HubKeyring.seqCeilingKey)
        XCTAssertFalse(try keyring(sidecar, store: store, clock: clock).rotationDue())
        try sidecar.setMetaValue(String(firstSeq + (1 << 28)), forKey: HubKeyring.seqCeilingKey)
        XCTAssertTrue(try keyring(sidecar, store: store, clock: clock).rotationDue())
    }

    // MARK: - Identity

    func testARecreatedIdentityWithLinkedPhonesIsReported() throws {
        let sidecar = try HubSyncState.inMemory()
        XCTAssertFalse(try keyring(sidecar, store: InMemoryHubKeyStore()).identityWasRecreated, "a fresh hub")

        let withPhone = try HubSyncState.inMemory()
        try linkPhone(withPhone, identity: newIdentity())
        XCTAssertTrue(try keyring(withPhone, store: InMemoryHubKeyStore()).identityWasRecreated)

        let withEpochs = try HubSyncState.inMemory()
        let store = InMemoryHubKeyStore()
        try keyring(withEpochs, store: store).ensureGroupKeys()
        XCTAssertFalse(try keyring(withEpochs, store: store).identityWasRecreated, "the same identity")
        XCTAssertTrue(try keyring(withEpochs, store: InMemoryHubKeyStore()).identityWasRecreated)
    }

    func testALockedKeychainPropagatesFromInit() throws {
        let backend = InMemoryKeychainBackend()
        backend.isBeforeFirstUnlock = true
        XCTAssertThrowsError(try HubKeyring(
            hubID: hubID, sidecar: try HubSyncState.inMemory(), store: KeychainHubKeyStore(backend: backend))
        ) { XCTAssertEqual($0 as? KeyStoreError, .locked) }
    }

    // MARK: - Rollback guard (F3)

    func testRollbackGuardKeepsTheHighestSeqPerWireNameAndSenderAndPrunesByAge() throws {
        let sidecar = try HubSyncState.inMemory()
        let clock = LinkTestClock()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore(), clock: clock)
        let phone = UUID()
        let wire = "abcdefghijklmnopqrstuvwxyz"

        XCTAssertEqual(try ring.check(wireName: wire, senderID: phone, epoch: 1, seq: 500), .newer)
        try ring.record(wireName: wire, senderID: phone, epoch: 1, seq: 500)
        XCTAssertEqual(try ring.check(wireName: wire, senderID: phone, epoch: 1, seq: 500), .same)
        XCTAssertEqual(try ring.check(wireName: wire, senderID: phone, epoch: 1, seq: 499), .older)
        XCTAssertEqual(try ring.check(wireName: wire, senderID: phone, epoch: 2, seq: 1), .newer)
        // The hub's own echo on the same wire name, in the hub's (lower) seq space.
        XCTAssertEqual(try ring.check(wireName: wire, senderID: hubUUID, epoch: 1, seq: 3), .newer)
        try ring.record(wireName: wire, senderID: hubUUID, epoch: 1, seq: 3)
        XCTAssertEqual(try ring.check(wireName: wire, senderID: phone, epoch: 1, seq: 500), .same)
        // record never lowers the stored version.
        try ring.record(wireName: wire, senderID: phone, epoch: 1, seq: 10)
        XCTAssertEqual(try ring.check(wireName: wire, senderID: phone, epoch: 1, seq: 499), .older)
        // A survivor of a restart: the guard is persisted.
        let restarted = try keyring(sidecar, store: InMemoryHubKeyStore(), clock: clock)
        XCTAssertEqual(try restarted.check(wireName: wire, senderID: phone, epoch: 1, seq: 500), .same)

        clock.advance(10 * 86_400)
        try ring.record(wireName: "fresh", senderID: phone, epoch: 1, seq: 1)
        try sidecar.pruneRelayProcessed(olderThan: clock.now.addingTimeInterval(-86_400))
        XCTAssertEqual(try ring.check(wireName: wire, senderID: phone, epoch: 1, seq: 1), .newer, "pruned by age")
        XCTAssertEqual(try ring.check(wireName: wire, senderID: hubUUID, epoch: 1, seq: 1), .newer, "pruned by age")
        XCTAssertEqual(try ring.check(wireName: "fresh", senderID: phone, epoch: 1, seq: 1), .same, "kept")
    }

    // MARK: - Keybox recipients (F5)

    func testTheKeyboxRecipientCoversLinkedPendingRevokedAndRefusedDevices() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        let linked = newIdentity()
        let pending = newIdentity()
        let revoked = newIdentity()
        let refused = newIdentity()
        try linkPhone(sidecar, identity: linked)
        try sidecar.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_devices (device_id, name, scope, user_record_name, signing_key, agreement_key,
                                                 link_nonce, sas, received_at)
                    VALUES (?, 'P', 'private', '_owner', ?, ?, 'n', '0000', 0)
                    """,
                arguments: [
                    pending.deviceID.uuidString, pending.signing.publicKey.rawRepresentation,
                    pending.agreement.publicKey.rawRepresentation
                ])
            try db.execute(
                sql: "INSERT INTO revoked_devices (device_id, agreement_key, removed_at) VALUES (?, ?, 0)",
                arguments: [revoked.deviceID.uuidString, revoked.agreement.publicKey.rawRepresentation])
            try db.execute(
                sql: """
                    INSERT INTO link_refusals (device_id, name, scope, reason, at, agreement_key)
                    VALUES (?, 'R', 'private', 'not_confirmed', 0, ?)
                    """,
                arguments: [refused.deviceID.uuidString, refused.agreement.publicKey.rawRepresentation])
        }
        for identity in [linked, pending, revoked, refused] {
            XCTAssertEqual(
                try ring.keyboxRecipient(deviceID: identity.deviceID)?.rawRepresentation,
                identity.agreement.publicKey.rawRepresentation)
        }
        XCTAssertNil(try ring.keyboxRecipient(deviceID: UUID()))
        // A refusal written before E2E has no key: no recipient.
        try sidecar.saveLinkRefusal(.init(
            deviceID: UUID().uuidString, name: "Old", scope: .private, reason: .usedCode, at: Date()))
        let legacyRefusal = try XCTUnwrap(try sidecar.linkRefusals().first { $0.name == "Old" })
        XCTAssertNil(try ring.keyboxRecipient(deviceID: try XCTUnwrap(UUID(uuidString: legacyRefusal.deviceID))))
    }

    func testPhoneOnlyCallsThrowWrongRole() throws {
        let ring = try keyring(try HubSyncState.inMemory(), store: InMemoryHubKeyStore())
        XCTAssertThrowsError(try ring.deviceSigner()) { XCTAssertEqual($0 as? SecureTransportError, .wrongRole) }
        XCTAssertThrowsError(try ring.hubAgreementPublicKey()) { XCTAssertEqual($0 as? SecureTransportError, .wrongRole) }
        XCTAssertThrowsError(try ring.linkNonce()) { XCTAssertEqual($0 as? SecureTransportError, .wrongRole) }
    }

    // MARK: - Schema (F27, F19)

    func testEveryKeyTableExistsAfterCreateSchema() throws {
        let sidecar = try HubSyncState.inMemory()
        let columns: [String: Set<String>] = try sidecar.queue.read { db in
            var result: [String: Set<String>] = [:]
            for table in ["hub_epochs", "devices", "link_refusals", "slice_state", "pending_devices", "revoked_devices", "relay_seen"] {
                result[table] = Set(try db.columns(in: table).map(\.name))
            }
            return result
        }
        XCTAssertEqual(columns["hub_epochs"], ["epoch", "sealed_keys", "created_at", "first_seq", "retired_at"])
        XCTAssertTrue(try XCTUnwrap(columns["devices"]).isSuperset(of: ["signing_key", "agreement_key", "link_nonce", "last_seq"]))
        XCTAssertTrue(try XCTUnwrap(columns["link_refusals"]).contains("agreement_key"))
        XCTAssertTrue(try XCTUnwrap(columns["slice_state"]).contains("wire_name"))
        XCTAssertEqual(columns["pending_devices"], [
            "device_id", "name", "model", "scope", "user_record_name", "signing_key", "agreement_key", "link_nonce", "sas",
            "received_at"
        ])
        XCTAssertEqual(columns["revoked_devices"], ["device_id", "agreement_key", "removed_at"])
        XCTAssertEqual(columns["relay_seen"], ["wire_name", "sender_id", "epoch", "seq", "at"])
    }

    func testAnOldSidecarGainsTheKeyColumns() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hubstate-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        // A pre-E2E sidecar: the old shapes of the three widened tables.
        let old = try DatabaseQueue(path: path)
        try old.write { db in
            try db.execute(sql: """
                CREATE TABLE slice_state (record_name TEXT PRIMARY KEY, payload_hash TEXT NOT NULL, pushed_at REAL NOT NULL DEFAULT 0);
                CREATE TABLE devices (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL,
                    user_record_name TEXT NOT NULL, linked_at REAL NOT NULL, typing_allowed INTEGER NOT NULL DEFAULT 0,
                    start_sessions_allowed INTEGER NOT NULL DEFAULT 1, decided_at REAL);
                CREATE TABLE link_refusals (device_id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL,
                    reason TEXT NOT NULL, at REAL NOT NULL);
                INSERT INTO devices (device_id, name, scope, user_record_name, linked_at) VALUES ('d1', 'Phone', 'private', '_owner', 0);
                """)
        }
        try old.close()
        let sidecar = try HubSyncState(path: path)
        XCTAssertEqual(try sidecar.linkedDevices().map(\.deviceID), ["d1"])
        let deviceColumns = try sidecar.queue.read { Set(try $0.columns(in: "devices").map(\.name)) }
        XCTAssertTrue(deviceColumns.isSuperset(of: ["signing_key", "agreement_key", "link_nonce", "last_seq"]))
        // Opening again is a no-op.
        XCTAssertNoThrow(try HubSyncState(path: path))
    }

    func testPlainNameForWireReadsSliceState() throws {
        let sidecar = try HubSyncState.inMemory()
        try sidecar.setHash("h", for: "workbench-7")
        try sidecar.queue.write {
            try $0.execute(sql: "UPDATE slice_state SET wire_name = 'wirename7' WHERE record_name = 'workbench-7'")
        }
        let index: any WireNameIndex = sidecar
        XCTAssertEqual(index.plainName(forWire: "wirename7"), "workbench-7")
        XCTAssertNil(index.plainName(forWire: "unknown"))
    }
}

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
        try ring.rotate(reason: .manual)
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
        try ring.rotate(reason: .manual)
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
        try ring.rotate(reason: .manual)
        XCTAssertTrue(try ring.acceptsRelayEpoch(2, deviceID: phone.deviceID))
        XCTAssertFalse(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
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

        try ring.rotate(reason: .manual)
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

    // MARK: - Rotation (Task 14, Review Focus 4)

    /// D3: the new epoch, the retired one, the removed device and the slice hash wipe are one transaction. A trigger
    /// makes the wipe (blanking every hash) fail after the epoch insert: nothing of the rotation is left, the device
    /// stays linked.
    func testRotationCommitsTheEpochAndTheHashWipeTogether() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let phone = newIdentity()
        let phoneID = phone.deviceID.uuidString
        try linkPhone(sidecar, identity: phone)
        try ring.record(wireName: "wire-1", senderID: phone.deviceID, epoch: 1, seq: 7)
        // A row trigger fires per row: the table must hold rows for it to fire. The wipe blanks hashes (an UPDATE;
        // the brief's DELETE trigger, adapted by the fix-round ruling: same property).
        try sidecar.setHash("h1", for: "workbench-1")
        try sidecar.setHash("h2", for: SliceKind.deviceGrant.recordName(id: phoneID))
        try sidecar.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_wipe BEFORE UPDATE ON slice_state BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        let epoch1 = try ring.epochKeys(1)
        let generation = try sidecar.generation()

        XCTAssertThrowsError(try ring.rotate(reason: .removed(phoneID)))
        XCTAssertThrowsError(try ring.rotate(reason: .manual))

        XCTAssertEqual(try ring.currentEpoch(), 1)
        XCTAssertEqual(try sidecar.latestEpochs().map(\.epoch), [1], "no second epoch was kept")
        XCTAssertNil(try sidecar.storedEpoch(1)?.retiredAt, "epoch 1 is not retired")
        XCTAssertEqual(try ring.epochKeys(1), epoch1)
        XCTAssertEqual(try sidecar.hashes(forKind: .workbench), ["workbench-1": "h1"], "the hashes are intact")
        XCTAssertEqual(try sidecar.hashes(forKind: .deviceGrant).count, 1)
        XCTAssertEqual(try sidecar.generation(), generation)
        XCTAssertNotNil(try sidecar.linkedDevice(phoneID), "the device is still linked")
        XCTAssertNotNil(try sidecar.deviceKeyRow(phoneID))
        XCTAssertNotNil(try sidecar.relaySeen(wireName: "wire-1", senderID: phoneID))
        XCTAssertEqual(try revokedCount(sidecar), 0)
        XCTAssertTrue(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))

        // Without the trigger the same rotation commits all of it.
        try sidecar.queue.write { try $0.execute(sql: "DROP TRIGGER fail_wipe") }
        try ring.rotate(reason: .removed(phoneID))

        XCTAssertEqual(try ring.currentEpoch(), 2)
        XCTAssertNotNil(try sidecar.storedEpoch(1)?.retiredAt)
        XCTAssertEqual(try ring.epochKeys(1), epoch1, "the previous epoch's keys stay readable")
        XCTAssertEqual(try sidecar.hashes(forKind: .workbench), ["workbench-1": ""], "kept, blanked: republished")
        XCTAssertEqual(Array(try sidecar.hashes(forKind: .deviceGrant).values), [""])
        XCTAssertGreaterThan(try sidecar.generation(), generation, "an in-flight publish cycle aborts")
        XCTAssertNil(try sidecar.linkedDevice(phoneID))
        XCTAssertNil(try sidecar.relaySeen(wireName: "wire-1", senderID: phoneID), "its relay_seen rows go (F3)")
        XCTAssertEqual(try revokedCount(sidecar), 1)
        XCTAssertFalse(try ring.acceptsRelayEpoch(1, deviceID: phone.deviceID))
        XCTAssertFalse(try ring.acceptsRelayEpoch(2, deviceID: phone.deviceID))
    }

    /// Review Focus 4: a hub process killed right after a rotation committed comes back on that epoch; its next
    /// start neither forks nor repeats the rotation.
    func testAKilledRotationResumesOnTheSameEpoch() throws {
        let sidecar = try HubSyncState.inMemory()
        let store = InMemoryHubKeyStore()
        let clock = LinkTestClock()
        var ring: HubKeyring? = try keyring(sidecar, store: store, clock: clock)
        try XCTUnwrap(ring).ensureGroupKeys()
        clock.advance(HubKeyring.rotationAge)
        XCTAssertTrue(try XCTUnwrap(ring).rotateIfDue())
        let epoch2 = try XCTUnwrap(ring).epochKeys(2)
        ring = nil

        let restarted = try keyring(sidecar, store: store, clock: clock)
        try restarted.ensureGroupKeys()
        XCTAssertFalse(try restarted.rotateIfDue(), "the committed rotation is not repeated")
        clock.advance(86_400)
        XCTAssertFalse(try restarted.rotateIfDue())

        XCTAssertEqual(try restarted.currentEpoch(), 2)
        XCTAssertEqual(try restarted.epochKeys(2), epoch2)
        XCTAssertEqual(try sidecar.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hub_epochs") }, 2)
    }

    func testRotationWithoutAnEpochOnlyRemovesTheDevice() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        let phone = newIdentity()
        try linkPhone(sidecar, identity: phone)

        try ring.rotate(reason: .manual)
        try ring.rotate(reason: .removed(phone.deviceID.uuidString))

        XCTAssertNil(try sidecar.linkedDevice(phone.deviceID.uuidString))
        XCTAssertTrue(try sidecar.latestEpochs().isEmpty, "nothing was ever sealed: no epoch to rotate")
    }

    func testRemovingAnUnlinkedDeviceDoesNotRotate() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()

        try ring.rotate(reason: .removed(UUID().uuidString))

        XCTAssertEqual(try ring.currentEpoch(), 1)
    }

    /// Two hub processes over one file: a rotation prepared for an epoch another process already created fails
    /// instead of forking it.
    func testARotationRacingAnotherProcessFailsInsteadOfForking() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        try ring.rotate(reason: .manual)

        XCTAssertThrowsError(try sidecar.rotate(newEpoch: (epoch: 2, sealedKeys: Data(repeating: 1, count: 92)), at: Date())) {
            XCTAssertEqual($0 as? HubKeyringError, .epochRaced(2))
        }
        XCTAssertThrowsError(try sidecar.rotate(newEpoch: (epoch: 4, sealedKeys: Data(repeating: 1, count: 92)), at: Date())) {
            XCTAssertEqual($0 as? HubKeyringError, .epochRaced(4))
        }
        XCTAssertEqual(try ring.currentEpoch(), 2)
    }

    /// The last epoch has no successor: both rotation layers name it `epochOverflow`, and nothing is written.
    func testRotatingPastTheLastEpochIsAnOverflow() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let last = try XCTUnwrap(try sidecar.storedEpoch(1))
        try sidecar.queue.write { db in
            try HubSyncState.insertEpoch(.init(
                epoch: .max, sealedKeys: last.sealedKeys, createdAt: last.createdAt, firstSeq: 0, retiredAt: nil), db)
        }

        XCTAssertThrowsError(try ring.rotate(reason: .manual)) { XCTAssertEqual($0 as? HubKeyringError, .epochOverflow) }
        XCTAssertThrowsError(try sidecar.rotate(newEpoch: (epoch: 0, sealedKeys: Data(repeating: 1, count: 92)), at: Date())) {
            XCTAssertEqual($0 as? HubKeyringError, .epochOverflow)
        }
        XCTAssertEqual(try ring.currentEpoch(), .max)
    }

    /// Spec §2.2: the remaining phones get the new epoch and the one just retired while its records are
    /// republished (the D10 grace), then the new one only.
    func testKeyboxKeysCarryThePreviousEpochDuringItsGrace() throws {
        let sidecar = try HubSyncState.inMemory()
        let clock = LinkTestClock()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore(), clock: clock)
        try ring.ensureGroupKeys()
        XCTAssertNil(try ring.keyboxKeys().previousEpoch)
        let epoch1 = try ring.epochKeys(1)

        try ring.rotate(reason: .cap)
        let keys = try ring.keyboxKeys()
        XCTAssertEqual(keys.epoch, 2)
        XCTAssertEqual(keys.dataKey, WireBytes.base64URL(try ring.epochKeys(2).dataKey))
        XCTAssertEqual(keys.previousEpoch, 1)
        XCTAssertEqual(keys.previousDataKey, WireBytes.base64URL(epoch1.dataKey))
        XCTAssertEqual(keys.previousAlertKey, WireBytes.base64URL(epoch1.alertKey))

        clock.advance(HubKeyring.previousEpochGrace)
        let later = try ring.keyboxKeys()
        XCTAssertEqual(later.epoch, 2)
        XCTAssertNil(later.previousEpoch)
        XCTAssertNil(later.previousDataKey)
        XCTAssertNil(later.previousAlertKey)
    }

    /// Task 11: a rotation republishes the open ask alerts under the new `K_alert` (their generation follows the
    /// bump) without re-saving their signals (the alert hashes stay known, blanked).
    func testRotationKeepsAlertsPublishableAndTheirSignalsKnown() throws {
        let sidecar = try HubSyncState.inMemory()
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        try ring.ensureGroupKeys()
        let stamp = Date()
        _ = try sidecar.markAlerted([7], at: stamp)
        try sidecar.setHash("alert-hash", for: SliceKind.askAlert.recordName(id: "7"))

        try ring.rotate(reason: .manual)

        let (generation, alerted) = try sidecar.markAlerted([], at: stamp)
        XCTAssertEqual(alerted[7]?.generation, generation, "the alert is still published in the new generation")
        let hashes = try sidecar.hashes(forKind: .askAlert)
        XCTAssertEqual(Array(hashes.keys), [SliceKind.askAlert.recordName(id: "7")], "its record stays known")
        XCTAssertNotEqual(hashes.values.first, "alert-hash", "but its hash no longer matches: it is resealed")
    }

    private func revokedCount(_ sidecar: HubSyncState) throws -> Int {
        try sidecar.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM revoked_devices") ?? 0 }
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

    /// Task 15: a crash between the three Keychain adds leaves a partial identity. It is deleted and recreated
    /// (never `.corrupt` on every launch); with a pairing in the sidecar that is a recreated identity (the hard cut).
    func testAPartialIdentityIsDeletedAndRecreated() throws {
        let backend = InMemoryKeychainBackend()
        _ = try backend.add(
            Data(repeating: 1, count: 32), account: "hubid.\(hubID).sig", access: .afterFirstUnlock, group: nil,
            dataProtection: true)
        let sidecar = try HubSyncState.inMemory()
        try linkPhone(sidecar, identity: newIdentity())

        let ring = try keyring(sidecar, store: KeychainHubKeyStore(backend: backend))

        XCTAssertTrue(ring.identityWasRecreated, "the old pairing cannot be used")
        let again = try keyring(sidecar, store: KeychainHubKeyStore(backend: backend))
        XCTAssertFalse(again.identityWasRecreated, "the recreated identity is whole")
        XCTAssertEqual(again.signingPublicKey.rawRepresentation, ring.signingPublicKey.rawRepresentation)
    }

    /// Review fix 1: a `.corrupt` read can be another creator mid-creation; the read is retried once, and an
    /// identity whole on the retry is kept (nothing deleted).
    func testACorruptReadThatIsWholeOnTheRetryDeletesNothing() throws {
        let store = FlakyHubKeyStore()
        let sidecar = try HubSyncState.inMemory()
        try linkPhone(sidecar, identity: newIdentity())

        let ring = try keyring(sidecar, store: store)

        XCTAssertEqual(store.deletes, 0, "an identity whole on the retry is never deleted")
        XCTAssertEqual(store.reads, 2)
        XCTAssertFalse(ring.identityWasRecreated)
    }

    func testAnUnparseableIdentityWithoutAPairingIsRecreatedQuietly() throws {
        let backend = InMemoryKeychainBackend()
        for (suffix, size) in [("sig", 32), ("kx", 32), ("wrap", 5)] {
            _ = try backend.add(
                Data(repeating: 2, count: size), account: "hubid.\(hubID).\(suffix)", access: .afterFirstUnlock,
                group: nil, dataProtection: true)
        }
        let ring = try keyring(try HubSyncState.inMemory(), store: KeychainHubKeyStore(backend: backend))
        XCTAssertFalse(ring.identityWasRecreated, "nothing was paired under the damaged identity")
        try ring.ensureGroupKeys()
        XCTAssertNoThrow(try ring.metaKey())
    }

    /// The flag holds until the old pairing is gone: `resetGroupKeys` (the cut's forget) clears it, so a second
    /// start in the same run does not cut again.
    func testResettingTheGroupKeysClearsTheRecreatedFlag() throws {
        let sidecar = try HubSyncState.inMemory()
        try linkPhone(sidecar, identity: newIdentity())
        let ring = try keyring(sidecar, store: InMemoryHubKeyStore())
        XCTAssertTrue(ring.identityWasRecreated)
        try ring.resetGroupKeys()
        XCTAssertFalse(ring.identityWasRecreated)
    }

    /// The probe behind the cut's crash window: group keys sealed under another identity do not open.
    func testStoredGroupKeysUnreadableUnderAnotherIdentity() throws {
        let sidecar = try HubSyncState.inMemory()
        let later = try keyring(sidecar, store: InMemoryHubKeyStore())
        XCTAssertFalse(try later.storedGroupKeysUnreadable(), "no keys stored yet")
        let first = try keyring(sidecar, store: InMemoryHubKeyStore())
        try first.ensureGroupKeys()
        XCTAssertFalse(try first.storedGroupKeysUnreadable())
        XCTAssertTrue(try later.storedGroupKeysUnreadable())
        try later.resetGroupKeys()
        XCTAssertFalse(try later.storedGroupKeysUnreadable())
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
            "received_at", "typing_requested", "confirm_nonce", "start_sessions"
        ])
        XCTAssertEqual(columns["revoked_devices"], ["device_id", "agreement_key", "removed_at", "name", "scope"])
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

    /// A sidecar from before B18 met E2E: its `pending_devices` gains `typing_requested` (unrequested),
    /// `confirm_nonce` and `start_sessions` (allowed) in place.
    func testAPendingDevicesTableWithoutTheTypingRequestGainsIt() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hubstate-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = try DatabaseQueue(path: path)
        try old.write { db in
            try db.execute(sql: """
                CREATE TABLE pending_devices (device_id TEXT PRIMARY KEY, name TEXT, model TEXT, scope TEXT,
                    user_record_name TEXT, signing_key BLOB, agreement_key BLOB, link_nonce TEXT, sas TEXT, received_at REAL);
                INSERT INTO pending_devices VALUES ('d1', 'Phone', 'iPhone18,1', 'private', '_owner', x'01', x'02', 'n', '1234', 0);
                """)
        }
        try old.close()
        let sidecar = try HubSyncState(path: path)
        let columns = try sidecar.queue.read { Set(try $0.columns(in: "pending_devices").map(\.name)) }
        XCTAssertTrue(columns.isSuperset(of: ["typing_requested", "confirm_nonce", "start_sessions"]))
        let typing = try sidecar.queue.read { try Bool.fetchAll($0, sql: "SELECT typing_requested FROM pending_devices") }
        XCTAssertEqual(typing, [false])
        let startSessions = try sidecar.queue.read { try Int.fetchAll($0, sql: "SELECT start_sessions FROM pending_devices") }
        XCTAssertEqual(startSessions, [1], "an existing request keeps the start-sessions default")
        // Pairing code v2: a request stored before it has no confirm nonce, so no phone can show its code: it is
        // never offered for a Link.
        XCTAssertTrue(try sidecar.pendingDevices().isEmpty)
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

/// Throws `.corrupt` on its first read (another creator mid-creation), then loads an existing identity.
private final class FlakyHubKeyStore: HubKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var deleteCount = 0
    private let keys = HubIdentityKeys(
        signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey(),
        wrapKey: SymmetricKey(size: .bits256))

    var reads: Int { lock.withLock { readCount } }
    var deletes: Int { lock.withLock { deleteCount } }

    func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool) {
        let first = lock.withLock {
            readCount += 1
            return readCount == 1
        }
        if first { throw KeyStoreError.corrupt("hub identity is partially present") }
        return (keys, false)
    }

    func deleteHubIdentity(hubID: String) throws {
        lock.withLock { deleteCount += 1 }
    }
}

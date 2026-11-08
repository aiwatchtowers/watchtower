import CryptoKit
import Foundation
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The phone's half of the weekly relay keys (relay client Phase 5, "The scheme"): the offered and current
/// ephemeral keys on `HubLinkKeys`, the per-epoch stored pair a keybox's `relay_kx` derives, and the provider's rule
/// for which relay key an epoch uses.
final class EphemeralKeysTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hubID = TestE2E.hubID.uuidString

    // MARK: - Fixtures

    private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    private func b64(_ data: Data) -> String { WireBytes.base64URL(data) }

    private func link(epochs: [EpochKeys] = [], current: EphemeralKey? = nil, offered: EphemeralKey? = nil) -> HubLinkKeys {
        HubLinkKeys(
            hubID: hubID,
            hubSigningKey: TestE2E.hubSigningKey.publicKey.rawRepresentation,
            hubAgreementKey: TestE2E.hubAgreementKey.publicKey.rawRepresentation,
            linkNonce: TestE2E.linkNonce,
            metaKey: raw(TestE2E.metaKey),
            epochs: epochs,
            currentKX: current,
            offeredKX: offered)
    }

    private func epoch(_ number: UInt32, pair: EpochRelayKeys? = nil, supersededAt: Date? = nil) -> EpochKeys {
        EpochKeys(
            epoch: number, dataKey: raw(TestE2E.dataKey(epoch: number)), alertKey: raw(TestE2E.alertKey(epoch: number)),
            supersededAt: supersededAt, relayKeys: pair)
    }

    private func kx(_ hubEph: Curve25519.KeyAgreement.PrivateKey, _ devicePub: Data) -> KeyboxRelayKX {
        KeyboxRelayKX(hubPub: b64(hubEph.publicKey.rawRepresentation), devicePub: b64(devicePub))
    }

    private func box(
        _ number: UInt32, relayKX: KeyboxRelayKX? = nil, previous: UInt32? = nil, previousRelayKX: KeyboxRelayKX? = nil
    ) -> KeyboxKeys {
        KeyboxKeys(
            epoch: number,
            dataKey: b64(raw(TestE2E.dataKey(epoch: number))),
            alertKey: b64(raw(TestE2E.alertKey(epoch: number))),
            metaKey: b64(raw(TestE2E.metaKey)),
            previousEpoch: previous,
            previousDataKey: previous.map { b64(raw(TestE2E.dataKey(epoch: $0))) },
            previousAlertKey: previous.map { b64(raw(TestE2E.alertKey(epoch: $0))) },
            relayKX: relayKX,
            previousRelayKX: previousRelayKX)
    }

    private func merge(_ keys: HubLinkKeys, _ box: KeyboxKeys) throws -> KeyboxMerge {
        try keys.merging(box, identity: TestE2E.deviceIdentity, hubID: TestE2E.hubID, deviceID: TestE2E.deviceID, now: now)
    }

    /// The pair as the hub derives it from its side: its own ephemeral and static private keys, the phone's publics.
    private func hubPair(_ hubEph: Curve25519.KeyAgreement.PrivateKey, _ devicePub: Data, epoch: UInt32) throws -> EpochRelayKeys {
        let deviceEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePub)
        func key(_ direction: RelayDirection) throws -> Data {
            raw(try KeyDerivation.ephemeralRelayKey(
                ownEphemeral: hubEph, peerEphemeral: deviceEph,
                ownStatic: TestE2E.hubAgreementKey, peerStatic: TestE2E.deviceIdentity.agreement.publicKey,
                hubEphemeralPublic: hubEph.publicKey.rawRepresentation, deviceEphemeralPublic: devicePub,
                linkNonce: TestE2E.linkNonce, hubID: TestE2E.hubID, deviceID: TestE2E.deviceID, epoch: epoch,
                direction: direction))
        }
        return EpochRelayKeys(p2h: try key(.phoneToHub), h2p: try key(.hubToPhone))
    }

    private func staticKey(_ direction: RelayDirection, epoch: UInt32) throws -> Data {
        raw(try KeyDerivation.relayKey(
            agreementPrivate: TestE2E.deviceIdentity.agreement, peerPublic: TestE2E.hubAgreementKey.publicKey,
            linkNonce: TestE2E.linkNonce, hubID: TestE2E.hubID, deviceID: TestE2E.deviceID, epoch: epoch,
            direction: direction))
    }

    private func pair(_ seed: UInt8) -> EpochRelayKeys {
        EpochRelayKeys(p2h: Data(repeating: seed, count: 32), h2p: Data(repeating: seed &+ 1, count: 32))
    }

    private func encoded(_ keys: HubLinkKeys) throws -> String {
        try XCTUnwrap(String(bytes: try JSONEncoder().encode(keys), encoding: .utf8))
    }

    private func provider(_ keys: HubLinkKeys) throws -> (PhoneKeyProvider, InMemoryPhoneKeyStore) {
        let store = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        try store.saveHubLink(keys)
        return (try TestE2E.phone(store: store), store)
    }

    // MARK: - Merge

    func testMergeDerivesPromotesAndErases() throws {
        let current = EphemeralKey.generate()
        let offered = EphemeralKey.generate()
        let hubEph1 = Curve25519.KeyAgreement.PrivateKey()
        let hubEph2 = Curve25519.KeyAgreement.PrivateKey()
        let before = link(epochs: [epoch(1)], current: current, offered: offered)
        let result = try merge(before, box(
            2, relayKX: kx(hubEph2, offered.publicKey), previous: 1, previousRelayKX: kx(hubEph1, current.publicKey)))

        let merged = result.keys
        XCTAssertEqual(merged.epochs.map(\.epoch), [1, 2])
        // The hub derives the same pair from its side: the transcript publics match the keys of the agreement.
        XCTAssertEqual(merged.epochs.first { $0.epoch == 2 }?.relayKeys, try hubPair(hubEph2, offered.publicKey, epoch: 2))
        XCTAssertEqual(merged.epochs.first { $0.epoch == 1 }?.relayKeys, try hubPair(hubEph1, current.publicKey, epoch: 1))
        XCTAssertEqual(merged.epochs.first { $0.epoch == 1 }?.supersededAt, now)
        XCTAssertEqual(merged.currentKX, offered, "the offer the keybox named is promoted")
        XCTAssertNil(merged.offeredKX)
        XCTAssertFalse(result.droppedNewestPair)
        let item = try encoded(merged)
        XCTAssertFalse(item.contains(current.privateKey.base64EncodedString()), "the older private key is erased")
    }

    func testMergeDerivesThePreviousEpochTooWhenMissing() throws {
        // Offline for one rotation (F6): the hub reused the last offer for both epochs.
        let offered = EphemeralKey.generate()
        let hubEph2 = Curve25519.KeyAgreement.PrivateKey()
        let hubEph3 = Curve25519.KeyAgreement.PrivateKey()
        let result = try merge(link(epochs: [epoch(1)], offered: offered), box(
            3, relayKX: kx(hubEph3, offered.publicKey), previous: 2, previousRelayKX: kx(hubEph2, offered.publicKey)))
        XCTAssertEqual(result.keys.epochs.map(\.epoch), [1, 2, 3])
        XCTAssertNil(result.keys.epochs.first { $0.epoch == 1 }?.relayKeys, "epoch 1 stays static")
        XCTAssertEqual(result.keys.epochs.first { $0.epoch == 2 }?.relayKeys, try hubPair(hubEph2, offered.publicKey, epoch: 2))
        XCTAssertEqual(result.keys.epochs.first { $0.epoch == 3 }?.relayKeys, try hubPair(hubEph3, offered.publicKey, epoch: 3))
        XCTAssertEqual(result.keys.currentKX, offered)
        XCTAssertNil(result.keys.offeredKX)
    }

    func testAPairMissingOnAHeldEpochStillMerges() throws {
        let offered = EphemeralKey.generate()
        let hubEph = Curve25519.KeyAgreement.PrivateKey()
        let result = try merge(link(epochs: [epoch(2)], offered: offered), box(2, relayKX: kx(hubEph, offered.publicKey)))
        XCTAssertEqual(result.keys.epochs.first?.relayKeys, try hubPair(hubEph, offered.publicKey, epoch: 2))
        XCTAssertEqual(result.keys.currentKX, offered)
    }

    func testMergeWithoutRelayKXIsStatic() throws {
        let offered = EphemeralKey.generate()
        let result = try merge(link(epochs: [epoch(1)], offered: offered), box(2, previous: 1))
        XCTAssertEqual(result.keys.epochs.map(\.epoch), [1, 2])
        XCTAssertTrue(result.keys.epochs.allSatisfy { $0.relayKeys == nil })
        XCTAssertEqual(result.keys.offeredKX, offered, "an unanswered offer stays")
        XCTAssertNil(result.keys.currentKX)
        XCTAssertFalse(result.droppedNewestPair)
    }

    func testAStaticKeyboxDropsThatEpochsPairAndOffersAgain() throws {
        let current = EphemeralKey.generate()
        let offered = EphemeralKey.generate()
        let before = link(epochs: [epoch(1, pair: pair(1)), epoch(2, pair: pair(3))], current: current, offered: offered)
        let result = try merge(before, box(2, previous: 1))
        XCTAssertTrue(result.droppedNewestPair)
        XCTAssertTrue(result.keys.epochs.allSatisfy { $0.relayKeys == nil }, "the hub cleared this phone's rows")
        XCTAssertEqual(result.keys.offeredKX, offered, "the offer stays for the ack that follows")
        XCTAssertEqual(result.keys.currentKX, current)
    }

    func testAStaticKeyboxWithNoPairReportsNothing() throws {
        let result = try merge(link(epochs: [epoch(2)], offered: EphemeralKey.generate()), box(2))
        XCTAssertFalse(result.droppedNewestPair)
    }

    func testRepeatedMergesReportOnce() throws {
        let before = link(epochs: [epoch(2, pair: pair(5))], offered: EphemeralKey.generate())
        let first = try merge(before, box(2))
        XCTAssertTrue(first.droppedNewestPair)
        let second = try merge(first.keys, box(2))
        XCTAssertFalse(second.droppedNewestPair)
        XCTAssertEqual(second.keys, first.keys)

        // A derived keybox read again: its named keys are erased by now, yet the held pairs make it a no-op.
        let current = EphemeralKey.generate()
        let offered = EphemeralKey.generate()
        let derived = box(2, relayKX: kx(.init(), offered.publicKey), previous: 1, previousRelayKX: kx(.init(), current.publicKey))
        let once = try merge(link(epochs: [epoch(1)], current: current, offered: offered), derived)
        let twice = try merge(once.keys, derived)
        XCTAssertEqual(twice.keys, once.keys)
        XCTAssertFalse(twice.droppedNewestPair)
    }

    func testAKeyboxNamingAnUnknownKeyIsNotMerged() throws {
        let offered = EphemeralKey.generate()
        let before = link(epochs: [epoch(1)], offered: offered)
        let stranger = EphemeralKey.generate()
        XCTAssertThrowsError(try merge(before, box(2, relayKX: kx(.init(), stranger.publicKey)))) { error in
            XCTAssertEqual(error as? KeyboxKeysError, .unknownEphemeral)
        }
        // Through the store: the link is kept as it was, nothing wiped (F17).
        let store = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        try store.saveHubLink(before)
        let unknown = box(2, relayKX: kx(.init(), stranger.publicKey))
        XCTAssertThrowsError(try store.updateHubLink(hubID) { keys in try self.merge(keys, unknown).keys }) {
            XCTAssertEqual($0 as? KeyboxKeysError, .unknownEphemeral)
        }
        XCTAssertEqual(try store.hubLink(hubID), before)
    }

    /// Caller contract of `KeyDerivation.ephemeralRelayKey` (Task 1 review): the transcript's device public must be
    /// the public of the private key used. A stored pair whose halves disagree is refused, never derived from.
    func testAMismatchedEphemeralPairIsRefusedNotDerived() throws {
        let real = EphemeralKey.generate()
        let other = EphemeralKey.generate()
        let mismatched = EphemeralKey(publicKey: real.publicKey, privateKey: other.privateKey)
        XCTAssertThrowsError(try merge(link(epochs: [epoch(1)], offered: mismatched), box(2, relayKX: kx(.init(), real.publicKey)))) {
            XCTAssertEqual($0 as? KeyStoreError, .corrupt("an ephemeral key's halves do not match"))
        }
    }

    func testAMalformedHubEphemeralIsRefused() throws {
        let offered = EphemeralKey.generate()
        let bad = KeyboxRelayKX(hubPub: b64(Data(repeating: 1, count: 31)), devicePub: b64(offered.publicKey))
        XCTAssertThrowsError(try merge(link(epochs: [epoch(1)], offered: offered), box(2, relayKX: bad))) {
            XCTAssertEqual($0 as? KeyboxKeysError, .badKey)
        }
    }

    func testMergeIsOneKeychainWrite() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainPhoneKeyStore(backend: backend, privateGroup: "TEAM.private", alertGroup: "TEAM.alerts") { self.now }
        let offered = EphemeralKey.generate()
        try store.saveHubLink(link(epochs: [epoch(1)], current: EphemeralKey.generate(), offered: offered))
        let before = backend.writes.filter { $0.account == "hub.\(hubID)" }.count
        let hubEph = Curve25519.KeyAgreement.PrivateKey()
        let stored = try store.updateHubLink(hubID) { try self.merge($0, self.box(2, relayKX: self.kx(hubEph, offered.publicKey), previous: 1)).keys }
        XCTAssertEqual(backend.writes.filter { $0.account == "hub.\(hubID)" }.count, before + 1, "derive and promote land together (F13)")
        let read = try XCTUnwrap(store.hubLink(hubID))
        XCTAssertEqual(read, stored)
        XCTAssertEqual(read.currentKX, offered)
        XCTAssertNil(read.offeredKX)
        XCTAssertEqual(read.epochs.last?.relayKeys, try hubPair(hubEph, offered.publicKey, epoch: 2))
    }

    // MARK: - Offer, clear, drop

    func testWithOfferDrawsOnceAndIsANoOpWhenOneExists() throws {
        let (first, publicKey) = link(epochs: [epoch(1)]).withOffer()
        let offer = try XCTUnwrap(first.offeredKX)
        XCTAssertEqual(offer.publicKey, publicKey)
        XCTAssertEqual(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: offer.privateKey).publicKey.rawRepresentation, publicKey)
        let (second, again) = first.withOffer()
        XCTAssertEqual(second, first)
        XCTAssertEqual(again, publicKey)
    }

    func testClearingKeepsPairsAndDroppingRemovesThem() throws {
        let keys = link(epochs: [epoch(1, pair: pair(1)), epoch(2, pair: pair(3))], current: .generate(), offered: .generate())
        let cleared = keys.clearingEphemeral()
        XCTAssertNil(cleared.currentKX)
        XCTAssertNil(cleared.offeredKX)
        XCTAssertEqual(cleared.epochs.map(\.relayKeys), [pair(1), pair(3)])
        let dropped = keys.droppingEphemeral()
        XCTAssertNil(dropped.currentKX)
        XCTAssertNil(dropped.offeredKX)
        XCTAssertTrue(dropped.epochs.allSatisfy { $0.relayKeys == nil })
        XCTAssertEqual(dropped.epochs.map(\.epoch), [1, 2], "the epochs stay, static")
    }

    // MARK: - Retention and the data zone

    func testRowsInAnErasedEpochStayPendingUntilRepublished() throws {
        // F22: the hub was closed for over 7 days after a partial republish; the phone dropped epoch 1 on schedule.
        let store = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        try store.saveHubLink(link(
            epochs: [epoch(1, pair: pair(1), supersededAt: Date().addingTimeInterval(-8 * 86_400)), epoch(2, pair: pair(3))],
            current: .generate()))
        let phone = try TestE2E.phone(store: store)
        XCTAssertEqual(try store.hubLink(hubID)?.epochs.map(\.epoch), [2])
        // A data-zone row sealed in epoch 1 waits (token kept) rather than being dropped as gone.
        XCTAssertThrowsError(try phone.dataKey(epoch: 1)) { XCTAssertEqual($0 as? SecureTransportError, .keysUnavailable) }
        XCTAssertThrowsError(try phone.alertKey(epoch: 1)) { XCTAssertEqual($0 as? SecureTransportError, .keysUnavailable) }
    }

    // MARK: - The provider's rule ("The scheme")

    func testRelayKey_presentWithAStoredPair() throws {
        let (phone, _) = try provider(link(epochs: [epoch(1, pair: pair(1))], current: .generate()))
        XCTAssertEqual(raw(try phone.relayKey(.phoneToHub, deviceID: TestE2E.deviceID, epoch: 1)), pair(1).p2h)
        XCTAssertEqual(raw(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 1)), pair(1).h2p)
    }

    func testRelayKey_presentWithNoPairIsStatic() throws {
        let (phone, _) = try provider(link(epochs: [epoch(1), epoch(2, pair: pair(1))], current: .generate()))
        XCTAssertEqual(raw(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 1)), try staticKey(.hubToPhone, epoch: 1))
    }

    func testRelayKey_absentWithNoEphemeralStateIsStaticForAnyEpoch() throws {
        let (phone, _) = try provider(link(epochs: [epoch(2)]))
        XCTAssertEqual(raw(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 1)), try staticKey(.hubToPhone, epoch: 1))
        XCTAssertEqual(raw(try phone.relayKey(.phoneToHub, deviceID: TestE2E.deviceID, epoch: 9)), try staticKey(.phoneToHub, epoch: 9))
    }

    func testRelayKey_absentAboveTheNewestIsPending() throws {
        let (phone, _) = try provider(link(epochs: [epoch(2, pair: pair(1))], current: .generate()))
        XCTAssertThrowsError(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 3)) {
            XCTAssertEqual($0 as? SecureTransportError, .epochKeysPending)
        }
        // An offer alone is ephemeral state too: the first ephemeral keybox may be on its way.
        let (offering, _) = try provider(link(epochs: [epoch(2)], offered: .generate()))
        XCTAssertThrowsError(try offering.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 3)) {
            XCTAssertEqual($0 as? SecureTransportError, .epochKeysPending)
        }
    }

    func testRelayKey_absentAtOrBelowTheNewestIsGone() throws {
        let (phone, _) = try provider(link(epochs: [epoch(3, pair: pair(1)), epoch(5, pair: pair(3))], current: .generate()))
        for missing: UInt32 in [1, 4] {
            XCTAssertThrowsError(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: missing)) {
                XCTAssertEqual($0 as? SecureTransportError, .epochKeysGone)
            }
        }
    }

    func testProviderHoldsNoEphemeralRelayKeyInItsCache() throws {
        let (phone, store) = try provider(link(epochs: [epoch(1, pair: pair(1))], current: .generate()))
        XCTAssertEqual(raw(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 1)), pair(1).h2p)
        // The hub cleared this phone (an opened `hub_on_relay`): the next read follows the store, not memory.
        _ = try store.updateHubLink(hubID) { $0.droppingEphemeral() }
        XCTAssertEqual(raw(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 1)), try staticKey(.hubToPhone, epoch: 1))
        // A cached static key never shadows a pair that a later merge stored.
        _ = try store.updateHubLink(hubID) { keys in
            var copy = keys
            copy.epochs[0].relayKeys = self.pair(7)
            return copy
        }
        XCTAssertEqual(raw(try phone.relayKey(.hubToPhone, deviceID: TestE2E.deviceID, epoch: 1)), pair(7).h2p)
    }

    // MARK: - Keybox recipients

    func testKeyboxRecipientsAreTheOfferTheCurrentThenTheDeviceKey() throws {
        let current = EphemeralKey.generate()
        let offered = EphemeralKey.generate()
        let (phone, _) = try provider(link(epochs: [epoch(1)], current: current, offered: offered))
        XCTAssertEqual(
            try phone.keyboxRecipients().map(\.publicKey.rawRepresentation),
            [offered.publicKey, current.publicKey, TestE2E.deviceIdentity.agreement.publicKey.rawRepresentation])
        let (plain, _) = try provider(link(epochs: [epoch(1)]))
        XCTAssertEqual(
            try plain.keyboxRecipients().map(\.publicKey.rawRepresentation),
            [TestE2E.deviceIdentity.agreement.publicKey.rawRepresentation])
        XCTAssertThrowsError(try TestE2E.hub().keyboxRecipients()) {
            XCTAssertEqual($0 as? SecureTransportError, .wrongRole)
        }
    }
}

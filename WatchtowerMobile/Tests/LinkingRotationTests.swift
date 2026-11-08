import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

private let acme = TestE2E.hubID.uuidString

/// The link flow's keybox merge under relay key rotation (relay client Phase 5, Task 10): it goes through the host's
/// merge (`LinkHost.mergeKeybox`, one `updateHubLink`), keeps the old link on a failed write, writes nothing back after
/// an unlink, and refuses a keybox naming a key this phone does not hold, the link kept. The fake host and the real
/// LinkStore, as `LinkingViewModelTests`.
@MainActor
final class LinkingRotationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let identity = DeviceIdentity(
        deviceID: TestE2E.deviceID.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0"
    )
    private var container: FakeLinkAccess!
    private var host: FakeLinkHost!
    private var clock: FakeLinkClock!
    private var defaults: UserDefaults!
    private var keyStore: InMemoryPhoneKeyStore!

    override func setUp() async throws {
        keyStore = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        let log = LinkEventLog()
        container = FakeLinkAccess(log: log)
        container.userRecordNameValue = "_owner-acme"
        host = FakeLinkHost(log: log)
        host.keys = keyStore
        clock = FakeLinkClock(now: start)
        defaults = try makeDefaults()
    }

    /// A linked model of the test hub (epoch 1 stored).
    private func linkedModel() async throws -> LinkingViewModel {
        let iat = Int64(clock.now().timeIntervalSince1970 - 10)
        let payload = LinkPayload(
            v: LinkPayload.currentVersion, hubID: acme, macName: "Acme Mac", ownerUser: "_owner-acme",
            nonce: LinkPayload.makeNonce(), iat: iat,
            exp: iat + LinkPayload.lifetime, dataShare: "https://www.icloud.com/share/acme-data",
            relayShare: "https://www.icloud.com/share/acme-relay",
            hubSigningKey: WireBytes.base64URL(TestE2E.hubSigningKey.publicKey.rawRepresentation),
            hubAgreementKey: WireBytes.base64URL(TestE2E.hubAgreementKey.publicKey.rawRepresentation))
        let deviceID = identity.deviceID ?? ""
        let start = start
        host.mac = { writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: deviceID, hubID: acme, name: "Colleague A's iPhone", scope: .private, linked: true,
                linkedAt: start, typingAllowed: false, startSessionsAllowed: true, decidedAt: start)
        }
        let model = LinkingViewModel(
            access: container, store: LinkStore(defaults: defaults), identity: identity, keys: keyStore, clock: clock)
        model.host = host
        await model.open(payload.url())
        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        await model.finish()
        XCTAssertTrue(model.hasLinks)
        return model
    }

    /// The epoch-2 keybox of the test hub, with epoch 1 as its previous one, optionally answering an offer.
    private func epoch2Keys(relayKX: KeyboxRelayKX? = nil) -> KeyboxKeys {
        KeyboxKeys(
            epoch: 2, dataKey: TestPhone.keyboxKeys(epoch: 2).dataKey, alertKey: TestPhone.keyboxKeys(epoch: 2).alertKey,
            metaKey: TestPhone.keyboxKeys().metaKey, previousEpoch: 1,
            previousDataKey: TestPhone.keyboxKeys(epoch: 1).dataKey, previousAlertKey: TestPhone.keyboxKeys(epoch: 1).alertKey,
            relayKX: relayKX
        )
    }

    /// F14: a Keychain write that fails during the merge leaves the old link and reports nothing; the next pass
    /// merges from the stored keybox.
    func testAFailedSaveKeepsTheOldLinkAndRetries() async throws {
        let model = try await linkedModel()
        let failing = UpdateFailingKeyStore(keyStore)
        host.keys = failing
        host.keyboxKeys = epoch2Keys()
        let before = try keyStore.hubLink(acme)

        await model.reconcileKeyboxKeys(hubID: acme)
        XCTAssertEqual(try keyStore.hubLink(acme), before, "the old link stays")
        XCTAssertEqual(host.keyMerges, 0, "nothing reported")

        await model.reconcileKeyboxKeys(hubID: acme)
        XCTAssertEqual(try keyStore.hubLink(acme)?.epochs.map(\.epoch), [1, 2])
        XCTAssertEqual(host.keyMergeRaised, [true])
        XCTAssertEqual(host.mergeCalls, 2)
    }

    /// An unlink that lands while a merge is under way wins: the merge writes nothing and reports nothing, and the
    /// link's keys stay gone.
    func testUnlinkDuringAMergeDoesNotResurrectTheLink() async throws {
        let model = try await linkedModel()
        host.keyboxKeys = epoch2Keys()
        host.parksMerge = true
        let merge = Task { await model.reconcileKeyboxKeys(hubID: acme) }
        while host.mergeCalls == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        await model.unlink(acme)
        host.parksMerge = false
        await merge.value

        XCTAssertNil(try keyStore.hubLink(acme), "not written back")
        XCTAssertEqual(host.keyMerges, 0)
    }

    /// F17: a keybox naming an ephemeral key this phone does not hold is refused, logged once however often it is read,
    /// the link and its keys kept; a keybox that merges ends the refusal.
    func testAKeyboxNamingAnUnknownKeyIsRefusedOnceAndTheLinkKept() async throws {
        let model = try await linkedModel()
        _ = try keyStore.updateHubLink(acme) { $0.withOffer().0 }
        let before = try keyStore.hubLink(acme)
        let unknown = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let hubEph = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        host.keyboxKeys = epoch2Keys(relayKX: KeyboxRelayKX(
            hubPub: WireBytes.base64URL(hubEph), devicePub: WireBytes.base64URL(unknown)))

        await model.reconcileKeyboxKeys(hubID: acme)
        await model.reconcileKeyboxKeys(hubID: acme)

        XCTAssertEqual(try keyStore.hubLink(acme), before, "nothing written")
        XCTAssertEqual(model.refusedKeyboxes, [acme])
        XCTAssertEqual(host.keyMerges, 0)
        XCTAssertEqual(model.links.first?.state, .linked, "the link kept")
        XCTAssertNil(model.notice)

        host.keyboxKeys = epoch2Keys()
        await model.reconcileKeyboxKeys(hubID: acme)
        XCTAssertEqual(try keyStore.hubLink(acme)?.epochs.map(\.epoch), [1, 2])
        XCTAssertTrue(model.refusedKeyboxes.isEmpty)
    }

    /// The switch keybox goes through the same merge as a fetched one (`mergeSwitchKeys`).
    func testASwitchKeyboxGoesThroughTheHostsMerge() async throws {
        let model = try await linkedModel()
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: acme, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true)

        let merged = await model.mergeSwitchKeys(Keybox(grant: grant, keys: epoch2Keys()), hubID: acme)

        XCTAssertTrue(merged)
        XCTAssertEqual(host.mergeCalls, 1)
        XCTAssertEqual(host.mergeReseals, [.droppedEpochs], "a switch moves only the rows of an epoch it drops")
        XCTAssertEqual(host.keyMergeRaised, [true])
        XCTAssertEqual(host.keyMergeDropped, [false])
    }
}

/// The phone's key store whose first `updateHubLink` fails as a Keychain write can (F14); every other call forwards.
private final class UpdateFailingKeyStore: PhoneKeyStore, @unchecked Sendable {
    private let inner: InMemoryPhoneKeyStore
    private var failures = 1

    init(_ inner: InMemoryPhoneKeyStore) {
        self.inner = inner
    }

    func identity() throws -> DeviceIdentityKeys { try inner.identity() }
    func existingIdentity() throws -> DeviceIdentityKeys? { try inner.existingIdentity() }
    func hubLink(_ hubID: String) throws -> HubLinkKeys? { try inner.hubLink(hubID) }
    func saveHubLink(_ keys: HubLinkKeys) throws { try inner.saveHubLink(keys) }
    func updateHubLink(_ hubID: String, _ change: (HubLinkKeys) throws -> HubLinkKeys) throws -> HubLinkKeys? {
        if failures > 0 {
            failures -= 1
            throw KeyStoreError.unexpected(-25_293)
        }
        return try inner.updateHubLink(hubID, change)
    }
    func removeHubLink(_ hubID: String) throws { try inner.removeHubLink(hubID) }
    func hubSigningKey(_ hubID: String) throws -> Curve25519.Signing.PublicKey? { try inner.hubSigningKey(hubID) }
    func alertMaterial(_ hubID: String) throws -> AlertMaterial? { try inner.alertMaterial(hubID) }
    func deviceID() throws -> UUID? { try inner.deviceID() }
}

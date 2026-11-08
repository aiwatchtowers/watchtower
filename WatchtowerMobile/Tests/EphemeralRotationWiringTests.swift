import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone runs relay key rotation (relay client Phase 5, Task 10): the live `AppRoot` over `Bed` (one hub with a
/// CloudKit route and a relay route on `FakeHostedRelay`). On a relay route every `epoch_ack` carries this phone's offer,
/// saved in the Keychain first; a merge goes through the session's merge and reports a raise and a dropped pair; a
/// merge or a return to the foreground wakes a parked feed and a raise kicks the uploader; a follow to iCloud erases
/// the private keys after the keybox merge. An iCloud route never offers: its bytes do not change.
@MainActor
final class EphemeralRotationWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString

    // MARK: - The offer

    func testARelayRoutePhoneOffersOnEveryRaise() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let first = try XCTUnwrap(try offer(bed), "the adoption's ack drew an offer and saved it")
        var acks = try await bed.relayControls(.epochAck)
        XCTAssertEqual(acks.map(\.epoch), [1])
        XCTAssertEqual(acks.map(\.nextKX), [WireBytes.base64URL(first)])

        await merge(bed, keybox(epoch: 2))
        try await settle(session)
        acks = try await bed.relayControls(.epochAck)
        XCTAssertEqual(acks.map(\.epoch), [1, 2], "one ack per raise")
        XCTAssertEqual(acks.map(\.nextKX), [WireBytes.base64URL(first), WireBytes.base64URL(first)], "the outstanding offer again")

        // The hub answers the offer at the next raise: it becomes the current key and a new offer goes out.
        await merge(bed, keybox(epoch: 3, relayKX: relayKX(naming: first)))
        try await settle(session)
        let link = try XCTUnwrap(try bed.keys.hubLink(hubID))
        XCTAssertEqual(link.currentKX?.publicKey, first)
        XCTAssertNotNil(link.epochs.last?.relayKeys, "epoch 3's pair is stored")
        let second = try XCTUnwrap(link.offeredKX?.publicKey)
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(try session.store.epochAckDue(3, nextKX: second), "epoch 3 acknowledged with the new offer")
    }

    /// "CloudKit crypto does not change": an iCloud route never draws an offer, and its acks' bytes carry no `next_kx`.
    func testAnICloudRoutePhoneNeverOffers() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let session = try await bed.orderedSession()

        await merge(bed, keybox(epoch: 2))
        try await settle(session)
        await session.keysBecameAvailable()
        try await settle(session)

        let link = try XCTUnwrap(try bed.keys.hubLink(hubID))
        XCTAssertFalse(link.hasEphemeralState, "no offer, no pair")
        XCTAssertEqual(link.epochs.map(\.epoch), [1, 2])
        let acks = try await openedPhoneControls(in: bed.cloud.inner).filter { $0.control.kind == .epochAck }
        XCTAssertEqual(acks.map(\.control.epoch), [1, 2])
        for ack in acks {
            XCTAssertNil(ack.control.nextKX)
            let text = String(bytes: ack.bytes, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("next_kx") || text.contains("nextKx"), "the control's bytes: \(text)")
        }
    }

    /// F12: killed after the offer was saved and before its ack was queued, the next boot sends it.
    func testAnOfferNotYetAckedGoesAtBoot() async throws {
        let bed = try await Bed.make(self, on: .relay)
        _ = try await bed.orderedSession()
        let carried = try XCTUnwrap(try offer(bed))
        _ = try bed.keys.updateHubLink(hubID) { link in
            var fresh = link
            fresh.offeredKX = nil
            return fresh.withOffer().0
        }
        let saved = try XCTUnwrap(try offer(bed))
        XCTAssertNotEqual(saved, carried)

        try await bed.relaunch(self)
        let next = try bed.session()
        await next.waitForBoot()
        try await settle(next)

        let acks = try await bed.relayControls(.epochAck)
        XCTAssertEqual(acks.map(\.epoch), [1, 1])
        XCTAssertEqual(acks.last?.nextKX, WireBytes.base64URL(saved), "the saved offer went out at boot")
    }

    /// A static keybox for an epoch that held a pair (the hub cleared this phone's relay keys) puts the offer out
    /// again, once: the merges that follow at each fetch and at the unlock change nothing and send nothing.
    func testADroppedPairSendsOneAckAcrossRepeatedMerges() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let first = try XCTUnwrap(try offer(bed))
        await merge(bed, keybox(epoch: 2, relayKX: relayKX(naming: first)))
        try await settle(session)
        let second = try XCTUnwrap(try offer(bed))
        XCTAssertNotNil(try bed.keys.hubLink(hubID)?.epochs.last?.relayKeys)
        let before = try await bed.relayMailbox().count

        await merge(bed, keybox(epoch: 2))
        try await settle(session)
        XCTAssertNil(try bed.keys.hubLink(hubID)?.epochs.last?.relayKeys, "the pair is dropped")
        let afterDrop = try await bed.relayMailbox().count
        XCTAssertEqual(afterDrop, before + 1, "one ack for the drop")
        XCTAssertFalse(try session.store.epochAckDue(2, nextKX: second), "it carries the outstanding offer")

        await merge(bed, keybox(epoch: 2))
        try await settle(session)
        try await bed.fetch(session)
        try await settle(session)
        await session.keysBecameAvailable()
        try await settle(session)
        let afterRepeats = try await bed.relayMailbox().count
        XCTAssertEqual(afterRepeats, before + 1, "the repeats send nothing")
    }

    func testTwoHubsKeepSeparateOffers() async throws {
        let store = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        var sessions: [String: HubSession] = [:]
        for (index, hub) in [TestHub.hubA, TestHub.hubB].enumerated() {
            let transport = InMemoryCloudTransport()
            let session = try HubSession(
                transport: transport, replicaPath: try makeReplicaPath(), backend: .live, hubID: hub,
                linkedDevice: device, keys: try TestHub.keys(hub, store: store), defaults: try makeDefaults(),
                recordingsDirectory: try makeRecordingsDirectory(), route: .hostedRelay(macDeviceID: "mac-\(index)"))
            closeAtTeardown(session)
            await session.waitForBoot()
            let grant = DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: hub, name: "Colleague A's iPhone", scope: .private,
                linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
            try await TestHub.hub(over: transport, hub).save([try TestPhone.grantRecord(grant, modifiedAt: Date())])
            _ = await session.refresh(.pull)
            try await settle(session)
            sessions[hub] = session
        }

        let offerA = try XCTUnwrap(try store.hubLink(TestHub.hubA)?.offeredKX?.publicKey)
        let offerB = try XCTUnwrap(try store.hubLink(TestHub.hubB)?.offeredKX?.publicKey)
        XCTAssertNotEqual(offerA, offerB, "one offer per Mac")
        let storeA = try XCTUnwrap(sessions[TestHub.hubA]).store
        let storeB = try XCTUnwrap(sessions[TestHub.hubB]).store
        XCTAssertFalse(try storeA.epochAckDue(1, nextKX: offerA), "A's ack carried A's offer")
        XCTAssertTrue(try storeA.epochAckDue(1, nextKX: offerB))
        XCTAssertFalse(try storeB.epochAckDue(1, nextKX: offerB), "B's ack carried B's offer")
        XCTAssertTrue(try storeB.epochAckDue(1, nextKX: offerA))
    }

    // MARK: - The parked feed

    func testKeysMergedWakesAParkedFeed() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let parkedAt = try await parkOnARecordInEpoch2(bed, session)

        await merge(bed, keybox(epoch: 2))
        try await bed.fetch(session)

        XCTAssertNil(try session.store.relayFeedParkedSince(), "the record was read: the wait ended")
        XCTAssertNotEqual(try session.store.relayToken()?.value, parkedAt, "the feed read past it")
    }

    func testAForegroundWakesAParkedFeed() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let parkedAt = try await parkOnARecordInEpoch2(bed, session)
        // Epoch 2's keys came while no merge was heard (another process, a locked pass).
        _ = try bed.keys.updateHubLink(hubID) { try $0.adding(TestPhone.keyboxKeys(epoch: 2)) }

        session.setActive(false)
        session.setActive(true)
        try await bed.fetch(session)

        XCTAssertNil(try session.store.relayFeedParkedSince())
        XCTAssertNotEqual(try session.store.relayToken()?.value, parkedAt)
    }

    // MARK: - Following the hub

    /// A follow to iCloud erases the private keys right after the keybox merge, never before it: a pass whose merge
    /// fails keeps them (the keybox may be sealed to them), and the next pass merges, then clears.
    func testFollowingToICloudClearsEphemeralState() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        XCTAssertNotNil(try offer(bed))
        let flaky = FollowerMergeFailsOnce(root: bed.root)
        let follower = TransportFollower(hubID: hubID, outbox: first.outbox, host: flaky)
        first.transportSignals.onControl = { control in await follower.handle(control: control, on: .relay) }

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        try await bed.fetch(first)
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit, "the move was written")
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1], "the merge failed")
        XCTAssertNotNil(try offer(bed), "kept: the merge did not happen")

        _ = try await bed.fetchAndFollow(first)
        let link = try XCTUnwrap(try bed.keys.hubLink(hubID))
        XCTAssertEqual(link.epochs.map(\.epoch), [1, 2])
        XCTAssertNil(link.offeredKX)
        XCTAssertNil(link.currentKX)
    }

    func testFollowingToRelayOffersAfterTheMove() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        XCTAssertNil(try offer(bed), "no offer on iCloud")

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        _ = try await bed.fetchAndFollow(first)

        let offered = try XCTUnwrap(try offer(bed), "drawn and saved on the relay")
        let acks = try await bed.relayControls(.epochAck)
        XCTAssertEqual(acks.map(\.epoch), [2], "one ack, on the relay")
        XCTAssertEqual(acks.map(\.nextKX), [WireBytes.base64URL(offered)])
        let cloudAcks = try await bed.cloudControls(.epochAck)
        XCTAssertEqual(cloudAcks.compactMap(\.nextKX), [], "none on iCloud")
    }

    /// Sim rule 13: a switch moves unechoed actions with the same bytes (its keybox merge drops no epoch here, so
    /// it moves no row); the next fetched merge then reseals them into the newest epoch.
    func testASwitchKeepsTheBytesAndALaterFetchedMergeReseals() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let first = try await bed.orderedSession()
        let envelopes = try await bed.sendTwoActions(first)

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        let second = try await bed.fetchAndFollow(first)
        XCTAssertTrue(second.resealsAcrossEpochs, "a link that moved routes")
        let onCloud = try await bed.cloudMailbox()
        for envelope in envelopes {
            XCTAssertTrue(onCloud.contains { $0.payload == envelope }, "the same bytes on CloudKit")
        }
        XCTAssertEqual(try ownEnvelopes(second), envelopes, "the rows keep their bytes")

        await merge(bed, keybox(epoch: 3))
        let after = try ownEnvelopes(second)
        XCTAssertEqual(after.count, 2)
        for envelope in after {
            XCTAssertEqual(try Envelope.parse(envelope).header.epoch, 3, "moved by the fetched merge")
        }
    }

    // MARK: - The uploader

    func testARaiseKicksTheUploader() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        XCTAssertTrue(session.resealsAcrossEpochs)
        let id = try await stuckRecording(session)

        await merge(bed, keybox(epoch: 2))
        try await session.uploadKick?.value(within: 60, "session.uploadKick")

        let row = try XCTUnwrap(try session.store.phoneRecording(id: id))
        XCTAssertFalse(row.isUploadStuck, "re-armed and sent again")
        XCTAssertEqual(try Envelope.parse(try XCTUnwrap(row.envelope)).header.epoch, 2, "resealed under the new epoch")
    }

    /// An iCloud-only link keeps today's upload bytes (ask #1066): a raise re-arms nothing.
    func testARaiseOnAnICloudOnlyLinkReArmsNothing() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let session = try await bed.orderedSession()
        XCTAssertFalse(session.resealsAcrossEpochs)
        let id = try await stuckRecording(session)

        await merge(bed, keybox(epoch: 2))
        try await session.uploadKick?.value(within: 60, "session.uploadKick")

        XCTAssertEqual(try session.store.phoneRecording(id: id)?.isUploadStuck, true, "still waits for the owner")
    }

    // MARK: - Refusals

    /// F17 with a low-order hub key: CryptoKit refuses the point, the merge is refused, the link kept.
    func testALowOrderHubKeyIsRefusedAndTheLinkKept() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let first = try XCTUnwrap(try offer(bed))
        let before = try bed.keys.hubLink(hubID)
        let zero = KeyboxRelayKX(hubPub: WireBytes.base64URL(Data(count: 32)), devicePub: WireBytes.base64URL(first))

        await merge(bed, keybox(epoch: 2, relayKX: zero))
        await merge(bed, keybox(epoch: 2, relayKX: zero))
        try await settle(session)

        XCTAssertEqual(try bed.keys.hubLink(hubID), before, "nothing written")
        XCTAssertEqual(bed.root.linking.refusedKeyboxes, [hubID], "logged once, kept refused")
        XCTAssertEqual(bed.root.linking.links.first?.state, .linked)

        await merge(bed, keybox(epoch: 2))
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
        XCTAssertTrue(bed.root.linking.refusedKeyboxes.isEmpty, "a merge that works ends the refusal")
    }

    /// A keybox sealed to a key this phone does not hold opens with no candidate: the grant reading is unreadable,
    /// and the link row, the screens and the keys stay as they were.
    func testNoNewScreenStateOnAnUnreadableKeybox() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let row = try XCTUnwrap(try bed.row())
        let keys = try bed.keys.hubLink(hubID)

        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
        let capture = InMemoryCloudTransport()
        let stranger = SecureTransport(
            inner: capture, keys: StrangerKeyboxHub(TestE2E.hub(firstSeq: TestPhone.nextSeqBlock())),
            rollback: InMemoryRollbackGuard())
        try await stranger.save([try TestPhone.grantRecord(grant, keys: keybox(epoch: 2).keys, modifiedAt: Date())])
        let batch = try await capture.changes(in: .data, since: nil)
        let sealed = try XCTUnwrap(batch.changed.first)
        try await bed.macSaveSealed(sealed, zone: "data/\(bed.mac.deviceID)")
        try await bed.fetch(session)
        try await bed.root.linkChecks[hubID]?.value(within: 60, "linkChecks")

        XCTAssertEqual(try bed.row(), row, "the link row unchanged")
        XCTAssertEqual(bed.root.linking.links.first?.state, .linked)
        XCTAssertNil(bed.root.linking.notice)
        XCTAssertEqual(try bed.keys.hubLink(hubID), keys, "no keys merged")
    }

    // MARK: - Helpers

    private var device: LinkedDevice {
        LinkedDevice(
            deviceID: TestE2E.deviceID.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0",
            scope: .private, userRecordName: "_owner-acme")
    }

    /// The ordered rows' envelopes, by seq.
    private func ownEnvelopes(_ session: HubSession) throws -> [Data] {
        try session.store.reader.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM pending_actions WHERE action_seq IS NOT NULL ORDER BY action_seq")
        }
    }

    /// The stored offer's public key.
    private func offer(_ bed: Bed) throws -> Data? {
        try bed.keys.hubLink(hubID)?.offeredKX?.publicKey
    }

    /// This phone's keybox of `epoch` (the previous epoch's keys with it), optionally answering an offer.
    private func keybox(epoch: UInt32, relayKX: KeyboxRelayKX? = nil) -> Keybox {
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
        let current = TestPhone.keyboxKeys(epoch: epoch)
        let previous = TestPhone.keyboxKeys(epoch: epoch - 1)
        return Keybox(grant: grant, keys: KeyboxKeys(
            epoch: epoch, dataKey: current.dataKey, alertKey: current.alertKey, metaKey: current.metaKey,
            previousEpoch: epoch > 1 ? epoch - 1 : nil, previousDataKey: epoch > 1 ? previous.dataKey : nil,
            previousAlertKey: epoch > 1 ? previous.alertKey : nil, relayKX: relayKX))
    }

    /// A hub answer naming `offer`, with a freshly drawn hub ephemeral key.
    private func relayKX(naming offer: Data) -> KeyboxRelayKX {
        KeyboxRelayKX(
            hubPub: WireBytes.base64URL(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
            devicePub: WireBytes.base64URL(offer))
    }

    /// The keybox reaches the link flow as a fetch hands it (`reconcileKeyboxKeys`).
    private func merge(_ bed: Bed, _ keybox: Keybox) async {
        await bed.root.linking.reconcileKeyboxKeys(hubID: hubID, keybox: keybox)
    }

    /// The ack the merge queued, written.
    private func settle(_ session: HubSession) async throws {
        try await session.epochAckWork?.value(within: 60, "session.epochAckWork")
        await session.outbox.drain()
    }

    /// The feed parks on a hub control sealed in epoch 2 (above the newest held) once the wait is past its cap;
    /// returns the relay token it parked at.
    private func parkOnARecordInEpoch2(_ bed: Bed, _ session: HubSession) async throws -> Int? {
        XCTAssertNotNil(try offer(bed), "the link holds ephemeral state")
        _ = try session.store.startRelayWait(at: Date().addingTimeInterval(-2 * SecureTransport.keyboxWaitCap))
        let control = ControlPayload(
            id: UUID().uuidString, kind: .resendFrom, deviceID: TestE2E.deviceID.uuidString, hubID: hubID, seq: 1)
        try await bed.writeControl(control, on: .relay, epoch: 2)
        try await bed.fetch(session)
        XCTAssertNotNil(try session.store.relayFeedParkedSince(), "parked")
        let parkedAt = try session.store.relayToken()?.value
        try await bed.fetch(session)
        XCTAssertEqual(try session.store.relayToken()?.value, parkedAt, "parked: nothing read")
        return parkedAt
    }

    /// A finished recording sealed in epoch 1 whose attempts reached the cap: it waits for the owner.
    private func stuckRecording(_ session: HubSession) async throws -> String {
        let file = try makeRecordingsDirectory().appendingPathComponent("capture-\(UUID().uuidString).m4a")
        let started = Date()
        let row = try await session.uploader.beginCapture(fileURL: file, startedAt: started, titleHint: "Design sync", eventID: nil)
        try Data(repeating: 4, count: 256).write(to: file)
        _ = try await session.uploader.finishCapture(
            id: row.id, endedAt: started.addingTimeInterval(60), activeDuration: 60, titleHint: "Design sync", eventID: nil)
        _ = try await session.uploader.uploadPending()
        for _ in 0 ..< PhoneRecording.uploadAttemptCap {
            try session.store.recordPhoneRecordingUploadAttempt(id: row.id, at: Date())
        }
        XCTAssertEqual(try session.store.phoneRecording(id: row.id)?.isUploadStuck, true)
        return row.id
    }

    /// The phone's own controls in `transport`'s mailbox with their opened bytes.
    private func openedPhoneControls(
        in transport: InMemoryCloudTransport
    ) async throws -> [(control: ControlPayload, bytes: Data)] {
        let opened = try await TestPhone.transport(over: transport).changes(in: .relay, since: nil).changed
        return try opened
            .filter { $0.kind == RelayRecordKind.control.rawValue }
            .map { (try RelayCoder.makeDecoder().decode(ControlPayload.self, from: $0.payload), $0.payload) }
    }
}

/// The follower's host whose first switch-keybox merge fails (a Keychain write failure), forwarding everything else.
@MainActor
private final class FollowerMergeFailsOnce: TransportFollowerHost {
    private let root: AppRoot
    private var merges = 0

    init(root: AppRoot) {
        self.root = root
    }

    func followerLink(hubID: String) -> LinkRecord? { root.followerLink(hubID: hubID) }
    func newestEpoch(hubID: String) -> UInt32? { root.newestEpoch(hubID: hubID) }
    func relayUse(for link: LinkRecord) async -> RelayUse { await root.relayUse(for: link) }
    func openSwitchKeybox(_ sealed: Data, hubID: String) async -> Keybox? { await root.openSwitchKeybox(sealed, hubID: hubID) }
    func persistRoute(_ link: LinkRecord) -> Bool { root.persistRoute(link) }
    func moveSession(hubID: String) { root.moveSession(hubID: hubID) }
    func relayOffer(hubID: String) async throws -> Data? { try await root.relayOffer(hubID: hubID) }
    func clearEphemeral(hubID: String) -> Bool { root.clearEphemeral(hubID: hubID) }

    func mergeSwitchKeys(_ keybox: Keybox, hubID: String) async -> Bool {
        merges += 1
        return merges > 1 ? await root.mergeSwitchKeys(keybox, hubID: hubID) : false
    }
}

/// The test hub, sealing every keybox to a stranger's key: no key of this phone opens it.
private struct StrangerKeyboxHub: SecureKeyProvider {
    let inner: TestHubKeyProvider
    private static let stranger = Curve25519.KeyAgreement.PrivateKey().publicKey

    init(_ inner: TestHubKeyProvider) {
        self.inner = inner
    }

    var role: SecureRole { inner.role }
    func metaKey() throws -> SymmetricKey { try inner.metaKey() }
    func currentEpoch() throws -> UInt32 { try inner.currentEpoch() }
    func dataKey(epoch: UInt32) throws -> SymmetricKey { try inner.dataKey(epoch: epoch) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { try inner.alertKey(epoch: epoch) }
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        try inner.relayKey(direction, deviceID: deviceID, epoch: epoch)
    }
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool { try inner.acceptsRelayEpoch(epoch, deviceID: deviceID) }
    func relayDeviceIDs() throws -> [UUID] { try inner.relayDeviceIDs() }
    func nextSeq() throws -> UInt64 { try inner.nextSeq() }
    func hubSigner() throws -> Curve25519.Signing.PrivateKey { try inner.hubSigner() }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { try inner.hubAgreement() }
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? { Self.stranger }
    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { try inner.deviceSigner() }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { try inner.hubAgreementPublicKey() }
    func linkNonce() throws -> Data { try inner.linkNonce() }
}

import CryptoKit
import Foundation
import WatchtowerE2ETesting
@testable import WatchtowerSync

/// Relay client Phase 5 test helpers over the paired test phone's key store: the link made ephemeral, epochs added
/// as a merge would add them, stored pairs derived as both sides derive them, keyboxes sealed by the test hub.
enum EphemeralLink {
    enum Failure: Error { case noLink }

    /// The link with an offer drawn (ephemeral state) and exactly `epochs`, none with a stored pair. Returns the offer.
    @discardableResult
    static func make(_ store: InMemoryPhoneKeyStore, epochs: [UInt32]) throws -> EphemeralKey {
        let offer = EphemeralKey.generate()
        guard try store.updateHubLink(TestE2E.hubID.uuidString, { link in
            var copy = link
            copy.offeredKX = offer
            copy.epochs = epochs.map(epochKeys)
            return copy
        }) != nil else { throw Failure.noLink }
        return offer
    }

    /// `epoch` joins the link (the keybox merged), with `pair` stored when given.
    static func add(_ store: InMemoryPhoneKeyStore, epoch: UInt32, pair: EpochRelayKeys? = nil) throws {
        guard try store.updateHubLink(TestE2E.hubID.uuidString, { link in
            var copy = link
            var keys = epochKeys(epoch)
            keys.relayKeys = pair
            copy.epochs = (link.epochs.filter { $0.epoch != epoch } + [keys]).sorted { $0.epoch < $1.epoch }
            return copy
        }) != nil else { throw Failure.noLink }
    }

    static func epochKeys(_ epoch: UInt32) -> EpochKeys {
        EpochKeys(
            epoch: epoch, dataKey: TestE2E.dataKey(epoch: epoch).withUnsafeBytes { Data($0) },
            alertKey: TestE2E.alertKey(epoch: epoch).withUnsafeBytes { Data($0) })
    }

    /// Both directions of `epoch`'s `wt/relay/v2/` keys for the test pairing, as the phone derives them from its
    /// `device` key and the hub's `hub` public (and the hub from the other halves).
    static func pair(
        epoch: UInt32, device: Curve25519.KeyAgreement.PrivateKey, hub: Curve25519.KeyAgreement.PrivateKey
    ) throws -> EpochRelayKeys {
        func key(_ direction: RelayDirection) throws -> Data {
            let key = try KeyDerivation.ephemeralRelayKey(
                ownEphemeral: device, peerEphemeral: hub.publicKey,
                ownStatic: TestE2E.deviceIdentity.agreement, peerStatic: TestE2E.hubAgreementKey.publicKey,
                hubEphemeralPublic: hub.publicKey.rawRepresentation, deviceEphemeralPublic: device.publicKey.rawRepresentation,
                linkNonce: TestE2E.linkNonce, hubID: TestE2E.hubID, deviceID: TestE2E.deviceID, epoch: epoch,
                direction: direction)
            return key.withUnsafeBytes { Data($0) }
        }
        return EpochRelayKeys(
            p2h: try key(.phoneToHub), h2p: try key(.hubToPhone), hubPub: hub.publicKey.rawRepresentation,
            devicePub: device.publicKey.rawRepresentation)
    }

    /// A keybox for the test phone sealed by the test hub to `recipient` and signed by `signer`.
    static func sealedKeybox(
        to recipient: Curve25519.KeyAgreement.PublicKey,
        keys: KeyboxKeys? = nil,
        epoch: UInt32 = 1,
        signer: Curve25519.Signing.PrivateKey = TestE2E.hubSigningKey
    ) throws -> Data {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: TestE2E.hubID.uuidString, name: "Acme iPhone", scope: .private,
            linked: true, linkedAt: stamp, typingAllowed: false, startSessionsAllowed: true, decidedAt: stamp)
        let frame = InnerFrame(
            kind: SliceKind.deviceGrant.rawValue, id: SliceKind.deviceGrant.recordName(id: TestE2E.deviceID.uuidString),
            payload: try RelayCoder.makeEncoder().encode(Keybox(grant: grant, keys: keys)))
        return try SealedBox.seal(
            frame, envelopeClass: .keybox, to: recipient,
            info: SealedBox.keyboxInfo(hubID: TestE2E.hubID, deviceID: TestE2E.deviceID),
            hubID: TestE2E.hubID, senderID: TestE2E.hubID, epoch: epoch, seq: 1,
            context: EnvelopeContext(zone: .data, wireName: Keybox.recordName(deviceID: TestE2E.deviceID.uuidString)),
            signer: signer)
    }
}

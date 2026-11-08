import CryptoKit
import Foundation

/// Why a keybox's keys could not be merged into a link.
public enum KeyboxKeysError: Error, Equatable {
    /// A key that is not base64url of 32 bytes.
    case badKey
    /// The keybox's `relay_kx` names an ephemeral key this link does not hold (F17): the merge is refused and the
    /// link kept as it is.
    case unknownEphemeral
}

/// A link with a keybox merged in. `droppedNewestPair`: the keybox's own epoch held a stored pair and the keybox
/// is static for it (the hub cleared this phone's relay keys), so the offer has to go out again.
public struct KeyboxMerge: Equatable, Sendable {
    public let keys: HubLinkKeys
    public let droppedNewestPair: Bool
}

extension HubLinkKeys {
    /// This link with a keybox's keys (spec §2.3): the meta key, the keybox's epoch and the one it just retired.
    /// Epochs this link already holds stay unless newer ones push them out (`saveHubLink` keeps the newest
    /// `maxEpochs`), and keep their stored relay pair and cleared mark. Throws `KeyboxKeysError.badKey` for a key that is not
    /// base64url of 32 bytes. Derives no relay keys: `merging` does.
    public func adding(_ keys: KeyboxKeys) throws -> HubLinkKeys {
        var byEpoch = Dictionary(epochs.map { ($0.epoch, $0) }) { _, new in new }
        if let previous = keys.previousEpoch, let data = keys.previousDataKey, let alert = keys.previousAlertKey {
            byEpoch[previous] = EpochKeys(
                epoch: previous, dataKey: try Self.key(data), alertKey: try Self.key(alert),
                relayKeys: byEpoch[previous]?.relayKeys, relayKeysClearedAt: byEpoch[previous]?.relayKeysClearedAt)
        }
        byEpoch[keys.epoch] = EpochKeys(
            epoch: keys.epoch, dataKey: try Self.key(keys.dataKey), alertKey: try Self.key(keys.alertKey),
            relayKeys: byEpoch[keys.epoch]?.relayKeys, relayKeysClearedAt: byEpoch[keys.epoch]?.relayKeysClearedAt)
        var updated = self
        updated.metaKey = try Self.key(keys.metaKey)
        updated.epochs = Array(byEpoch.values.sorted { $0.epoch < $1.epoch }.suffix(Self.maxEpochs))
        return updated
    }

    /// This link with a keybox merged in (relay client Phase 5, "The scheme" step 5): its epochs as `adding` puts
    /// them, stamped as `stampingSuperseded(from:now:)` does; for the keybox's epoch and the previous one it
    /// carries:
    /// - a `relay_kx` and no pair held: the pair is derived (pair presence is compared, not only epoch numbers),
    ///   unless the epoch is marked `relayKeysClearedAt`, which stays static;
    /// - a `relay_kx` and a pair held: the same pair is a no-op; another pair is refused (F17, a restored sidecar);
    /// - no `relay_kx`: a held pair is dropped, and on a link with ephemeral state the epoch is marked cleared.
    /// When the newest `relay_kx` names the offer, the offer becomes the current key and the older current key is
    /// erased. Throws `KeyboxKeysError.unknownEphemeral` when a pair has to be derived from a key this link does not
    /// hold or the keybox names another pair than the one held, `.badKey` for a malformed key, `KeyStoreError.corrupt` for a stored key that does not parse or whose halves
    /// disagree, and `E2EError.allZeroSharedSecret` for a low-order hub key.
    public func merging(
        _ keys: KeyboxKeys, identity: DeviceIdentityKeys, hubID: UUID, deviceID: UUID, now: Date
    ) throws -> KeyboxMerge {
        var merged = try adding(keys).stampingSuperseded(from: self, now: now)
        var named: [(epoch: UInt32, kx: KeyboxRelayKX?)] = [(keys.epoch, keys.relayKX)]
        if let previous = keys.previousEpoch, keys.previousDataKey != nil, keys.previousAlertKey != nil {
            named.append((previous, keys.previousRelayKX))
        }
        var droppedNewestPair = false
        for (epoch, kx) in named {
            guard let index = merged.epochs.firstIndex(where: { $0.epoch == epoch }) else { continue }
            guard let kx else {
                if merged.epochs[index].relayKeys != nil {
                    merged.epochs[index].relayKeys = nil
                    if epoch == keys.epoch { droppedNewestPair = true }
                }
                if hasEphemeralState, merged.epochs[index].relayKeysClearedAt == nil {
                    merged.epochs[index].relayKeysClearedAt = now
                }
                continue
            }
            if let held = merged.epochs[index].relayKeys {
                guard try held.hubPub == Self.ephemeralPublic(kx.hubPub), try held.devicePub == Self.ephemeralPublic(kx.devicePub)
                else { throw KeyboxKeysError.unknownEphemeral }
                continue
            }
            guard merged.epochs[index].relayKeysClearedAt == nil else { continue }
            merged.epochs[index].relayKeys = try relayPair(
                kx, epoch: epoch, identity: identity, hubID: hubID, deviceID: deviceID)
        }
        if let newest = keys.relayKX, let offered = offeredKX, try Self.ephemeralPublic(newest.devicePub) == offered.publicKey {
            merged.currentKX = offered
            merged.offeredKX = nil
        }
        return KeyboxMerge(keys: merged, droppedNewestPair: droppedNewestPair)
    }

    /// Both directions of one epoch's `wt/relay/v2/` keys. The transcript's two ephemeral publics are taken from
    /// the very keys of the agreement (the device's from its private key, checked against the stored half), so
    /// they can never disagree (the caller contract of `KeyDerivation.ephemeralRelayKey`).
    private func relayPair(
        _ kx: KeyboxRelayKX, epoch: UInt32, identity: DeviceIdentityKeys, hubID: UUID, deviceID: UUID
    ) throws -> EpochRelayKeys {
        let devicePub = try Self.ephemeralPublic(kx.devicePub)
        guard let own = [offeredKX, currentKX].compactMap({ $0 }).first(where: { $0.publicKey == devicePub }) else {
            throw KeyboxKeysError.unknownEphemeral
        }
        let ownEphemeral = try own.agreementKey()
        let hubEphemeral: Curve25519.KeyAgreement.PublicKey
        do { hubEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try Self.ephemeralPublic(kx.hubPub)) } catch {
            throw KeyboxKeysError.badKey
        }
        let hubStatic: Curve25519.KeyAgreement.PublicKey
        do { hubStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hubAgreementKey) } catch {
            throw KeyStoreError.corrupt("hub agreement key does not parse")
        }
        func key(_ direction: RelayDirection) throws -> Data {
            let key = try KeyDerivation.ephemeralRelayKey(
                ownEphemeral: ownEphemeral, peerEphemeral: hubEphemeral,
                ownStatic: identity.agreement, peerStatic: hubStatic,
                hubEphemeralPublic: hubEphemeral.rawRepresentation,
                deviceEphemeralPublic: ownEphemeral.publicKey.rawRepresentation,
                linkNonce: linkNonce, hubID: hubID, deviceID: deviceID, epoch: epoch, direction: direction)
            return key.withUnsafeBytes { Data($0) }
        }
        return EpochRelayKeys(
            p2h: try key(.phoneToHub), h2p: try key(.hubToPhone),
            hubPub: hubEphemeral.rawRepresentation, devicePub: ownEphemeral.publicKey.rawRepresentation)
    }

    /// This link with an offer: the one it holds (unchanged), else a freshly drawn one. Returns the offer's public.
    public func withOffer() -> (HubLinkKeys, publicKey: Data) {
        if let offeredKX { return (self, offeredKX.publicKey) }
        let fresh = EphemeralKey.generate()
        var copy = self
        copy.offeredKX = fresh
        return (copy, fresh.publicKey)
    }

    /// Both private ephemeral keys erased; stored pairs stay (a follow to iCloud still reseals with them).
    public func clearingEphemeral() -> HubLinkKeys {
        var copy = self
        copy.currentKX = nil
        copy.offeredKX = nil
        return copy
    }

    /// Every ephemeral trace gone, stored pairs too: the link is static for every epoch. Only on an opened
    /// `hub_on_relay`, the proof the hub cleared this phone's rows.
    public func droppingEphemeral() -> HubLinkKeys {
        var copy = clearingEphemeral()
        copy.epochs = epochs.map { keys in
            var plain = keys
            plain.relayKeys = nil
            return plain
        }
        return copy
    }

    /// Whether this link took part in the ephemeral scheme: an offered or current key, or any stored pair.
    public var hasEphemeralState: Bool {
        currentKX != nil || offeredKX != nil || epochs.contains { $0.relayKeys != nil }
    }

    /// The phone's rule for an epoch's relay key ("The scheme"): the stored pair when the epoch is held with one;
    /// nil (the static `wt/relay/v1/` key) when it is held without one, or when the link has no ephemeral state.
    /// Otherwise an epoch above the newest held throws `SecureTransportError.epochKeysPending` (its keybox may yet
    /// come) and one at or below it `epochKeysGone` (retired or never sent to this phone: it never will).
    public func storedRelayKeys(epoch: UInt32) throws -> EpochRelayKeys? {
        if let held = epochs.first(where: { $0.epoch == epoch }) { return held.relayKeys }
        guard hasEphemeralState else { return nil }
        if let newest = epochs.map(\.epoch).max(), epoch <= newest { throw SecureTransportError.epochKeysGone }
        throw SecureTransportError.epochKeysPending
    }

    private static func key(_ text: String) throws -> Data {
        guard let bytes = WireBytes.fromBase64URL(text), bytes.count == 32 else { throw KeyboxKeysError.badKey }
        return bytes
    }

    private static func ephemeralPublic(_ text: String) throws -> Data {
        guard let bytes = WireBytes.fromBase64URL(text), bytes.count == KeyDerivation.ephemeralPublicKeyLength else {
            throw KeyboxKeysError.badKey
        }
        return bytes
    }
}

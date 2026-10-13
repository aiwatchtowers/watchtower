import CryptoKit
import Foundation
import WatchtowerSync

/// Why a scanned code's key material is unusable: the hub id is not a UUID, or the nonce or a hub key does not
/// decode. The flow shows such a code as refused.
enum ScannedHubKeysError: Error, Equatable {
    case badNonce
    case badHubKey
}

/// What a v3 code carries for the pairing (mobile E2E spec §2.3): the hub's public keys and the link nonce, as
/// the phone keeps them before the keybox (`HubLinkKeys` with no meta key and no epochs), and the four-digit code
/// both sides show.
struct ScannedHubKeys {
    let hubID: String
    let hubUUID: UUID
    /// The code's nonce bytes, exactly as the hub decodes them (`WireBytes.fromBase64URL`).
    let linkNonce: Data
    let hubSigning: Curve25519.Signing.PublicKey
    let hubAgreement: Curve25519.KeyAgreement.PublicKey

    /// From the scanned code.
    init(_ payload: LinkPayload) throws {
        guard let nonce = WireBytes.fromBase64URL(payload.nonce), !nonce.isEmpty else {
            throw ScannedHubKeysError.badNonce
        }
        try self.init(
            hubID: payload.hubID,
            linkNonce: nonce,
            hubSigningKey: WireBytes.fromBase64URL(payload.hubSigningKey),
            hubAgreementKey: WireBytes.fromBase64URL(payload.hubAgreementKey)
        )
    }

    /// From what the scan stored (a wait resumed after a kill).
    init(stored keys: HubLinkKeys) throws {
        try self.init(
            hubID: keys.hubID, linkNonce: keys.linkNonce,
            hubSigningKey: keys.hubSigningKey, hubAgreementKey: keys.hubAgreementKey
        )
    }

    private init(hubID: String, linkNonce: Data, hubSigningKey: Data?, hubAgreementKey: Data?) throws {
        self.hubID = hubID
        hubUUID = try WireBytes.hubUUID(hubID)
        self.linkNonce = linkNonce
        guard let signing = hubSigningKey, signing.count == 32, let agreement = hubAgreementKey, agreement.count == 32 else {
            throw ScannedHubKeysError.badHubKey
        }
        do {
            hubSigning = try Curve25519.Signing.PublicKey(rawRepresentation: signing)
            hubAgreement = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)
        } catch {
            throw ScannedHubKeysError.badHubKey
        }
    }

    /// The link before the owner confirmed it: the hub's keys and the nonce, no meta key, no epochs. The hello is
    /// sealed with it, and the replica verifies the hub's records with its signing key.
    var unconfirmedLink: HubLinkKeys {
        HubLinkKeys(
            hubID: hubID,
            hubSigningKey: hubSigning.rawRepresentation,
            hubAgreementKey: hubAgreement.rawRepresentation,
            linkNonce: linkNonce
        )
    }

    /// The four-digit code the Mac shows for this phone: `KeyDerivation.sas` with the hub's argument order
    /// (`MobileLinkCenter.handleHello`) and the confirm nonce the Mac drew after it accepted this phone's hello
    /// (SAS v2, from the waiting keybox). Never logged.
    func code(for device: DeviceIdentityKeys, confirmNonce: Data) -> String {
        KeyDerivation.sas(
            hubID: hubUUID, linkNonce: linkNonce,
            hubSigning: hubSigning, hubAgreement: hubAgreement,
            deviceSigning: device.signing.publicKey, deviceAgreement: device.agreement.publicKey,
            confirmNonce: confirmNonce
        )
    }

    /// A waiting keybox's `confirm_nonce`: base64url of exactly `KeyDerivation.confirmNonceLength` bytes, else nil
    /// (no code is shown).
    static func confirmNonce(from text: String?) -> Data? {
        guard let text, let bytes = WireBytes.fromBase64URL(text), bytes.count == KeyDerivation.confirmNonceLength else {
            return nil
        }
        return bytes
    }
}

/// Why a keybox's keys could not be stored.
enum KeyboxKeysError: Error, Equatable {
    case badKey
}

extension HubLinkKeys {
    /// This link with a keybox's keys (spec §2.3): the meta key, the keybox's epoch and the one it just retired.
    /// Epochs this link already holds stay unless newer ones push them out (`saveHubLink` keeps the newest
    /// `maxEpochs`). Throws for a key that is not base64url of 32 bytes.
    func adding(_ keys: KeyboxKeys) throws -> HubLinkKeys {
        var byEpoch = Dictionary(epochs.map { ($0.epoch, $0) }) { _, new in new }
        if let previous = keys.previousEpoch, let data = keys.previousDataKey, let alert = keys.previousAlertKey {
            byEpoch[previous] = EpochKeys(epoch: previous, dataKey: try Self.key(data), alertKey: try Self.key(alert))
        }
        byEpoch[keys.epoch] = EpochKeys(epoch: keys.epoch, dataKey: try Self.key(keys.dataKey), alertKey: try Self.key(keys.alertKey))
        var updated = self
        updated.metaKey = try Self.key(keys.metaKey)
        updated.epochs = Array(byEpoch.values.sorted { $0.epoch < $1.epoch }.suffix(Self.maxEpochs))
        return updated
    }

    private static func key(_ text: String) throws -> Data {
        guard let bytes = WireBytes.fromBase64URL(text), bytes.count == 32 else { throw KeyboxKeysError.badKey }
        return bytes
    }
}

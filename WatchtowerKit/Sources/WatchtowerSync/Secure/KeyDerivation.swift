import CryptoKit
import Foundation

public enum RelayDirection: String, Sendable, CaseIterable {
    case phoneToHub = "p2h"
    case hubToPhone = "h2p"
}

/// Every key, record-name, device-id and SAS derivation of the E2E scheme.
/// The byte layouts here are frozen by `Fixtures/e2e/kdf.json`.
public enum KeyDerivation {
    public static let zoneByte: [CloudZoneID: UInt8] = [.data: 1, .relay: 2]

    /// HKDF-SHA256(ikm: X25519(own, peer), salt: linkNonce,
    /// info: "wt/relay/v1/" ‖ dir ‖ 0x00 ‖ hub_id(16) ‖ device_id(16) ‖ epoch u32 BE), 32 bytes.
    public static func relayKey(
        agreementPrivate: Curve25519.KeyAgreement.PrivateKey,
        peerPublic: Curve25519.KeyAgreement.PublicKey,
        linkNonce: Data,
        hubID: UUID,
        deviceID: UUID,
        epoch: UInt32,
        direction: RelayDirection
    ) throws -> SymmetricKey {
        let shared = try agreementPrivate.sharedSecretFromKeyAgreement(with: peerPublic)
        var info = Data("wt/relay/v1/\(direction.rawValue)".utf8)
        info.append(0)
        info.append(WireBytes.bytes(of: hubID))
        info.append(WireBytes.bytes(of: deviceID))
        WireBytes.append(epoch, to: &info)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: linkNonce, sharedInfo: info, outputByteCount: 32)
    }

    /// base32(HMAC-SHA256(K_meta, "wt/name/v1" ‖ zone u8 ‖ kind_len u8 ‖ kind ‖ id utf8)[0..<16]),
    /// 26 lowercase characters. Kinds longer than 255 bytes do not exist; they are clamped, not trapped.
    public static func recordName(metaKey: SymmetricKey, zone: CloudZoneID, kind: String, id: String) -> String {
        var message = Data("wt/name/v1".utf8)
        message.append(zoneByte[zone] ?? 0)
        let kindBytes = Data(kind.utf8).prefix(255)
        message.append(UInt8(kindBytes.count))
        message.append(kindBytes)
        message.append(Data(id.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: metaKey)
        return WireBytes.base32(Data(mac).prefix(16))
    }

    /// UUID of SHA-256("wt/device-id/v1" ‖ dev_sig_pub)[0..<16] (D7).
    public static func deviceID(signingPublicKey: Curve25519.Signing.PublicKey) -> UUID {
        var input = Data("wt/device-id/v1".utf8)
        input.append(signingPublicKey.rawRepresentation)
        let digest = Data(SHA256.hash(data: input)).prefix(16)
        // 16 bytes by construction.
        return WireBytes.uuid(Data(digest)) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    /// Transcript T = SHA-256("wt/sas/v1" ‖ hub_id(16) ‖ nonce ‖ hub_sig_pub ‖ hub_kx_pub ‖ dev_sig_pub ‖ dev_kx_pub);
    /// okm = HKDF-SHA256(ikm: T, salt: nonce, info: "wt/sas/v1", 4 bytes);
    /// four decimal digits of UInt32(bigEndian okm) % 10_000 (D6).
    public static func sas(
        hubID: UUID,
        linkNonce: Data,
        hubSigning: Curve25519.Signing.PublicKey,
        hubAgreement: Curve25519.KeyAgreement.PublicKey,
        deviceSigning: Curve25519.Signing.PublicKey,
        deviceAgreement: Curve25519.KeyAgreement.PublicKey
    ) -> String {
        var transcript = Data("wt/sas/v1".utf8)
        transcript.append(WireBytes.bytes(of: hubID))
        transcript.append(linkNonce)
        transcript.append(hubSigning.rawRepresentation)
        transcript.append(hubAgreement.rawRepresentation)
        transcript.append(deviceSigning.rawRepresentation)
        transcript.append(deviceAgreement.rawRepresentation)
        let digest = Data(SHA256.hash(data: transcript))
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: digest), salt: linkNonce,
            info: Data("wt/sas/v1".utf8), outputByteCount: 4)
        let value = okm.withUnsafeBytes { WireBytes.readUInt32(Data($0), at: 0) } ?? 0
        return String(format: "%04u", value % 10_000)
    }
}

import CryptoKit
import Foundation

/// The proof an upgraded phone gives for the relay id its device record names (protocol §5.5, the Go hub's
/// `link.VerifyRelayIDProof`): its `relay_auth` Ed25519 key signs `message`, which binds the hub, the device and the
/// id, so no linked phone can claim another phone's relay id. `RelaySigner` lives in `WatchtowerHostedRelay`, so
/// `sign` takes the public key and a signing closure.
public enum RelayIDProof {
    /// The message's domain, before a 0x00 byte.
    static let domain = "watchtower/v1/relay-id"

    public enum ProofError: Error, Equatable {
        /// The key is not 32 bytes or the signer gave no 64-byte signature.
        case badKey
    }

    /// `"watchtower/v1/relay-id" ‖ 0x00 ‖ hub_id (16 bytes) ‖ device_id (16 bytes) ‖ relay_device_id (UTF-8)`.
    public static func message(hubID: UUID, deviceID: UUID, relayDeviceID: String) -> Data {
        var message = Data(domain.utf8)
        message.append(0)
        message.append(WireBytes.bytes(of: hubID))
        message.append(WireBytes.bytes(of: deviceID))
        message.append(Data(relayDeviceID.utf8))
        return message
    }

    /// The device record's three relay fields for `authPub`.
    /// `authPub`: the raw 32-byte Ed25519 key; `sign`: the relay_auth signer (the app passes KeychainRelayIdentity's).
    public static func sign(authPub: Data, hubID: UUID, deviceID: UUID, sign: (Data) throws -> Data) throws
        -> (relayDeviceID: String, authPub: String, sig: String) {
        guard authPub.count == 32 else { throw ProofError.badKey }
        let relayDeviceID = RelayIDs.deviceID(publicKey: authPub)
        let sig = try sign(message(hubID: hubID, deviceID: deviceID, relayDeviceID: relayDeviceID))
        guard sig.count == 64 else { throw ProofError.badKey }
        return (relayDeviceID, WireBytes.base64URL(authPub), WireBytes.base64URL(sig))
    }

    /// The hub's check, Kit-side: all three fields, a valid id that is the key's own, and the key's signature over
    /// `message` for this hub and device.
    public static func verify(_ payload: DevicePayload, hubID: UUID, deviceID: UUID) -> Bool {
        guard let relayDeviceID = payload.relayDeviceID, RelayIDs.isValid(relayDeviceID),
              let pubText = payload.relayAuthPub, let pub = WireBytes.fromBase64URL(pubText), pub.count == 32,
              RelayIDs.deviceID(publicKey: pub) == relayDeviceID,
              let sigText = payload.relayIDSig, let sig = WireBytes.fromBase64URL(sigText), sig.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub)
        else { return false }
        return key.isValidSignature(sig, for: message(hubID: hubID, deviceID: deviceID, relayDeviceID: relayDeviceID))
    }
}

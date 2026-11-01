import CryptoKit
import Foundation
import WatchtowerSync

/// The relay's device id and the bytes a device signs at register and login,
/// byte-for-byte the Go client's (`client.DeviceID`, `client.RegisterClientDataHash`,
/// `loginLocked`) and the relay's `proto/README.md`; pinned by
/// `Fixtures/relay/auth_vectors.json`. Strings are UTF-8.
public enum RelayAuthMessages {
    /// lower-case unpadded RFC 4648 base32 of SHA-256(publicKey); `RelayIDs.deviceID`
    public static func deviceID(publicKey: Data) -> String {
        RelayIDs.deviceID(publicKey: publicKey)
    }

    /// SHA256("relay/v1/register" ‖ nonce ‖ authPub ‖ origin)
    public static func registerClientDataHash(nonce: Data, authPub: Data, origin: RelayOrigin) -> Data {
        sha256(Data("relay/v1/register".utf8), nonce, authPub, Data(origin.string.utf8))
    }

    /// nonce ‖ deviceID ‖ origin — what the Ed25519 key signs at login
    public static func loginMessage(nonce: Data, deviceID: String, origin: RelayOrigin) -> Data {
        nonce + Data(deviceID.utf8) + Data(origin.string.utf8)
    }

    /// SHA256("relay/v1/login" ‖ nonce ‖ deviceID ‖ origin) — what the App Attest assertion covers
    public static func loginClientDataHash(nonce: Data, deviceID: String, origin: RelayOrigin) -> Data {
        sha256(Data("relay/v1/login".utf8), nonce, Data(deviceID.utf8), Data(origin.string.utf8))
    }

    private static func sha256(_ parts: Data...) -> Data {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }
}

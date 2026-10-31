import CryptoKit
import Foundation

/// The relay's device id and the bytes a device signs at register and login,
/// byte-for-byte the Go client's (`client.DeviceID`, `client.RegisterClientDataHash`,
/// `loginLocked`) and the relay's `proto/README.md`; pinned by
/// `Fixtures/relay/auth_vectors.json`. Strings are UTF-8.
public enum RelayAuthMessages {
    /// lower-case unpadded RFC 4648 base32 of SHA-256(publicKey)
    public static func deviceID(publicKey: Data) -> String {
        base32LowerUnpadded(Data(SHA256.hash(data: publicKey)))
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

    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// RFC 4648 base32, lower-case, no padding.
    private static func base32LowerUnpadded(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(base32Alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            out.append(base32Alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return out
    }
}

import CryptoKit
import Foundation

/// The hosted relay's device ids: lower-case unpadded RFC 4648 base32 of SHA-256 of the device's `relay_auth`
/// public key, 52 characters `a–z2–7` (the Go `identity.RelayDeviceID` and the hub's `validRelayDeviceID`).
/// CryptoKit and base32 only, so `WatchtowerSync` stays free of protobuf; `RelayAuthMessages.deviceID`
/// forwards here.
public enum RelayIDs {
    /// Length of a relay device id: unpadded base32 of a 32-byte digest.
    static let length = 52

    /// lower-case unpadded RFC 4648 base32 of SHA-256(publicKey)
    public static func deviceID(publicKey: Data) -> String {
        base32LowerUnpadded(Data(SHA256.hash(data: publicKey)))
    }

    /// The format rule only: 52 characters of `a–z2–7`.
    public static func isValid(_ id: String) -> Bool {
        id.utf8.count == length && id.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x32...0x37).contains($0) }
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

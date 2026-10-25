import CryptoKit
import Foundation

/// A stand-in for company text in state kept outside the database (#604
/// S16): `"sha256:" + hex(SHA-256(text))`. Equal texts give equal digests;
/// the text cannot be read back.
package enum ContentDigest {
    package static func of(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

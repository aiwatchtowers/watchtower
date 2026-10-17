import CryptoKit
import Foundation

package enum SessionHostPaths {
    /// `<tmp>/watchtower-sh-<first 8 hex of SHA-256(bundleID)>.sock`: short
    /// enough for `sockaddr_un` (104 bytes on macOS) and the same for the app
    /// and the host (Go twin). `tempDir` may end with a slash or not.
    package static func socketPath(bundleID: String, tempDir: String) -> String {
        let digest = SHA256.hash(data: Data(bundleID.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let dir = tempDir.hasSuffix("/") ? tempDir : tempDir + "/"
        return dir + "watchtower-sh-" + hex + ".sock"
    }
}

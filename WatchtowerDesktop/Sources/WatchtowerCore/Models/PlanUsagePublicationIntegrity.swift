import CryptoKit
import Foundation

/// The Go publisher semantically validated these exact stored bytes. This is an
/// integrity receipt, not an authentication credential or a Swift forecast fit.
package enum PlanUsagePublicationIntegrity: Equatable, Sendable {
    case verified, unverified

    package static func verify(limits: String, plot: String, proof: String) -> Self {
        guard proof.count == 64, proof == digest(limits: limits, plot: plot) else { return .unverified }
        return .verified
    }

    /// Shared framing with Go: domain then two big-endian UInt64 UTF-8 byte lengths.
    private static func digest(limits: String, plot: String) -> String {
        var data = Data("watchtower.planusage.publication.v1\0".utf8)
        for text in [limits, plot] {
            let bytes = Data(text.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

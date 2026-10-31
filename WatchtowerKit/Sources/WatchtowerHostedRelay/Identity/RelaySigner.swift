import CryptoKit
import Foundation

/// The device's relay auth key (`relay_auth`, Ed25519): its public key derives
/// the relay device id and it signs the register hash and the login message.
public protocol RelaySigner: Sendable {
    /// The raw 32-byte Ed25519 public key (`auth_pub`).
    var publicKey: Data { get }
    /// An Ed25519 signature over `message`.
    func sign(_ message: Data) throws -> Data
}

/// A `RelaySigner` over a CryptoKit key held in memory. CryptoKit's Ed25519
/// signatures are randomized: they verify under the Go client's key but differ
/// from its bytes.
public struct Ed25519RelaySigner: RelaySigner {
    private let key: Curve25519.Signing.PrivateKey

    public init(_ key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    public var publicKey: Data {
        key.publicKey.rawRepresentation
    }

    public func sign(_ message: Data) throws -> Data {
        try key.signature(for: message)
    }
}

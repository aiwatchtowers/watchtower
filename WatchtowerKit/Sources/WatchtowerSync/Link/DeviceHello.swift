import Foundation

/// Plain payload of the hello (spec §2.3), RelayCoder JSON, sealed to `hub_kx` with `SealedBox`: the phone's
/// `DevicePayload` plus its public keys (base64url, 32 bytes each). The record name is key-free (D7).
public struct DeviceHello: Codable, Equatable, Sendable {
    public let device: DevicePayload
    /// `dev_sig` public key; wire `signing_key`.
    public let signingKey: String
    /// `dev_kx` public key; wire `agreement_key`.
    public let agreementKey: String

    public var recordName: String { "hello-\(device.deviceID)" }

    public init(device: DevicePayload, signingKey: String, agreementKey: String) {
        self.device = device
        self.signingKey = signingKey
        self.agreementKey = agreementKey
    }

    // `recordName` is derived, never on the wire.
    enum CodingKeys: String, CodingKey {
        case device
        case signingKey
        case agreementKey
    }
}

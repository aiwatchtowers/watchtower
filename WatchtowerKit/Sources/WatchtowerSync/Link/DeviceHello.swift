import Foundation

/// Plain payload of the hello (spec §2.3), RelayCoder JSON, sealed to `hub_kx` with `SealedBox`: the phone's
/// `DevicePayload` plus its public keys (base64url, 32 bytes each). The record name is key-free (D7).
public struct DeviceHello: Codable, Equatable, Sendable {
    public let device: DevicePayload
    /// `dev_sig` public key; wire `signing_key`.
    public let signingKey: String
    /// `dev_kx` public key; wire `agreement_key`.
    public let agreementKey: String
    /// The phone's own hosted-relay device id (`RelayIDs.deviceID` of its `relay_auth` key), sent when it links
    /// over the relay so the hub can name it to the relay; wire `relay_device_id`, absent when nil. A decoded id
    /// that fails `RelayIDs.isValid` reads as nil (the Go hub drops such a hello; this phone never sends one).
    public let relayDeviceID: String?

    public var recordName: String { "hello-\(device.deviceID)" }

    public init(device: DevicePayload, signingKey: String, agreementKey: String, relayDeviceID: String? = nil) {
        self.device = device
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        self.relayDeviceID = relayDeviceID
    }

    /// The hello of a link through a Relay pairing slot (#2387): `device` carries this phone's relay id, its
    /// `relay_auth` key and the key's signature (`RelayIDProof.sign` for the hub and this device), and the hello
    /// names the same id. The hub marks the link as one over Relay only for such a hello (`RelayIDProof.verify`).
    public init(
        device: DevicePayload,
        signingKey: String,
        agreementKey: String,
        relayIDProof proof: (relayDeviceID: String, authPub: String, sig: String)
    ) {
        self.init(
            device: device.withRelayID(proof.relayDeviceID, authPub: proof.authPub, sig: proof.sig),
            signingKey: signingKey, agreementKey: agreementKey, relayDeviceID: proof.relayDeviceID
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            device: try values.decode(DevicePayload.self, forKey: .device),
            signingKey: try values.decode(String.self, forKey: .signingKey),
            agreementKey: try values.decode(String.self, forKey: .agreementKey),
            relayDeviceID: try values.decodeIfPresent(String.self, forKey: .relayDeviceID).flatMap { RelayIDs.isValid($0) ? $0 : nil }
        )
    }

    // `recordName` is derived, never on the wire. convertFromSnakeCase maps "relay_device_id" -> "relayDeviceId"
    // (lowercase d), as `ControlPayload`'s `deviceId`.
    enum CodingKeys: String, CodingKey {
        case device
        case signingKey
        case agreementKey
        case relayDeviceID = "relayDeviceId"
    }
}

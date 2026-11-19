import Foundation

/// Plain payload of a keybox (spec §2.3), RelayCoder JSON, sealed to one phone's `dev_kx` with `SealedBox` and
/// signed by `hub_sig`: the grant every reader already decodes as `DeviceGrant`, plus the keys once the owner
/// confirmed the link (D9: a revoked keybox carries the grant only).
public struct Keybox: Codable, Equatable, Sendable {
    public let grant: DeviceGrant
    public let keys: KeyboxKeys?

    /// Key-free name `keybox-<device_id>`.
    public static func recordName(deviceID: String) -> String { "keybox-\(deviceID)" }

    public init(grant: DeviceGrant, keys: KeyboxKeys?) {
        self.grant = grant
        self.keys = keys
    }
}

/// The epoch keys of a keybox, base64url of 32 bytes each. `previous*` carry the epoch just retired while its
/// records are being republished.
public struct KeyboxKeys: Codable, Equatable, Sendable {
    public let epoch: UInt32
    public let dataKey: String
    public let alertKey: String
    public let metaKey: String
    public let previousEpoch: UInt32?
    public let previousDataKey: String?
    public let previousAlertKey: String?
    /// The ephemeral pair of this epoch's `wt/relay/v2/` relay keys; nil means the static `wt/relay/v1/` keys (no
    /// offer, or a hub that predates Phase 5).
    public let relayKX: KeyboxRelayKX?
    /// `relayKX` of `previousEpoch`.
    public let previousRelayKX: KeyboxRelayKX?

    // convertFromSnakeCase maps "relay_kx" -> "relayKx".
    enum CodingKeys: String, CodingKey {
        case epoch, dataKey, alertKey, metaKey, previousEpoch, previousDataKey, previousAlertKey
        case relayKX = "relayKx"
        case previousRelayKX = "previousRelayKx"
    }

    public init(
        epoch: UInt32,
        dataKey: String,
        alertKey: String,
        metaKey: String,
        previousEpoch: UInt32? = nil,
        previousDataKey: String? = nil,
        previousAlertKey: String? = nil,
        relayKX: KeyboxRelayKX? = nil,
        previousRelayKX: KeyboxRelayKX? = nil
    ) {
        self.epoch = epoch
        self.dataKey = dataKey
        self.alertKey = alertKey
        self.metaKey = metaKey
        self.previousEpoch = previousEpoch
        self.previousDataKey = previousDataKey
        self.previousAlertKey = previousAlertKey
        self.relayKX = relayKX
        self.previousRelayKX = previousRelayKX
    }
}

/// The ephemeral pair of one epoch's relay keys (relay client Phase 5): the hub's drawn `hub_eph` public and the
/// phone's offered `dev_eph` public it answers, unpadded base64url of 32 bytes each. The phone finds its private
/// half by `devicePub`.
public struct KeyboxRelayKX: Codable, Equatable, Sendable {
    public let hubPub: String
    public let devicePub: String

    public init(hubPub: String, devicePub: String) {
        self.hubPub = hubPub
        self.devicePub = devicePub
    }
}

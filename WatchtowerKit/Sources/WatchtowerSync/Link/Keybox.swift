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

    public init(
        epoch: UInt32,
        dataKey: String,
        alertKey: String,
        metaKey: String,
        previousEpoch: UInt32? = nil,
        previousDataKey: String? = nil,
        previousAlertKey: String? = nil
    ) {
        self.epoch = epoch
        self.dataKey = dataKey
        self.alertKey = alertKey
        self.metaKey = metaKey
        self.previousEpoch = previousEpoch
        self.previousDataKey = previousDataKey
        self.previousAlertKey = previousAlertKey
    }
}

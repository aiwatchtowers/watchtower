import Foundation

/// The kind of a control record. rawValues are wire format (Go `wire.Control*`); a kind added by a newer peer
/// decodes as an unknown value and never fails the record.
public struct ControlKind: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let resendFrom = Self(rawValue: "resend_from")
    public static let skipTo = Self(rawValue: "skip_to")
    public static let epochAck = Self(rawValue: "epoch_ack")
    public static let transportSwitch = Self(rawValue: "transport_switch")
    public static let transportSwitched = Self(rawValue: "transport_switched")
    public static let transportSwitchRejected = Self(rawValue: "transport_switch_rejected")
    public static let hubOnRelay = Self(rawValue: "hub_on_relay")
    public static let knownValues: [Self] = [
        .resendFrom, .skipTo, .epochAck, .transportSwitch, .transportSwitched, .transportSwitchRejected, .hubOnRelay
    ]
}

/// The sealed body of a control record `c-<uuid>` (relay client Phase 1), byte-compatible with the Go hub's
/// `wire.Control`. Fields by kind: `resend_from`/`skip_to` → `seq`; `epoch_ack` → `epoch`; `transport_switch`
/// → `target` (and `reason`); `transport_switched` → `target`, `epoch`, `by`, `at` and `keybox` (relay client Phase 3:
/// base64url of the sealed `keybox-<DEVICE_ID>` envelope of the new epoch, opened by `SecureTransport.openKeybox`);
/// `transport_switch_rejected` → `reason`, `retryAfterS`; `hub_on_relay` → nothing.
///
/// Wire: RelayCoder JSON (snake_case, Unix-second dates); a nil optional is an absent key.
public struct ControlPayload: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ControlKind
    /// The phone the record is about. A phone's control always carries it (the hub drops a `skip_to` without).
    public let deviceID: String?
    /// The hub the record is about. A phone's control always carries it.
    public let hubID: String?
    public let seq: UInt64?
    public let epoch: UInt32?
    public let target: String?
    public let by: String?
    public let at: Date?
    public let reason: String?
    /// Whole seconds.
    public let retryAfterS: UInt32?
    /// `transport_switched` only: base64url of the sealed keybox envelope of the new epoch for this phone. A secret
    /// in transit: never logged.
    public let keybox: String?

    /// The plain record name.
    public var recordName: String { "c-\(id)" }

    // convertFromSnakeCase maps "device_id" -> "deviceId" (lowercase d).
    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case deviceID = "deviceId"
        case hubID = "hubId"
        case seq
        case epoch
        case target
        case by
        case at
        case reason
        case retryAfterS
        case keybox
    }

    public init(
        id: String,
        kind: ControlKind,
        deviceID: String?,
        hubID: String?,
        seq: UInt64? = nil,
        epoch: UInt32? = nil,
        target: String? = nil,
        by: String? = nil,
        at: Date? = nil,
        reason: String? = nil,
        retryAfterS: UInt32? = nil,
        keybox: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.deviceID = deviceID
        self.hubID = hubID
        self.seq = seq
        self.epoch = epoch
        self.target = target
        self.by = by
        self.at = at
        self.reason = reason
        self.retryAfterS = retryAfterS
        self.keybox = keybox
    }

    /// A `keybox` that is not a string (an earlier Go hub's plain keybox object) reads as absent, so the control
    /// still decodes and its switch waits for a keybox this build can open, instead of being dropped unread.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(ControlKind.self, forKey: .kind)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        hubID = try container.decodeIfPresent(String.self, forKey: .hubID)
        seq = try container.decodeIfPresent(UInt64.self, forKey: .seq)
        epoch = try container.decodeIfPresent(UInt32.self, forKey: .epoch)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        by = try container.decodeIfPresent(String.self, forKey: .by)
        at = try container.decodeIfPresent(Date.self, forKey: .at)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        retryAfterS = try container.decodeIfPresent(UInt32.self, forKey: .retryAfterS)
        keybox = try? container.decodeIfPresent(String.self, forKey: .keybox)
    }

    /// A phone's `skip_to(seq)`: the order continues from `seq`. Every id is the canonical uppercase
    /// `uuidString`, as the Go hub writes and compares them.
    public static func skipTo(_ seq: UInt64, deviceID: UUID, hubID: UUID, id: UUID = UUID()) -> Self {
        Self(id: id.uuidString, kind: .skipTo, deviceID: deviceID.uuidString, hubID: hubID.uuidString, seq: seq)
    }
}

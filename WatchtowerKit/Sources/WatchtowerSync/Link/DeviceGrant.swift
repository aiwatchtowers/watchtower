import Foundation

/// Why the hub refused a link (spec §4.13). rawValues are wire format. A
/// code added by a newer Mac decodes as an unknown value (`OpenWireValue`)
/// and is still a refusal: the link flow treats any non-nil `linkRefused`
/// as refused.
public struct LinkRefusal: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let usedCode = Self(rawValue: "used_code")
    public static let expiredCode = Self(rawValue: "expired_code")
    public static let unknownCode = Self(rawValue: "unknown_code")
    public static let knownValues: [Self] = [.usedCode, .expiredCode, .unknownCode]
}

/// The hub's `device_grant` slice (mobile POC spec §4.13), record name
/// `device_grant-<device_id>`: the hub's view of one phone that wrote a
/// `device` record. The hub writes it; the phone's Settings and link flow
/// read it ("Waiting for your Mac to confirm" / "Allowed").
///
/// Wire: RelayCoder JSON (snake_case, Unix-second dates, sorted keys). A nil
/// optional is an absent key.
public struct DeviceGrant: Codable, Equatable, Sendable {
    public let deviceID: String
    public let hubID: String
    /// The phone's name, at most 60 grapheme clusters.
    public let name: String
    public let scope: DeviceScope
    public let linked: Bool
    /// Set when the hub refused the scanned code.
    public let linkRefused: LinkRefusal?
    /// nil until the device is linked.
    public let linkedAt: Date?
    /// Default false: typing into sessions needs the owner's allow.
    public let typingAllowed: Bool
    /// Default true.
    public let startSessionsAllowed: Bool
    /// nil while the hub has not decided yet.
    public let decidedAt: Date?

    public var recordName: String { SliceKind.deviceGrant.recordName(id: deviceID) }

    // convertFromSnakeCase maps "device_id" -> "deviceId" and "hub_id" ->
    // "hubId" (lowercase d), so the CodingKey stringValues use that form.
    enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case hubID = "hubId"
        case name
        case scope
        case linked
        case linkRefused
        case linkedAt
        case typingAllowed
        case startSessionsAllowed
        case decidedAt
    }

    public init(
        deviceID: String,
        hubID: String,
        name: String,
        scope: DeviceScope,
        linked: Bool,
        linkRefused: LinkRefusal? = nil,
        linkedAt: Date? = nil,
        typingAllowed: Bool,
        startSessionsAllowed: Bool,
        decidedAt: Date? = nil
    ) {
        self.deviceID = deviceID
        self.hubID = hubID
        self.name = name
        self.scope = scope
        self.linked = linked
        self.linkRefused = linkRefused
        self.linkedAt = linkedAt
        self.typingAllowed = typingAllowed
        self.startSessionsAllowed = startSessionsAllowed
        self.decidedAt = decidedAt
    }
}

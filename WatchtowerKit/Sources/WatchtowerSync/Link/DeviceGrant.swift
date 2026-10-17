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
    /// The owner refused on the Mac, or closed the confirmation sheet.
    public static let notConfirmed = Self(rawValue: "not_confirmed")
    /// The code already has as many phones waiting as the Mac shows (SAS v2 attempt cap): a further one is refused.
    public static let tooManyRequests = Self(rawValue: "too_many_requests")
    public static let knownValues: [Self] = [.usedCode, .expiredCode, .unknownCode, .notConfirmed, .tooManyRequests]
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
    /// Answering permission prompts from the phone needs its own allow, never implied by typing. Default false;
    /// absent on the wire reads false, and false is not written, so older peers' bytes stay as they were.
    public let permissionsAllowed: Bool
    /// nil while the hub has not decided yet.
    public let decidedAt: Date?
    /// The hub read the hello and waits for the owner; absent otherwise.
    public let awaitingConfirmation: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// SAS v2: with `awaitingConfirmation`, base64url of the hub's confirm nonce (`KeyDerivation.sas`), drawn after
    /// the hub accepted this phone's hello; the phone shows its code only once it has it. Absent otherwise.
    public let confirmNonce: String?
    /// With `confirmNonce`: `KeyDerivation.linkCodeTag` of the link code the waiting request was made with, so a
    /// keybox left from an earlier code never gives this scan a code. Absent otherwise.
    public let linkCodeTag: String?
    /// Removed on the Mac (D9); absent otherwise.
    public let revoked: Bool? // swiftlint:disable:this discouraged_optional_boolean

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
        case permissionsAllowed
        case decidedAt
        case awaitingConfirmation
        case confirmNonce
        case linkCodeTag
        case revoked
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
        permissionsAllowed: Bool = false,
        decidedAt: Date? = nil,
        awaitingConfirmation: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        confirmNonce: String? = nil,
        linkCodeTag: String? = nil,
        revoked: Bool? = nil // swiftlint:disable:this discouraged_optional_boolean
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
        self.permissionsAllowed = permissionsAllowed
        self.decidedAt = decidedAt
        self.awaitingConfirmation = awaitingConfirmation
        self.confirmNonce = confirmNonce
        self.linkCodeTag = linkCodeTag
        self.revoked = revoked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        hubID = try c.decode(String.self, forKey: .hubID)
        name = try c.decode(String.self, forKey: .name)
        scope = try c.decode(DeviceScope.self, forKey: .scope)
        linked = try c.decode(Bool.self, forKey: .linked)
        linkRefused = try c.decodeIfPresent(LinkRefusal.self, forKey: .linkRefused)
        linkedAt = try c.decodeIfPresent(Date.self, forKey: .linkedAt)
        typingAllowed = try c.decode(Bool.self, forKey: .typingAllowed)
        startSessionsAllowed = try c.decode(Bool.self, forKey: .startSessionsAllowed)
        permissionsAllowed = try c.decodeIfPresent(Bool.self, forKey: .permissionsAllowed) ?? false
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        awaitingConfirmation = try c.decodeIfPresent(Bool.self, forKey: .awaitingConfirmation)
        confirmNonce = try c.decodeIfPresent(String.self, forKey: .confirmNonce)
        linkCodeTag = try c.decodeIfPresent(String.self, forKey: .linkCodeTag)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(hubID, forKey: .hubID)
        try c.encode(name, forKey: .name)
        try c.encode(scope, forKey: .scope)
        try c.encode(linked, forKey: .linked)
        try c.encodeIfPresent(linkRefused, forKey: .linkRefused)
        try c.encodeIfPresent(linkedAt, forKey: .linkedAt)
        try c.encode(typingAllowed, forKey: .typingAllowed)
        try c.encode(startSessionsAllowed, forKey: .startSessionsAllowed)
        if permissionsAllowed { try c.encode(true, forKey: .permissionsAllowed) }
        try c.encodeIfPresent(decidedAt, forKey: .decidedAt)
        try c.encodeIfPresent(awaitingConfirmation, forKey: .awaitingConfirmation)
        try c.encodeIfPresent(confirmNonce, forKey: .confirmNonce)
        try c.encodeIfPresent(linkCodeTag, forKey: .linkCodeTag)
        try c.encodeIfPresent(revoked, forKey: .revoked)
    }
}

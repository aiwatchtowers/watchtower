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
    /// The phone's own "Start sessions" toggle as the hub stored it (its opt-out). Before #565 this alone let a
    /// phone start sessions, and an older phone still reads it so; a newer one reads `mayStartSessions`.
    public let startSessionsAllowed: Bool
    /// #565: whether a `session_start` from the phone goes — the owner allowed starting sessions and typing on the
    /// Mac, and the phone's own toggle is on. A newer hub always writes it; absent (an older hub) falls back to
    /// `startSessionsAllowed`, which was that hub's whole rule.
    let startSessionsGranted: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Answering permission prompts from the phone needs its own allow, never implied by typing
    /// (`permissionsAllowed`). Absent on the wire reads false, and false is not written, so older peers' bytes
    /// stay as they were.
    let permissionsGranted: Bool? // swiftlint:disable:this discouraged_optional_boolean
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
    /// Default false.
    public var permissionsAllowed: Bool { permissionsGranted ?? false }
    /// Whether the hub takes a `session_start` from this phone (#565; an older hub: its `startSessionsAllowed`).
    public var mayStartSessions: Bool { startSessionsGranted ?? startSessionsAllowed }

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
        case startSessionsGranted
        case permissionsGranted = "permissionsAllowed"
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
        mayStartSessions: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
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
        startSessionsGranted = mayStartSessions
        permissionsGranted = permissionsAllowed ? true : nil
        self.decidedAt = decidedAt
        self.awaitingConfirmation = awaitingConfirmation
        self.confirmNonce = confirmNonce
        self.linkCodeTag = linkCodeTag
        self.revoked = revoked
    }
}

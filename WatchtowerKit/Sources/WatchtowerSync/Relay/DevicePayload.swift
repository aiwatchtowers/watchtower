import Foundation

/// The CloudKit database a linked phone syncs through (spec §2.3): the
/// Mac user's private database (same Apple ID) or the shared database (a
/// different Apple ID, through zone shares). rawValues are wire format; a
/// scope added by a newer build decodes as an unknown value (`OpenWireValue`).
public struct DeviceScope: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let `private` = Self(rawValue: "private")
    public static let shared = Self(rawValue: "shared")
    public static let knownValues: [Self] = [.private, .shared]
}

/// The phone's link record in RelayZone (mobile POC spec §5.1), record name
/// `device-<device_id>`. Only the phone writes it; the Mac never rewrites it
/// and answers through the `device_grant` slice. A new scan rewrites it with
/// the new `linkNonce`.
///
/// Wire: RelayCoder JSON. A nil optional is an absent key.
public struct DevicePayload: Codable, Equatable, Sendable {
    /// Cap on `name`, in grapheme clusters.
    public static let maxNameLength = 60

    /// UUID kept in the Keychain, so it survives a reinstall.
    public let deviceID: String
    /// The phone's name, at most `maxNameLength`.
    public let name: String
    public let model: String
    public let appVersion: String
    public let scope: DeviceScope
    /// The phone's iCloud user record name; in `shared` scope the hub checks
    /// it against each relay record's creator (spec §5.2 rule 4).
    public let userRecordName: String
    /// The single-use nonce from the scanned QR code.
    public let linkNonce: String?
    /// true once the phone unlinked itself.
    public let unlinked: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The phone asks to type into sessions (the Mac decides).
    public let typingRequested: Bool
    /// The phone asks to start sessions (the Mac decides).
    public let startSessions: Bool
    /// The phone asks to answer permission prompts (the Mac decides; `permissionsRequested`). Absent reads false;
    /// false is not written.
    let permissionsAsked: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// When the phone last reached out to the Mac (keep-awake, ask #614). Written only when set; absent from
    /// older phones, whose `updatedAt` stands in.
    public let seenAt: Date?
    public let updatedAt: Date
    /// An upgraded phone's hosted-relay device id (`RelayIDs.deviceID` of its `relay_auth` key), named so a hub it
    /// linked to over iCloud can name it to the relay; wire `relay_device_id`, absent when nil. A decoded id that
    /// fails `RelayIDs.isValid` reads as nil. The hub takes it only with `relayAuthPub` and `relayIDSig`
    /// (`RelayIDProof`).
    public let relayDeviceID: String?
    /// The `relay_auth` Ed25519 public key, unpadded base64url; wire `relay_auth_pub`.
    public let relayAuthPub: String?
    /// The `relay_auth` key's signature over `RelayIDProof.message`, unpadded base64url; wire `relay_id_sig`.
    public let relayIDSig: String?

    /// The phone's "When work stops" switch is off, so the hub sends it no alert; wire `work_alerts_off`, true or
    /// absent. An older hub ignores it.
    let workAlertsOffFlag: Bool? // swiftlint:disable:this discouraged_optional_boolean

    public var workAlertsOff: Bool { workAlertsOffFlag ?? false }
    public var recordName: String { "device-\(deviceID)" }
    public var permissionsRequested: Bool { permissionsAsked ?? false }

    // convertFromSnakeCase maps "device_id" -> "deviceId" (lowercase d), so
    // the CodingKey stringValue must be "deviceId" to round-trip.
    enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case name
        case model
        case appVersion
        case scope
        case userRecordName
        case linkNonce
        case unlinked
        case typingRequested
        case startSessions
        case permissionsAsked = "permissionsRequested"
        case seenAt
        case updatedAt
        case relayDeviceID = "relayDeviceId"
        case relayAuthPub
        case relayIDSig = "relayIdSig"
        case workAlertsOffFlag = "workAlertsOff"
    }

    public init(
        deviceID: String,
        name: String,
        model: String,
        appVersion: String,
        scope: DeviceScope,
        userRecordName: String,
        linkNonce: String? = nil,
        unlinked: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        typingRequested: Bool,
        startSessions: Bool,
        permissionsRequested: Bool = false,
        seenAt: Date? = nil,
        updatedAt: Date,
        relayDeviceID: String? = nil,
        relayAuthPub: String? = nil,
        relayIDSig: String? = nil,
        workAlertsOff: Bool = false
    ) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.scope = scope
        self.userRecordName = userRecordName
        self.linkNonce = linkNonce
        self.unlinked = unlinked
        self.typingRequested = typingRequested
        self.startSessions = startSessions
        permissionsAsked = permissionsRequested ? true : nil
        self.seenAt = seenAt
        self.updatedAt = updatedAt
        self.relayDeviceID = relayDeviceID
        self.relayAuthPub = relayAuthPub
        self.relayIDSig = relayIDSig
        workAlertsOffFlag = workAlertsOff ? true : nil
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        name = try values.decode(String.self, forKey: .name)
        model = try values.decode(String.self, forKey: .model)
        appVersion = try values.decode(String.self, forKey: .appVersion)
        scope = try values.decode(DeviceScope.self, forKey: .scope)
        userRecordName = try values.decode(String.self, forKey: .userRecordName)
        linkNonce = try values.decodeIfPresent(String.self, forKey: .linkNonce)
        unlinked = try values.decodeIfPresent(Bool.self, forKey: .unlinked)
        typingRequested = try values.decode(Bool.self, forKey: .typingRequested)
        startSessions = try values.decode(Bool.self, forKey: .startSessions)
        permissionsAsked = try values.decodeIfPresent(Bool.self, forKey: .permissionsAsked)
        seenAt = try values.decodeIfPresent(Date.self, forKey: .seenAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        relayDeviceID = try values.decodeIfPresent(String.self, forKey: .relayDeviceID).flatMap { RelayIDs.isValid($0) ? $0 : nil }
        relayAuthPub = try values.decodeIfPresent(String.self, forKey: .relayAuthPub)
        relayIDSig = try values.decodeIfPresent(String.self, forKey: .relayIDSig)
        workAlertsOffFlag = try values.decodeIfPresent(Bool.self, forKey: .workAlertsOffFlag) == true ? true : nil
    }
}

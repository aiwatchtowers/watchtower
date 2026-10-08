import Foundation

/// The CloudKit database a linked phone syncs through (spec §2.3): the
/// Mac user's private database (same Apple ID) or the shared database (a
/// different Apple ID, through zone shares). rawValues are wire format.
public enum DeviceScope: String, Codable, CaseIterable, Sendable {
    case `private`
    case shared
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
    public let updatedAt: Date

    public var recordName: String { "device-\(deviceID)" }

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
        case updatedAt
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
        updatedAt: Date
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
        self.updatedAt = updatedAt
    }
}

import Foundation

/// The hub's liveness record (mobile POC spec §4.1), rewritten every 300 s.
/// It lives in DataZone under the record name `heartbeat`: only the hub
/// writes that zone, so a RelayZone share participant cannot rewrite it.
/// The phone shows the Mac online while `updatedAt` is under 720 s old.
///
/// Wire: RelayCoder JSON (snake_case, Unix-second dates, sorted keys). A nil
/// optional is an absent key.
public struct HeartbeatPayload: Codable, Equatable, Sendable {
    public static let recordName = "heartbeat"
    /// Cap on `macName`, in grapheme clusters (clipped by the hub).
    public static let maxMacNameLength = 60
    /// Cap on `accounts` (the hub publishes at most this many).
    public static let maxAccounts = 20

    public let updatedAt: Date
    public let appVersion: String
    /// One UUID per hub install.
    public let hubID: String
    /// `Host.current().localizedName`, at most `maxMacNameLength`.
    public let macName: String
    public let flavor: HubFlavor
    /// nil until the hub's first publish.
    public let lastPublishAt: Date?
    /// nil until the hub's first relay cycle.
    public let lastRelayAt: Date?
    /// Unprocessed relay records the hub has seen.
    public let relayBacklog: Int
    /// Read-only account status rows, never a token.
    public let accounts: [HeartbeatAccount]
    /// When the hub was turned on.
    public let enabledAt: Date
    /// The Mac's `CKContainer.userRecordID().recordName` (spec §2.3).
    public let ownerUser: String
    public let sharing: HubSharing

    // convertFromSnakeCase maps "hub_id" -> "hubId" (lowercase d), so the
    // CodingKey stringValue must be "hubId" to round-trip.
    enum CodingKeys: String, CodingKey {
        case updatedAt
        case appVersion
        case hubID = "hubId"
        case macName
        case flavor
        case lastPublishAt
        case lastRelayAt
        case relayBacklog
        case accounts
        case enabledAt
        case ownerUser
        case sharing
    }

    public init(
        updatedAt: Date,
        appVersion: String,
        hubID: String,
        macName: String,
        flavor: HubFlavor,
        lastPublishAt: Date?,
        lastRelayAt: Date?,
        relayBacklog: Int,
        accounts: [HeartbeatAccount],
        enabledAt: Date,
        ownerUser: String,
        sharing: HubSharing
    ) {
        self.updatedAt = updatedAt
        self.appVersion = appVersion
        self.hubID = hubID
        self.macName = macName
        self.flavor = flavor
        self.lastPublishAt = lastPublishAt
        self.lastRelayAt = lastRelayAt
        self.relayBacklog = relayBacklog
        self.accounts = accounts
        self.enabledAt = enabledAt
        self.ownerUser = ownerUser
        self.sharing = sharing
    }
}

/// The Desktop build flavor that runs the hub. rawValues are wire format.
public enum HubFlavor: String, Codable, CaseIterable, Sendable {
    case `default`
    case corp
}

/// Whether the hub's zone shares exist (spec §4.1). rawValues are wire format.
public enum HubSharing: String, Codable, CaseIterable, Sendable {
    /// The zone shares exist.
    case available
    /// Sharing failed or is not possible on this account.
    case unavailable
    /// No QR code has been shown yet, so no share was created.
    case none
}

/// One read-only account row in the heartbeat: label and status only.
public struct HeartbeatAccount: Codable, Equatable, Sendable {
    /// Cap on `label`, in grapheme clusters (clipped by the hub).
    public static let maxLabelLength = 80

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case slack
        case google
        case jira
    }

    public let kind: Kind
    public let label: String
    public let status: String

    public init(kind: Kind, label: String, status: String) {
        self.kind = kind
        self.label = label
        self.status = status
    }
}

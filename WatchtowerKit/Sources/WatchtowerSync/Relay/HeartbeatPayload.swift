import Foundation

/// The hub's liveness record (mobile POC spec §4.1), rewritten every 900 s.
/// It lives in DataZone under the record name `heartbeat`: only the hub
/// writes that zone, so a RelayZone share participant cannot rewrite it.
/// The phone shows the Mac online while `updatedAt` is under 2100 s old.
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
    /// What runs the hub (#1783); nil from an older hub, which is a Mac.
    public let hubKind: HubKind?
    /// The host's switches (protocol §9); nil from an older hub.
    public let capabilities: HeartbeatCapabilities?
    /// When the oldest kind the hub still cannot publish whole (a failed save, a refused or oversized record)
    /// first failed (#1873); nil while every kind goes through, and from an older hub.
    public let stuckSince: Date?

    /// Whether the phone offers recording: on unless the hub says `off` (an older hub, an absent key and an
    /// unknown value read as on).
    public var recordingsOffered: Bool { capabilities?.recordings != "off" }

    /// Whether the phone shows AI chat: only on an explicit `"on"` (iPhone chat spec D4). An absent key is an older
    /// hub, which is not a chat host, unlike `recordings`.
    public var chatOffered: Bool { capabilities?.chat == "on" }

    /// Whether the hub runs beside the Watchtower app on a Mac, so the app's
    /// menus exist there: true for `mac` and for an older hub that sends no
    /// kind; false for `server` and a kind this build does not know.
    public var isMac: Bool { hubKind == nil || hubKind == .mac }

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
        case hubKind
        case capabilities
        case stuckSince
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
        sharing: HubSharing,
        hubKind: HubKind? = nil,
        capabilities: HeartbeatCapabilities? = nil,
        stuckSince: Date? = nil
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
        self.hubKind = hubKind
        self.capabilities = capabilities
        self.stuckSince = stuckSince
    }
}

/// The heartbeat's `capabilities` object. Values are strings so one a newer hub adds never fails the heartbeat.
public struct HeartbeatCapabilities: Codable, Equatable, Sendable {
    /// "on" or "off"; absent reads as on.
    public let recordings: String?
    /// "on" or "off"; only an explicit "on" offers chat.
    public let chat: String?
    /// Why `chat` is off (`ChatOffReason`); absent while on.
    public let chatReason: String?
    /// The phone Inbox (mobile Inbox spec §6): "on", or "policy_off" under the organization's workbench_only
    /// policy; absent from an older hub, which publishes no Inbox.
    public let inbox: String?
    /// Why `inbox` is off ("policy"); absent while on.
    public let inboxReason: String?
    /// The chat approval decisions beyond approve and reject (mobile Inbox spec §12.9): "retry_dismiss" while
    /// `chat_action_answer` takes retry and dismiss; absent from an older hub, whose chat offers neither.
    public let chatActions: String?

    /// The hub's `chat_action_answer` takes retry and dismiss.
    public var chatRetryAndDismiss: Bool { chatActions == "retry_dismiss" }

    /// `chatReason` as a typed value; nil while absent.
    public var chatOffReason: ChatOffReason? { chatReason.map(ChatOffReason.init(rawValue:)) }

    public init(
        recordings: String? = nil,
        chat: String? = nil,
        chatReason: String? = nil,
        inbox: String? = nil,
        inboxReason: String? = nil,
        chatActions: String? = nil
    ) {
        self.recordings = recordings
        self.chat = chat
        self.chatReason = chatReason
        self.inbox = inbox
        self.inboxReason = inboxReason
        self.chatActions = chatActions
    }
}

/// Why the hub's chat capability is off (iPhone chat spec §4.8). rawValues are wire format; a reason added by a
/// newer hub decodes as an unknown value (`OpenWireValue`) and the phone shows the generic "unavailable" line.
public struct ChatOffReason: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The hub's transport is not the relay (CloudKit).
    public static let notRelay = Self(rawValue: "not_relay")
    /// The hub's chat runner did not start.
    public static let runnerDown = Self(rawValue: "runner_down")
    /// A running Desktop app does not honour the chat lease: "Update Watchtower on your Mac".
    public static let desktopTooOld = Self(rawValue: "desktop_too_old")
    /// The organization's policy forbids it.
    public static let policy = Self(rawValue: "policy")
    public static let knownValues: [Self] = [.notRelay, .runnerDown, .desktopTooOld, .policy]
}

/// The Desktop build flavor that runs the hub. rawValues are wire format;
/// a newer Mac's flavor decodes as an unknown value (`OpenWireValue`).
public struct HubFlavor: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let `default` = Self(rawValue: "default")
    public static let corp = Self(rawValue: "corp")
    public static let knownValues: [Self] = [.default, .corp]
}

/// What runs the hub (#1783). rawValues are wire format; a kind added by a
/// newer hub decodes as an unknown value (`OpenWireValue`).
public struct HubKind: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A hub beside the Watchtower app on a Mac.
    public static let mac = Self(rawValue: "mac")
    /// A headless hub (a server).
    public static let server = Self(rawValue: "server")
    public static let knownValues: [Self] = [.mac, .server]
}

/// Whether the hub's zone shares exist (spec §4.1). rawValues are wire
/// format; a newer state decodes as an unknown value (`OpenWireValue`).
public struct HubSharing: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The zone shares exist.
    public static let available = Self(rawValue: "available")
    /// Sharing failed or is not possible on this account.
    public static let unavailable = Self(rawValue: "unavailable")
    /// No QR code has been shown yet, so no share was created.
    public static let none = Self(rawValue: "none")
    public static let knownValues: [Self] = [.available, .unavailable, .none]
}

/// One read-only account row in the heartbeat: label and status only.
public struct HeartbeatAccount: Codable, Equatable, Sendable {
    /// Cap on `label`, in grapheme clusters (clipped by the hub).
    public static let maxLabelLength = 80

    /// rawValues are wire format; a connector kind added by a newer Mac
    /// decodes as an unknown value (`OpenWireValue`).
    public struct Kind: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let slack = Self(rawValue: "slack")
        public static let google = Self(rawValue: "google")
        public static let jira = Self(rawValue: "jira")
        public static let knownValues: [Self] = [.slack, .google, .jira]
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

import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerSync

/// The Mac this phone is linked to (mobile POC spec §2.3): the hub, the
/// database scope it syncs through, and the share URLs kept from the scan.
struct LinkRecord: Codable, Equatable, Sendable {
    let hubID: String
    let macName: String
    let scope: DeviceScope
    /// The Mac user's `userRecordID.recordName` (the code's `owner_user`):
    /// in `shared` scope, the owner of every shared zone.
    let ownerName: String
    /// This phone's iCloud user when it linked. Another account signing in
    /// ends the link (spec §9).
    let userRecordName: String
    /// The single-use code the link was made with.
    let nonce: String
    /// The two `CKShare.url`s of a `shared` link (nil in `private` scope):
    /// kept so the shares can be accepted again (spec §2.3 fallback F2).
    let dataShareURL: String?
    let relayShareURL: String?
    /// The device id this phone linked with (its `device` record's): the
    /// grant the removal check reads (#64), whatever the Keychain says
    /// later. nil in a link saved before it was kept: no removal is ever
    /// read from such a link.
    var deviceID: String?
    /// The linked grant's `linked_at` (the Mac's clock) when the link was
    /// saved; nil in an older link. A removal is read only from a heartbeat
    /// newer than it.
    var linkedAt: Date?

    // The hosted relay (relay client Phase 3). Every key is optional and
    // absent in a link saved before it, and in every CloudKit link.

    /// The transport this link talks over; nil = `.cloudKit`. Set with the
    /// Mac's relay id (`setRelay(mac:)`), never alone.
    private(set) var transport: TransportKind?
    /// The Mac's relay device id: the route of a `.relay` link, which never
    /// saves or reads without it.
    private(set) var relayMacDeviceID: String?
    /// The Mac's `relay_auth` public key, base64url, from the code.
    var relayAuthPub: String?
    /// Every transport the hub offers, raw wire values, from the code or grant.
    var hubTransports: [String]?
    /// Who switched the hub's transport last, and when (R13: Phase 4 shows them).
    var switchedBy: String?
    var switchedAt: Date?
    /// A transport the link left whose mailbox is still to drain (rule 15).
    var leftTransport: TransportKind?
    /// An iCloud link's upgrade to the relay (relay client Phase 3b Task 19): its step, request and refusal. Absent in
    /// every link saved before it and in every link that never upgraded. One this build cannot read reads as absent.
    var relayUpgrade: RelayUpgradeRecord?
    /// This phone's request that the hub move to iCloud, or the end it came to (relay client Phase 4 Task 5). Absent
    /// while none is open and on every CloudKit link. One this build cannot read reads as absent.
    var transportRequest: TransportRequestRecord?
    /// When the hub told this phone it stays on the relay for another paying phone (`hub_on_relay`, or a move to the
    /// relay this phone cannot follow), while it has not moved since. Absent on every CloudKit link.
    var hubOnRelayAt: Date?
    /// A relay-only link the relay refuses (relay client Phase 5): set at the first `relayLapsed` (`.lapse`) or
    /// `slotLost` (`.slot`) with no other route; its `since` starts the link's term. Absent on every other link and
    /// in every link saved before it. One this build cannot read reads as absent.
    var relayRefused: RelayRefusedRecord?

    /// A `.relay` transport needs `relayMacDeviceID` (it is the route).
    init(
        hubID: String,
        macName: String,
        scope: DeviceScope,
        ownerName: String,
        userRecordName: String,
        nonce: String,
        dataShareURL: String?,
        relayShareURL: String?,
        deviceID: String? = nil,
        linkedAt: Date? = nil,
        transport: TransportKind? = nil,
        relayMacDeviceID: String? = nil,
        relayAuthPub: String? = nil,
        hubTransports: [String]? = nil,
        switchedBy: String? = nil,
        switchedAt: Date? = nil,
        leftTransport: TransportKind? = nil,
        relayUpgrade: RelayUpgradeRecord? = nil,
        transportRequest: TransportRequestRecord? = nil,
        hubOnRelayAt: Date? = nil,
        relayRefused: RelayRefusedRecord? = nil
    ) {
        precondition(transport != .relay || relayMacDeviceID != nil, Self.relayWithoutMac)
        self.hubID = hubID
        self.macName = macName
        self.scope = scope
        self.ownerName = ownerName
        self.userRecordName = userRecordName
        self.nonce = nonce
        self.dataShareURL = dataShareURL
        self.relayShareURL = relayShareURL
        self.deviceID = deviceID
        self.linkedAt = linkedAt
        self.transport = transport
        self.relayMacDeviceID = relayMacDeviceID
        self.relayAuthPub = relayAuthPub
        self.hubTransports = hubTransports
        self.switchedBy = switchedBy
        self.switchedAt = switchedAt
        self.leftTransport = leftTransport
        self.relayUpgrade = relayUpgrade
        self.transportRequest = transportRequest
        self.hubOnRelayAt = hubOnRelayAt
        self.relayRefused = relayRefused
    }

    /// A `.relay` link without its Mac's relay id does not decode: the row is
    /// unreadable (listed with Forget), never routed anywhere.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hubID = try container.decode(String.self, forKey: .hubID)
        macName = try container.decode(String.self, forKey: .macName)
        scope = try container.decode(DeviceScope.self, forKey: .scope)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        userRecordName = try container.decode(String.self, forKey: .userRecordName)
        nonce = try container.decode(String.self, forKey: .nonce)
        dataShareURL = try container.decodeIfPresent(String.self, forKey: .dataShareURL)
        relayShareURL = try container.decodeIfPresent(String.self, forKey: .relayShareURL)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        linkedAt = try container.decodeIfPresent(Date.self, forKey: .linkedAt)
        transport = try container.decodeIfPresent(TransportKind.self, forKey: .transport)
        relayMacDeviceID = try container.decodeIfPresent(String.self, forKey: .relayMacDeviceID)
        relayAuthPub = try container.decodeIfPresent(String.self, forKey: .relayAuthPub)
        hubTransports = try container.decodeIfPresent([String].self, forKey: .hubTransports)
        switchedBy = try container.decodeIfPresent(String.self, forKey: .switchedBy)
        switchedAt = try container.decodeIfPresent(Date.self, forKey: .switchedAt)
        leftTransport = try container.decodeIfPresent(TransportKind.self, forKey: .leftTransport)
        // A newer build's step or refusal must not make the whole link unreadable.
        relayUpgrade = try? container.decodeIfPresent(RelayUpgradeRecord.self, forKey: .relayUpgrade)
        transportRequest = try? container.decodeIfPresent(TransportRequestRecord.self, forKey: .transportRequest)
        hubOnRelayAt = try? container.decodeIfPresent(Date.self, forKey: .hubOnRelayAt)
        relayRefused = try? container.decodeIfPresent(RelayRefusedRecord.self, forKey: .relayRefused)
        if lacksRelayMac {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: Self.relayWithoutMac))
        }
    }

    /// Never saved as a `.relay` link without its Mac's relay id.
    func encode(to encoder: any Encoder) throws {
        if lacksRelayMac {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: Self.relayWithoutMac))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hubID, forKey: .hubID)
        try container.encode(macName, forKey: .macName)
        try container.encode(scope, forKey: .scope)
        try container.encode(ownerName, forKey: .ownerName)
        try container.encode(userRecordName, forKey: .userRecordName)
        try container.encode(nonce, forKey: .nonce)
        try container.encodeIfPresent(dataShareURL, forKey: .dataShareURL)
        try container.encodeIfPresent(relayShareURL, forKey: .relayShareURL)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(linkedAt, forKey: .linkedAt)
        try container.encodeIfPresent(transport, forKey: .transport)
        try container.encodeIfPresent(relayMacDeviceID, forKey: .relayMacDeviceID)
        try container.encodeIfPresent(relayAuthPub, forKey: .relayAuthPub)
        try container.encodeIfPresent(hubTransports, forKey: .hubTransports)
        try container.encodeIfPresent(switchedBy, forKey: .switchedBy)
        try container.encodeIfPresent(switchedAt, forKey: .switchedAt)
        try container.encodeIfPresent(leftTransport, forKey: .leftTransport)
        try container.encodeIfPresent(relayUpgrade, forKey: .relayUpgrade)
        try container.encodeIfPresent(transportRequest, forKey: .transportRequest)
        try container.encodeIfPresent(hubOnRelayAt, forKey: .hubOnRelayAt)
        try container.encodeIfPresent(relayRefused, forKey: .relayRefused)
    }

    private enum CodingKeys: String, CodingKey {
        case hubID, macName, scope, ownerName, userRecordName, nonce, dataShareURL, relayShareURL, deviceID, linkedAt
        case transport, relayMacDeviceID, relayAuthPub, hubTransports, switchedBy, switchedAt, leftTransport, relayUpgrade
        case transportRequest, hubOnRelayAt, relayRefused
    }

    private static let relayWithoutMac = "a relay link without its Mac's relay device id"

    private var lacksRelayMac: Bool { transport == .relay && relayMacDeviceID == nil }

    /// Moves the link to the relay Mac `mac`.
    mutating func setRelay(mac: String) {
        transport = .relay
        relayMacDeviceID = mac
    }

    /// Keeps the Mac's relay identity on a link that stays where it is (an iCloud link upgrading to the relay, after
    /// its `add_slot`): the route does not change until the hub switches.
    mutating func setRelayIdentity(mac: String, authPub: String?, transports: [String]?) {
        relayMacDeviceID = mac
        relayAuthPub = authPub
        hubTransports = transports
    }

    /// Moves the link back to CloudKit (its scope's database), keeping the Mac's relay id so a later switch can
    /// move it to the relay again; `left` is the transport whose mailbox is still to drain (rule 15).
    mutating func setCloudKit(left: TransportKind?) {
        transport = .cloudKit
        leftTransport = left
    }

    /// The mailbox on `kind`, which this link left, is drained (rule 15): nothing is left to drain there.
    mutating func leftMailboxDrained(_ kind: TransportKind) {
        if leftTransport == kind { leftTransport = nil }
    }

    /// Where the phone's transport syncs this link: the relay Mac of a
    /// `.relay` link, else a CloudKit database.
    var route: HubRoute {
        guard transport == .relay else { return cloudKitRoute }
        guard let relayMacDeviceID else { preconditionFailure(Self.relayWithoutMac) }
        return .hostedRelay(macDeviceID: relayMacDeviceID)
    }

    /// The link's CloudKit database, whatever its transport.
    var cloudKitRoute: HubRoute {
        scope == .shared ? .cloudKit(.shared(ownerName: ownerName)) : .cloudKit(.private)
    }

    /// The hub offers CloudKit; an absent list offers it, as in `TransportFollower`'s refusal.
    var offersCloudKit: Bool {
        hubTransports?.contains(TransportKind.cloudKit.rawValue) ?? true
    }

    /// The hub has no iCloud to go to: by its own list on the row, or by the grant it published.
    func isRelayOnly(grant: DeviceGrant?) -> Bool {
        !offersCloudKit || grant?.transports?.contains(TransportKind.cloudKit.rawValue) == false
    }

    /// The hub's route on the transport this link is not on, when the hub has both (relay client Phase 3 Task 12):
    /// the relay needs the Mac's relay id, CloudKit a hub that offers it. nil for a link with one route.
    var otherRoute: HubRoute? {
        guard let relayMacDeviceID, offersCloudKit else { return nil }
        return transport == .relay ? cloudKitRoute : .hostedRelay(macDeviceID: relayMacDeviceID)
    }
}

/// Why and since when the relay refuses a relay-only link (relay client Phase 5): the link's term runs from `since`
/// (Task 17 reads it; no merge clears it).
struct RelayRefusedRecord: Codable, Equatable, Sendable {
    let since: Date
    var cause: RelayRefusal
}

/// A link written to the Mac and not answered yet (spec §2.3 step 5). Kept
/// across a kill, so a relaunch resumes the wait for what is left of it.
struct PendingLink: Codable, Equatable, Sendable {
    let link: LinkRecord
    /// The end of the 60 s grant wait, on the phone's clock.
    let deadline: Date
    /// This phone's grant as the replica held it just before the device
    /// record was written: an earlier answer (a refusal of another code) is
    /// not this scan's.
    let baseline: DeviceGrant?
    /// `baseline` was read (nil then means no grant). false while the sync
    /// stack restarts, before the device record is written; a value saved
    /// by an older build reads false.
    let baselineCaptured: Bool
    /// The scanned code's `iat`, on the Mac's clock (mobile E2E review M-3):
    /// a `linked` keybox decided before it is an older link, not this scan's
    /// confirmation. nil in a value an older build saved.
    let issuedAt: Date?
    /// A Relay link's pairing slot (`open_pairing`) and when it expires; nil for an iCloud link.
    let relaySlot: String?
    let relaySlotExpiresAt: Date?
    /// A Relay link's grant `linked_at` (the Mac's clock), written before the keybox's keys are stored: a launch
    /// that finds the keys and no promoted entry confirms the link with it. Absent in a value an older build saved.
    var linkedAt: Date?

    init(
        link: LinkRecord,
        deadline: Date,
        baseline: DeviceGrant?,
        baselineCaptured: Bool,
        issuedAt: Date? = nil,
        relaySlot: String? = nil,
        relaySlotExpiresAt: Date? = nil
    ) {
        self.link = link
        self.deadline = deadline
        self.baseline = baseline
        self.baselineCaptured = baselineCaptured
        self.issuedAt = issuedAt
        self.relaySlot = relaySlot
        self.relaySlotExpiresAt = relaySlotExpiresAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        link = try container.decode(LinkRecord.self, forKey: .link)
        deadline = try container.decode(Date.self, forKey: .deadline)
        baseline = try container.decodeIfPresent(DeviceGrant.self, forKey: .baseline)
        baselineCaptured = try container.decodeIfPresent(Bool.self, forKey: .baselineCaptured) ?? false
        issuedAt = try container.decodeIfPresent(Date.self, forKey: .issuedAt)
        relaySlot = try container.decodeIfPresent(String.self, forKey: .relaySlot)
        relaySlotExpiresAt = try container.decodeIfPresent(Date.self, forKey: .relaySlotExpiresAt)
        linkedAt = try container.decodeIfPresent(Date.self, forKey: .linkedAt)
    }
}

/// A Relay link the owner confirmed on the Mac (relay client Phase 3 Task 10, point 9): it left the link screen,
/// holds its keys until it completes or the owner cancels it, and is resumed by `PromotedLinkResumer` at every
/// launch, on every foreground and on Try Again. Kept in `LinkStore.promoted` by hub id.
struct PromotedLink: Codable, Equatable, Sendable {
    /// Why a confirmed link waits for the owner, from a definite refusal of `vouch` or `promote`.
    enum Reason: String, Codable, CaseIterable, Sendable {
        /// `PAIRING_EXPIRED`: the slot passed its 600 s.
        case slotExpired
        /// `SLOT_LIMIT`: the account holds 3 other Macs.
        case slotsFull
        /// `SLOT_REPLACEMENT_LIMIT`.
        case replacementLimit
        /// `ENTITLEMENT_INACTIVE`.
        case notPaying
        /// `NOT_FOUND` from `vouch`: the hub is not registered on the relay.
        case hubNotOnRelay
        /// The relay did not confirm the link (a second `HUB_NOT_VOUCHED`, a `NOT_FOUND` re-promote, `FORBIDDEN`).
        case notConfirmed
        /// `ATTESTATION_REQUIRED`, or `ATTESTATION_FAILED` after the retries.
        case updateApp
        /// `HubRegistry.limit` Macs got linked meanwhile: the promoted link cannot be saved (review round 1).
        case tooManyMacs

        /// The Settings → Macs row's line (and the link screen's notice, before "See Settings → Macs.").
        func message(macName: String) -> String {
            switch self {
            case .slotExpired: "The link timed out on Relay. Try again, or cancel it."
            case .slotsFull: "Relay already has \(HostedRelayLimits.maxMacSlots) Macs. Remove one, then try again, or cancel this link."
            case .replacementLimit: "Too many Mac changes on Relay. Try again later, or cancel this link."
            case .notPaying: "Relay isn't active on this iPhone. Try again when it is, or cancel this link."
            case .hubNotOnRelay: "\(macName) isn't on Relay yet. Keep Watchtower open on it and try again, or cancel this link."
            case .notConfirmed: "Relay didn't confirm the link. Try again, or cancel it."
            case .updateApp: "Update Watchtower to finish this link, or cancel it."
            case .tooManyMacs: "You can link up to \(HubRegistry.limit) Macs. Unlink one, then try again, or cancel this link."
            }
        }

        /// Try Again opens a new slot first (no hello: the keys are held).
        var needsNewSlot: Bool { self == .slotExpired || self == .notConfirmed }
    }

    enum State: Codable, Equatable, Sendable {
        /// The keys are held, no vouch yet.
        case confirmed
        /// `promote_pairing` was sent and its answer is unknown.
        case promoteSent
        /// The Mac holds a slot: only `prepare` and `linked` are left.
        case promoted
        /// Nothing automatic: the owner's Try Again, Manage Macs or Cancel.
        case needsOwner(Reason)
    }

    /// The link to save once it completes: a `.relay` link to `link.relayMacDeviceID`.
    var link: LinkRecord
    var slot: String
    var slotExpiresAt: Date
    var state: State
    /// When the owner confirmed it.
    var since: Date
    /// The last successful `vouch_hub`: a promote more than 10 minutes after it vouches first again.
    var vouchedAt: Date?

    var hubID: String { link.hubID }
    var macName: String { link.macName }
    /// The Mac's relay device id (a `.relay` link always has it).
    var macDeviceID: String { link.relayMacDeviceID ?? "" }
}

/// The link flow's state in `UserDefaults`: a link waiting for its grant,
/// which a relaunch resumes. The saved links are the hub registry's
/// (`HubRegistry`); an F1 phone's single link is read here once, by
/// `HubBoot.migrateF1`, which moves it into the registry and clears it.
final class LinkStore {
    private let defaults: UserDefaults
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkStore")

    private enum Keys {
        static let legacyLink = "link.record"
        static let pending = "link.pending"
        static let legacyGrantMissingSince = "link.grantMissingSince"
        static let promoted = "link.promoted"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The single link of F1 (`link.record`), for the migration only.
    var legacyLink: LinkRecord? {
        get { read(LinkRecord.self, key: Keys.legacyLink) }
        set { write(newValue, key: Keys.legacyLink) }
    }

    /// `link.record` holds data that does not decode: a link is saved, but
    /// `legacyLink` reads nil.
    var holdsUnreadableLink: Bool {
        defaults.object(forKey: Keys.legacyLink) != nil && legacyLink == nil
    }

    /// F1's first look of the removal check (#64), for the migration only.
    var legacyGrantMissingSince: Date? {
        get { defaults.object(forKey: Keys.legacyGrantMissingSince) as? Date }
        set { defaults.set(newValue, forKey: Keys.legacyGrantMissingSince) }
    }

    /// Removes F1's link keys.
    func clearLegacyLink() {
        defaults.removeObject(forKey: Keys.legacyLink)
        defaults.removeObject(forKey: Keys.legacyGrantMissingSince)
    }

    var pending: PendingLink? {
        get { read(PendingLink.self, key: Keys.pending) }
        set { write(newValue, key: Keys.pending) }
    }

    /// The confirmed Relay links still finishing, by hub id. Decoded per entry: an entry this build cannot read (a
    /// `Reason` or `State` case of a newer build, after a downgrade) is skipped with a log line, never the others,
    /// and kept as it is stored by every write (`unreadablePromotedHubIDs`).
    var promoted: [String: PromotedLink] {
        get { promotedEntries().compactMapValues(\.link) }
        set {
            var entries = promotedEntries().filter { $0.value.link == nil && newValue[$0.key] == nil }
            for (hubID, link) in newValue { entries[hubID] = .link(link) }
            write(entries.isEmpty ? nil : entries, key: Keys.promoted)
        }
    }

    /// The hubs of the promoted entries this build cannot read: their files and keys stay (the launch's orphan pass
    /// keeps them); a build that reads them goes on with them.
    var unreadablePromotedHubIDs: [String] {
        promotedEntries().filter { $0.value.link == nil }.keys.sorted()
    }

    /// One stored promoted entry: a link, or JSON this build cannot read, kept as it is.
    private enum PromotedEntry: Codable {
        case link(PromotedLink)
        case unreadable(JSONValue)

        var link: PromotedLink? {
            if case .link(let link) = self { return link }
            return nil
        }

        init(from decoder: Decoder) throws {
            if let link = try? PromotedLink(from: decoder) {
                self = .link(link)
            } else {
                self = .unreadable(try JSONValue(from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .link(let link): try link.encode(to: encoder)
            case .unreadable(let value): try value.encode(to: encoder)
            }
        }
    }

    /// Hub ids whose unreadable entry was logged: one line per hub per store; a clean read of the hub re-arms it.
    private var loggedUnreadable: Set<String> = []
    private let loggedLock = NSLock()
    /// Called with the hub id when its unreadable entry is logged (tests).
    var onUnreadableLogged: ((String) -> Void)?

    private func promotedEntries() -> [String: PromotedEntry] {
        let entries = read([String: PromotedEntry].self, key: Keys.promoted) ?? [:]
        let unreadable = Set(entries.filter { $0.value.link == nil }.keys)
        let fresh = loggedLock.withLock { () -> [String] in
            let new = unreadable.subtracting(loggedUnreadable)
            loggedUnreadable = unreadable
            return new.sorted()
        }
        for hubID in fresh {
            Self.logger.error("unreadable promoted link skipped: \(hubID, privacy: .private)")
            onUnreadableLogged?(hubID)
        }
        return entries
    }

    /// Why `confirm` did not keep the link.
    struct NotKept: Error {}

    /// The owner confirmed `link`: it is kept in `promoted` and leaves `pending`, the promoted write first and
    /// checked, so a failed write keeps the link in `pending` (a relaunch resumes it and writes this again).
    func confirm(_ link: PromotedLink) throws {
        var all = promoted
        all[link.hubID] = link
        promoted = all
        guard promoted[link.hubID] == link else { throw NotKept() }
        if pending?.link.hubID == link.hubID {
            pending = nil
        }
    }

    /// Updates a promoted link that is still kept (a cancel meanwhile is never undone).
    func update(_ link: PromotedLink) {
        var all = promoted
        guard all[link.hubID] != nil else { return }
        all[link.hubID] = link
        promoted = all
    }

    /// The owner's own removal of `hubID` (Unlink, Forget): its promoted entry this build cannot read goes too, so a
    /// later build that could read it does not bring the removed Mac back. Never a readable entry (those go through
    /// `removePromoted`) and never another hub's. The only deletion of an unreadable entry.
    func removeUnreadablePromoted(_ hubID: String) {
        let entries = promotedEntries()
        guard let entry = entries[hubID], entry.link == nil else { return }
        var rest = entries
        rest[hubID] = nil
        write(rest.isEmpty ? nil : rest, key: Keys.promoted)
    }

    func removePromoted(_ hubID: String) {
        var all = promoted
        guard all.removeValue(forKey: hubID) != nil else { return }
        promoted = all
    }

    /// Plain JSON (local state, not wire format: RelayCoder's snake-case
    /// keys would not round-trip `hubID`). An unreadable value reads as
    /// absent and is logged: the phone then shows Welcome rather than run a
    /// link it cannot read.
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error("unreadable \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T?, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Self.logger.error("could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

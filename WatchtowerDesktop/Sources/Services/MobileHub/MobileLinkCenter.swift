import CloudKit
import Foundation
import os
import WatchtowerCore
import WatchtowerSync

/// Why `issueCode()` showed no QR.
enum MobileLinkError: Error, Equatable, LocalizedError {
    /// iCloud is not `.available` on this Mac (spec §2.3 failure table).
    case account(CloudAvailability)
    /// The Mac's iCloud user record name (the QR's `owner_user`) could not
    /// be looked up.
    case ownerUnknown

    var errorDescription: String? {
        switch self {
        case .account(.noAccount): return "Mobile isn't available on this Mac: iCloud is off."
        case .account(.restricted): return "Mobile isn't available on this Mac: iCloud is restricted by your organization."
        case .account(.unavailable(let reason)): return "Mobile isn't available on this Mac: \(reason)"
        case .account(.available), .ownerUnknown: return "This Mac couldn't read its iCloud account. Try again."
        }
    }
}

/// The Mac side of linking a phone (mobile POC spec §2.3, §4.13, §10): the
/// QR code and its single-use nonce, the two zone shares and their public
/// link window, the decision on each phone `device` record, the linked
/// phones and their grants.
///
/// - `issueCode()` refuses without iCloud, creates the zone shares on first
///   use (a failure leaves the share URLs out: only a same-Apple-ID phone can
///   link then), opens the public link and stores the code (`exp = iat + 600`).
/// - `closeLink(reason:)` runs on use, at expiry and when the sheet closes:
///   it closes the public link, then removes every participant whose iCloud
///   user is not a linked `shared` phone (one bound to a used nonce). The
///   sweep runs only while `hub_meta` marks it pending (the link was opened,
///   or a Remove failed to drop its participant); a failed sweep keeps the
///   mark and is retried by the next close (`.restart` at the next hub build).
/// - Every share call is bounded (`shareTimeout`): offline CloudKit waits
///   for connectivity, and `handleDevice` runs inside the relay pass, which a
///   hub stop waits for. The close after a link runs outside the pass.
/// - `handleDevice(_:)` links a phone whose record carries a valid nonce,
///   written by the phone's own user (`shared`: the record's creator equals
///   `user_record_name` and has accepted both shares). A refused nonce is
///   published as `device_grant` with `link_refused`; a wrong creator gets
///   no grant at all. A linked phone keeps its link whatever nonce it sends
///   later; a removed one is never re-linked by an old nonce.
///
/// The `device_grant` records are `DeviceGrantSlice`'s, from the sidecar;
/// every change here nudges that kind.
@MainActor
@Observable
final class MobileLinkCenter {
    enum CloseReason: String, Sendable {
        case used
        case expired
        case sheetClosed = "sheet_closed"
        /// A link left open by an earlier run (a crash with the QR shown).
        case restart
    }

    /// `link_codes` keeps this many, newest first (spec §2.3).
    nonisolated static let keptCodes = 50
    /// `hub_meta`: "1" while the shares need a close-and-sweep (from just
    /// before the public link opens, or after a Remove whose participant
    /// removal failed) until a close succeeds.
    nonisolated static let sweepPendingKey = "share_sweep_pending"
    /// Bound on the iCloud user lookup.
    nonisolated static let ownerLookupTimeout: Duration = .seconds(30)

    /// The QR on screen; nil once it was used, expired or the sheet closed.
    private(set) var openCode: LinkPayload?
    /// The linked phones, oldest link first.
    private(set) var devices: [HubSyncState.LinkedDevice] = []

    /// The heartbeat's `sharing` (set to `MobileHubService.sharing`).
    @ObservationIgnored var onSharingChanged: (@MainActor (HubSharing) -> Void)?

    @ObservationIgnored private let sidecar: HubSyncState
    @ObservationIgnored private let shares: any ShareService
    @ObservationIgnored private let macName: String
    @ObservationIgnored private let ownerUser: @Sendable () async -> String?
    @ObservationIgnored private let nudge: @MainActor (Set<SliceKind>) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let shareTimeout: Duration
    /// The close that follows a link, run outside the relay pass.
    @ObservationIgnored private(set) var closeAfterLink: Task<Void, Never>?
    @ObservationIgnored private var knownOwnerUser: String?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// Bumped each time the public link opens, so a close that was
    /// suspended while a new code opened it never marks it closed.
    @ObservationIgnored private var linkEpoch = 0
    @ObservationIgnored private let logger = Logger(subsystem: Constants.bundleID, category: "MobileLinkCenter")

    init(
        sidecar: HubSyncState,
        shares: any ShareService,
        macName: String,
        ownerUser: @escaping @Sendable () async -> String?,
        nudge: @escaping @MainActor (Set<SliceKind>) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        shareTimeout: Duration = MobileHubService.defaultCloudTimeout
    ) {
        self.sidecar = sidecar
        self.shares = shares
        self.macName = macName
        self.ownerUser = ownerUser
        self.nudge = nudge
        self.now = now
        self.sleep = sleep
        self.shareTimeout = shareTimeout
        reloadDevices()
    }

    /// The hub's link center over `storage`'s shares; nil for a storage
    /// without a share service (a stub), which links no phone.
    static func forHub(storage: MobileHubStorage, macName: String, publisher: SlicePublisher) -> MobileLinkCenter? {
        guard let shares = storage.shares else { return nil }
        return MobileLinkCenter(
            sidecar: storage.sidecar, shares: shares, macName: macName, ownerUser: storage.ownerUser,
            nudge: { [weak publisher] in publisher?.nudge(kinds: $0) } // swiftlint:disable:this trailing_closure
        )
    }

    /// Where the relay sends phone `device` records.
    var relayRoute: RelayProcessor.DeviceRecords {
        RelayProcessor.DeviceRecords { [weak self] in try await self?.handleDevice($0) }
    }

    /// Hangs the center on `hub`: Settings reaches it there, a take over
    /// tears the shares down, the heartbeat carries `sharing`. A public link
    /// an earlier run left open (a crash with the QR shown) is closed now.
    func attach(to hub: MobileHubService) {
        hub.linkCenter = self
        hub.onTakeOver = { [weak self] in await self?.takeOverReset() }
        onSharingChanged = { [weak hub] in hub?.sharing = $0 }
        Task { await closeLink(reason: .restart) }
    }

    /// The Mac's iCloud account, for Settings → Mobile's sentences.
    func accountAvailability() async -> CloudAvailability {
        let shares = self.shares
        do {
            return try await share { await shares.accountStatus() }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    // MARK: - The QR code and the public link

    /// A new QR code (Use Watchtower on iPhone, New code). Throws without
    /// iCloud or the Mac's user name; nothing is created then.
    func issueCode() async throws -> LinkPayload {
        let account = await accountAvailability()
        guard account == .available else { throw MobileLinkError.account(account) }
        guard let owner = await resolveOwnerUser() else { throw MobileLinkError.ownerUnknown }
        let hubID = try sidecar.ensureHubID()
        let urls = await openPublicLink()
        let code = LinkPayload.issue(
            hubID: hubID, macName: macName, ownerUser: owner,
            dataShare: urls?.data, relayShare: urls?.relay, now: now()
        )
        try sidecar.addLinkCode(
            nonce: code.nonce, issuedAt: Date(timeIntervalSince1970: TimeInterval(code.iat)),
            exp: Date(timeIntervalSince1970: TimeInterval(code.exp)), keeping: Self.keptCodes
        )
        openCode = code
        scheduleExpiry(of: code)
        return code
    }

    /// Creates the shares if needed and opens their public link; nil (no
    /// share URLs in the QR) when sharing fails.
    private func openPublicLink() async -> ShareURLs? {
        do {
            let shares = self.shares
            let urls = try await share { try await shares.ensureShares() }
            linkEpoch += 1
            // Marked before it opens: a crash in between still closes it.
            try sidecar.setMetaValue("1", forKey: Self.sweepPendingKey)
            try await share { try await shares.setPublicLink(open: true) }
            onSharingChanged?(.available)
            return urls
        } catch {
            logger.warning("zone shares unavailable, QR without share URLs: \(error.localizedDescription, privacy: .public)")
            onSharingChanged?(.unavailable)
            return nil
        }
    }

    private func scheduleExpiry(of code: LinkPayload) {
        expiryTask?.cancel()
        let wait = max(0, TimeInterval(code.exp) - now().timeIntervalSince1970)
        // Holds the center: a center dropped with its QR open still closes
        // the link at expiry.
        expiryTask = Task { [sleep] in
            await sleep(.seconds(wait))
            guard !Task.isCancelled else { return }
            // Detach first: the close cancels `expiryTask`, which would
            // otherwise cancel this very close mid-flight.
            self.expiryTask = nil
            await self.closeLinkIfExpired()
        }
    }

    /// Closes the link once the open code's `exp` has come (its timer).
    func closeLinkIfExpired() async {
        guard let code = openCode, Int64(now().timeIntervalSince1970) >= code.exp else { return }
        await closeLink(reason: .expired)
    }

    /// Closes the public link and removes every participant not bound to a
    /// used nonce (spec §2.3). No share call when no link was opened.
    func closeLink(reason: CloseReason) async {
        expiryTask?.cancel()
        expiryTask = nil
        openCode = nil
        do {
            guard try sidecar.metaValue(forKey: Self.sweepPendingKey) == "1" else { return }
            let epoch = linkEpoch
            let shares = self.shares
            try await share { try await shares.setPublicLink(open: false) }
            let bound = Set(try sidecar.linkedDevices().filter { $0.scope == .shared }.map(\.userRecordName))
            for zone in [CloudZoneID.data, .relay] {
                try await share { try await shares.removeParticipants(in: zone) { !bound.contains($0.userRecordName ?? "") } }
            }
            guard epoch == linkEpoch else { return }
            try sidecar.setMetaValue("0", forKey: Self.sweepPendingKey)
        } catch {
            let why = error.localizedDescription
            logger.error("share link not closed (\(reason.rawValue, privacy: .public)), retried at the next close: \(why, privacy: .public)")
        }
    }

    // MARK: - Device records (spec §2.3, §5.1)

    /// Decides one phone `device` record from RelayZone. Share lookups that
    /// fail leave the phone without a grant (logged; it scans again); only a
    /// sidecar failure throws.
    func handleDevice(_ record: CloudRecord) async throws {
        let payload: DevicePayload
        do {
            payload = try RelayCoder.makeDecoder().decode(DevicePayload.self, from: record.payload)
        } catch {
            logger.warning("undecodable device record \(record.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let nonce = payload.linkNonce, !nonce.isEmpty, payload.unlinked != true else { return }
        guard DeviceScope.knownValues.contains(payload.scope), await creatorMatches(record, payload) else {
            logger.warning("device record \(record.recordName, privacy: .public) not written by its phone's user: no grant")
            return
        }
        let current = now()
        switch HubSyncState.LinkDecision.of(try sidecar.linkCode(nonce), deviceID: payload.deviceID, now: current) {
        case .alreadyUsedByThisDevice:
            return
        case .refused(let reason):
            try refuse(payload, reason, at: current)
            return
        case .valid:
            break
        }
        if payload.scope == .shared {
            guard await hasAcceptedBothShares(payload.userRecordName) else { return }
        }
        let device = HubSyncState.LinkedDevice(
            deviceID: payload.deviceID,
            name: String(payload.name.prefix(DevicePayload.maxNameLength)),
            scope: payload.scope,
            userRecordName: payload.userRecordName,
            linkedAt: Self.wholeSeconds(current)
        )
        let decision = try sidecar.linkDevice(device, nonce: nonce, now: current)
        if case .refused(let reason) = decision {
            try refuse(payload, reason, at: current)
            return
        }
        guard decision == .valid else { return }
        logger.info("linked phone \(payload.deviceID, privacy: .public) (\(payload.scope.rawValue, privacy: .public))")
        reloadDevices()
        nudge([.deviceGrant])
        // Outside the relay pass: the close's share calls never hold it.
        closeAfterLink = Task { await self.closeLink(reason: .used) }
    }

    /// Publishes the refusal, unless the phone is linked already: a linked
    /// phone keeps its link whatever code it sends later.
    private func refuse(_ payload: DevicePayload, _ reason: LinkRefusal, at date: Date) throws {
        guard try sidecar.linkedDevice(payload.deviceID) == nil else { return }
        try sidecar.saveLinkRefusal(HubSyncState.LinkRefusalRecord(
            deviceID: payload.deviceID, name: String(payload.name.prefix(DevicePayload.maxNameLength)),
            scope: payload.scope, reason: reason, at: Self.wholeSeconds(date)
        ))
        nudge([.deviceGrant])
    }

    /// `shared`: the record's creator is the phone's own user. `private`:
    /// the Mac's user wrote it (a stranger on a share cannot pass as a
    /// same-Apple-ID phone). An unknown creator passes `private` only.
    private func creatorMatches(_ record: CloudRecord, _ payload: DevicePayload) async -> Bool {
        guard payload.scope == .private else { return record.creatorUserRecordName == payload.userRecordName }
        guard let creator = record.creatorUserRecordName, creator != CKCurrentUserDefaultName else { return true }
        return creator == (await resolveOwnerUser())
    }

    private func hasAcceptedBothShares(_ userRecordName: String) async -> Bool {
        do {
            for zone in [CloudZoneID.data, .relay] {
                let shares = self.shares
                let participants = try await share { try await shares.participants(in: zone) }
                guard participants.contains(where: { $0.userRecordName == userRecordName && $0.accepted }) else {
                    logger.warning("phone user has not accepted the \(zone.rawValue, privacy: .public) share: no grant")
                    return false
                }
            }
            return true
        } catch {
            logger.error("share participants unreadable, phone not linked: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - The phone list (Settings → Mobile)

    /// Remove (spec §2.3): the device leaves `devices` (the gate refuses it
    /// at once), its `device_grant` is deleted at the next publish, and in
    /// `shared` scope its iCloud user leaves both shares (unless another
    /// linked phone is on that user). A failed participant removal marks the
    /// sweep pending, so the next close removes it, and is rethrown.
    func remove(deviceID: String) async throws {
        guard let removed = try sidecar.removeLinkedDevice(deviceID) else { return }
        reloadDevices()
        nudge([.deviceGrant])
        let name = removed.userRecordName
        guard removed.scope == .shared, !devices.contains(where: { $0.scope == .shared && $0.userRecordName == name }) else {
            return
        }
        let shares = self.shares
        do {
            for zone in [CloudZoneID.data, .relay] {
                try await share { try await shares.removeParticipants(in: zone) { $0.userRecordName == name } }
            }
        } catch {
            try sidecar.setMetaValue("1", forKey: Self.sweepPendingKey)
            throw error
        }
    }

    /// Allow… / Revoke of typing into sessions.
    func setTypingAllowed(_ allowed: Bool, deviceID: String) throws {
        try setGrant(.typing, allowed, deviceID: deviceID)
    }

    /// Whether the phone may start sessions (default on).
    func setStartSessionsAllowed(_ allowed: Bool, deviceID: String) throws {
        try setGrant(.startSessions, allowed, deviceID: deviceID)
    }

    private func setGrant(_ grant: HubSyncState.DeviceGrantKind, _ allowed: Bool, deviceID: String) throws {
        guard try sidecar.setDeviceGrant(grant, allowed, deviceID: deviceID, at: Self.wholeSeconds(now())) else { return }
        reloadDevices()
        nudge([.deviceGrant])
    }

    /// The grants a session start or input from `deviceID` gets. The relay
    /// gate already refused an unlinked device; an unreadable sidecar
    /// grants nothing.
    nonisolated static func sessionGrant(_ sidecar: HubSyncState, deviceID: String?) -> SessionStartStopHandlers.DeviceGrant {
        guard let deviceID else { return .denied }
        do {
            guard let device = try sidecar.linkedDevice(deviceID) else { return .denied }
            return .init(typingAllowed: device.typingAllowed, startSessionsAllowed: device.startSessionsAllowed)
        } catch {
            Logger(subsystem: Constants.bundleID, category: "MobileLinkCenter")
                .error("device grants unreadable: \(error.localizedDescription, privacy: .public)")
            return .denied
        }
    }

    // MARK: - Take over (spec §2.3, §8 I-1)

    /// The new hub of a take over: deletes both zone shares (every
    /// participant goes with them) and forgets every code and phone, so the
    /// next QR creates new shares and every phone scans again.
    func takeOverReset() async {
        expiryTask?.cancel()
        expiryTask = nil
        openCode = nil
        do {
            let shares = self.shares
            try await share { try await shares.deleteShares() }
            try sidecar.setMetaValue("0", forKey: Self.sweepPendingKey)
        } catch {
            logger.error("take over: zone shares not deleted: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try sidecar.clearLinkState()
        } catch {
            logger.error("take over: linked phones not cleared: \(error.localizedDescription, privacy: .public)")
        }
        reloadDevices()
        nudge([.deviceGrant])
        onSharingChanged?(.none)
    }

    // MARK: - Helpers

    private func reloadDevices() {
        do {
            devices = try sidecar.linkedDevices()
        } catch {
            logger.error("linked phones unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveOwnerUser() async -> String? {
        if let knownOwnerUser { return knownOwnerUser }
        let lookup = ownerUser
        let lookedUp = await MobileHubService.bounded(Self.ownerLookupTimeout) { await lookup() }
        guard let found = lookedUp.flatMap({ $0 }) else { return nil }
        knownOwnerUser = found
        return found
    }

    /// Runs one share call for at most `shareTimeout`; a call still running
    /// then is cancelled and left to end on its own.
    private func share<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome = await MobileHubService.bounded(shareTimeout) { () -> Result<T, Error> in
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        guard let outcome else { throw ShareServiceError.timedOut }
        return try outcome.get()
    }

    /// Unix-second stamps on the wire.
    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

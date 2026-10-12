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
    /// The Mac's iCloud account changed while the code was being made.
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .account(.noAccount): return "Mobile isn't available on this Mac: iCloud is off."
        case .account(.restricted): return "Mobile isn't available on this Mac: iCloud is restricted by your organization."
        case .account(.unavailable(let reason)): return "Mobile isn't available on this Mac: \(reason)"
        case .account(.available), .ownerUnknown: return "This Mac couldn't read its iCloud account. Try again."
        case .accountChanged: return "This Mac's iCloud account changed. Show a new code."
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
///   later; a removed one is never re-linked by an old nonce. A linked
///   phone's own rewrite without a nonce unlinks it (`unlinked: true`) or
///   sets its start-sessions grant.
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
        /// The code could not be stored after its link opened.
        case issueFailed = "issue_failed"
        /// The Mac's iCloud account changed: the QR names the old user.
        case accountChanged = "account_changed"
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
    /// Why the last close ran (the sheet tells an account change from expiry).
    private(set) var lastCloseReason: CloseReason?
    /// The linked phones, oldest link first.
    private(set) var devices: [HubSyncState.LinkedDevice] = []

    /// The heartbeat's `sharing` (set to `MobileHubService.sharing`).
    @ObservationIgnored var onSharingChanged: (@MainActor (HubSharing) -> Void)?
    /// The last `sharing` reported, re-applied to a rebuilt hub.
    @ObservationIgnored private var sharing: HubSharing?

    @ObservationIgnored private let sidecar: HubSyncState
    @ObservationIgnored private let shares: any ShareService
    @ObservationIgnored private let macName: String
    @ObservationIgnored private let ownerUser: @Sendable () async -> String?
    /// nil: the attached hub's publisher.
    @ObservationIgnored private let nudge: (@MainActor (Set<SliceKind>) -> Void)?
    /// The hub the center hangs on now; a rebuilt hub replaces it.
    @ObservationIgnored private weak var hub: MobileHubService?
    /// The first `attach` closes a link an earlier run left open; a rebuilt
    /// hub's does the same unless a QR is on screen.
    @ObservationIgnored private var attachedOnce = false
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let shareTimeout: Duration
    /// The close that follows a link, run outside the relay pass.
    @ObservationIgnored private(set) var closeAfterLink: Task<Void, Never>?
    /// The close an account change started; a new code waits for it, so it
    /// never lands on the new code's link.
    @ObservationIgnored private var accountChangeClose: Task<Void, Never>?
    @ObservationIgnored private var knownOwnerUser: String?
    /// Bumped when the account changes, so a lookup still running then
    /// never caches the old user.
    @ObservationIgnored private var ownerEpoch = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    /// Bumped each time the sweep is marked pending (the public link opens,
    /// a Remove fails), so a close that was suspended meanwhile never clears
    /// the mark.
    @ObservationIgnored private var sweepEpoch = 0
    @ObservationIgnored private let logger = Logger(subsystem: Constants.bundleID, category: "MobileLinkCenter")

    init(
        sidecar: HubSyncState,
        shares: any ShareService,
        macName: String,
        ownerUser: @escaping @Sendable () async -> String?,
        nudge: (@MainActor (Set<SliceKind>) -> Void)? = nil,
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

    /// The run's link center over `storage`'s shares, kept across hub
    /// rebuilds; nil for a storage without a share service (a stub), which
    /// links no phone.
    static func forRun(storage: MobileHubStorage, macName: String) -> MobileLinkCenter? {
        guard let shares = storage.shares else { return nil }
        return MobileLinkCenter(sidecar: storage.sidecar, shares: shares, macName: macName, ownerUser: storage.ownerUser)
    }

    /// Where the relay sends phone `device` records.
    var relayRoute: RelayProcessor.DeviceRecords {
        RelayProcessor.DeviceRecords { [weak self] in try await self?.handleDevice($0) }
    }

    /// Hangs the center on `hub`: Settings reaches it there, the hub's
    /// zones deleted forget every phone, the heartbeat carries `sharing`, an
    /// account change forgets the iCloud user. A public link an earlier run
    /// left open (a crash with the QR shown), or a sweep still pending, is
    /// closed now, unless a rebuilt hub attaches while the QR is on screen:
    /// that code keeps its link.
    func attach(to hub: MobileHubService) {
        self.hub = hub
        hub.linkCenter = self
        hub.onZonesDeleted = { [weak self] in try self?.hubZonesDeleted() }
        hub.onAccountChanged = { [weak self] in self?.accountChanged() }
        onSharingChanged = { [weak hub] in hub?.sharing = $0 }
        if let sharing { hub.sharing = sharing }
        let keepsQR = attachedOnce && openCode != nil
        attachedOnce = true
        guard !keepsQR else { return }
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
    /// iCloud or the Mac's user name; nothing is created then. The codes
    /// still open are retired: only the newest one links.
    func issueCode() async throws -> LinkPayload {
        await accountChangeClose?.value
        let epoch = ownerEpoch
        let account = await accountAvailability()
        guard account == .available else { throw MobileLinkError.account(account) }
        guard let owner = await resolveOwnerUser() else { throw MobileLinkError.ownerUnknown }
        let hubID = try sidecar.ensureHubID()
        let urls = await openPublicLink()
        guard epoch == ownerEpoch else {
            // The account changed meanwhile: the code would name the old user.
            await closeLink(reason: .accountChanged)
            throw MobileLinkError.accountChanged
        }
        let code = LinkPayload.issue(
            hubID: hubID, macName: macName, ownerUser: owner,
            dataShare: urls?.data, relayShare: urls?.relay, now: now()
        )
        do {
            try sidecar.addLinkCode(
                nonce: code.nonce, issuedAt: Date(timeIntervalSince1970: TimeInterval(code.iat)),
                exp: Date(timeIntervalSince1970: TimeInterval(code.exp)), keeping: Self.keptCodes,
                retiringOpenCodesAt: now()
            )
        } catch {
            // No code links, so the link just opened must not stay open.
            await closeLink(reason: .issueFailed)
            throw error
        }
        openCode = code
        scheduleExpiry(of: code)
        // The relay loop polls fast while a QR is open: start now, not after
        // the idle wait.
        hub?.wakeRelay()
        return code
    }

    /// Creates the shares if needed and opens their public link; nil (no
    /// share URLs in the QR) when sharing fails.
    private func openPublicLink() async -> ShareURLs? {
        do {
            let shares = self.shares
            let urls = try await share { try await shares.ensureShares() }
            // Marked before it opens: a crash in between still closes it.
            try markSweepPending()
            try await share { try await shares.setPublicLink(open: true) }
            report(.available)
            return urls
        } catch {
            logger.warning("zone shares unavailable, QR without share URLs: \(error.localizedDescription, privacy: .public)")
            report(.unavailable)
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
        lastCloseReason = reason
        do {
            guard try sidecar.metaValue(forKey: Self.sweepPendingKey) == "1" else { return }
            let epoch = sweepEpoch
            let shares = self.shares
            try await share { try await shares.setPublicLink(open: false) }
            let bound = Set(try sidecar.linkedDevices().filter { $0.scope == .shared }.map(\.userRecordName))
            for zone in [CloudZoneID.data, .relay] {
                try await share { try await shares.removeParticipants(in: zone) { !bound.contains($0.userRecordName ?? "") } }
            }
            guard epoch == sweepEpoch else { return }
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
        guard let nonce = payload.linkNonce, !nonce.isEmpty, payload.unlinked != true else {
            try await handleLinkedRewrite(record, payload)
            return
        }
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
        nudgeKinds([.deviceGrant])
        // Outside the relay pass: the close's share calls never hold it.
        closeAfterLink = Task { await self.closeLink(reason: .used) }
    }

    /// A linked phone's own rewrite without a nonce (spec §2.3 "Unlink and
    /// revoke", §10): `unlinked: true` removes it as Remove does (in
    /// `shared` scope it has left the shares already); otherwise its
    /// start-sessions choice becomes the grant. `typing_requested` is not
    /// stored (the typing prompt is deferred). The record must be the
    /// linked phone's: its scope, and a creator both checks accept. An
    /// unlinked device's record changes nothing.
    private func handleLinkedRewrite(_ record: CloudRecord, _ payload: DevicePayload) async throws {
        guard let device = try sidecar.linkedDevice(payload.deviceID) else { return }
        guard payload.scope == device.scope, device.accepts(creator: record.creatorUserRecordName),
              await creatorMatches(record, payload) else {
            logger.warning("device record \(record.recordName, privacy: .public) not written by its linked phone: ignored")
            return
        }
        if payload.unlinked == true {
            logger.info("phone \(device.deviceID, privacy: .public) unlinked itself")
            guard let removed = try dropDevice(device.deviceID) else { return }
            do {
                try await removeParticipant(of: removed)
            } catch {
                // Inside the relay pass: logged, swept by the next close.
                logger.warning("unlinked phone's share participant not removed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard payload.startSessions != device.startSessionsAllowed else { return }
        try setStartSessionsAllowed(payload.startSessions, deviceID: device.deviceID)
    }

    /// Publishes the refusal, unless the phone is linked already: a linked
    /// phone keeps its link whatever code it sends later.
    private func refuse(_ payload: DevicePayload, _ reason: LinkRefusal, at date: Date) throws {
        guard try sidecar.linkedDevice(payload.deviceID) == nil else { return }
        try sidecar.saveLinkRefusal(HubSyncState.LinkRefusalRecord(
            deviceID: payload.deviceID, name: String(payload.name.prefix(DevicePayload.maxNameLength)),
            scope: payload.scope, reason: reason, at: Self.wholeSeconds(date)
        ))
        nudgeKinds([.deviceGrant])
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
        guard let removed = try dropDevice(deviceID) else { return }
        try await removeParticipant(of: removed)
    }

    /// Deletes the device's row; the removed row, nil when it was not linked.
    private func dropDevice(_ deviceID: String) throws -> HubSyncState.LinkedDevice? {
        guard let removed = try sidecar.removeLinkedDevice(deviceID) else { return nil }
        reloadDevices()
        nudgeKinds([.deviceGrant])
        return removed
    }

    /// In `shared` scope, the removed phone's iCloud user leaves both shares
    /// unless another linked phone is on it. A participant already gone is
    /// no error; a failure marks the sweep pending and is rethrown.
    private func removeParticipant(of removed: HubSyncState.LinkedDevice) async throws {
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
            do {
                try markSweepPending()
            } catch let markError {
                logger.error("removed phone's participant left unswept: \(markError.localizedDescription, privacy: .public)")
            }
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
        nudgeKinds([.deviceGrant])
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

    // MARK: - Hub zones deleted (multi-hub spec §3.3)

    /// Settings turned the hub off and its zones were deleted: their shares
    /// and every participant went with them. Forgets every code and phone,
    /// so the next QR creates new shares and every phone scans again. Throws
    /// when the phones could not be forgotten, after doing the rest: the hub
    /// keeps the delete pending and redoes it at the next start.
    func hubZonesDeleted() throws {
        expiryTask?.cancel()
        expiryTask = nil
        openCode = nil
        do {
            try sidecar.setMetaValue("0", forKey: Self.sweepPendingKey)
        } catch {
            logger.error("hub zones deleted: share sweep flag not reset: \(error.localizedDescription, privacy: .public)")
        }
        var clearFailure: (any Error)?
        do {
            try sidecar.clearLinkState()
        } catch {
            logger.error("hub zones deleted: linked phones not cleared: \(error.localizedDescription, privacy: .public)")
            clearFailure = error
        }
        reloadDevices()
        nudgeKinds([.deviceGrant])
        report(.none)
        if let clearFailure { throw clearFailure }
    }

    // MARK: - iCloud account change

    /// The Mac's iCloud account signed out or switched (the transport's
    /// account reset): the cached user is the old one, so it is looked up
    /// again, the new account has no shares yet (`sharing` none), and a QR
    /// on screen, which names the old user, closes.
    func accountChanged() {
        knownOwnerUser = nil
        ownerEpoch += 1
        report(.none)
        guard openCode != nil else { return }
        accountChangeClose = Task { await self.closeLink(reason: .accountChanged) }
    }

    // MARK: - Helpers

    private func report(_ value: HubSharing) {
        sharing = value
        onSharingChanged?(value)
    }

    private func markSweepPending() throws {
        sweepEpoch += 1
        try sidecar.setMetaValue("1", forKey: Self.sweepPendingKey)
    }

    private func nudgeKinds(_ kinds: Set<SliceKind>) {
        if let nudge {
            nudge(kinds)
        } else {
            hub?.nudge(kinds: kinds)
        }
    }

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
        let epoch = ownerEpoch
        let lookedUp = await MobileHubService.bounded(Self.ownerLookupTimeout) { await lookup() }
        // The account changed during the lookup: its answer may be the old user.
        guard let found = lookedUp.flatMap({ $0 }), epoch == ownerEpoch else { return nil }
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

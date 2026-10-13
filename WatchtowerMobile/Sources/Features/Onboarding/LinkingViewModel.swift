import Foundation
import Observation
import os
import WatchtowerSync

/// The link flow (mobile POC spec §2.3 steps 1–6) and the link's life
/// after it (§9: unlink, removed, moved, stale, iCloud account switch).
/// Owned by `AppRoot` for the app's lifetime, so a wait survives any
/// navigation; a kill mid-wait is resumed from `LinkStore.pending`.
@MainActor
@Observable
final class LinkingViewModel {
    enum Phase: Equatable {
        case idle
        /// The camera is open.
        case scanning
        /// Steps 1–4: checking the code and iCloud, accepting, writing.
        case checking
        /// Step 5: the hello is written; waiting for the keybox. The code to
        /// compare is `linkCode`, and `macSeesPhone` says the Mac read it.
        case waiting(macName: String)
        /// Settings → Unlink this Mac is running.
        case unlinking
        /// Step 6: linked to another Mac, scanned a new one.
        case confirmSwitch(from: String, to: String)
        case failed(LinkFailure)
        /// "Linked to <Mac name>", until the owner continues.
        case linked(macName: String)
    }

    /// Step 1's grace for the phone's clock: the code is refused locally
    /// only when `exp < now − 120 s`; the Mac's own check decides the rest.
    /// The wait for the keybox lasts until the same `exp + 120 s`: the owner
    /// needs time to compare the code and click Link.
    static let expiryGrace: TimeInterval = 120
    /// How often the wait fetches the keybox (mobile E2E Task 16).
    static let grantPollInterval: TimeInterval = 2
    /// No heartbeat for this long reads as the Mac gone (spec §9).
    static let staleAfter: TimeInterval = 86_400

    static func switchPrompt(from old: String, to new: String) -> String {
        "Switch from \(old) to \(new)?"
    }

    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue {
                phaseStartedAt = clock.now()
                phaseStartedUptime = clock.uptime()
            }
        }
    }
    /// When `phase` last changed, on the flow's clock; nil before the first
    /// change. The waiting screen's hint reads it (design pass O2).
    private(set) var phaseStartedAt: Date?
    @ObservationIgnored private var phaseStartedUptime: TimeInterval?

    /// Seconds since `phase` last changed, on the monotonic source (a clock
    /// jump neither brings the 20 s hint forward nor holds it back); nil
    /// before the first phase change.
    func phaseElapsed() -> TimeInterval? {
        phaseStartedUptime.map { max(0, clock.uptime() - $0) }
    }
    private(set) var notice: LinkNotice?
    /// The four-digit code of the running link (mobile E2E spec §2.3): the
    /// Mac shows the same one for this phone. nil outside a wait, or when a
    /// resumed wait cannot read the keys (locked).
    private(set) var linkCode: String?
    /// The Mac read this phone's hello and waits for the owner's Link
    /// (the keybox says `awaiting_confirmation`).
    private(set) var macSeesPhone = false
    /// The saved link; nil while unlinked (Welcome). A pending link is not
    /// a link.
    private(set) var link: LinkRecord?

    /// Set by the owner right after init (it owns this model).
    @ObservationIgnored weak var host: (any LinkHost)?
    @ObservationIgnored private let container: any LinkContainer
    @ObservationIgnored private let store: LinkStore
    /// The device id is filled in when the link flow creates the device keys.
    @ObservationIgnored private var identity: DeviceIdentity
    /// The phone's E2E keys: the device identity and each hub's link.
    @ObservationIgnored private let keys: any PhoneKeyStore
    @ObservationIgnored private let clock: any LinkClock
    /// The scanned code a switch prompt is about, with this phone's user.
    @ObservationIgnored private var pendingSwitch: (payload: LinkPayload, hubKeys: ScannedHubKeys, userRecordName: String)?
    /// The moved notice took the writes away; a heartbeat of the linked hub
    /// gives them back.
    @ObservationIgnored private var writesBlocked = false
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkingViewModel")

    init(
        container: any LinkContainer,
        store: LinkStore,
        identity: DeviceIdentity,
        keys: any PhoneKeyStore,
        clock: any LinkClock = SystemLinkClock()
    ) {
        self.container = container
        self.store = store
        self.identity = identity
        self.keys = keys
        self.clock = clock
        link = store.link
    }

    /// This phone as the saved link describes it.
    var linkedDevice: LinkedDevice? {
        link.flatMap(identity.linkedDevice(for:))
    }

    /// A scan or a link is running: a second code is ignored meanwhile.
    var isBusy: Bool {
        switch phase {
        case .checking, .waiting, .unlinking: true
        default: false
        }
    }

    // MARK: - Scan

    func startScan() {
        guard !isBusy else { return }
        // A report about the last link is read by now; moved and stale stay
        // until the heartbeat clears them.
        switch notice {
        case .removed, .notSent, .recordingKept, .recordingsProblem, .encryptionReScan: notice = nil
        case .moved, .stale, nil: break
        }
        phase = .scanning
    }

    func dismissNotice() {
        notice = nil
    }

    /// Closes the scanner, a failure or the Linked screen (not a running
    /// link).
    func dismiss() {
        guard !isBusy else { return }
        pendingSwitch = nil
        phase = .idle
    }

    /// A code the in-app scanner read.
    func scanned(_ code: String) async {
        guard let url = URL(string: code) else {
            phase = .failed(.refused)
            return
        }
        await open(url)
    }

    /// A `watchtower://link` URL, from the scanner or the system Camera app:
    /// steps 1–6.
    func open(_ url: URL) async {
        guard !isBusy else { return }
        let payload: LinkPayload
        switch LinkPayload.parse(url) {
        case let .success(parsed):
            payload = parsed
        case .failure(.newerVersion):
            phase = .failed(.updateApp)
            return
        case .failure(.olderVersion):
            phase = .failed(.updateMac)
            return
        case let .failure(error):
            Self.logger.warning("unusable link code: \(String(describing: error), privacy: .public)")
            phase = .failed(.refused)
            return
        }
        let hubKeys: ScannedHubKeys
        do {
            hubKeys = try ScannedHubKeys(payload)
        } catch {
            Self.logger.warning("link code with unusable keys: \(String(describing: error), privacy: .public)")
            phase = .failed(.refused)
            return
        }
        // Step 1: only a code clearly past its expiry on this clock.
        if Double(payload.exp) < clock.now().timeIntervalSince1970 - Self.expiryGrace {
            phase = .failed(.expired)
            return
        }
        phase = .checking
        if let link, link.hubID == payload.hubID, await isGranted(link) {
            // Already linked to this Mac: nothing to write.
            phase = .linked(macName: link.macName)
            return
        }
        // Step 2.
        guard await container.accountStatus() == .available else {
            phase = .failed(.signIn)
            return
        }
        let userRecordName: String
        do {
            userRecordName = try await container.userRecordName()
        } catch {
            phase = .failed(.iCloud(error.localizedDescription))
            return
        }
        // Step 6's prompt: before anything is accepted or written.
        if let link, link.hubID != payload.hubID {
            pendingSwitch = (payload, hubKeys, userRecordName)
            phase = .confirmSwitch(from: link.macName, to: payload.macName)
            return
        }
        // The linked Mac, whose keybox does not say "linked" (a missed
        // removal, an absent keybox): a re-pair. The dead link ends first,
        // reporting what its wipe lost, so a refused or unanswered re-pair
        // leaves the phone unlinked (Welcome), never on tabs whose keys open
        // nothing.
        if link != nil {
            notice = LinkNotice.after(await unlinkCurrent(writeUnlinked: false))
        }
        await connect(payload, hubKeys: hubKeys, userRecordName: userRecordName)
    }

    /// The answer to "Switch from <old Mac> to <new Mac>?": yes unlinks the
    /// old Mac and links the new one, no keeps the old link untouched.
    func confirmSwitch(_ accepted: Bool) async {
        guard case .confirmSwitch = phase, let request = pendingSwitch else { return }
        pendingSwitch = nil
        guard accepted else {
            phase = .idle
            return
        }
        phase = .checking
        notice = LinkNotice.after(await unlinkCurrent(writeUnlinked: true))
        await connect(request.payload, hubKeys: request.hubKeys, userRecordName: request.userRecordName)
    }

    /// "Linked to <Mac name>" → the notification prompt → Now.
    func finish() async {
        guard case .linked = phase else { return }
        phase = .idle
        await host?.requestNotificationPermission()
        host?.openNow()
    }

    /// Steps 3–5 for a valid code.
    private func connect(_ payload: LinkPayload, hubKeys: ScannedHubKeys, userRecordName: String) async {
        // Step 3: same Apple ID → the private database, share URLs ignored
        // (an owner cannot accept their own share). Another Apple ID → both
        // shares, then the shared database.
        let scope: CloudDatabaseScope
        if userRecordName == payload.ownerUser {
            scope = .private
        } else {
            guard let data = payload.dataShare.flatMap(URL.init(string:)),
                  let relay = payload.relayShare.flatMap(URL.init(string:))
            else {
                phase = .failed(.cannotShare)
                return
            }
            do {
                try await container.acceptShares([data, relay])
            } catch {
                Self.logger.error("share accept failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(.cannotShare)
                return
            }
            scope = .shared(ownerName: payload.ownerUser)
        }
        // The device keys (created here, in the foreground, on the first scan:
        // F14) and the hub's keys from the code. A re-pair replaces the old
        // link's keys: its epochs start again with the new keybox.
        let deviceKeys: DeviceIdentityKeys
        do {
            deviceKeys = try keys.identity()
            try keys.saveHubLink(hubKeys.unconfirmedLink)
        } catch {
            Self.logger.error("device keys unavailable: \(String(describing: error), privacy: .public)")
            phase = .failed(.local(Self.keysUnavailableReason))
            return
        }
        identity.deviceID = deviceKeys.deviceID.uuidString
        let shared = scope != .private
        let record = LinkRecord(
            hubID: payload.hubID,
            macName: payload.macName,
            scope: shared ? .shared : .private,
            ownerName: payload.ownerUser,
            userRecordName: userRecordName,
            nonce: payload.nonce,
            dataShareURL: shared ? payload.dataShare : nil,
            relayShareURL: shared ? payload.relayShare : nil
        )
        guard let host, let device = identity.linkedDevice(for: record) else { return }
        // From the accept on, a kill is resumed (the scope's database, the
        // rest of the wait), never shown as linked. No baseline yet: a
        // relaunch before it is captured has written nothing to the Mac.
        let deadline = waitDeadline(expiresAt: payload.exp)
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(payload.iat))
        store.pending = PendingLink(
            link: record, deadline: deadline, baseline: nil, baselineCaptured: false, issuedAt: issuedAt
        )
        // Step 4: the hello with the code's nonce, sealed to the hub's key, in
        // the scope's database, on a fresh replica (a re-pair must not keep the
        // old link's rollback marks: a reset hub's seqs start again).
        let transport: any CloudSyncTransport
        do {
            transport = try await host.prepare(scope: scope, hubID: record.hubID, fresh: true)
        } catch is CancellationError {
            // Torn down mid-restart: the pending link stays for the relaunch.
            return
        } catch {
            store.pending = nil
            forgetUnconfirmedKeys(record.hubID)
            phase = .failed(.local(error.localizedDescription))
            return
        }
        let baseline = await host.fetchKeybox(deviceID: device.deviceID)?.grant
        let pending = PendingLink(
            link: record, deadline: deadline, baseline: baseline, baselineCaptured: true, issuedAt: issuedAt
        )
        store.pending = pending
        do {
            // The transport queues the record locally; CloudKit sends it
            // later, so a throw here is this iPhone's store.
            try await transport.save([try helloRecord(for: device, keys: deviceKeys, linkNonce: payload.nonce)])
        } catch {
            store.pending = nil
            forgetUnconfirmedKeys(record.hubID)
            phase = .failed(.local(error.localizedDescription))
            return
        }
        linkCode = hubKeys.code(for: deviceKeys)
        await waitForGrant(pending)
    }

    static let keysUnavailableReason = "This iPhone's Watchtower keys can't be read. Unlock it and scan again."

    /// The wait's end: the code's expiry plus the clock grace, on the phone's
    /// clock; never past a full code lifetime from now (an `exp` from a Mac
    /// clock far ahead does not keep the phone waiting for ever).
    private func waitDeadline(expiresAt exp: Int64) -> Date {
        let now = clock.now()
        let latest = now.addingTimeInterval(TimeInterval(LinkPayload.lifetime) + Self.expiryGrace)
        return min(Date(timeIntervalSince1970: TimeInterval(exp) + Self.expiryGrace), latest)
    }

    /// The hello (mobile E2E spec §2.3): this phone's device record plus its
    /// public keys, `hello-<device_id>` in RelayZone. The host's transport
    /// seals it to the hub's agreement key and signs it with the device key.
    private func helloRecord(for device: LinkedDevice, keys deviceKeys: DeviceIdentityKeys, linkNonce: String) throws -> CloudRecord {
        guard let host else { throw CancellationError() }
        let payload = host.devicePayload(for: device, linkNonce: linkNonce, unlinked: false, now: clock.now())
        let hello = DeviceHello(
            device: payload,
            signingKey: WireBytes.base64URL(deviceKeys.signing.publicKey.rawRepresentation),
            agreementKey: WireBytes.base64URL(deviceKeys.agreement.publicKey.rawRepresentation)
        )
        return try CloudRecordFactory.record(for: hello, modifiedAt: payload.updatedAt)
    }

    // MARK: - Keybox wait (step 5)

    /// At launch: a link written before a kill and not answered yet waits
    /// for what is left of its wait, then offers to scan again. A link
    /// killed before its baseline was captured wrote nothing to the Mac
    /// (the hello follows the baseline), and without the baseline an earlier
    /// answer in the replica (a refusal of another code) would read as this
    /// scan's: it offers to scan again at once.
    func resumePendingLink() async {
        guard let pending = store.pending, !isBusy else { return }
        guard clock.now() < pending.deadline, pending.baselineCaptured else {
            endPendingLink(pending, failure: .noAnswer)
            return
        }
        // The keys the scan stored: the code again, and the hub keys the
        // keybox's epoch keys join. Without them the link cannot be completed.
        let stored: HubLinkKeys?
        do {
            stored = try keys.hubLink(pending.link.hubID)
        } catch KeyStoreError.locked {
            Self.logger.notice("keys locked at launch: the pending link waits for the next launch")
            return
        } catch {
            Self.logger.error("pending link keys unreadable: \(String(describing: error), privacy: .public)")
            stored = nil
        }
        guard let stored, let hubKeys = try? ScannedHubKeys(stored: stored) else {
            // `try?`: a stored link that does not parse is the same dead end as none at all.
            endPendingLink(pending, failure: .noAnswer)
            return
        }
        // F14: read, never created; the scan created it, so none means the wait cannot be this phone's.
        let deviceKeys: DeviceIdentityKeys?
        do {
            deviceKeys = try keys.existingIdentity()
        } catch KeyStoreError.locked {
            Self.logger.notice("keys locked at launch: the pending link waits for the next launch")
            return
        } catch {
            Self.logger.error("device keys unreadable: \(String(describing: error), privacy: .public)")
            deviceKeys = nil
        }
        guard let deviceKeys else {
            endPendingLink(pending, failure: .noAnswer)
            return
        }
        phase = .checking
        do {
            _ = try await host?.prepare(scope: pending.link.databaseScope, hubID: pending.link.hubID, fresh: false)
        } catch {
            endPendingLink(pending, failure: .local(error.localizedDescription))
            return
        }
        linkCode = hubKeys.code(for: deviceKeys)
        await waitForGrant(pending)
    }

    /// Fetches the keybox every 2 s until the deadline. A keybox for this
    /// hub whose grant differs from the baseline is the Mac's answer:
    /// `link_refused` (any code, `not_confirmed` included, even one this
    /// build does not know) refuses; `awaiting_confirmation` shows that the
    /// Mac sees this iPhone; `linked` with keys stores them and links. A
    /// cancelled wait (the app killed) leaves the pending link to resume.
    private func waitForGrant(_ pending: PendingLink) async {
        macSeesPhone = false
        phase = .waiting(macName: pending.link.macName)
        while true {
            if let deviceID = identity.deviceID,
               let keybox = await host?.fetchKeybox(deviceID: deviceID),
               keybox.grant != pending.baseline, keybox.grant.hubID == pending.link.hubID {
                let grant = keybox.grant
                if grant.linkRefused != nil {
                    endPendingLink(pending, failure: .refused)
                    return
                }
                if grant.linked, grant.revoked != true, Self.isDecided(grant.linkedAt, after: pending.issuedAt) {
                    if let boxKeys = keybox.keys {
                        await complete(pending, keys: boxKeys)
                        return
                    }
                    Self.logger.warning("a linked keybox without keys: still waiting")
                } else if grant.awaitingConfirmation == true {
                    macSeesPhone = true
                }
            }
            let remaining = pending.deadline.timeIntervalSince(clock.now())
            guard remaining > 0 else { break }
            do {
                try await clock.sleep(for: .seconds(min(Self.grantPollInterval, remaining)))
            } catch {
                return
            }
        }
        endPendingLink(pending, failure: .noAnswer)
    }

    /// A link decided at `decidedAt` (the Mac's clock) answers a code issued
    /// at `issuedAt` (the same clock) only when it came at or after it: the
    /// Mac links at the owner's click, after the code was shown (review M-3).
    /// A pending link an older build saved has no `issuedAt`: unbound.
    static func isDecided(_ decidedAt: Date?, after issuedAt: Date?) -> Bool {
        guard let issuedAt else { return true }
        guard let decidedAt else { return false }
        return decidedAt >= issuedAt
    }

    /// A wait that ended without a link: the scan's keys go (unless they are
    /// the saved link's), and the failure is shown.
    private func endPendingLink(_ pending: PendingLink, failure: LinkFailure) {
        store.pending = nil
        forgetUnconfirmedKeys(pending.link.hubID)
        linkCode = nil
        macSeesPhone = false
        phase = .failed(failure)
    }

    /// Removes the keys a scan stored for `hubID`, unless they belong to the
    /// saved link (a re-scan of the linked Mac replaced them already).
    private func forgetUnconfirmedKeys(_ hubID: String) {
        guard link?.hubID != hubID else { return }
        removeKeys(hubID)
    }

    private func removeKeys(_ hubID: String) {
        do {
            try keys.removeHubLink(hubID)
        } catch {
            Self.logger.error("hub keys not removed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The keybox's keys join the scan's, then the link is saved.
    private func complete(_ pending: PendingLink, keys boxKeys: KeyboxKeys) async {
        do {
            guard let unconfirmed = try keys.hubLink(pending.link.hubID) else { throw SecureTransportError.keysUnavailable }
            try keys.saveHubLink(try unconfirmed.adding(boxKeys))
        } catch {
            Self.logger.error("keybox keys not stored: \(String(describing: error), privacy: .public)")
            endPendingLink(pending, failure: .local(Self.keysUnavailableReason))
            return
        }
        let record = pending.link
        store.link = record
        store.pending = nil
        link = record
        linkCode = nil
        macSeesPhone = false
        writesBlocked = false
        // A notice about an old link no longer applies; the report of a
        // switch's unlink ("Not sent", a recording kept) stays.
        switch notice {
        case .notSent, .recordingKept, .recordingsProblem: break
        default: notice = nil
        }
        await host?.setLink(identity.linkedDevice(for: record), writesAllowed: true)
        phase = .linked(macName: record.macName)
    }

    /// The replica holds a linked, unrevoked keybox of this link's hub.
    private func isGranted(_ link: LinkRecord) async -> Bool {
        guard let deviceID = identity.deviceID,
              let grant = await host?.fetchKeybox(deviceID: deviceID)?.grant else { return false }
        return grant.hubID == link.hubID && grant.linked && grant.linkRefused == nil && grant.revoked != true
    }

    // MARK: - The keybox after the link

    /// A keybox the replica indexed after the link (a rotation, or Remove on
    /// the Mac; read after unlock, through `indexPending`'s callback). A
    /// revoked one is the Mac removing this phone (D9): the removal wipe, in
    /// either scope. Newer epoch keys join the stored ones.
    func keyboxChanged() async {
        guard let link, !isBusy, let deviceID = identity.deviceID,
              let keybox = await host?.storedKeybox(deviceID: deviceID),
              keybox.grant.hubID == link.hubID, self.link == link
        else { return }
        if keybox.grant.revoked == true {
            Self.logger.notice("the Mac revoked this phone's keybox: removed")
            await removedByMac()
            return
        }
        guard let boxKeys = keybox.keys else { return }
        do {
            guard let current = try keys.hubLink(link.hubID) else { return }
            // Saved even when unchanged: key material is never compared outside CryptoKit.
            try keys.saveHubLink(try current.adding(boxKeys))
        } catch {
            Self.logger.error("keybox keys not stored: \(String(describing: error), privacy: .public)")
        }
    }

    /// At launch: a link saved before encryption (no hub keys in the
    /// Keychain) cannot sync any more. It is dropped, the replica wiped, and
    /// the owner asked to scan again. A pending link without keys is dropped
    /// too. Locked keys decide nothing.
    func dropUnencryptedLink() async {
        if let pending = store.pending, hubKeys(pending.link.hubID) == .absent {
            store.pending = nil
        }
        guard let link, hubKeys(link.hubID) == .absent else { return }
        Self.logger.notice("a link made before encryption is dropped: scan again")
        let wipe = await unlinkCurrent(writeUnlinked: false)
        notice = LinkNotice.after(wipe, otherwise: .encryptionReScan)
    }

    private enum StoredHubKeys { case present, absent, unknown }

    /// Whether `hubID`'s keys are stored, from the public signing key copy
    /// (readable while locked); `unknown` when the Keychain cannot say.
    private func hubKeys(_ hubID: String) -> StoredHubKeys {
        do {
            return try keys.hubSigningKey(hubID) != nil ? .present : .absent
        } catch {
            Self.logger.warning("hub keys unreadable at launch: \(String(describing: error), privacy: .public)")
            return .unknown
        }
    }

    // MARK: - Unlink and the link's events (spec §9)

    /// Settings → Unlink this Mac.
    func unlink() async {
        guard link != nil, !isBusy else { return }
        phase = .unlinking
        notice = LinkNotice.after(await unlinkCurrent(writeUnlinked: true))
        phase = .idle
    }

    /// `TransportEvent.unlinked`: the Mac's zones are gone (the phone was
    /// removed, maybe while offline).
    func removedByMac() async {
        guard link != nil else { return }
        let wipe = await unlinkCurrent(writeUnlinked: false)
        pendingSwitch = nil
        if !isBusy { phase = .idle }
        // A recording problem, or a capture the removal cut short, is the
        // news that matters: it also says the link ended.
        notice = LinkNotice.after(wipe, otherwise: .removed)
    }

    /// The transport saw an iCloud account change. Another account ends the
    /// link and wipes the replica; a sign-out keeps it until an account is
    /// back (spec §9).
    func accountChanged() async {
        guard let link else { return }
        guard await container.accountStatus() == .available else { return }
        let current: String
        do {
            current = try await container.userRecordName()
        } catch {
            Self.logger.warning("account check failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // An unlink or a removal that ran during the check already ended it.
        guard current != link.userRecordName, self.link == link else { return }
        Self.logger.notice("iCloud account changed while linked: unlinking")
        store.pending = nil
        // The recordings were made for the old account's Mac: not carried
        // to whatever the new account links, reported "Not sent".
        let wipe = await unlinkCurrent(writeUnlinked: false, keepRecordings: false)
        pendingSwitch = nil
        phase = .idle
        notice = LinkNotice.after(wipe)
    }

    /// After each fetch: the heartbeat names another hub (moved: writes
    /// stop), or none came for a day (stale).
    ///
    /// Since E2E (F36) a Mac that lost its identity cannot reach this check:
    /// the replica refuses a heartbeat signed by another hub's key at apply
    /// (`ReplicaStore.rejectedCount()`), and that Mac re-cuts its zones, so
    /// this phone sees its link fail instead (the zones gone: the unlinked
    /// path; or a revoked or absent keybox). The check stays: it is harmless
    /// and covers a heartbeat signed by the linked hub's key under another
    /// `hub_id`.
    func evaluate(heartbeat: HeartbeatPayload?) async {
        guard let link, let heartbeat, let device = linkedDevice else { return }
        if heartbeat.hubID != link.hubID {
            let moved = LinkNotice.moved(macName: heartbeat.macName)
            guard notice != moved || !writesBlocked else { return }
            notice = moved
            if !writesBlocked {
                writesBlocked = true
                await host?.setLink(device, writesAllowed: false)
            }
            return
        }
        if writesBlocked {
            writesBlocked = false
            await host?.setLink(device, writesAllowed: true)
        }
        let stale = clock.now().timeIntervalSince(heartbeat.updatedAt) >= Self.staleAfter
        switch notice {
        case .moved, .stale, nil:
            notice = stale ? .stale : nil
        case .removed, .notSent, .recordingKept, .recordingsProblem, .encryptionReScan:
            break
        }
    }

    /// Ends the current link: the `unlinked` record (best effort), leaving
    /// the shares in `shared` scope, then the wipe. Returns what the wipe
    /// lost, and whether it stopped a capture (kept for the next link).
    ///
    /// The link ends before the first await: a removal or an account signal
    /// arriving meanwhile (leaving the shares is what makes the Mac's zones
    /// vanish) finds no link and is ignored, so one unlink wipes once.
    /// The wipe runs first, in the link's own database: the restarted send
    /// queue then holds only the `unlinked` record, so the flush sends
    /// nothing of what is reported "Not sent". A `private` link then
    /// restarts on the unlinked hub, so the old hub's zones stop syncing. A
    /// `shared` link whose shares were left needs no second restart: the
    /// shared database holds none of the hub's zones any more, so its
    /// environment is retired (replaced by the next launch or link) and the
    /// `unlinked` record keeps its chance to go out until then (its
    /// delivery guarantee is #143's).
    ///
    /// The hub's keys are deleted when the link has ended (`removeHubLink`),
    /// after the `unlinked` record was sealed with them; the wipes empty the
    /// replica, so the outbox and the recordings sealed under this link go
    /// with it, and the next link's epochs start from its own keybox.
    private func unlinkCurrent(writeUnlinked: Bool, keepRecordings: Bool = true) async -> LocalWipe {
        guard let current = link, let host else { return LocalWipe() }
        defer { removeKeys(current.hubID) }
        let device = linkedDevice
        store.link = nil
        link = nil
        writesBlocked = false
        await host.setLink(nil, writesAllowed: true)
        guard writeUnlinked, let device else {
            return await host.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: keepRecordings)
        }
        let scope = current.databaseScope
        var wipe = await host.wipeLocalData(restartingOn: scope, hubID: current.hubID, keepRecordings: keepRecordings)
        do {
            let transport = try await host.prepare(scope: scope, hubID: current.hubID, fresh: false)
            try await transport.save([try deviceRecord(for: device, linkNonce: nil, unlinked: true)])
            await host.flushSends()
        } catch {
            Self.logger.warning("unlinked record not written: \(error.localizedDescription, privacy: .public)")
        }
        if case let .shared(ownerName) = scope {
            do {
                try await container.leaveShares(ownerName: ownerName, hubID: current.hubID)
                host.retireEnvironment()
                return wipe
            } catch {
                Self.logger.warning("leaving the shares failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // The linked hub's zones are still reachable (a private link, or
        // shares not left): end on the phone's own database, unlinked.
        // Nothing is left to stop; what this wipe could not hand over adds.
        let final = await host.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID, keepRecordings: keepRecordings)
        wipe.notSent += final.notSent
        wipe.problem = wipe.problem ?? final.problem
        return wipe
    }

    private func deviceRecord(for device: LinkedDevice, linkNonce: String?, unlinked: Bool = false) throws -> CloudRecord {
        guard let host else { throw CancellationError() }
        let payload = host.devicePayload(for: device, linkNonce: linkNonce, unlinked: unlinked, now: clock.now())
        return try CloudRecordFactory.record(for: payload, modifiedAt: payload.updatedAt)
    }
}

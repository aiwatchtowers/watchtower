import Foundation
import Observation
import os
import WatchtowerSync

/// The link flow (mobile POC spec §2.3 steps 1–5, mobile E2E spec §2.3) and
/// each link's life after it (§9; multi-hub spec §5.7, §6: unlink, forget,
/// removed by the Mac, stale, iCloud account switch), one hub at a time: a
/// scan adds a hub (up to `HubRegistry.limit`), never replaces one. Owned by
/// `AppRoot` for the app's lifetime, so a wait survives any navigation; a
/// kill mid-wait is resumed from `LinkStore.pending`. Each hub's keys live
/// in the Keychain under its hub id (`PhoneKeyStore`): stored at the scan,
/// completed by the keybox, removed when that hub's link ends.
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
        /// An unlink or a Forget is running.
        case unlinking
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
    /// Mac shows the same one for this phone. SAS v2: it hashes the nonce the
    /// Mac drew after it accepted the hello, so it shows only once the waiting
    /// keybox brought that nonce. nil outside a wait, before the nonce, or
    /// when a resumed wait cannot read the keys (locked).
    private(set) var linkCode: String?
    /// The Mac read this phone's hello and waits for the owner's Link
    /// (the keybox says `awaiting_confirmation`).
    private(set) var macSeesPhone = false
    /// The saved links, in registry order, as the host last reported them
    /// (refreshed after every change); empty while unlinked (Welcome). A
    /// pending link is not a link.
    private(set) var links: [HubRow] = []
    /// The hub ids of the saved links that cannot be read (#222), refreshed
    /// with `links`: listed with Forget only, never linked through.
    private(set) var unreadableHubIDs: [String] = []

    /// Set by the owner right after init (it owns this model).
    @ObservationIgnored weak var host: (any LinkHost)? {
        didSet { refreshLinks() }
    }
    @ObservationIgnored private let container: any LinkContainer
    @ObservationIgnored private let store: LinkStore
    /// The device id is filled in when the link flow creates the device keys.
    @ObservationIgnored private var identity: DeviceIdentity
    /// The phone's E2E keys: the device identity and each hub's link.
    @ObservationIgnored private let keys: any PhoneKeyStore
    @ObservationIgnored private let clock: any LinkClock
    /// Hubs whose link is ending (an unlink, a removal, the account
    /// switch): a removal or an account signal arriving meanwhile is the
    /// ending's own, and is ignored.
    @ObservationIgnored private var ending: Set<String> = []
    /// The hub of the code being linked (`open`), from its check on: a
    /// kept farewell of that hub is not followed by a share leave.
    @ObservationIgnored private var linkingHubID: String?
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
    }

    /// The phone has at least one saved link (the tabs, not Welcome).
    var hasLinks: Bool { !links.isEmpty }

    /// This phone as `hubID`'s saved link describes it.
    func linkedDevice(for hubID: String) -> LinkedDevice? {
        links.first { $0.hubID == hubID }.flatMap { identity.linkedDevice(for: $0.link) }
    }

    /// Reads the saved links again from the host.
    func refreshLinks() {
        links = host?.linkedHubs() ?? []
        unreadableHubIDs = host?.unreadableHubIDs() ?? []
    }

    /// `hubID`'s row as the host holds it now (not the cached `links`).
    private func row(_ hubID: String) -> HubRow? {
        host?.linkedHubs().first { $0.hubID == hubID }
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
        // A report about the last link is read by now; stale stays until
        // the active hub's heartbeat clears it.
        switch notice {
        case .removed, .notSent, .recordingKept, .recordingsProblem, .encryptionReScan: notice = nil
        case .stale, nil: break
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
    /// steps 1–5 for the code's hub, added to the linked ones.
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
        // The hub id names the hub's directories: only a plain name.
        guard HubPaths.isValidHubID(payload.hubID) else {
            Self.logger.warning("link code with an unusable hub id")
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
        linkingHubID = payload.hubID
        defer { linkingHubID = nil }
        refreshLinks()
        if let row = links.first(where: { $0.hubID == payload.hubID }), row.state == .linked, await isGranted(row.link) {
            // Already linked to this Mac: nothing to write, except epoch keys a lost keybox signal left out of
            // the Keychain (final review Phone I-1: the owner's natural recovery is a re-scan).
            if let deviceID = identity.deviceID,
               let keybox = await host?.storedKeybox(hubID: row.hubID, deviceID: deviceID) {
                await mergeKeys(of: keybox, into: row.link)
            }
            phase = .linked(macName: row.link.macName)
            return
        }
        // A fifth Mac: refused before any share is accepted or written.
        if links.count >= HubRegistry.limit, !links.contains(where: { $0.hubID == payload.hubID }) {
            phase = .failed(.tooManyMacs)
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
        // A saved link to this Mac whose keybox does not say "linked" (a
        // missed removal, an absent keybox) or that the Mac removed (frozen):
        // a re-pair. That link ends first, its keys with it, reporting what
        // its removal lost, so a refused or unanswered re-pair leaves no row
        // whose keys open nothing. Other hubs are untouched.
        if let row = row(payload.hubID), !ending.contains(row.hubID) {
            report(LinkNotice.after(await endLink(row, farewell: false, keepRecordings: true), macName: row.link.macName), removed: row.hubID)
        }
        await connect(payload, hubKeys: hubKeys, userRecordName: userRecordName)
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
                try await container.acceptShares([data, relay], ownerName: payload.ownerUser, hubID: payload.hubID)
            } catch {
                Self.logger.error("share accept failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(.cannotShare)
                return
            }
            scope = .shared(ownerName: payload.ownerUser)
        }
        // The device keys (created here, in the foreground, on the first scan:
        // F14; one identity for every hub) and the hub's keys from the code.
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
            relayShareURL: shared ? payload.relayShare : nil,
            deviceID: identity.deviceID
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
            // Torn down mid-prepare: the pending link stays for the relaunch.
            return
        } catch {
            await fail(.local(error.localizedDescription), hubID: record.hubID)
            return
        }
        let baseline = await host.fetchKeybox(hubID: record.hubID, deviceID: device.deviceID)?.grant
        let pending = PendingLink(
            link: record, deadline: deadline, baseline: baseline, baselineCaptured: true, issuedAt: issuedAt
        )
        store.pending = pending
        do {
            // The transport queues the record locally; CloudKit sends it
            // later, so a throw here is this iPhone's store.
            try await transport.save([try helloRecord(hubID: record.hubID, for: device, keys: deviceKeys, linkNonce: payload.nonce)])
        } catch {
            await fail(.local(error.localizedDescription), hubID: record.hubID)
            return
        }
        await waitForGrant(pending, code: PairingCode(hubKeys: hubKeys, deviceKeys: deviceKeys))
    }

    /// A link that did not complete: nothing to resume, and a hub that has
    /// no row yet (a first link, or a re-pair whose old link ended) leaves no
    /// session, directory or keys behind.
    private func fail(_ failure: LinkFailure, hubID: String) async {
        store.pending = nil
        linkCode = nil
        macSeesPhone = false
        if row(hubID) == nil, let host {
            let dropped = await host.removeHub(hubID, keepRecordings: true, farewell: nil)
            if let problem = dropped.problem {
                Self.logger.error("recordings of a failed link: \(problem, privacy: .public)")
            }
            removeKeys(hubID)
        }
        phase = .failed(failure)
    }

    /// What the code is computed from, apart from the Mac's nonce.
    private struct PairingCode {
        let hubKeys: ScannedHubKeys
        let deviceKeys: DeviceIdentityKeys

        /// The tag a waiting keybox for this scan's link code carries.
        var linkCodeTag: String { KeyDerivation.linkCodeTag(linkNonce: hubKeys.linkNonce) }

        /// nil while the keybox carries no well-formed nonce.
        func code(confirmNonce text: String?) -> String? {
            ScannedHubKeys.confirmNonce(from: text).map { hubKeys.code(for: deviceKeys, confirmNonce: $0) }
        }
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

    /// The hello (mobile E2E spec §2.3): this phone's device record for
    /// `hubID` plus its public keys, `hello-<device_id>` in RelayZone. The
    /// host's transport seals it to the hub's agreement key and signs it with
    /// the device key.
    private func helloRecord(
        hubID: String, for device: LinkedDevice, keys deviceKeys: DeviceIdentityKeys, linkNonce: String
    ) throws -> CloudRecord {
        guard let host else { throw CancellationError() }
        let payload = host.devicePayload(hubID: hubID, for: device, linkNonce: linkNonce, unlinked: false, now: clock.now())
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
        // A hub id that is not a plain name never names a directory: the
        // pending link is dropped, nothing is removed.
        guard HubPaths.isValidHubID(pending.link.hubID) else {
            Self.logger.warning("pending link with an unusable hub id dropped")
            store.pending = nil
            phase = .failed(.refused)
            return
        }
        guard clock.now() < pending.deadline, pending.baselineCaptured else {
            await fail(.noAnswer, hubID: pending.link.hubID)
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
            await fail(.noAnswer, hubID: pending.link.hubID)
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
            await fail(.noAnswer, hubID: pending.link.hubID)
            return
        }
        phase = .checking
        do {
            _ = try await host?.prepare(scope: pending.link.databaseScope, hubID: pending.link.hubID, fresh: false)
        } catch {
            await fail(.local(error.localizedDescription), hubID: pending.link.hubID)
            return
        }
        await waitForGrant(pending, code: PairingCode(hubKeys: hubKeys, deviceKeys: deviceKeys))
    }

    /// Fetches the keybox every 2 s until the deadline. A keybox for this
    /// hub whose grant differs from the baseline is the Mac's answer:
    /// `link_refused` (any code, `not_confirmed` included, even one this
    /// build does not know) refuses; `awaiting_confirmation` shows that the
    /// Mac sees this iPhone and, with its `confirm_nonce`, gives the code
    /// (SAS v2; a waiting keybox without a well-formed nonce, or naming
    /// another link code by its `link_code_tag`, shows none);
    /// `linked` with keys stores them and links. A cancelled wait (the app
    /// killed) leaves the pending link to resume.
    private func waitForGrant(_ pending: PendingLink, code: PairingCode) async {
        let hubID = pending.link.hubID
        macSeesPhone = false
        linkCode = nil
        phase = .waiting(macName: pending.link.macName)
        while true {
            if let deviceID = identity.deviceID,
               let keybox = await host?.fetchKeybox(hubID: hubID, deviceID: deviceID),
               keybox.grant.hubID == hubID {
                let grant = keybox.grant
                // A refusal or a link answers this scan only when it differs from the baseline. A waiting keybox
                // counts by the link code it names instead: an unchanged re-send of this QR keeps the Mac's request
                // (equal to the baseline) and still gives the code; one left from an earlier code never does.
                let fresh = grant != pending.baseline
                if fresh, grant.linkRefused != nil {
                    await fail(.refused, hubID: hubID)
                    return
                }
                if fresh, grant.linked, grant.revoked != true, Self.isDecided(grant.linkedAt, after: pending.issuedAt) {
                    if let boxKeys = keybox.keys {
                        await complete(pending, keys: boxKeys, linkedAt: grant.linkedAt)
                        return
                    }
                    Self.logger.warning("a linked keybox without keys: still waiting")
                } else if grant.awaitingConfirmation == true, grant.linkRefused == nil {
                    let ours = grant.linkCodeTag == code.linkCodeTag
                    macSeesPhone = ours
                    linkCode = ours ? code.code(confirmNonce: grant.confirmNonce) : nil
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
        await fail(.noAnswer, hubID: hubID)
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

    /// The keybox's keys join the scan's, then the host saves the row and
    /// puts the hub on screen. `linkedAt`: the linked grant's `linked_at`
    /// (the Mac's clock), kept in the link for the removal check (#64). A
    /// fifth hub that raced past the scan's check is refused (its keys go).
    private func complete(_ pending: PendingLink, keys boxKeys: KeyboxKeys, linkedAt: Date?) async {
        let hubID = pending.link.hubID
        do {
            guard let unconfirmed = try keys.hubLink(hubID) else { throw SecureTransportError.keysUnavailable }
            try keys.saveHubLink(try unconfirmed.adding(boxKeys))
        } catch {
            Self.logger.error("keybox keys not stored: \(String(describing: error), privacy: .public)")
            await fail(.local(Self.keysUnavailableReason), hubID: hubID)
            return
        }
        var record = pending.link
        record.linkedAt = linkedAt
        guard let host, let device = identity.linkedDevice(for: record) else { return }
        do {
            try await host.linked(record, device: device)
        } catch HubRegistryError.full {
            await fail(.tooManyMacs, hubID: hubID)
            return
        } catch {
            Self.logger.error("link not saved: \(error.localizedDescription, privacy: .public)")
            await fail(.local(error.localizedDescription), hubID: hubID)
            return
        }
        store.pending = nil
        linkCode = nil
        macSeesPhone = false
        refreshLinks()
        // A notice about another link's state no longer applies; a report of
        // what an unlink lost ("Not sent", a recording kept) stays.
        switch notice {
        case .notSent, .recordingKept, .recordingsProblem: break
        default: notice = nil
        }
        phase = .linked(macName: record.macName)
    }

    /// The replica of `link`'s hub holds a linked, unrevoked keybox of that
    /// hub.
    private func isGranted(_ link: LinkRecord) async -> Bool {
        guard let deviceID = identity.deviceID,
              let grant = await host?.fetchKeybox(hubID: link.hubID, deviceID: deviceID)?.grant else { return false }
        return grant.hubID == link.hubID && grant.linked && grant.linkRefused == nil && grant.revoked != true
    }

    /// Removes the keys stored for `hubID` (best effort, logged).
    private func removeKeys(_ hubID: String) {
        do {
            try keys.removeHubLink(hubID)
        } catch {
            Self.logger.error("hub keys not removed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - The keybox after the link

    /// A keybox `hubID`'s replica indexed after the link (a rotation, or
    /// Remove on the Mac; read after unlock, through `indexPending`'s
    /// callback). A revoked one is that Mac removing this phone (D9): the
    /// hub freezes, in either scope. Newer epoch keys join the stored ones.
    /// Another hub's scan running meanwhile does not hold this one up.
    func keyboxChanged(hubID: String) async {
        guard let row = row(hubID), row.state == .linked, !ending.contains(hubID),
              let deviceID = identity.deviceID,
              let keybox = await host?.storedKeybox(hubID: hubID, deviceID: deviceID),
              keybox.grant.hubID == hubID, self.row(hubID)?.link == row.link
        else { return }
        if keybox.grant.revoked == true {
            Self.logger.notice("a Mac revoked this phone's keybox: removed")
            await removedByMac(hubID)
            return
        }
        await mergeKeys(of: keybox, into: row.link)
    }

    /// Final review Phone I-1: the keybox → Keychain merge is a reconcile, not only an edge. After every fetch of
    /// `hubID` (`keybox`: the one the fetch's grant check read), at unlock and on a re-scan of a linked Mac, the
    /// stored keybox's epoch keys the Keychain lacks are merged. A revoked keybox is left to `keyboxChanged` and
    /// the grant check. Idempotent: nothing missing, nothing written.
    func reconcileKeyboxKeys(hubID: String, keybox: Keybox? = nil) async {
        guard let row = row(hubID), row.state == .linked, !ending.contains(hubID) else { return }
        let stored: Keybox?
        if let keybox {
            stored = keybox
        } else if let deviceID = identity.deviceID {
            stored = await host?.storedKeybox(hubID: hubID, deviceID: deviceID)
        } else {
            stored = nil
        }
        guard let stored, self.row(hubID)?.link == row.link else { return }
        await mergeKeys(of: stored, into: row.link)
    }

    /// Adds `keybox`'s epoch keys to `link`'s stored hub keys when that changes which epochs the Keychain holds
    /// (epoch numbers are compared, never key material), then has the host open the rows they unlock.
    private func mergeKeys(of keybox: Keybox, into link: LinkRecord) async {
        guard keybox.grant.hubID == link.hubID, keybox.grant.linked, keybox.grant.revoked != true,
              let boxKeys = keybox.keys else { return }
        do {
            guard let current = try keys.hubLink(link.hubID) else { return }
            let merged = try current.adding(boxKeys)
            guard merged.epochs.map(\.epoch) != current.epochs.map(\.epoch) else { return }
            try keys.saveHubLink(merged)
        } catch KeyStoreError.locked {
            Self.logger.notice("keybox keys wait for the unlock")
            return
        } catch {
            Self.logger.error("keybox keys not stored: \(String(describing: error), privacy: .public)")
            return
        }
        Self.logger.notice("epoch keys merged from the keybox")
        host?.keysMerged(hubID: link.hubID)
    }

    /// At launch: a link saved before encryption (no hub keys in the
    /// Keychain, an F1 link moved into the registry included) cannot sync any
    /// more. Its hub is removed (recordings held) and the owner asked to scan
    /// again. A pending link without keys is dropped too. Locked keys decide
    /// nothing; other hubs are untouched.
    func dropUnencryptedLinks() async {
        if let pending = store.pending, hubKeys(pending.link.hubID) == .absent {
            store.pending = nil
        }
        refreshLinks()
        var dropped = false
        var total = LocalWipe()
        for row in links where hubKeys(row.hubID) == .absent && !ending.contains(row.hubID) {
            Self.logger.notice("a link made before encryption is dropped: scan again")
            let wipe = await endLink(row, farewell: false, keepRecordings: true)
            dropped = true
            total.notSent += wipe.notSent
            total.stoppedRecording = total.stoppedRecording || wipe.stoppedRecording
            total.problem = total.problem ?? wipe.problem
        }
        if dropped {
            notice = LinkNotice.after(total, otherwise: .encryptionReScan)
        }
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

    // MARK: - Unlink and the link's events (spec §9, multi-hub §6)

    /// Settings → Macs: reorders the Macs (the host saves it and the order
    /// follows on screen).
    func moveHub(_ hubID: String, to index: Int) {
        guard !isBusy else { return }
        host?.moveHub(hubID, to: index)
    }

    /// Settings → Macs → Unlink: the hub's files and row go, then its Mac
    /// hears `unlinked` (sealed with the hub's keys), then a shared link
    /// leaves the shares; the hub's keys go last.
    func unlink(_ hubID: String) async {
        guard !isBusy, let row = row(hubID), !ending.contains(hubID) else { return }
        phase = .unlinking
        report(LinkNotice.after(await endLink(row, farewell: true, keepRecordings: true), macName: row.link.macName), removed: hubID)
        phase = .idle
    }

    /// Settings → Macs → Forget: a hub the Mac removed goes with no farewell
    /// and no share leave (its zones are gone), its keys with it; a
    /// long-offline linked one, or one whose data could not be opened, is
    /// unlinked. A row that cannot be read goes with its keys and nothing
    /// else: its link (the scope, the shares) is unknown (#222).
    func forget(_ hubID: String) async {
        guard !isBusy, !ending.contains(hubID) else { return }
        guard let row = row(hubID) else {
            await forgetUnreadable(hubID)
            return
        }
        guard row.state == .unlinkedByMac else {
            await unlink(hubID)
            return
        }
        phase = .unlinking
        report(LinkNotice.after(await endLink(row, farewell: false, keepRecordings: true), macName: row.link.macName), removed: hubID)
        phase = .idle
    }

    /// Forget of a registry row that cannot be read: the host removes it
    /// (no session, so its files wait for the next launch's orphan pass),
    /// then its keys go.
    private func forgetUnreadable(_ hubID: String) async {
        guard let host, host.unreadableHubIDs().contains(hubID) else { return }
        phase = .unlinking
        ending.insert(hubID)
        let wipe = await host.removeHub(hubID, keepRecordings: true, farewell: nil)
        removeKeys(hubID)
        ending.remove(hubID)
        refreshLinks()
        report(LinkNotice.after(wipe), removed: hubID)
        phase = .idle
    }

    /// The report of `hubID`'s removal (`LinkNotice.after`), or, with
    /// nothing to report, no report. A stale notice stays only while
    /// another hub is on screen: the activation of the hub that took the
    /// screen set it, or the hub on screen did (#222); with no hub left on
    /// screen it goes with the removed one.
    private func report(_ found: LinkNotice?, removed hubID: String) {
        if let found {
            notice = found
        } else if case .stale = notice, let active = host?.activeHubID, active != hubID {
            return
        } else {
            notice = nil
        }
    }

    /// `TransportEvent.unlinked` for `hubID`: its zones are gone (the phone
    /// was removed, maybe while offline); or that Mac deleted this phone's
    /// grant (`evaluate(hubID:grant:heartbeat:)`), or revoked its keybox
    /// (D9, `keyboxChanged`). The hub freezes, its data readable (its keys
    /// stay) until Forget; nothing is wiped and other hubs are untouched.
    func removedByMac(_ hubID: String) async {
        guard let row = row(hubID), row.state == .linked, !ending.contains(hubID), let host else { return }
        ending.insert(hubID)
        await host.markRemovedByMac(hubID)
        ending.remove(hubID)
        refreshLinks()
        notice = .removed(macName: row.link.macName)
    }

    /// How long a kept farewell is sent again (#143): after it, the Mac is
    /// left to its own removal and a `shared` link's shares are left.
    static let farewellLifetime: TimeInterval = 7 * 24 * 3600

    /// When the app becomes active (`AppRoot.becameActive`): the unlink
    /// farewells a removal kept unsent (#143) are sent again, each in turn;
    /// one sent, or past `farewellLifetime`, stops being kept and its
    /// `shared` link leaves the shares. One made on another iCloud account,
    /// or of a hub linked again (or being linked) since, is dropped unsent
    /// and its shares untouched. Nothing runs while a link flow is busy or
    /// the account cannot be read. Each farewell is decided on the state
    /// read when its turn comes, and again after its resend: a link of its
    /// hub that began meanwhile keeps the shares (the new link's), and one
    /// a relink dropped while an earlier one was sent is not sent.
    func retryFarewells() async {
        guard let host, !isBusy else { return }
        let kept = host.pendingFarewells()
        guard !kept.isEmpty, await container.accountStatus() == .available else { return }
        let account: String
        do {
            account = try await container.userRecordName()
        } catch {
            Self.logger.warning("account check before the farewells failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for farewell in kept {
            let hubID = farewell.hubID
            // Read again at its turn: a relink dropped it (`LinkHost.linked`), or an unlink replaced it.
            guard host.pendingFarewells().contains(where: { $0.isSame(as: farewell) }), !ending.contains(hubID) else { continue }
            if isLinked(hubID) || farewell.userRecordName != account {
                host.dropFarewell(hubID)
                continue
            }
            if clock.now().timeIntervalSince(farewell.since) >= Self.farewellLifetime {
                Self.logger.notice("a kept unlinked record expired unsent")
                host.dropFarewell(hubID)
            } else if await !host.resendFarewell(farewell) {
                continue
            }
            // The resend awaited: a link of this hub begun meanwhile has its own shares.
            guard !isLinked(hubID) else { continue }
            if case let .shared(ownerName) = farewell.scope {
                do {
                    try await container.leaveShares(ownerName: ownerName, hubID: hubID)
                } catch {
                    Self.logger.warning("leaving the shares failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// `hubID` has a saved link, a pending one, or a code of it being
    /// linked: read now, from the host and the store.
    private func isLinked(_ hubID: String) -> Bool {
        row(hubID) != nil || store.pending?.link.hubID == hubID || linkingHubID == hubID
    }

    /// The transport saw an iCloud account change. Another account ends
    /// every link and removes every hub, their keys with them; a sign-out
    /// keeps them until an account is back (spec §9, multi-hub §6.2).
    func accountChanged() async {
        refreshLinks()
        guard !links.isEmpty else { return }
        guard await container.accountStatus() == .available else { return }
        let current: String
        do {
            current = try await container.userRecordName()
        } catch {
            Self.logger.warning("account check failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // An unlink or a removal that ran during the check already ended
        // its hub.
        let rows = (host?.linkedHubs() ?? []).filter { !ending.contains($0.hubID) }
        guard let host, rows.contains(where: { $0.link.userRecordName != current }) else { return }
        Self.logger.notice("iCloud account changed while linked: removing every hub")
        store.pending = nil
        ending.formUnion(rows.map(\.hubID))
        // The recordings were made for the old account's Macs: not carried
        // to whatever the new account links, reported "Not sent".
        var total = LocalWipe()
        for row in rows {
            let wipe = await host.removeHub(row.hubID, keepRecordings: false, farewell: nil)
            removeKeys(row.hubID)
            total.notSent += wipe.notSent
            total.stoppedRecording = total.stoppedRecording || wipe.stoppedRecording
            total.problem = total.problem ?? wipe.problem
        }
        ending.subtract(rows.map(\.hubID))
        refreshLinks()
        if !isBusy { phase = .idle }
        notice = LinkNotice.after(total)
    }

    /// How long a hub must go on without this phone's grant, across two
    /// fetches, before the phone reads it as removed (#64).
    static let removalConfirmAfter: TimeInterval = 30

    /// After each fetch of `hubID`: this phone's own `device_grant` in that
    /// hub's replica (since E2E, the grant its keybox carries). The Mac's
    /// Remove deletes it (`DeviceGrantSlice` publishes no record for a
    /// removed phone), and for a same-Apple-ID
    /// phone that is the only sign: its zones are the Mac's own and never
    /// vanish, so no `unlinked` event comes (#64). A wrongful removal stops
    /// a hub, so it needs all of:
    /// - a `linked` row that kept the device id it linked with and its
    ///   grant's `linked_at` (an older link never reads a removal);
    /// - no scan, unlink or pending link running;
    /// - that hub's heartbeat, newer than the link's `linked_at` (the
    ///   replica holds that hub's zone as the Mac wrote it after the link);
    /// - no linked grant for that device id (absent, or `linked: false`)
    ///   on two looks at least `removalConfirmAfter` apart, with none in
    ///   between: the first look is kept on the hub's row (across a
    ///   relaunch) and a linked grant of the linked device and hub clears it
    ///   in any fetch, whatever its heartbeat or a scan running — so a
    ///   stale first look never counts as the second.
    /// Then it is the same removal as that event. A shared phone whose
    /// participant removal failed is told the same way.
    func evaluate(hubID: String, grant: DeviceGrant?, heartbeat: HeartbeatPayload?) async {
        guard let row = row(hubID), row.state == .linked, !ending.contains(hubID),
              let deviceID = row.link.deviceID, let linkedAt = row.link.linkedAt else { return }
        // Another device's or hub's grant says nothing about this link.
        if let grant, grant.deviceID != deviceID || grant.hubID != hubID { return }
        if grant?.linked == true {
            if row.grantMissingSince != nil {
                host?.setGrantMissingSince(nil, hubID: hubID)
            }
            return
        }
        // Only the missing or unlinked grant needs the rest.
        guard !isBusy, store.pending == nil,
              let heartbeat, heartbeat.hubID == hubID, heartbeat.updatedAt > linkedAt else { return }
        let now = clock.now()
        guard let since = row.grantMissingSince else {
            host?.setGrantMissingSince(now, hubID: hubID)
            return
        }
        guard now.timeIntervalSince(since) >= Self.removalConfirmAfter else { return }
        Self.logger.notice("a linked Mac no longer grants this phone: removed")
        await removedByMac(hubID)
    }

    /// After each fetch of `hubID`: no heartbeat for a day reads as the Mac
    /// gone (stale), for the hub on screen only (`isActive`).
    func evaluate(hubID: String, heartbeat: HeartbeatPayload?, isActive: Bool) async {
        guard isActive, let heartbeat, row(hubID)?.state == .linked else { return }
        setStaleNotice(staleNotice(hubID: hubID, heartbeat: heartbeat))
    }

    /// A switch put `hubID` on screen: the stale notice is the new hub's,
    /// from its session's last heartbeat (none read yet, or a hub the Mac
    /// removed: no stale notice), never the old hub's carried over.
    func activated(hubID: String, heartbeat: HeartbeatPayload?) {
        setStaleNotice(staleNotice(hubID: hubID, heartbeat: heartbeat))
    }

    /// `hubID`'s stale notice: a linked hub whose `heartbeat` is a day old
    /// or more, named by its Mac; nil otherwise.
    private func staleNotice(hubID: String, heartbeat: HeartbeatPayload?) -> LinkNotice? {
        guard let heartbeat, let row = row(hubID), row.state == .linked,
              clock.now().timeIntervalSince(heartbeat.updatedAt) >= Self.staleAfter else { return nil }
        return .stale(macName: row.link.macName)
    }

    /// Sets the stale notice, or clears it, unless a report of what a link
    /// lost is showing (that stays until read).
    private func setStaleNotice(_ stale: LinkNotice?) {
        switch notice {
        case .stale, nil:
            notice = stale
        case .removed, .notSent, .recordingKept, .recordingsProblem, .encryptionReScan:
            break
        }
    }

    /// Ends `row`'s link: the host removes the hub (its row first, then, for
    /// an unlink of a linked hub (`farewell`), the `unlinked` record through
    /// the hub's own transport, sealed with the hub's keys, which holds the
    /// record's server state, best effort and bounded; then its session,
    /// recordings and files), then a `shared` link that said farewell leaves
    /// the shares (unless the farewell was kept unsent: `retryFarewells`
    /// leaves them once it is out), then the hub's keys are deleted (`removeHubLink`). The
    /// record is built here, before the hub's Settings choices go. A frozen
    /// hub's zones are gone: no farewell, no leave. Removing the hub's
    /// replica takes the outbox and the recordings sealed under this link
    /// with it; held audio is sealed again under the next link.
    private func endLink(_ row: HubRow, farewell sendsFarewell: Bool, keepRecordings: Bool) async -> LocalWipe {
        guard let host else { return LocalWipe() }
        let hubID = row.hubID
        ending.insert(hubID)
        defer { ending.remove(hubID) }
        let linked = row.state == .linked && sendsFarewell
        let scope = row.link.databaseScope
        var farewell: CloudRecord?
        if linked, let device = identity.linkedDevice(for: row.link) {
            do {
                farewell = try deviceRecord(hubID: hubID, for: device, linkNonce: nil, unlinked: true)
            } catch {
                Self.logger.warning("unlinked record not built: \(error.localizedDescription, privacy: .public)")
            }
        }
        let wipe = await host.removeHub(hubID, keepRecordings: keepRecordings, farewell: farewell)
        removeKeys(hubID)
        refreshLinks()
        // A kept farewell still needs the zones: the shares go once it is out (`retryFarewells`).
        if linked, !wipe.farewellKept, case let .shared(ownerName) = scope {
            do {
                try await container.leaveShares(ownerName: ownerName, hubID: hubID)
            } catch {
                Self.logger.warning("leaving the shares failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return wipe
    }

    private func deviceRecord(hubID: String, for device: LinkedDevice, linkNonce: String?, unlinked: Bool = false) throws -> CloudRecord {
        guard let host else { throw CancellationError() }
        let payload = host.devicePayload(hubID: hubID, for: device, linkNonce: linkNonce, unlinked: unlinked, now: clock.now())
        return try CloudRecordFactory.record(for: payload, modifiedAt: payload.updatedAt)
    }
}

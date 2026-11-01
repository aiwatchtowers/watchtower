import Foundation
import Observation
import os
import WatchtowerHostedRelay
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
        /// The relay account holds 3 Macs (the `open_pairing` pre-check, before any hello): the slots screen,
        /// whose removal lets the link go on with the same code (`relaySlots`).
        case slotsFull(macName: String)
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
    /// The confirmed Relay links still finishing (`LinkStore.promoted`), oldest first, refreshed with `links`.
    private(set) var promotedLinks: [PromotedLink] = []
    /// The slots screen's state: the Macs in this account's slots and the removal running or failed.
    private(set) var relaySlots = RelaySlotsState()
    /// Finishes the confirmed Relay links (Settings → Macs reads its running and failed hubs).
    let resumer: PromotedLinkResumer

    /// Set by the owner right after init (it owns this model).
    @ObservationIgnored weak var host: (any LinkHost)? {
        didSet { refreshLinks() }
    }
    @ObservationIgnored private let access: any LinkAccess
    @ObservationIgnored private let store: LinkStore
    /// The device id is filled in when the link flow creates the device keys.
    @ObservationIgnored private var identity: DeviceIdentity
    /// The phone's E2E keys: the device identity and each hub's link.
    @ObservationIgnored private let keys: any PhoneKeyStore
    @ObservationIgnored private let clock: any LinkClock
    /// The relay's account ops (off: never asked).
    @ObservationIgnored private let relay: any RelayLinkOps
    /// The code a failure's Try Again opens again (`LinkFailure.retryTitle`).
    @ObservationIgnored private var retryCode: URL?
    /// The code the inline slots screen goes on with after a removal.
    @ObservationIgnored private var slotsCode: RelayCode?
    /// Hubs whose link is ending (an unlink, a removal, the account
    /// switch): a removal or an account signal arriving meanwhile is the
    /// ending's own, and is ignored.
    @ObservationIgnored private var ending: Set<String> = []
    /// The hub of the code being linked (`open`), from its check on: a
    /// kept farewell of that hub is not followed by a share leave.
    @ObservationIgnored private var linkingHubID: String?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkingViewModel")

    init(
        access: any LinkAccess,
        store: LinkStore,
        identity: DeviceIdentity,
        keys: any PhoneKeyStore,
        clock: any LinkClock = SystemLinkClock(),
        relay: any RelayLinkOps = OffRelayLinkOps()
    ) {
        self.access = access
        self.store = store
        self.identity = identity
        self.keys = keys
        self.clock = clock
        self.relay = relay
        resumer = PromotedLinkResumer(store: store, relay: relay, clock: clock)
        resumer.finish = { [weak self] link in await self?.completePromoted(link) ?? .failed }
        resumer.changed = { [weak self] in self?.refreshLinks() }
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
        promotedLinks = store.promoted.values.sorted { $0.since < $1.since }
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
        case .removed, .notSent, .recordingKept, .recordingsProblem, .encryptionReScan, .macOnRelay, .finishingInBackground,
             .needsOwner: notice = nil
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
        if case .slotsFull = phase { closeSlots() }
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
        guard !isBusy, let (payload, hubKeys) = readCode(url) else { return }
        // A confirmed Relay link of this hub: one attempt to finish it, whatever the code (its expiry included); no
        // hello, no relay pairing call of the code's own.
        if store.promoted[payload.hubID] != nil {
            await finishPromoted(payload.hubID, ownerAsked: true)
            return
        }
        // Step 1: only a code clearly past its expiry on this clock.
        guard !isExpired(payload) else {
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
        // A fifth Mac: refused before any share is accepted or written. A confirmed Relay link still finishing
        // counts as a Mac.
        let promotedElsewhere = store.promoted.keys.filter { key in !links.contains { $0.hubID == key } }.count
        if links.count + promotedElsewhere >= HubRegistry.limit, !links.contains(where: { $0.hubID == payload.hubID }) {
            phase = .failed(.tooManyMacs)
            return
        }
        // The route (R4): the paying check only for a hub on the relay with the relay available.
        let route = await LinkRoutePolicy.decide(payload, relay: relay.availability) { [relay] in
            await LinkRoutePolicy.paying { try await relay.accountState() }
        }
        let ownerUser: String
        switch route {
        case let .refuse(failure):
            phase = .failed(failure)
            return
        case let .relay(mac, authPub):
            if let row = row(payload.hubID), !ending.contains(row.hubID) {
                report(LinkNotice.after(await endLink(row, farewell: false, keepRecordings: true), macName: row.link.macName), removed: row.hubID)
            }
            await connectRelay(RelayCode(payload: payload, mac: mac, authPub: authPub, hubKeys: hubKeys))
            return
        case .cloudKit:
            // The route rule sends only a code that offers iCloud here, and such a code names its owner.
            guard let owner = payload.ownerUser else {
                phase = .failed(.refused)
                return
            }
            ownerUser = owner
        }
        // Step 2.
        guard await access.availability() == .available else {
            phase = .failed(.signIn)
            return
        }
        let userRecordName: String
        do {
            userRecordName = try await access.identity()
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
        await connect(payload, ownerUser: ownerUser, hubKeys: hubKeys, userRecordName: userRecordName)
    }

    /// The scanned code and its hub keys; nil with the failure shown when the code cannot be used.
    private func readCode(_ url: URL) -> (LinkPayload, ScannedHubKeys)? {
        let payload: LinkPayload
        switch LinkPayload.parse(url) {
        case let .success(parsed):
            payload = parsed
        case .failure(.newerVersion):
            phase = .failed(.updateApp)
            return nil
        case .failure(.olderVersion):
            phase = .failed(.updateMac)
            return nil
        case let .failure(error):
            Self.logger.warning("unusable link code: \(String(describing: error), privacy: .public)")
            phase = .failed(.refused)
            return nil
        }
        // The hub id names the hub's directories: only a plain name.
        guard HubPaths.isValidHubID(payload.hubID) else {
            Self.logger.warning("link code with an unusable hub id")
            phase = .failed(.refused)
            return nil
        }
        do {
            return (payload, try ScannedHubKeys(payload))
        } catch {
            Self.logger.warning("link code with unusable keys: \(String(describing: error), privacy: .public)")
            phase = .failed(.refused)
            return nil
        }
    }

    /// "Linked to <Mac name>" → the notification prompt → Now.
    func finish() async {
        guard case .linked = phase else { return }
        phase = .idle
        await host?.requestNotificationPermission()
        host?.openNow()
    }

    /// Steps 3–5 for a valid code.
    private func connect(_ payload: LinkPayload, ownerUser: String, hubKeys: ScannedHubKeys, userRecordName: String) async {
        // Step 3: same Apple ID → the private database, share URLs ignored
        // (an owner cannot accept their own share). Another Apple ID → both
        // shares, then the shared database.
        let route: HubRoute
        if userRecordName == ownerUser {
            route = .cloudKit(.private)
        } else {
            guard payload.dataShare.flatMap(URL.init(string:)) != nil,
                  payload.relayShare.flatMap(URL.init(string:)) != nil
            else {
                phase = .failed(.cannotShare)
                return
            }
            do {
                try await access.join(
                    LinkInvitation(dataShare: payload.dataShare, relayShare: payload.relayShare),
                    route: .cloudKit(.shared(ownerName: ownerUser)), hubID: payload.hubID)
            } catch {
                Self.logger.error("share accept failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(.cannotShare)
                return
            }
            route = .cloudKit(.shared(ownerName: ownerUser))
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
        let shared: Bool
        if case .cloudKit(.shared) = route { shared = true } else { shared = false }
        let record = LinkRecord(
            hubID: payload.hubID,
            macName: payload.macName,
            scope: shared ? .shared : .private,
            ownerName: ownerUser,
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
            transport = try await host.prepare(route: route, hubID: record.hubID, fresh: true)
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
        // A confirmed Relay link is never failed: its slot and keys go only by the owner's Cancel.
        guard store.promoted[hubID] == nil else {
            Self.logger.notice("a pending link of a confirmed relay link dropped; the link resumes")
            store.pending = nil
            linkCode = nil
            macSeesPhone = false
            phase = .idle
            return
        }
        // A Relay link not confirmed yet: its pairing slot is closed first (best effort; it expires anyway).
        if let pending = store.pending, pending.link.hubID == hubID, let slot = pending.relaySlot {
            await relay.close(slot: slot)
        }
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
        hubID: String,
        for device: LinkedDevice,
        keys deviceKeys: DeviceIdentityKeys,
        linkNonce: String,
        relayDeviceID: String? = nil
    ) throws -> CloudRecord {
        guard let host else { throw CancellationError() }
        let payload = host.devicePayload(hubID: hubID, for: device, linkNonce: linkNonce, unlinked: false, now: clock.now())
        let hello = DeviceHello(
            device: payload,
            signingKey: WireBytes.base64URL(deviceKeys.signing.publicKey.rawRepresentation),
            agreementKey: WireBytes.base64URL(deviceKeys.agreement.publicKey.rawRepresentation),
            relayDeviceID: relayDeviceID
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
        // A Relay link the owner already confirmed is never bounded by the code's deadline (point 9).
        switch relayConfirmation(of: pending) {
        case .promoted:
            // A kill between the two writes of `LinkStore.confirm`: the promoted entry is the link.
            store.pending = nil
            return
        case .keysArrived:
            await confirmPendingRelay(pending)
            return
        case .locked:
            Self.logger.notice("keys locked at launch: the pending link waits for the next launch")
            return
        case .notYet:
            break
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
            if let slot = pending.relaySlot, let mac = pending.link.relayMacDeviceID {
                _ = try await host?.preparePairing(macDeviceID: mac, slot: slot, hubID: pending.link.hubID)
            } else {
                _ = try await host?.prepare(route: pending.link.route, hubID: pending.link.hubID, fresh: false)
            }
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
        // A Relay link's wait ends with its slot at the latest: a code still valid then needs a new slot.
        if let expiresAt = pending.relaySlotExpiresAt, clock.now() >= expiresAt {
            await fail(.expired, hubID: hubID)
            return
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
        if pending.relaySlot != nil {
            // Kept before the keys: a launch that finds them confirms the link with the grant's own time.
            var kept = pending
            kept.linkedAt = linkedAt
            store.pending = kept
        }
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
        if let slot = pending.relaySlot {
            await confirmRelay(pending, record: record, slot: slot)
            return
        }
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
        // R4: the fetch that brought the keys also read the hub's data zone and the mailbox. A Mac that runs over
        // Relay, on a phone that cannot use Relay, would send this link nothing: it ends at once.
        if host.hubRunsOnRelay(hubID), !(await canUseRelay()), let row = row(hubID), !ending.contains(hubID) {
            Self.logger.notice("an iCloud link to a Mac on Relay ended")
            _ = await endLink(row, farewell: true, keepRecordings: true)
            phase = .failed(.macOnRelay(macName: record.macName))
            return
        }
        clearNoticeAfterLink()
        phase = .linked(macName: record.macName)
    }

    /// A notice about another link's state no longer applies once a link completes; a report of what an unlink
    /// lost ("Not sent", a recording kept) stays.
    private func clearNoticeAfterLink() {
        switch notice {
        case .notSent, .recordingKept, .recordingsProblem: break
        default: notice = nil
        }
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
    /// (epoch numbers are compared, never key material), then has the host open the rows they unlock. Every epoch
    /// but the newest carries when it was superseded (the previous newest stamped now; one stored before the stamp
    /// existed too), which the Keychain's 7-day retention reads; the host hears whether the newest epoch went up.
    /// Returns whether the Keychain holds the keybox's epochs afterwards (merged now, or already there).
    @discardableResult
    private func mergeKeys(of keybox: Keybox, into link: LinkRecord) async -> Bool {
        guard keybox.grant.hubID == link.hubID, keybox.grant.linked, keybox.grant.revoked != true,
              let boxKeys = keybox.keys else { return false }
        let raised: Bool
        do {
            guard let current = try keys.hubLink(link.hubID) else { return false }
            let merged = try current.adding(boxKeys).stampingSuperseded(from: current, now: clock.now())
            guard merged.epochs.map(\.epoch) != current.epochs.map(\.epoch) else { return true }
            raised = merged.newestEpochRaised(over: current)
            try keys.saveHubLink(merged)
        } catch KeyStoreError.locked {
            Self.logger.notice("keybox keys wait for the unlock")
            return false
        } catch {
            Self.logger.error("keybox keys not stored: \(String(describing: error), privacy: .public)")
            return false
        }
        Self.logger.notice("epoch keys merged from the keybox")
        host?.keysMerged(hubID: link.hubID, newestEpochRaised: raised)
        return true
    }

    // MARK: - The transport follower's questions (relay client Phase 3 Task 11)

    /// Merges the keybox a `transport_switched` carried into `hubID`'s keys, as a data-zone keybox is merged; false
    /// when the hub has no linked row or the keys could not be stored (the control is then read again).
    func mergeSwitchKeys(_ keybox: Keybox, hubID: String) async -> Bool {
        guard let row = row(hubID), row.state == .linked, !ending.contains(hubID) else { return false }
        return await mergeKeys(of: keybox, into: row.link)
    }

    /// The newest epoch the Keychain holds for `hubID`; nil when it cannot be read (locked) or holds none.
    func newestEpoch(hubID: String) -> UInt32? {
        do {
            return try keys.hubLink(hubID)?.epochs.map(\.epoch).max()
        } catch {
            return nil
        }
    }

    /// Whether this phone may use the relay to reach `link`'s Mac, asked now: `.no` while the relay is off or the
    /// link has no relay id for its Mac, or when the account answers not paying; `.unknown` when the relay did not
    /// answer (unreachable, attestation backoff, an update needed), which decides nothing.
    func relayUse(for link: LinkRecord) async -> RelayUse {
        guard case .available = relay.availability, link.relayMacDeviceID != nil else { return .no }
        let paying = await LinkRoutePolicy.paying { [relay] in try await relay.accountState() }
        switch paying {
        case .success(true): return .yes
        case .success(false): return .no
        case .failure: return .unknown
        }
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
        _ = await unlinkRow(row)
        phase = .idle
    }

    /// An unlink of `row`: its farewell, the hub removed, and for a Relay link its slot freed afterwards (R14:
    /// once the farewell left the queue or was kept, `remove_slot`; a failure is kept for a retry at launch).
    /// Returns whether the slot is free (true for an iCloud link).
    private func unlinkRow(_ row: HubRow) async -> Bool {
        report(LinkNotice.after(await endLink(row, farewell: true, keepRecordings: true), macName: row.link.macName), removed: row.hubID)
        guard case let .hostedRelay(mac) = row.link.route, row.state == .linked else { return true }
        return await removeRelaySlot(mac, keepOnFailure: true)
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
        guard !kept.isEmpty else { return }
        // Only an iCloud farewell needs the account (carry-over R19: a Relay farewell never depends on iCloud).
        var account: String?
        if kept.contains(where: { $0.route.cloudKitScope != nil }), await access.availability() == .available {
            do {
                account = try await access.identity()
            } catch {
                Self.logger.warning("account check before the farewells failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for farewell in kept {
            let hubID = farewell.hubID
            let iCloud = farewell.route.cloudKitScope != nil
            if iCloud, account == nil { continue }
            // Read again at its turn: a relink dropped it (`LinkHost.linked`), or an unlink replaced it.
            guard host.pendingFarewells().contains(where: { $0.isSame(as: farewell) }), !ending.contains(hubID) else { continue }
            if isLinked(hubID) || (iCloud && farewell.userRecordName != account) {
                host.dropFarewell(hubID)
                continue
            }
            if clock.now().timeIntervalSince(farewell.since) >= Self.farewellLifetime {
                Self.logger.notice("a kept unlinked record expired unsent")
                host.dropFarewell(hubID)
            } else if await !host.resendFarewell(farewell) {
                continue
            }
            // The resend awaited: a link of this hub begun meanwhile has its own shares. A Relay link has none.
            guard iCloud, !isLinked(hubID) else { continue }
            do {
                try await access.leave(route: farewell.route, hubID: hubID)
            } catch {
                Self.logger.warning("leaving the shares failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `hubID` has a saved link, a pending one, or a code of it being
    /// linked: read now, from the host and the store.
    private func isLinked(_ hubID: String) -> Bool {
        row(hubID) != nil || store.pending?.link.hubID == hubID || linkingHubID == hubID || store.promoted[hubID] != nil
    }

    /// The transport saw an iCloud account change. Another account ends
    /// every link and removes every hub, their keys with them; a sign-out
    /// keeps them until an account is back (spec §9, multi-hub §6.2).
    func accountChanged() async {
        refreshLinks()
        // A Relay link depends on no iCloud account (R19).
        guard links.contains(where: { $0.link.route.cloudKitScope != nil }) else { return }
        guard await access.availability() == .available else { return }
        let current: String
        do {
            current = try await access.identity()
        } catch {
            Self.logger.warning("account check failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // An unlink or a removal that ran during the check already ended
        // its hub.
        let rows = (host?.linkedHubs() ?? []).filter { !ending.contains($0.hubID) && $0.link.route.cloudKitScope != nil }
        guard let host, rows.contains(where: { $0.link.userRecordName != current }) else { return }
        Self.logger.notice("iCloud account changed while linked: removing every iCloud hub")
        if store.pending?.relaySlot == nil {
            store.pending = nil
        }
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
        case .removed, .notSent, .recordingKept, .recordingsProblem, .encryptionReScan, .macOnRelay, .finishingInBackground,
             .needsOwner:
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
        let route = row.link.route
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
        if linked, !wipe.farewellKept, route.cloudKitScope != nil {
            do {
                try await access.leave(route: route, hubID: hubID)
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

// MARK: - Linking over the relay (relay client Phase 3 Task 10)

/// A scanned code that links over a relay pairing slot: the code, the Mac's relay id and `relay_auth` key, and the
/// hub's keys from it.
struct RelayCode {
    let payload: LinkPayload
    let mac: String
    let authPub: Data
    let hubKeys: ScannedHubKeys
}

/// The slots screen's state (`LinkingViewModel.relaySlots`): the Macs in slots, which one is being removed, and
/// which removal failed. `finishing` names the confirmed link the screen was opened for from Settings → Macs
/// (Manage Macs); nil while it shows on the link screen, before the owner confirmed.
struct RelaySlotsState: Equatable {
    var macs: [String] = []
    var removing: String?
    var failed: String?
    /// The removed Mac's row as it read when Remove was pressed: an unlink ends its registry row before
    /// `remove_slot` answers, and the row keeps its name and kind while removing and after a failure.
    var pinned: [String: RelaySlotsModel.Pinned] = [:]
    var finishing: String?
    /// The account state is being read (Manage Macs).
    var loading = false
}

extension LinkingViewModel {
    /// A code clearly past its expiry on this clock.
    private func isExpired(_ payload: LinkPayload) -> Bool {
        Double(payload.exp) < clock.now().timeIntervalSince1970 - Self.expiryGrace
    }

    /// The relay path of steps 2–5 (R3): the slot (`open_pairing`, after its pre-check), the keys, the pairing
    /// transport, the hello with this phone's relay id in `pair/<slot>`, the wait. Nothing is written before the
    /// slot opens; a failure before the owner confirmed closes it and removes what the link wrote.
    private func connectRelay(_ code: RelayCode) async {
        let payload = code.payload
        let slot: (slot: String, expiresAt: Date)
        do {
            slot = try await relay.open(mac: code.mac)
        } catch HostedRelayPairing.Refusal.slotsFull(let macs) {
            slotsCode = code
            relaySlots = RelaySlotsState(macs: macs)
            phase = .slotsFull(macName: payload.macName)
            return
        } catch {
            let failure = Self.openFailure(error, code: payload)
            retryCode = failure.retryTitle == nil ? nil : payload.url()
            phase = .failed(failure)
            return
        }
        let deviceKeys: DeviceIdentityKeys
        let relayDeviceID: String
        do {
            deviceKeys = try keys.identity()
            try keys.saveHubLink(code.hubKeys.unconfirmedLink)
        } catch {
            Self.logger.error("device keys unavailable: \(String(describing: error), privacy: .public)")
            await relay.close(slot: slot.slot)
            phase = .failed(.local(Self.keysUnavailableReason))
            return
        }
        identity.deviceID = deviceKeys.deviceID.uuidString
        var record = LinkRecord(
            hubID: payload.hubID, macName: payload.macName, scope: .private, ownerName: payload.ownerUser ?? "",
            userRecordName: "", nonce: payload.nonce, dataShareURL: nil, relayShareURL: nil, deviceID: identity.deviceID,
            relayAuthPub: payload.relayAuthPub, hubTransports: payload.transports
        )
        record.setRelay(mac: code.mac)
        guard let host, let device = identity.linkedDevice(for: record) else { return }
        let deadline = min(waitDeadline(expiresAt: payload.exp), slot.expiresAt)
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(payload.iat))
        store.pending = PendingLink(
            link: record, deadline: deadline, baseline: nil, baselineCaptured: false, issuedAt: issuedAt,
            relaySlot: slot.slot, relaySlotExpiresAt: slot.expiresAt
        )
        let transport: any CloudSyncTransport
        do {
            relayDeviceID = try relay.phoneDeviceID()
            transport = try await host.preparePairing(macDeviceID: code.mac, slot: slot.slot, hubID: record.hubID)
        } catch is CancellationError {
            return
        } catch {
            await fail(.local(error.localizedDescription), hubID: record.hubID)
            return
        }
        let baseline = await host.fetchKeybox(hubID: record.hubID, deviceID: device.deviceID)?.grant
        let pending = PendingLink(
            link: record, deadline: deadline, baseline: baseline, baselineCaptured: true, issuedAt: issuedAt,
            relaySlot: slot.slot, relaySlotExpiresAt: slot.expiresAt
        )
        store.pending = pending
        do {
            try await transport.save([
                try helloRecord(
                    hubID: record.hubID, for: device, keys: deviceKeys, linkNonce: payload.nonce, relayDeviceID: relayDeviceID
                )
            ])
        } catch {
            await fail(.local(error.localizedDescription), hubID: record.hubID)
            return
        }
        await waitForGrant(pending, code: PairingCode(hubKeys: code.hubKeys, deviceKeys: deviceKeys))
    }

    /// What a refused `open_pairing` (before any hello) shows.
    static func openFailure(_ error: any Error, code: LinkPayload) -> LinkFailure {
        switch error as? HostedRelayPairing.Refusal {
        case .notPaying where code.offersCloudKit: .macOnRelay(macName: code.macName)
        case .notPaying: .needsRelay(macName: code.macName)
        case .updateRequired: .updateApp
        case .pairingExpired: .expired
        case .replacementLimit, .slotsFull, .unreachable, .attestationBackoff: .relayUnreachable
        case nil:
            if case HostedRelayError.server(code: .notFound, _)? = error as? HostedRelayError {
                .macNotOnRelay(macName: code.macName)
            } else {
                .relayUnreachable
            }
        }
    }

    /// The owner confirmed (the keys arrived): the link moves to `LinkStore.promoted` as `.confirmed`, and from
    /// here it never belongs to the link screen; a slot removal or a relay farewell kept for this Mac or hub goes.
    /// Then one attempt to finish it inline.
    private func confirmRelay(_ pending: PendingLink, record: LinkRecord, slot: String) async {
        let link = PromotedLink(
            link: record, slot: slot, slotExpiresAt: pending.relaySlotExpiresAt ?? clock.now(), state: .confirmed,
            since: clock.now()
        )
        linkCode = nil
        macSeesPhone = false
        do {
            try store.confirm(link)
        } catch {
            // Kept in `pending`: the next launch's resume writes it again before any relay call.
            Self.logger.error("confirmed relay link not saved: it resumes at the next launch")
            notice = .finishingInBackground(macName: record.macName)
            phase = .idle
            return
        }
        if let host {
            host.forgetSlotRemoval(link.macDeviceID)
            if host.pendingFarewells().contains(where: { $0.hubID == link.hubID && $0.route.cloudKitScope == nil }) {
                host.dropFarewell(link.hubID)
            }
        }
        refreshLinks()
        await finishPromoted(link.hubID, ownerAsked: false)
    }

    /// One attempt for a confirmed link, from the link screen (the inline attempt, or a scan of its hub's code):
    /// "Linked", or the notice of what is left, and the scanner is free.
    private func finishPromoted(_ hubID: String, ownerAsked: Bool) async {
        guard let macName = store.promoted[hubID]?.macName else { return }
        phase = .checking
        let outcome = await resumer.run(hubID, ownerAsked: ownerAsked)
        switch outcome {
        case .linked:
            clearNoticeAfterLink()
            phase = .linked(macName: macName)
        case let .needsOwner(reason):
            notice = .needsOwner(macName: macName, reason: reason)
            phase = .idle
        case .waiting, .none:
            notice = .finishingInBackground(macName: macName)
            phase = .idle
        }
    }

    /// `prepare` on the Mac's data zone (the pairing transport goes), then `linked` with the `.relay` route: the row
    /// is saved and the promoted entry goes. False (logged) when either throws: the link resumes later.
    private func completePromoted(_ link: PromotedLink) async -> PromotedLinkResumer.Finish {
        guard let host, let device = identity.linkedDevice(for: link.link) else { return .failed }
        do {
            _ = try await host.prepare(route: link.link.route, hubID: link.hubID, fresh: false)
            try await host.linked(link.link, device: device)
        } catch HubRegistryError.full {
            return .registryFull
        } catch {
            Self.logger.error("promoted link not finished: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        store.removePromoted(link.hubID)
        resumer.forget(link.hubID)
        refreshLinks()
        return .linked
    }

    /// At launch and on every foreground: one automatic attempt per confirmed link (`.needsOwner` waits).
    func resumePromotedLinks() async {
        await resumer.resumeAll()
        refreshLinks()
    }

    /// Settings → Macs → Try Again on a confirmed link.
    func tryAgain(_ hubID: String) async {
        _ = await resumer.run(hubID, ownerAsked: true)
        refreshLinks()
    }

    /// Settings → Macs → Cancel (after "Cancel the link to <Mac>?"), and Remove on the slots screen for a Mac still
    /// finishing. Never waits on `prepare`: the farewell, sealed with the keys the phone holds, goes straight into
    /// the mailbox (10 s bound; kept on failure); then `remove_slot`, always (kept on failure); then the hub's keys,
    /// session, directory and the promoted entry go, whatever those did. Returns whether the slot is free.
    @discardableResult
    func cancelPromoted(_ hubID: String) async -> Bool {
        guard let link = store.promoted[hubID], let host, !ending.contains(hubID) else { return false }
        ending.insert(hubID)
        defer { ending.remove(hubID) }
        let route = link.link.route
        var sent = false
        if let device = identity.linkedDevice(for: link.link),
           let record = try? deviceRecord(hubID: hubID, for: device, linkNonce: nil, unlinked: true),
           let sealed = await host.sealFarewell(hubID: hubID, route: route, record: record) {
            let farewell = PendingFarewell(
                hubID: hubID, route: route, userRecordName: link.link.userRecordName, record: sealed, since: clock.now()
            )
            if host.keepFarewell(farewell) {
                sent = await host.resendFarewell(farewell)
            }
        }
        let freed = await removeRelaySlot(link.macDeviceID, keepOnFailure: true)
        if freed, !sent, host.pendingFarewells().contains(where: { $0.hubID == hubID && $0.route == route }) {
            Self.logger.notice("relay farewell undeliverable after slot removal")
            host.dropFarewell(hubID)
        }
        store.removePromoted(hubID)
        resumer.forget(hubID)
        _ = await host.removeHub(hubID, keepRecordings: true, farewell: nil)
        removeKeys(hubID)
        refreshLinks()
        return freed
    }

    /// `remove_slot` for the relay Mac `mac`. On failure the removal is kept for a retry at launch
    /// (`keepOnFailure`). True once the slot is free (`Ok` or `NOT_FOUND`).
    private func removeRelaySlot(_ mac: String, keepOnFailure: Bool) async -> Bool {
        do {
            try await relay.removeSlot(mac: mac)
            host?.forgetSlotRemoval(mac)
            return true
        } catch {
            Self.logger.warning("relay slot removal failed: kept for the next launch")
            if keepOnFailure { host?.keepSlotRemoval(mac) }
            return false
        }
    }

    /// At launch, after the kept farewells: each kept slot removal again, unless a local link names that Mac (a
    /// row, a promoted link or a pending one): then the removal is dropped, never sent (it would free that link's
    /// slot). A slot freed leaves its Mac's relay farewell undeliverable: it is dropped.
    func retrySlotRemovals() async {
        guard let host else { return }
        for mac in host.pendingSlotRemovals() {
            if localLinkNames(mac) {
                host.forgetSlotRemoval(mac)
                continue
            }
            guard await removeRelaySlot(mac, keepOnFailure: true) else { continue }
            for farewell in host.pendingFarewells() where farewell.route == .hostedRelay(macDeviceID: mac) {
                Self.logger.notice("relay farewell undeliverable after slot removal")
                host.dropFarewell(farewell.hubID)
            }
        }
    }

    /// A local link record names the relay Mac `mac`: a registry row, a promoted link in any state, or the pending one.
    private func localLinkNames(_ mac: String) -> Bool {
        (host?.linkedHubs() ?? []).contains { $0.link.relayMacDeviceID == mac }
            || store.promoted.values.contains { $0.macDeviceID == mac }
            || store.pending?.link.relayMacDeviceID == mac
    }

    // MARK: - A Mac on Relay over iCloud (R4)

    /// Whether this phone may use the relay: off → no; else the paying check, where only a definite "no" says no.
    private func canUseRelay() async -> Bool {
        guard case .available = relay.availability else { return false }
        let answer = await LinkRoutePolicy.paying { [relay] in try await relay.accountState() }
        switch answer {
        case .success(let paying): return paying
        case .failure: return true
        }
    }

    /// After a fetch of `hubID` found that its hub runs over Relay (a relay marker or `hub_on_relay`): an iCloud
    /// link that never came alive (no heartbeat after its `linkedAt`) on a phone that cannot use Relay ends with
    /// the notice; a link that was alive is kept (the Mac can switch back; Task 11 follows it).
    func hubRunsOnRelay(_ hubID: String) async {
        guard let row = row(hubID), row.state == .linked, row.link.route.cloudKitScope != nil, !ending.contains(hubID) else {
            return
        }
        let linkedAt = row.link.linkedAt ?? .distantPast
        guard row.lastHeartbeatAt.map({ $0 <= linkedAt }) ?? true else { return }
        guard !(await canUseRelay()), self.row(hubID) != nil, !ending.contains(hubID) else { return }
        Self.logger.notice("a never-live iCloud link to a Mac on Relay ended")
        let wipe = await endLink(row, farewell: true, keepRecordings: true)
        notice = LinkNotice.after(wipe, macName: row.link.macName, otherwise: .macOnRelay(macName: row.link.macName))
    }

    // MARK: - The slots screen

    /// Remove on the slots screen (after its confirmation): a Mac linked on this iPhone is unlinked (farewell,
    /// then `remove_slot`); a Mac still finishing its link is cancelled; a Mac not on this iPhone only frees its
    /// slot. After a removal the link goes on: on the link screen with the same code while it is valid, from
    /// Settings → Macs the confirmed link (vouch, promote).
    func removeFromSlots(_ mac: String) async {
        guard relaySlots.removing == nil else { return }
        if relaySlots.pinned[mac] == nil,
           let row = RelaySlotsModel(state: relaySlots, links: links, promoted: promotedLinks).rows.first(where: { $0.id == mac }) {
            relaySlots.pinned[mac] = RelaySlotsModel.Pinned(name: row.name, sub: row.sub, kind: row.kind)
        }
        relaySlots.removing = mac
        relaySlots.failed = nil
        let freed: Bool
        if let row = links.first(where: { $0.link.relayMacDeviceID == mac }) {
            freed = await unlinkRow(row)
        } else if let promoted = store.promoted.values.first(where: { $0.macDeviceID == mac }) {
            freed = await cancelPromoted(promoted.hubID)
        } else {
            freed = await removeRelaySlot(mac, keepOnFailure: false)
        }
        relaySlots.removing = nil
        guard freed else {
            relaySlots.failed = mac
            return
        }
        relaySlots.macs.removeAll { $0 == mac }
        relaySlots.pinned[mac] = nil
        if let hubID = relaySlots.finishing {
            closeSlots()
            await tryAgain(hubID)
        } else if let code = slotsCode {
            slotsCode = nil
            guard !isExpired(code.payload) else {
                phase = .failed(.expired)
                return
            }
            phase = .checking
            linkingHubID = code.payload.hubID
            await connectRelay(code)
            linkingHubID = nil
        }
    }

    /// Settings → Macs → Manage Macs on a `.slotsFull` link: the slots screen with the account's Macs.
    func manageSlots(for hubID: String) async {
        relaySlots = RelaySlotsState(finishing: hubID, loading: true)
        do {
            relaySlots.macs = try await relay.accountState().macs
        } catch {
            Self.logger.notice("relay account state unread for the slots screen")
        }
        relaySlots.loading = false
    }

    /// Leaves the slots screen (its Cancel, or the sheet dismissed).
    func closeSlots() {
        relaySlots = RelaySlotsState()
        slotsCode = nil
        if case .slotsFull = phase { phase = .idle }
    }
}

// MARK: - A confirmed Relay link left in `pending` (relay client Phase 3 Task 10, review round 1)

extension LinkingViewModel {
    enum RelayConfirmation {
        /// Its hub is already in `LinkStore.promoted`.
        case promoted
        /// The keybox's keys are stored: the owner confirmed, the `.confirmed` write did not land.
        case keysArrived
        /// The keys cannot be read now.
        case locked
        /// An iCloud link, or a Relay link still waiting for the owner.
        case notYet
    }

    /// Where a pending link stands before its deadline is looked at.
    private func relayConfirmation(of pending: PendingLink) -> RelayConfirmation {
        if store.promoted[pending.link.hubID] != nil { return .promoted }
        guard pending.relaySlot != nil else { return .notYet }
        do {
            return try keys.hubLink(pending.link.hubID)?.epochs.isEmpty == false ? .keysArrived : .notYet
        } catch KeyStoreError.locked {
            return .locked
        } catch {
            return .notYet
        }
    }

    /// The `.confirmed` write again, at launch, whatever the time: the link's `linkedAt` is the grant's, kept in the
    /// pending link before the keys; one an older build saved without it falls back to the code's issue time.
    private func confirmPendingRelay(_ pending: PendingLink) async {
        guard let slot = pending.relaySlot else { return }
        var record = pending.link
        record.linkedAt = pending.linkedAt ?? pending.issuedAt
        phase = .checking
        await confirmRelay(pending, record: record, slot: slot)
    }
}

extension LinkingViewModel {
    /// The failure screen's Try Again: the same code once more (its expiry checked again).
    func retryFailedCode() async {
        guard case .failed = phase, let url = retryCode else { return }
        retryCode = nil
        phase = .idle
        await open(url)
    }
}

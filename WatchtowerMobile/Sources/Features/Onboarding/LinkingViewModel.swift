import Foundation
import Observation
import os
import WatchtowerSync

/// The link flow (mobile POC spec §2.3 steps 1–5) and each link's life
/// after it (§9; multi-hub spec §5.7, §6: unlink, forget, removed by the
/// Mac, stale, iCloud account switch), one hub at a time: a scan adds a hub
/// (up to `HubRegistry.limit`), never replaces one. Owned by `AppRoot` for
/// the app's lifetime, so a wait survives any navigation; a kill mid-wait
/// is resumed from `LinkStore.pending`.
@MainActor
@Observable
final class LinkingViewModel {
    enum Phase: Equatable {
        case idle
        /// The camera is open.
        case scanning
        /// Steps 1–4: checking the code and iCloud, accepting, writing.
        case checking
        /// Step 5: the device record is written; waiting for the grant.
        case waiting(macName: String)
        /// An unlink or a Forget is running.
        case unlinking
        case failed(LinkFailure)
        /// "Linked to <Mac name>", until the owner continues.
        case linked(macName: String)
    }

    /// Step 1's grace for the phone's clock: the code is refused locally
    /// only when `exp < now − 120 s`; the Mac's own check decides the rest.
    static let expiryGrace: TimeInterval = 120
    /// Step 5 (spec §3).
    static let grantWait: TimeInterval = 60
    /// How often the wait fetches the grant: each poll is a CloudKit fetch,
    /// so 4 s keeps a full wait at 15 of them.
    static let grantPollInterval: TimeInterval = 4
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
    /// The saved links, in registry order, as the host last reported them
    /// (refreshed after every change); empty while unlinked (Welcome). A
    /// pending link is not a link.
    private(set) var links: [HubRow] = []

    /// Set by the owner right after init (it owns this model).
    @ObservationIgnored weak var host: (any LinkHost)? {
        didSet { refreshLinks() }
    }
    @ObservationIgnored private let container: any LinkContainer
    @ObservationIgnored private let store: LinkStore
    @ObservationIgnored private let identity: DeviceIdentity
    @ObservationIgnored private let clock: any LinkClock
    /// Hubs whose link is ending (an unlink, a removal, the account
    /// switch): a removal or an account signal arriving meanwhile is the
    /// ending's own, and is ignored.
    @ObservationIgnored private var ending: Set<String> = []
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkingViewModel")

    init(container: any LinkContainer, store: LinkStore, identity: DeviceIdentity, clock: any LinkClock = SystemLinkClock()) {
        self.container = container
        self.store = store
        self.identity = identity
        self.clock = clock
    }

    /// The phone has at least one saved link (the tabs, not Welcome).
    var hasLinks: Bool { !links.isEmpty }

    /// This phone as `hubID`'s saved link describes it.
    func linkedDevice(for hubID: String) -> LinkedDevice? {
        links.first { $0.hubID == hubID }.map { identity.linkedDevice(for: $0.link) }
    }

    /// Reads the saved links again from the host.
    func refreshLinks() {
        links = host?.linkedHubs() ?? []
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
        case .removed, .notSent, .recordingKept, .recordingsProblem: notice = nil
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
        // Step 1: only a code clearly past its expiry on this clock.
        if Double(payload.exp) < clock.now().timeIntervalSince1970 - Self.expiryGrace {
            phase = .failed(.expired)
            return
        }
        phase = .checking
        refreshLinks()
        if let row = links.first(where: { $0.hubID == payload.hubID }), row.state == .linked, await isGranted(row.link) {
            // Already linked to this Mac: nothing to write.
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
        await connect(payload, userRecordName: userRecordName)
    }

    /// "Linked to <Mac name>" → the notification prompt → Now.
    func finish() async {
        guard case .linked = phase else { return }
        phase = .idle
        await host?.requestNotificationPermission()
        host?.openNow()
    }

    /// Steps 3–5 for a valid code.
    private func connect(_ payload: LinkPayload, userRecordName: String) async {
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
        guard let host else { return }
        // From the accept on, a kill is resumed (the scope's database, the
        // rest of the wait), never shown as linked. No baseline yet: a
        // relaunch before it is captured has written nothing to the Mac.
        let deadline = clock.now().addingTimeInterval(Self.grantWait)
        store.pending = PendingLink(link: record, deadline: deadline, baseline: nil, baselineCaptured: false)
        // Step 4: the device record with the code's nonce, in the scope's
        // database.
        let transport: any CloudSyncTransport
        do {
            transport = try await host.prepare(scope: scope, hubID: record.hubID)
        } catch is CancellationError {
            // Torn down mid-prepare: the pending link stays for the relaunch.
            return
        } catch {
            await fail(.local(error.localizedDescription), hubID: record.hubID)
            return
        }
        let baseline = await host.fetchGrant(hubID: record.hubID, deviceID: identity.deviceID)
        let pending = PendingLink(link: record, deadline: deadline, baseline: baseline, baselineCaptured: true)
        store.pending = pending
        do {
            // The transport queues the record locally; CloudKit sends it
            // later, so a throw here is this iPhone's store.
            let device = identity.linkedDevice(for: record)
            try await transport.save([try deviceRecord(hubID: record.hubID, for: device, linkNonce: payload.nonce)])
        } catch {
            await fail(.local(error.localizedDescription), hubID: record.hubID)
            return
        }
        await waitForGrant(pending)
    }

    /// A link that did not complete: nothing to resume, and a hub that has
    /// no row yet (a first link) leaves no session or directory behind.
    private func fail(_ failure: LinkFailure, hubID: String) async {
        store.pending = nil
        if row(hubID) == nil, let host {
            let dropped = await host.removeHub(hubID, keepRecordings: true, farewell: nil)
            if let problem = dropped.problem {
                Self.logger.error("recordings of a failed link: \(problem, privacy: .public)")
            }
        }
        phase = .failed(failure)
    }

    // MARK: - Grant wait (step 5)

    /// At launch: a link written before a kill and not answered yet waits
    /// for what is left of its 60 s, then offers to scan again. A link
    /// killed before its baseline was captured wrote nothing to the Mac
    /// (the device record follows the baseline), and without the baseline
    /// an earlier answer in the replica (a refusal of another code) would
    /// read as this scan's: it offers to scan again at once.
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
        phase = .checking
        do {
            _ = try await host?.prepare(scope: pending.link.databaseScope, hubID: pending.link.hubID)
        } catch {
            await fail(.local(error.localizedDescription), hubID: pending.link.hubID)
            return
        }
        await waitForGrant(pending)
    }

    /// Fetches the grant until the deadline. A grant for this hub that
    /// differs from the baseline is the Mac's answer: `link_refused` (any
    /// code, even one this build does not know) refuses, `linked` links. A
    /// cancelled wait (the app killed) leaves the pending link to resume.
    private func waitForGrant(_ pending: PendingLink) async {
        phase = .waiting(macName: pending.link.macName)
        while true {
            if let grant = await host?.fetchGrant(hubID: pending.link.hubID, deviceID: identity.deviceID),
               grant != pending.baseline, grant.hubID == pending.link.hubID {
                if grant.linkRefused != nil {
                    await fail(.refused, hubID: pending.link.hubID)
                    return
                }
                if grant.linked {
                    var linked = pending.link
                    linked.linkedAt = grant.linkedAt
                    await complete(linked)
                    return
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
        await fail(.noAnswer, hubID: pending.link.hubID)
    }

    /// The Mac granted the link: the host saves the row and puts the hub on
    /// screen. A fifth hub that raced past the scan's check is refused.
    private func complete(_ record: LinkRecord) async {
        guard let host else { return }
        do {
            try await host.linked(record, device: identity.linkedDevice(for: record))
        } catch HubRegistryError.full {
            await fail(.tooManyMacs, hubID: record.hubID)
            return
        } catch {
            Self.logger.error("link not saved: \(error.localizedDescription, privacy: .public)")
            await fail(.local(error.localizedDescription), hubID: record.hubID)
            return
        }
        store.pending = nil
        refreshLinks()
        // A notice about another link's state no longer applies; a report of
        // what an unlink lost ("Not sent", a recording kept) stays.
        switch notice {
        case .notSent, .recordingKept, .recordingsProblem: break
        default: notice = nil
        }
        phase = .linked(macName: record.macName)
    }

    /// The replica of `link`'s hub holds a linked grant of that hub.
    private func isGranted(_ link: LinkRecord) async -> Bool {
        guard let grant = await host?.fetchGrant(hubID: link.hubID, deviceID: identity.deviceID) else { return false }
        return grant.hubID == link.hubID && grant.linked && grant.linkRefused == nil
    }

    // MARK: - Unlink and the link's events (spec §9, multi-hub §6)

    /// Settings → Macs: reorders the Macs (the host saves it and the order
    /// follows on screen).
    func moveHub(_ hubID: String, to index: Int) {
        host?.moveHub(hubID, to: index)
    }

    /// Settings → Macs → Unlink: the hub's files and row go, then its Mac
    /// hears `unlinked`, then a shared link leaves the shares.
    func unlink(_ hubID: String) async {
        guard !isBusy, let row = row(hubID), !ending.contains(hubID) else { return }
        phase = .unlinking
        notice = LinkNotice.after(await unlinkHub(row))
        phase = .idle
    }

    /// Settings → Macs → Forget: a hub the Mac removed goes with no farewell
    /// and no share leave (its zones are gone); a long-offline linked one is
    /// unlinked.
    func forget(_ hubID: String) async {
        guard !isBusy, let row = row(hubID), !ending.contains(hubID) else { return }
        guard row.state == .unlinkedByMac, let host else {
            await unlink(hubID)
            return
        }
        phase = .unlinking
        ending.insert(hubID)
        let wipe = await host.removeHub(hubID, keepRecordings: true, farewell: nil)
        ending.remove(hubID)
        refreshLinks()
        notice = LinkNotice.after(wipe)
        phase = .idle
    }

    /// `TransportEvent.unlinked` for `hubID`: its zones are gone (the phone
    /// was removed, maybe while offline); or that Mac deleted this phone's
    /// grant (`evaluate(hubID:grant:heartbeat:)`). The hub freezes, its data
    /// readable until Forget; nothing is wiped and other hubs are untouched.
    func removedByMac(_ hubID: String) async {
        guard let row = row(hubID), row.state == .linked, !ending.contains(hubID), let host else { return }
        ending.insert(hubID)
        await host.markRemovedByMac(hubID)
        ending.remove(hubID)
        refreshLinks()
        notice = .removed(macName: row.link.macName)
    }

    /// The transport saw an iCloud account change. Another account ends
    /// every link and removes every hub; a sign-out keeps them until an
    /// account is back (spec §9, multi-hub §6.2).
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
    /// hub's replica. The Mac's Remove deletes it (`DeviceGrantSlice`
    /// publishes no record for a removed phone), and for a same-Apple-ID
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
        let stale = clock.now().timeIntervalSince(heartbeat.updatedAt) >= Self.staleAfter
        switch notice {
        case .stale, nil:
            notice = stale ? .stale : nil
        case .removed, .notSent, .recordingKept, .recordingsProblem:
            break
        }
    }

    /// Ends `row`'s link: the host removes the hub (its row first, then the
    /// `unlinked` record through the hub's own transport, which holds the
    /// record's server state, best effort and bounded; then its session,
    /// recordings and files), then a `shared` link leaves the shares. The
    /// record is built here, before the hub's Settings choices go. A frozen
    /// hub's zones are gone: no farewell, no leave.
    private func unlinkHub(_ row: HubRow) async -> LocalWipe {
        guard let host else { return LocalWipe() }
        let hubID = row.hubID
        ending.insert(hubID)
        defer { ending.remove(hubID) }
        let linked = row.state == .linked
        let scope = row.link.databaseScope
        var farewell: CloudRecord?
        if linked {
            do {
                farewell = try deviceRecord(hubID: hubID, for: identity.linkedDevice(for: row.link), linkNonce: nil, unlinked: true)
            } catch {
                Self.logger.warning("unlinked record not built: \(error.localizedDescription, privacy: .public)")
            }
        }
        let wipe = await host.removeHub(hubID, keepRecordings: true, farewell: farewell)
        refreshLinks()
        if linked, case let .shared(ownerName) = scope {
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

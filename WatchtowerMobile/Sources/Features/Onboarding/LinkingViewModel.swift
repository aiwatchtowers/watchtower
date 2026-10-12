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
        /// Step 5: the device record is written; waiting for the grant.
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
    static let expiryGrace: TimeInterval = 120
    /// Step 5 (spec §3).
    static let grantWait: TimeInterval = 60
    /// How often the wait fetches the grant.
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
    /// The saved link; nil while unlinked (Welcome). A pending link is not
    /// a link.
    private(set) var link: LinkRecord?

    /// Set by the owner right after init (it owns this model).
    @ObservationIgnored weak var host: (any LinkHost)?
    @ObservationIgnored private let container: any LinkContainer
    @ObservationIgnored private let store: LinkStore
    @ObservationIgnored private let identity: DeviceIdentity
    @ObservationIgnored private let clock: any LinkClock
    /// The scanned code a switch prompt is about, with this phone's user.
    @ObservationIgnored private var pendingSwitch: (payload: LinkPayload, userRecordName: String)?
    /// The moved notice took the writes away; a heartbeat of the linked hub
    /// gives them back.
    @ObservationIgnored private var writesBlocked = false
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkingViewModel")

    init(container: any LinkContainer, store: LinkStore, identity: DeviceIdentity, clock: any LinkClock = SystemLinkClock()) {
        self.container = container
        self.store = store
        self.identity = identity
        self.clock = clock
        link = store.link
    }

    /// This phone as the saved link describes it.
    var linkedDevice: LinkedDevice? {
        link.map(identity.linkedDevice(for:))
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
        case .removed, .notSent: notice = nil
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
            pendingSwitch = (payload, userRecordName)
            phase = .confirmSwitch(from: link.macName, to: payload.macName)
            return
        }
        await connect(payload, userRecordName: userRecordName)
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
        let notSent = await unlinkCurrent(writeUnlinked: true)
        notice = notSent > 0 ? .notSent(notSent) : nil
        await connect(request.payload, userRecordName: request.userRecordName)
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
            relayShareURL: shared ? payload.relayShare : nil
        )
        guard let host else { return }
        // From the accept on, a kill is resumed (the scope's database, the
        // rest of the wait), never shown as linked.
        let deadline = clock.now().addingTimeInterval(Self.grantWait)
        store.pending = PendingLink(link: record, deadline: deadline, baseline: nil)
        // Step 4: the device record with the code's nonce, in the scope's
        // database.
        let transport: any CloudSyncTransport
        do {
            transport = try await host.prepare(scope: scope, hubID: record.hubID)
        } catch is CancellationError {
            // Torn down mid-restart: the pending link stays for the relaunch.
            return
        } catch {
            store.pending = nil
            phase = .failed(.iCloud(error.localizedDescription))
            return
        }
        let baseline = await host.fetchGrant(deviceID: identity.deviceID)
        let pending = PendingLink(link: record, deadline: deadline, baseline: baseline)
        store.pending = pending
        do {
            try await transport.save([try deviceRecord(for: identity.linkedDevice(for: record), linkNonce: payload.nonce)])
        } catch {
            store.pending = nil
            phase = .failed(.iCloud(error.localizedDescription))
            return
        }
        await waitForGrant(pending)
    }

    // MARK: - Grant wait (step 5)

    /// At launch: a link written before a kill and not answered yet waits
    /// for what is left of its 60 s, then offers to scan again.
    func resumePendingLink() async {
        guard let pending = store.pending, !isBusy else { return }
        guard clock.now() < pending.deadline else {
            store.pending = nil
            phase = .failed(.noAnswer)
            return
        }
        phase = .checking
        do {
            _ = try await host?.prepare(scope: pending.link.databaseScope, hubID: pending.link.hubID)
        } catch {
            store.pending = nil
            phase = .failed(.iCloud(error.localizedDescription))
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
            if let grant = await host?.fetchGrant(deviceID: identity.deviceID),
               grant != pending.baseline, grant.hubID == pending.link.hubID {
                if grant.linkRefused != nil {
                    store.pending = nil
                    phase = .failed(.refused)
                    return
                }
                if grant.linked {
                    await complete(pending.link)
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
        store.pending = nil
        phase = .failed(.noAnswer)
    }

    private func complete(_ record: LinkRecord) async {
        store.link = record
        store.pending = nil
        link = record
        writesBlocked = false
        // A notice about an old link no longer applies; the "Not sent"
        // report of a switch's unlink stays.
        if case .notSent = notice {} else { notice = nil }
        await host?.setLink(identity.linkedDevice(for: record), writesAllowed: true)
        phase = .linked(macName: record.macName)
    }

    /// The replica holds a linked grant of this link's hub.
    private func isGranted(_ link: LinkRecord) async -> Bool {
        guard let grant = await host?.fetchGrant(deviceID: identity.deviceID) else { return false }
        return grant.hubID == link.hubID && grant.linked && grant.linkRefused == nil
    }

    // MARK: - Unlink and the link's events (spec §9)

    /// Settings → Unlink this Mac.
    func unlink() async {
        guard link != nil, !isBusy else { return }
        phase = .unlinking
        let notSent = await unlinkCurrent(writeUnlinked: true)
        notice = notSent > 0 ? .notSent(notSent) : nil
        phase = .idle
    }

    /// `TransportEvent.unlinked`: the Mac's zones are gone (the phone was
    /// removed, maybe while offline).
    func removedByMac() async {
        guard link != nil else { return }
        _ = await unlinkCurrent(writeUnlinked: false)
        pendingSwitch = nil
        if !isBusy { phase = .idle }
        notice = .removed
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
        _ = await unlinkCurrent(writeUnlinked: false)
        pendingSwitch = nil
        phase = .idle
        notice = nil
    }

    /// After each fetch: the heartbeat names another hub (moved: writes
    /// stop), or none came for a day (stale).
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
        case .removed, .notSent:
            break
        }
    }

    /// Ends the current link: the `unlinked` record (best effort), leaving
    /// the shares in `shared` scope, then the wipe. Returns what was not
    /// sent.
    ///
    /// The link ends before the first await: a removal or an account signal
    /// arriving meanwhile (leaving the shares is what makes the Mac's zones
    /// vanish) finds no link and is ignored, so one unlink wipes once.
    /// The wipe runs first, in the link's own database: the restarted send
    /// queue then holds only the `unlinked` record, so the flush sends
    /// nothing of what is reported "Not sent".
    private func unlinkCurrent(writeUnlinked: Bool) async -> Int {
        guard let current = link, let host else { return 0 }
        let device = linkedDevice
        store.link = nil
        link = nil
        writesBlocked = false
        await host.setLink(nil, writesAllowed: true)
        guard writeUnlinked, let device else {
            return await host.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)
        }
        let scope = current.databaseScope
        let notSent = await host.wipeLocalData(restartingOn: scope, hubID: current.hubID)
        do {
            let transport = try await host.prepare(scope: scope, hubID: current.hubID)
            try await transport.save([try deviceRecord(for: device, linkNonce: nil, unlinked: true)])
            await host.flushSends()
        } catch {
            Self.logger.warning("unlinked record not written: \(error.localizedDescription, privacy: .public)")
        }
        if case let .shared(ownerName) = scope {
            do {
                try await container.leaveShares(ownerName: ownerName, hubID: current.hubID)
            } catch {
                Self.logger.warning("leaving the shares failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Both scopes end unlinked, on the phone's own database: the linked
        // hub's zones are no longer synced. Nothing is left to count.
        _ = await host.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)
        return notSent
    }

    private func deviceRecord(for device: LinkedDevice, linkNonce: String?, unlinked: Bool = false) throws -> CloudRecord {
        guard let host else { throw CancellationError() }
        let payload = host.devicePayload(for: device, linkNonce: linkNonce, unlinked: unlinked, now: clock.now())
        return try CloudRecordFactory.record(for: payload, modifiedAt: payload.updatedAt)
    }
}

import Foundation
import os
import WatchtowerCore
import WatchtowerSync

/// The transport surface the hub needs beyond record I/O: lifecycle,
/// availability probing and the two reset callbacks. CloudKitTransport
/// satisfies it natively; tests use a stub over InMemoryCloudTransport.
protocol HubTransport: CloudSyncTransport, Sendable {
    func start() async
    func pull() async throws
    func availability() async -> CloudAvailability
    /// Stops syncing until the next `start()` (the hub was turned off).
    func stop() async
    /// Sends the pending queue at once (the fast lane, spec §4.5); a no-op
    /// while stopped, unlinked, paused or throttled.
    func sendNow() async
    /// Set the reset callback before `start()`: an account change, or (private
    /// scope) the server deleting DataZone — either way nothing published survives.
    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async
    /// A record CloudKit rejects even alone (`.limitExceeded`, spec §9).
    func setRecordRejectedHandler(_ handler: (@Sendable (_ recordName: String, _ zone: CloudZoneID) -> Void)?) async
}

extension CloudKitTransport: HubTransport {}

/// Background work that runs only while the hub publishes (a slice's
/// refresher): started with the publisher, stopped with the hub. It never
/// touches the relay processor.
protocol HubCompanion: AnyObject, Sendable {
    func start()
    func stop()
}

/// The process-wide part of the hub: one transport and one sidecar over the
/// files in the hub directory. Built once per app run and kept across hub
/// rebuilds, so two CKSyncEngines never drive one `transport.db`.
struct MobileHubStorage {
    let transport: any HubTransport
    let sidecar: HubSyncState
    /// The iCloud user record name for the heartbeat's `owner_user`. Kept
    /// with the transport, so a stub storage never reaches CloudKit.
    var ownerUser: @Sendable () async -> String? = { nil }
    /// The staged CKAsset files of asset-backed slices (`SliceAssets/` in
    /// the hub directory); nil in a stub storage.
    var sliceAssets: SliceAssetStore?

    /// `~/Library/Application Support/Watchtower/MobileHub/` (spec §3).
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower/MobileHub", isDirectory: true)
    }

    /// The real storage: `transport.db` behind a private-scope
    /// CloudKitTransport, and `hubstate.db`.
    static func live() throws -> Self {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try TransportStore(path: dir.appendingPathComponent("transport.db").path)
        let sidecar = try HubSyncState(path: dir.appendingPathComponent("hubstate.db").path)
        return Self(
            transport: CloudKitTransport(store: store), sidecar: sidecar, ownerUser: HubHostInfo.iCloudUserRecordName,
            sliceAssets: SliceAssetStore(directory: dir.appendingPathComponent("SliceAssets", isDirectory: true))
        )
    }
}

enum HubStatus: Equatable {
    case off
    case starting
    case running
    /// CloudKit can't be used (no entitlement on unsigned dev builds, no
    /// iCloud account, …): expected and harmless; no loops run.
    case unavailable(String)
    /// Enabling was refused: the named Mac's heartbeat is under 720 s old
    /// (spec §8 I-1). Settings shows "<mac_name> is your hub. Turn it off
    /// there, or Take over".
    case otherHub(String)
    /// The named Mac took over while this hub ran, so this one stopped.
    /// Settings shows "Another Mac took over".
    case tookOver(String)
}

/// Composition root of the mobile hub (spec §6.1): owns the slice publisher
/// loop and the adaptive relay loop. Opt-in: AppState builds it only while
/// `mobileSyncEnabled` is on. All intervals are injectable for tests.
@MainActor
@Observable
final class MobileHubService {
    nonisolated static let defaultRelayIdleInterval: Duration = .seconds(30)
    nonisolated static let defaultRelayActiveInterval: Duration = .seconds(3)
    /// A phone action seen this recently keeps the fast relay cadence.
    nonisolated static let activityWindow: TimeInterval = 300
    /// The heartbeat is rewritten this often (spec §3).
    nonisolated static let heartbeatInterval: Duration = .seconds(300)
    /// Bound on each CloudKit wait the heartbeat adds: the pull before the
    /// single-hub check and the iCloud user lookup.
    nonisolated static let defaultCloudTimeout: Duration = .seconds(30)
    /// Heartbeat ticks failing in a row before the hub stops (3 × 300 s
    /// outlasts the 720 s the phone waits before it shows the Mac offline).
    nonisolated static let maxTickFailures = 3

    private(set) var status: HubStatus = .off
    /// The heartbeat's `sharing` field; the link center sets it once the
    /// zone shares exist.
    @ObservationIgnored var sharing: HubSharing = .none
    /// Runs after a successful `takeOver()` (the seam for the share
    /// teardown of spec §2.3, wired with the zone shares).
    @ObservationIgnored var onTakeOver: (@MainActor () async -> Void)?
    /// The end of the last relay cycle that ran without an error.
    @ObservationIgnored private(set) var lastRelayAt: Date?

    @ObservationIgnored private let transport: any HubTransport
    @ObservationIgnored private let publisher: SlicePublisher
    @ObservationIgnored private let companions: [any HubCompanion]
    @ObservationIgnored private let processor: RelayProcessor
    @ObservationIgnored private let sidecar: HubSyncState
    @ObservationIgnored private let identity: HubIdentity
    @ObservationIgnored private let hostInfo: HubHostInfo
    @ObservationIgnored private let heartbeatEvery: Duration
    @ObservationIgnored private let cloudTimeout: Duration
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// The iCloud user record name, once looked up.
    @ObservationIgnored private var ownerUser: String?
    /// Heartbeat ticks failed in a row; reset by a good tick and a start.
    @ObservationIgnored private var tickFailures = 0
    @ObservationIgnored private let relayIdleInterval: Duration
    @ObservationIgnored private let relayActiveInterval: Duration
    @ObservationIgnored private let availabilityReprobeInterval: Duration
    /// Whether mobile sync is enabled — injected by AppState (the defaults
    /// read lives there), so the service itself has no settings dependency.
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var relayTask: Task<Void, Never>?
    /// Runs only while `.unavailable`: re-probes iCloud and starts the hub
    /// when it comes back.
    @ObservationIgnored private var reprobeTask: Task<Void, Never>?
    /// Bumped by stop() so a start() suspended before it detects it lost.
    @ObservationIgnored private var epoch = 0
    /// What the last stop() left running: the cancelled relay loop (its
    /// pass ends between two records) and the transport stop. start()
    /// awaits it, so two relay passes never overlap.
    @ObservationIgnored private var teardown: Task<Void, Never>?
    /// Set by dispose(): a replaced hub never starts again, even from a
    /// start() queued before it was replaced.
    @ObservationIgnored private var disposed = false
    @ObservationIgnored private let logger = Logger(subsystem: Constants.bundleID, category: "MobileHubService")

    init(
        transport: any HubTransport,
        publisher: SlicePublisher,
        processor: RelayProcessor,
        sidecar: HubSyncState,
        hostInfo: HubHostInfo,
        companions: [any HubCompanion] = [],
        relayIdleInterval: Duration = MobileHubService.defaultRelayIdleInterval,
        relayActiveInterval: Duration = MobileHubService.defaultRelayActiveInterval,
        availabilityReprobeInterval: Duration = .seconds(600),
        heartbeatInterval: Duration = MobileHubService.heartbeatInterval,
        cloudTimeout: Duration = MobileHubService.defaultCloudTimeout,
        now: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping () -> Bool
    ) {
        self.transport = transport
        self.publisher = publisher
        self.companions = companions
        self.processor = processor
        self.sidecar = sidecar
        self.identity = HubIdentity(sidecar: sidecar)
        self.hostInfo = hostInfo
        self.heartbeatEvery = heartbeatInterval
        self.cloudTimeout = cloudTimeout
        self.relayIdleInterval = relayIdleInterval
        self.relayActiveInterval = relayActiveInterval
        self.availabilityReprobeInterval = availabilityReprobeInterval
        self.now = now
        self.isEnabled = isEnabled
    }

    var isPublishing: Bool { publisher.isRunning }
    var relayBacklog: Int { processor.relayBacklog }

    /// Asks the publisher's fast lane for `kinds` (B and C call this on a
    /// change they know of).
    func nudge(kinds: Set<SliceKind>) {
        publisher.nudge(kinds: kinds)
    }

    /// Turns the hub on and reports where it landed: `.running`, or
    /// `.otherHub` when another Mac's heartbeat is live (spec §8 I-1).
    @discardableResult
    func enable() async -> HubStatus {
        await start()
        return status
    }

    /// Enables over a live foreign heartbeat: writes this hub's heartbeat,
    /// so the other hub stops at its next read.
    @discardableResult
    func takeOver() async -> HubStatus {
        await start(takingOver: true)
        if status == .running, let onTakeOver {
            await onTakeOver()
        }
        return status
    }

    /// Starts the transport, gates on availability and the single-hub rule,
    /// then spins up the loops. Safe to call again after `.unavailable`,
    /// `.otherHub`, `.tookOver` or `stop()`.
    func start() async {
        await start(takingOver: false)
    }

    private func start(takingOver: Bool) async {
        guard !disposed, isEnabled() else { return }
        guard status != .running, status != .starting else { return }
        status = .starting
        let startEpoch = epoch
        await teardown?.value
        guard status == .starting, epoch == startEpoch else { return }
        await installTransportHandlers()
        // stop() may have run during the install: never start the
        // transport it already stopped.
        guard status == .starting, epoch == startEpoch else { return }
        await transport.start()
        let availability = await transport.availability()
        // stop() may have run while we awaited above.
        guard status == .starting, epoch == startEpoch else { return }
        guard case .available = availability else {
            status = .unavailable(Self.describe(availability))
            startReprobeLoop()
            return
        }
        reprobeTask?.cancel()
        reprobeTask = nil
        switch await claimHub(takingOver: takingOver, startEpoch: startEpoch) {
        case nil:
            return
        case .refused(let macName):
            stop()
            status = .otherHub(macName)
            return
        case .failed(let message):
            status = .unavailable(message)
            startReprobeLoop()
            return
        case .claimed:
            break
        }
        tickFailures = 0
        publisher.start()
        companions.forEach { $0.start() }
        startRelayLoop()
        startHeartbeatLoop()
        status = .running
    }

    /// Registered BEFORE `transport.start()`, so an account change seen
    /// during startup still wipes the derived sync state. The same handler
    /// covers a server-side DataZone deletion (`.encryptedDataReset`, the
    /// owner deleting iCloud data): the recreated zone gets every record again.
    private func installTransportHandlers() async {
        let sidecar = self.sidecar
        let publisher = self.publisher
        let logger = self.logger
        let now = self.now
        await transport.setAccountResetHandler {
            do {
                try sidecar.wipeSyncState(now: now())
            } catch {
                logger.error("account reset: wipeSyncState failed: \(error.localizedDescription, privacy: .public)")
            }
            // The new account's zone gets every record again, restaged.
            publisher.removeStagedAssets()
        }
        await transport.setRecordRejectedHandler { recordName, zone in
            guard zone == .data else { return }
            publisher.recordRejected(recordName)
        }
    }

    func stop() {
        publisher.stop()
        companions.forEach { $0.stop() }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reprobeTask?.cancel()
        reprobeTask = nil
        let relay = relayTask
        relayTask = nil
        relay?.cancel()
        let previous = teardown
        let transport = self.transport
        // The transport stops first, so a hung CloudKit fetch in the
        // cancelled cycle is cancelled rather than awaited; the pass then
        // ends after the record it is applying (its echo waits in the store).
        teardown = Task {
            await previous?.value
            await transport.stop()
            await relay?.value
        }
        epoch &+= 1
        status = .off
    }

    /// The Settings toggle turned off: stops, and removes the staged slice
    /// assets (restaged and republished at the next start).
    func disable() {
        stop()
        publisher.closeStagedAssets()
    }

    /// Terminal stop for a hub being replaced (an `initWorkbenches` re-run).
    func dispose() {
        disposed = true
        stop()
    }

    /// Returns once the last stop() has drained (relay pass ended,
    /// transport stopped).
    func waitUntilStopped() async {
        await teardown?.value
    }

    // MARK: - Loops

    private func startRelayLoop() {
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.runRelayCycle()
                try? await Task.sleep(for: self.relayInterval())
            }
        }
    }

    /// One relay cycle: pull, daily hygiene, then passes until the backlog
    /// is empty — a long Mac sleep drains in one cycle (Review focus 5).
    private func runRelayCycle() async {
        do {
            try await transport.pull()
            try await processor.runHygieneIfDue()
            var pass = try await processor.processOnce()
            while pass.remaining > 0, !Task.isCancelled {
                pass = try await processor.processOnce()
            }
            lastRelayAt = now()
        } catch is CancellationError {
            return
        } catch {
            logger.error("relay cycle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 3 s while a phone action was seen in the last 300 s, otherwise 30 s.
    private func relayInterval() -> Duration {
        if let last = processor.lastActivityAt, now().timeIntervalSince(last) < Self.activityWindow {
            return relayActiveInterval
        }
        return relayIdleInterval
    }

    // MARK: - Heartbeat and the single-hub rule (spec §4.1, §8 I-1)

    private enum Claim {
        case claimed
        case refused(macName: String)
        case failed(String)
    }

    /// Pulls (bounded), reads the heartbeat and, unless another hub's is
    /// live, writes this hub's. `takingOver` skips the refusal. nil: a
    /// stop() ran meanwhile.
    private func claimHub(takingOver: Bool, startEpoch: Int) async -> Claim? {
        let transport = self.transport
        let logger = self.logger
        let pulled = await Self.bounded(cloudTimeout) { () -> Bool in
            do {
                try await transport.pull()
                return true
            } catch {
                logger.warning("heartbeat pull failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard status == .starting, epoch == startEpoch else { return nil }
        do {
            // A pull that failed or timed out leaves a buffer that proves
            // nothing: empty, or as old as the last fetch that got through,
            // so a live hub's newer heartbeat may be missing from it.
            // Claiming on it would silently take over that hub (spec §8 I-1).
            // Only the owner's explicit Take over goes ahead without it.
            if pulled != true, !takingOver {
                let why = pulled == nil ? "iCloud didn't answer in time" : "iCloud fetch failed"
                logger.warning("single-hub check deferred: \(why, privacy: .public)")
                return .failed("Couldn't check which Mac is the hub: \(why)")
            }
            if pulled != true { logger.warning("heartbeat pull did not complete; taking over on the buffered heartbeat") }
            let hubID = try identity.hubID()
            let latest = try await identity.readHeartbeat(from: transport)
            if !takingOver, let latest, HubIdentity.isLiveForeign(latest, hubID: hubID, now: now()) {
                return .refused(macName: latest.macName)
            }
            await resolveOwnerUser()
            guard status == .starting, epoch == startEpoch else { return nil }
            try await writeHeartbeat(hubID: hubID, after: latest)
            return .claimed
        } catch {
            logger.error("single-hub check failed: \(error.localizedDescription, privacy: .public)")
            return .failed("Couldn't check which Mac is the hub: \(error.localizedDescription)")
        }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, interval = heartbeatEvery] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.heartbeatTick()
            }
        }
    }

    /// One heartbeat tick: read the record first. When the newest
    /// heartbeat known is another hub's, live, and later than this hub's
    /// own last write, that hub took over: this one stops (`.tookOver`).
    /// Otherwise this hub's heartbeat is rewritten. Reads only the local
    /// buffer the relay loop's pulls fill. `maxTickFailures` failures in a
    /// row stop the hub as `.unavailable` (it could no longer see a take
    /// over), and the reprobe loop restarts it through the full check.
    func heartbeatTick() async {
        guard status == .running else { return }
        let tickEpoch = epoch
        do {
            let hubID = try identity.hubID()
            let latest = try await identity.readHeartbeat(from: transport)
            guard status == .running, epoch == tickEpoch else { return }
            if let latest, HubIdentity.isLiveForeign(latest, hubID: hubID, now: now()) {
                logger.notice("another Mac took over the hub; stopping")
                stop()
                status = .tookOver(latest.macName)
                return
            }
            await resolveOwnerUser()
            guard status == .running, epoch == tickEpoch else { return }
            try await writeHeartbeat(hubID: hubID, after: latest)
            tickFailures = 0
        } catch {
            guard status == .running, epoch == tickEpoch else { return }
            tickFailures += 1
            // Logged on the first and the last failure of a run, not on every tick.
            if tickFailures == 1 || tickFailures >= Self.maxTickFailures {
                logger.error(
                    "heartbeat tick failed (\(self.tickFailures, privacy: .public) in a row): \(error.localizedDescription, privacy: .public)"
                )
            }
            guard tickFailures >= Self.maxTickFailures else { return }
            stop()
            status = .unavailable("Couldn't check which Mac is the hub: \(error.localizedDescription)")
            startReprobeLoop()
        }
    }

    /// Stamped `max(now, newest heartbeat known + 1 s)`: a take over must
    /// read as the later write on the old hub even when this Mac's clock
    /// runs behind it, and every later write keeps that order (the newest
    /// known is then this hub's own), so clock skew cannot hand the hub back.
    private func writeHeartbeat(hubID: String, after latest: HeartbeatPayload?) async throws {
        let at = max(now(), latest.map { $0.updatedAt.addingTimeInterval(1) } ?? .distantPast)
        let heartbeat = HeartbeatPayload(
            updatedAt: at,
            appVersion: hostInfo.appVersion,
            hubID: hubID,
            macName: hostInfo.macName,
            flavor: hostInfo.flavor,
            lastPublishAt: publisher.lastPublishAt,
            lastRelayAt: lastRelayAt,
            relayBacklog: processor.relayBacklog,
            accounts: Array(hostInfo.accounts().prefix(HeartbeatPayload.maxAccounts)),
            enabledAt: try identity.ensureEnabledAt(at),
            ownerUser: ownerUser ?? "",
            sharing: sharing
        )
        let record = try CloudRecordFactory.record(for: heartbeat, modifiedAt: at)
        try await transport.save([record])
        try identity.remember(record.payload)
    }

    /// Looks the iCloud user up once (bounded); retried at the next write
    /// while unknown.
    private func resolveOwnerUser() async {
        guard ownerUser == nil else { return }
        let lookup = hostInfo.ownerUser
        if let found = await Self.bounded(cloudTimeout, { await lookup() }) {
            ownerUser = found
        }
    }

    /// Runs `operation` for at most `timeout`. On timeout it is cancelled,
    /// left to finish on its own, and nil is returned.
    nonisolated static func bounded<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: continuation)
            let finish: @Sendable (T?) -> Void = { value in
                let waiting = pending.withLock { slot -> CheckedContinuation<T?, Never>? in
                    defer { slot = nil }
                    return slot
                }
                waiting?.resume(returning: value)
            }
            let work = Task { await operation() }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                work.cancel()
                finish(nil)
            }
            Task {
                let value = await work.value
                timer.cancel()
                finish(value)
            }
        }
    }

    /// While `.unavailable`, periodically re-probes iCloud; when it returns,
    /// runs the full start() path. Exits on stop(), on leaving
    /// `.unavailable`, or after handing off to start().
    private func startReprobeLoop() {
        reprobeTask?.cancel()
        let startEpoch = epoch
        reprobeTask = Task { [weak self, interval = availabilityReprobeInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard self.epoch == startEpoch, case .unavailable = self.status else { return }
                guard case .available = await self.transport.availability() else { continue }
                guard self.epoch == startEpoch, case .unavailable = self.status else { return }
                await self.start()
                return
            }
        }
    }

    private static func describe(_ availability: CloudAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .noAccount: return "No iCloud account is signed in"
        case .restricted: return "iCloud access is restricted on this Mac"
        case .unavailable(let reason): return reason
        }
    }
}

import AppKit
import CloudKit
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
    /// Set the account-change reset callback before `start()`.
    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async
    /// Set before `start()`: the server deleted the private DataZone, so
    /// nothing published survives — but the relay zone and its cursor do.
    func setDataZoneResetHandler(_ handler: (@Sendable () -> Void)?) async
    /// A record CloudKit rejects even alone (`.limitExceeded`, spec §9).
    func setRecordRejectedHandler(_ handler: (@Sendable (_ recordName: String, _ zone: CloudZoneID) -> Void)?) async
    /// Start of the current throttling stretch (`.requestRateLimited` /
    /// `.zoneBusy`); nil once a send goes through. Settings → Mobile shows
    /// "iCloud is slowing sync down" after 60 s of it (spec §9).
    var throttledSince: Date? { get async }
    /// Hub zones deleted when Settings turns the hub off (multi-hub spec
    /// §3.3); call after `stop()`. Throws `HubZoneError.partlyDeleted` when
    /// something was deleted but the delete did not finish. Serialized on
    /// the transport: a second delete joins a running one and `start()`
    /// waits for it, whichever hub object calls them.
    func deleteHubZones() async throws
    /// The single-hub build's fixed-name zones (multi-hub spec §3.6).
    func removeLegacyZones(deleteIf: @Sendable (_ heartbeatPayload: Data?) -> Bool) async throws -> LegacyZoneCleanup
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
    /// The hub's zone shares (linking, spec §2.3); nil in a stub storage,
    /// which then links no phone.
    var shares: (any ShareService)?
    /// Registers the app for CloudKit's silent pushes (the CKSyncEngine's
    /// database subscription); nil in a stub storage, which reaches no
    /// CloudKit. No user prompt: silent pushes need no notification
    /// permission.
    var registerForPushes: (@MainActor () -> Void)?
    /// The hub's E2E keys (Task 10): the Keychain identity and the sealed epoch keys in `hubstate.db`. One per
    /// sidecar (it owns the envelope seq allocator). nil only in a live storage without the CloudKit entitlement
    /// (an unsigned dev build has no data protection keychain and reaches no CloudKit).
    var keyring: HubKeyring?
    /// The hub's record I/O (Task 11): `transport` behind the keyring, sealing what the hub publishes; the
    /// sidecar is its persisted wire → plain name map (F19). Lifecycle calls stay on `transport`. nil exactly when
    /// `keyring` is: then nothing is published, never in the clear.
    var secure: SecureTransport?

    /// A stub storage (tests): no CloudKit, and a hub identity in an in-memory keychain.
    static func stub(transport: any HubTransport, sidecar: HubSyncState) throws -> Self {
        var storage = Self(transport: transport, sidecar: sidecar)
        let keyring = try HubKeyring(hubID: try sidecar.ensureHubID(), sidecar: sidecar, store: InMemoryHubKeyStore())
        storage.keyring = keyring
        storage.secure = sealing(transport, keyring: keyring, sidecar: sidecar)
        return storage
    }

    /// The hub's sealing transport over `transport`: the keyring provides the keys and the relay rollback guard.
    static func sealing(_ transport: any HubTransport, keyring: HubKeyring, sidecar: HubSyncState) -> SecureTransport {
        SecureTransport(inner: transport, keys: keyring, rollback: keyring, names: sidecar)
    }

    /// `~/Library/Application Support/Watchtower/MobileHub/` (spec §3).
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower/MobileHub", isDirectory: true)
    }

    /// The real storage (multi-hub spec §3.1): `hubstate.db`, whose `hub_id`
    /// names this hub's zones, and `transport.db` behind a hub-role
    /// CloudKitTransport on those zones; the shares are of the same zones.
    static func live() throws -> Self {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sidecar = try HubSyncState(path: dir.appendingPathComponent("hubstate.db").path)
        let hubID = try sidecar.ensureHubID()
        let store = try TransportStore(path: dir.appendingPathComponent("transport.db").path)
        let keyring = CloudKitTransport.entitlementPresent()
            ? try HubKeyring(hubID: hubID, sidecar: sidecar, store: KeychainHubKeyStore(backend: SecItemKeychainBackend()))
            : nil
        let transport = CloudKitTransport(store: store, scope: .private, hubID: hubID, role: .hub)
        return Self(
            transport: transport,
            sidecar: sidecar, ownerUser: HubHostInfo.iCloudUserRecordName,
            sliceAssets: SliceAssetStore(directory: dir.appendingPathComponent("SliceAssets", isDirectory: true)),
            shares: CloudKitShareService(hubID: hubID),
            registerForPushes: registerForCloudKitPushes,
            keyring: keyring,
            secure: keyring.map { sealing(transport, keyring: $0, sidecar: sidecar) }
        )
    }

    /// Unsigned dev builds lack the iCloud and push entitlements: no-op.
    @MainActor
    private static func registerForCloudKitPushes() {
        guard CloudKitTransport.entitlementPresent() else { return }
        NSApplication.shared.registerForRemoteNotifications()
    }
}

enum HubStatus: Equatable {
    case off
    case starting
    case running
    /// CloudKit can't be used (no entitlement on unsigned dev builds, no
    /// iCloud account, …): expected and harmless; no loops run.
    case unavailable(String)
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
    /// The heartbeat is rewritten this often (spec §3; 15 min since board
    /// #724, owner decision Q2: each write is a silent push to the phone).
    nonisolated static let heartbeatInterval: Duration = .seconds(900)
    /// How often the heartbeat loop compares the accounts' rows and
    /// `sharing` with what the last write carried; a change is written at
    /// once (Settings on the phone shows them), no change writes nothing.
    nonisolated static let defaultHeartbeatFactsCheckInterval: Duration = .seconds(60)
    /// Bound on each CloudKit wait the hub adds: the iCloud user lookup,
    /// the legacy zone check and the zone delete.
    nonisolated static let defaultCloudTimeout: Duration = .seconds(30)
    /// Heartbeat ticks failing in a row before the hub stops: 3 × 900 s
    /// (45 min) outlasts the 35 min (`RelayFeed.heartbeatStaleAfter`) the
    /// phone waits before it shows the Mac offline, so the phone has shown
    /// it offline before the hub gives up; one missed write (30 min) does
    /// not show it offline.
    nonisolated static let maxTickFailures = 3

    private(set) var status: HubStatus = .off
    /// Why the last hub-off zone delete did not go through, for Settings →
    /// Mobile while the toggle is off; nil once it went through or started.
    private(set) var hubOffProblem: String?
    /// The heartbeat's `sharing` field; the link center sets it once the
    /// zone shares exist.
    @ObservationIgnored var sharing: HubSharing = .none
    /// Runs after Settings turned the hub off and its zones were deleted
    /// (multi-hub spec §3.3): the link center forgets codes and phones. A
    /// throw keeps the delete pending, so the next start redoes it.
    @ObservationIgnored var onZonesDeleted: (@MainActor () throws -> Void)?
    /// Runs on the main actor after the iCloud account signed out or
    /// switched (the transport's account reset): the link center forgets
    /// the old user.
    @ObservationIgnored var onAccountChanged: (@MainActor () -> Void)?
    /// Phone linking (Settings → Mobile); nil when the storage has no share
    /// service.
    @ObservationIgnored var linkCenter: MobileLinkCenter?
    /// The end of the last relay cycle that ran without an error.
    @ObservationIgnored private(set) var lastRelayAt: Date?

    @ObservationIgnored private let transport: any HubTransport
    @ObservationIgnored private let publisher: SlicePublisher
    @ObservationIgnored private let companions: [any HubCompanion]
    @ObservationIgnored private let processor: RelayProcessor
    @ObservationIgnored private let sidecar: HubSyncState
    /// The hub's E2E keys; `start()` creates `K_meta` and the first epoch when none exist. nil in tests that seal
    /// with fixed test keys, and without the CloudKit entitlement.
    @ObservationIgnored private let keyring: HubKeyring?
    @ObservationIgnored private let identity: HubIdentity
    @ObservationIgnored private let hostInfo: HubHostInfo
    @ObservationIgnored private let heartbeatEvery: Duration
    @ObservationIgnored private let heartbeatFactsEvery: Duration
    /// What the last heartbeat write carried (or the last facts check
    /// tried to write); nil before the first.
    @ObservationIgnored private var heartbeatFacts: HeartbeatFacts?
    @ObservationIgnored private let cloudTimeout: Duration
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// The iCloud user record name, once looked up; forgotten when the
    /// account changes.
    @ObservationIgnored private var ownerUser: String?
    /// Bumped by an account change, so a lookup still running then never
    /// stores the old user.
    @ObservationIgnored private var ownerEpoch = 0
    /// A due epoch rotation failed and was logged; cleared by the next one that runs.
    @ObservationIgnored private var rotationFailing = false
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
    /// The relay loop's current wait between cycles; `wakeRelay()` ends it.
    @ObservationIgnored private var relayWait: Task<Void, Never>?
    /// A wake that arrived during a cycle: the next wait is skipped.
    @ObservationIgnored private var relayWakePending = false
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
        keyring: HubKeyring? = nil,
        companions: [any HubCompanion] = [],
        relayIdleInterval: Duration = MobileHubService.defaultRelayIdleInterval,
        relayActiveInterval: Duration = MobileHubService.defaultRelayActiveInterval,
        availabilityReprobeInterval: Duration = .seconds(600),
        heartbeatInterval: Duration = MobileHubService.heartbeatInterval,
        heartbeatFactsCheckInterval: Duration = MobileHubService.defaultHeartbeatFactsCheckInterval,
        cloudTimeout: Duration = MobileHubService.defaultCloudTimeout,
        now: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping () -> Bool
    ) {
        self.transport = transport
        self.publisher = publisher
        self.companions = companions
        self.processor = processor
        self.sidecar = sidecar
        self.keyring = keyring
        self.identity = HubIdentity(sidecar: sidecar)
        self.hostInfo = hostInfo
        self.heartbeatEvery = heartbeatInterval
        self.heartbeatFactsEvery = heartbeatFactsCheckInterval
        self.cloudTimeout = cloudTimeout
        self.relayIdleInterval = relayIdleInterval
        self.relayActiveInterval = relayActiveInterval
        self.availabilityReprobeInterval = availabilityReprobeInterval
        self.now = now
        self.isEnabled = isEnabled
    }

    var isPublishing: Bool { publisher.isRunning }
    var relayBacklog: Int { processor.relayBacklog }
    /// The publisher's last send (Settings → Mobile's status).
    var lastPublishAt: Date? { publisher.lastPublishAt }

    /// The transport's current throttling stretch, if any.
    func throttledSince() async -> Date? {
        await transport.throttledSince
    }

    /// Asks the publisher's fast lane for `kinds` (B and C call this on a
    /// change they know of); only the urgent kinds are kept, the others
    /// ride the 30 s full tick.
    func nudge(kinds: Set<SliceKind>) {
        publisher.nudge(kinds: kinds)
    }

    /// Turns the hub on and reports where it landed: `.running`, or
    /// `.unavailable` when iCloud can't be used or the heartbeat write failed.
    @discardableResult
    func enable() async -> HubStatus {
        await start()
        return status
    }

    /// Starts the transport, gates on availability, writes the heartbeat,
    /// then spins up the loops. Safe to call again after `.unavailable` or
    /// `stop()`.
    func start() async {
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
        do {
            try markE2ECutIfDue()
        } catch {
            logger.error("E2E cut check failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable("Couldn't prepare this Mac's encryption keys: \(error.localizedDescription)")
            startReprobeLoop()
            return
        }
        let zonesSettled = await finishPendingZoneDelete()
        guard status == .starting, epoch == startEpoch else { return }
        guard zonesSettled else {
            status = .unavailable("Couldn't finish deleting this Mac's iCloud zones")
            startReprobeLoop()
            return
        }
        do {
            try adoptPerHubZones()
        } catch {
            logger.error("per-hub zone adoption failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable("Couldn't prepare this Mac's iCloud zones: \(error.localizedDescription)")
            startReprobeLoop()
            return
        }
        do {
            // The zones are gone: the cut, if one ran, is done. Then, before anything seals: K_meta and the first
            // epoch (idempotent).
            try finishE2ECut()
            try keyring?.ensureGroupKeys()
        } catch {
            logger.error("hub group keys unavailable: \(String(describing: error), privacy: .public)")
            status = .unavailable("Couldn't prepare this Mac's encryption keys: \(error.localizedDescription)")
            startReprobeLoop()
            return
        }
        // The resume check: a rotation that came due while the hub was off runs before anything seals; one
        // committed before a crash reads as fresh and does not run again (Review Focus 4).
        rotateEpochIfDue()
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
        await removeLegacyZonesIfDue()
        guard status == .starting, epoch == startEpoch else { return }
        // Each Mac publishes into its own zones (multi-hub spec §2, §3.2):
        // no other hub's heartbeat is read, so there is nothing to refuse.
        await resolveOwnerUser()
        guard status == .starting, epoch == startEpoch else { return }
        do {
            let wrote = try await writeHeartbeat(hubID: try identity.hubID()) {
                status == .starting && epoch == startEpoch
            }
            guard wrote else { return }
        } catch {
            logger.error("first heartbeat failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable("Couldn't write the heartbeat: \(error.localizedDescription)")
            startReprobeLoop()
            return
        }
        tickFailures = 0
        // The companions first: the fast lane's liveness copy must be in
        // place before the publisher's first full cycle, or that cycle
        // would publish live sessions as not running.
        companions.forEach { $0.start() }
        publisher.start()
        startRelayLoop()
        startHeartbeatLoop()
        hubOffProblem = nil
        status = .running
    }

    /// Registered BEFORE `transport.start()`, so an account change seen
    /// during startup still wipes the derived sync state. A server-side
    /// DataZone deletion (`.encryptedDataReset`, the owner deleting iCloud
    /// data) wipes the same publish state so the recreated zone gets every
    /// record again, but KEEPS the relay token: the relay buffer survived,
    /// and re-reading it from the start would re-ingest a failed upload the
    /// phone never retried and re-echo received ones (P2-I1).
    private func installTransportHandlers() async {
        let sidecar = self.sidecar
        let publisher = self.publisher
        let logger = self.logger
        let now = self.now
        await transport.setAccountResetHandler { [weak self] in
            do {
                try sidecar.wipeSyncState(now: now())
            } catch {
                logger.error("account reset: wipeSyncState failed: \(error.localizedDescription, privacy: .public)")
            }
            // The new account's zone gets every record again, restaged.
            publisher.removeStagedAssets()
            Task { @MainActor in self?.accountChanged() }
        }
        await transport.setDataZoneResetHandler {
            do {
                try sidecar.wipeSyncState(now: now(), keepingRelayToken: true)
            } catch {
                logger.error("data-zone reset: wipeSyncState failed: \(error.localizedDescription, privacy: .public)")
            }
            // The recreated zone gets every record again, restaged.
            publisher.removeStagedAssets()
        }
        // CloudKit names the rejected record by its wire name; the publisher maps it back (F19).
        await transport.setRecordRejectedHandler { wireName, zone in
            guard zone == .data else { return }
            Task { await publisher.recordRejected(wireName: wireName) }
        }
    }

    func stop() {
        publisher.stop()
        linkCenter?.cancelSweepRetry()
        companions.forEach { $0.stop() }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reprobeTask?.cancel()
        reprobeTask = nil
        let relay = relayTask
        relayTask = nil
        relay?.cancel()
        relayWakePending = false
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

    /// The Settings toggle turned off (multi-hub spec §3.3): stops, removes
    /// the staged slice assets, then deletes this hub's two zones (bounded).
    /// Once they are gone the link center forgets every phone and the sync
    /// state is wiped (nothing is published; the relay buffer was wiped, so
    /// it is re-read from the start; the ledger stays). A delete that fails
    /// changes nothing: the zones, the state and the phones stay consistent
    /// (Review focus 5). One that times out may still land, so its outcome is
    /// unknown: `hub_zones_delete_pending` stays set and the next start
    /// finishes it before the engine runs.
    func disable() {
        stop()
        publisher.closeStagedAssets()
        let previous = teardown
        teardown = Task { [weak self] in
            await previous?.value
            await self?.deleteZonesForHubOff()
        }
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

    // MARK: - Zone lifecycle (multi-hub spec §3.3, §3.6)

    /// `failed`: refused before anything was sent or applied (see
    /// `isDefinitelyRefused`), so nothing changed. `partlyDeleted`: something
    /// was deleted (one zone, or both without the store wipe). `unconfirmed`:
    /// the bound ran out, or an error left it open whether the server
    /// applied the delete. The last two have to be finished at the next start.
    private enum ZoneDeleteOutcome { case deleted, failed, partlyDeleted, unconfirmed }

    /// Turning the hub off: records the delete as pending first, so an
    /// unconfirmed outcome (a timeout, or an error after the request may have
    /// reached the server), a partial delete or a crash leaves the next start
    /// to finish it. Only a delete that was definitely refused clears the
    /// marker. What did not go through shows in `hubOffProblem`.
    private func deleteZonesForHubOff() async {
        hubOffProblem = nil
        do {
            try sidecar.setMetaValue("1", forKey: HubIdentity.zonesDeletePendingKey)
        } catch {
            logger.error("hub off: zones kept, sidecar unwritable: \(error.localizedDescription, privacy: .public)")
            hubOffProblem = "This Mac's iCloud zones were kept: its sync state couldn't be written "
                + "(\(error.localizedDescription))"
            return
        }
        switch await deleteHubZonesBounded() {
        case .deleted:
            if !zonesDeleted() {
                hubOffProblem = "This Mac's iCloud zones were deleted, but its phones and sync state "
                    + "weren't cleared. That finishes when the hub is turned on."
            }
        case .failed:
            hubOffProblem = "Couldn't delete this Mac's iCloud zones; they and the linked phones are kept"
            do {
                try sidecar.removeMetaValue(forKey: HubIdentity.zonesDeletePendingKey)
            } catch {
                logger.error("hub off: pending marker not cleared: \(error.localizedDescription, privacy: .public)")
            }
        case .partlyDeleted:
            logger.warning("hub off: zones partly deleted; the next start finishes it")
            hubOffProblem = "This Mac's iCloud zones were only partly deleted. That finishes when the hub is turned on."
        case .unconfirmed:
            logger.warning("hub off: zone delete unconfirmed; the next start finishes it")
            hubOffProblem = "iCloud didn't confirm deleting this Mac's zones. That finishes when the hub is turned on."
        }
    }

    /// At start, before the engine runs: a hub-off zone delete whose outcome
    /// is unknown is done again (`deleteHubZones` treats a missing zone as
    /// deleted). True when nothing is pending any more; false keeps the hub
    /// off the engine, so a late store wipe never lands under it.
    private func finishPendingZoneDelete() async -> Bool {
        do {
            guard try sidecar.metaValue(forKey: HubIdentity.zonesDeletePendingKey) != nil else { return true }
        } catch {
            logger.error("pending zone delete: sidecar unreadable: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard case .deleted = await deleteHubZonesBounded() else { return false }
        return zonesDeleted()
    }

    /// Runs `deleteHubZones()`, bounded by `cloudTimeout`. The delete is not
    /// cancelled on timeout and may still land; the transport, which lives
    /// for the app run with its store, serializes it: a later delete joins
    /// it and `transport.start()` waits for it — from this hub object or one
    /// built after it — so its late store wipe never races either.
    private func deleteHubZonesBounded() async -> ZoneDeleteOutcome {
        let transport = self.transport
        let logger = self.logger
        let work = Task<ZoneDeleteOutcome, Never> {
            do {
                try await transport.deleteHubZones()
                return .deleted
            } catch HubZoneError.partlyDeleted {
                return .partlyDeleted
            } catch {
                logger.error("zones not deleted: \(error.localizedDescription, privacy: .public)")
                return Self.isDefinitelyRefused(error) ? .failed : .unconfirmed
            }
        }
        return await Self.bounded(cloudTimeout) { await work.value } ?? .unconfirmed
    }

    /// Errors that mean the delete was never sent or never applied: the
    /// transport refused it, or CloudKit rejected the request up front.
    /// Anything else (a lost response, a network failure mid-request,
    /// throttling, a server rejection, a non-CloudKit error) may have landed.
    nonisolated static func isDefinitelyRefused(_ error: any Error) -> Bool {
        if let hub = error as? HubZoneError {
            return [.notHub, .engineRunning, .noEntitlement].contains(hub)
        }
        guard let ck = error as? CKError else { return false }
        let refused: Set<CKError.Code> = [
            .networkUnavailable, .notAuthenticated, .permissionFailure, .quotaExceeded, .missingEntitlement,
            .badContainer, .managedAccountRestricted, .incompatibleVersion, .accountTemporarilyUnavailable,
            .invalidArguments
        ]
        return refused.contains(ck.code)
    }

    /// The zones are gone: the link center forgets the phones, then the sync
    /// state is wiped. The pending marker clears only once both landed, so
    /// a failure is redone at the next start. True when it cleared.
    private func zonesDeleted() -> Bool {
        do {
            try onZonesDeleted?()
            try sidecar.wipeSyncState(now: now())
            try sidecar.removeMetaValue(forKey: HubIdentity.zonesDeletePendingKey)
            return true
        } catch {
            logger.error("zones deleted: phones or sync state not cleared: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The E2E hard cut (spec §2.8, D13): a hub that published before the E2E build (or whose pairing a recreated
    /// identity voided) deletes its two zones once, through the pending zone delete that `finishPendingZoneDelete`
    /// runs next, which forgets the phones (`onZonesDeleted`, keys included) and wipes the sync state. Due when the
    /// marker is absent on a hub that ran before, `pending` (a cut a failure, a timeout or a crash interrupted),
    /// or `1` with a recreated identity or stored keys that no longer open. A hub that never ran, or one without
    /// keys (nothing is published), cuts nothing.
    private func markE2ECutIfDue() throws {
        guard let keyring else { return }
        switch try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey) {
        case HubIdentity.e2eCutDone?:
            if keyring.identityWasRecreated {
                logger.notice("E2E cut due: the hub identity was recreated")
            } else if try keyring.storedGroupKeysUnreadable() {
                logger.error("E2E cut due: the stored hub keys do not open under this identity; phones must re-pair")
            } else {
                return
            }
        case nil:
            guard try keyring.identityWasRecreated || sidecar.ranBeforeE2E() else {
                try sidecar.setMetaValue(HubIdentity.e2eCutDone, forKey: HubIdentity.e2eMigrationKey)
                return
            }
            logger.notice("E2E cut due: first start on the E2E build; linked phones re-pair once")
        default:
            logger.notice("E2E cut due: finishing an interrupted cut")
        }
        try sidecar.markE2ECutPending()
    }

    /// After the cut's zone delete settled: the pre-E2E staged files (plaintext, no `.desc`) go, the phones and the
    /// group keys are forgotten even without a link center, and only then is the marker `1` (never beside a pre-E2E
    /// device row). A crash before it reruns the cut.
    private func finishE2ECut() throws {
        guard let keyring,
              try sidecar.metaValue(forKey: HubIdentity.e2eMigrationKey) == HubIdentity.e2eCutPending else { return }
        publisher.removeStagedAssets()
        try sidecar.clearLinkState()
        try keyring.resetGroupKeys()
        try sidecar.setMetaValue(HubIdentity.e2eCutDone, forKey: HubIdentity.e2eMigrationKey)
        logger.notice("E2E cut done: this Mac's zones start empty on fresh keys")
    }

    /// First start on the per-hub build: the transport store, bound to no
    /// hub, wipes itself at `start()`, so what the sidecar believes published
    /// and its relay cursor describe the old fixed-name zones. Forgets them
    /// once (Review focus 3); the exactly-once ledger stays.
    private func adoptPerHubZones() throws {
        guard try sidecar.metaValue(forKey: HubIdentity.perHubZonesKey) == nil else { return }
        try sidecar.wipeSyncState(now: now())
        publisher.removeStagedAssets()
        try sidecar.setMetaValue("1", forKey: HubIdentity.perHubZonesKey)
    }

    /// Deletes the single-hub build's zones when they are this hub's (or
    /// nobody's), bounded by `cloudTimeout`. Best-effort: a failure or a
    /// timeout leaves the marker unset, so the next start checks again; it
    /// never blocks the hub.
    private func removeLegacyZonesIfDue() async {
        do {
            guard try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey) == nil else { return }
            let hubID = try identity.hubID()
            let transport = self.transport
            let outcome = await Self.bounded(cloudTimeout) { () -> Result<LegacyZoneCleanup, any Error> in
                do {
                    return .success(try await transport.removeLegacyZones {
                        HubIdentity.legacyZonesAreOurs(heartbeat: $0, hubID: hubID)
                    })
                } catch {
                    return .failure(error)
                }
            }
            switch outcome {
            case .success(let cleanup)?:
                try sidecar.setMetaValue(cleanup.rawValue, forKey: HubIdentity.legacyZonesCheckedKey)
                logger.notice("legacy zones: \(cleanup.rawValue, privacy: .public)")
            case .failure(let error)?:
                logger.warning("legacy zone check failed: \(error.localizedDescription, privacy: .public)")
            case nil:
                logger.warning("legacy zone check timed out")
            }
        } catch {
            logger.error("legacy zone check: sidecar unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Loops

    private func startRelayLoop() {
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.runRelayCycle()
                await self.waitForNextRelayCycle()
            }
        }
    }

    /// The wait between two relay cycles, cut short by `wakeRelay()`.
    private func waitForNextRelayCycle() async {
        if relayWakePending {
            relayWakePending = false
            return
        }
        let interval = relayInterval()
        let wait = Task<Void, Never> { try? await Task.sleep(for: interval) }
        relayWait = wait
        await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
        relayWait = nil
    }

    /// A CloudKit push arrived (`TrayAppDelegate`): the relay loop pulls now
    /// instead of after its 3 s / 30 s wait. A wake during a cycle runs the
    /// next one right after it. No-op while the relay loop is not running.
    func wakeRelay() {
        guard relayTask != nil else { return }
        if let relayWait {
            relayWait.cancel()
        } else {
            relayWakePending = true
        }
    }

    /// One relay cycle: pull, daily hygiene, then passes until the backlog
    /// is empty — a long Mac sleep drains in one cycle (Review focus 5).
    private func runRelayCycle() async {
        rotateEpochIfDue()
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

    /// Spec §2.2: at each cycle start, the epoch rotates once it is 90 days old or used 2^28 seqs. The rotation
    /// wipes the slice hashes, so the publisher's next cycle republishes the window under the new epoch; the
    /// keyboxes are nudged first. A failure keeps the current epoch (still valid) and is retried next cycle,
    /// logged once per failing stretch.
    func rotateEpochIfDue() {
        guard let keyring else { return }
        do {
            let rotated = try keyring.rotateIfDue()
            rotationFailing = false
            if rotated { publisher.nudge(kinds: [.deviceGrant]) }
        } catch {
            guard !rotationFailing else { return }
            rotationFailing = true
            logger.error("epoch rotation failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 3 s while a QR code is open (the scanning phone's `device` record
    /// waits for its grant) or a phone action was seen in the last 300 s,
    /// otherwise 30 s.
    func relayInterval() -> Duration {
        if linkCenter?.openCode != nil { return relayActiveInterval }
        if let last = processor.lastActivityAt, now().timeIntervalSince(last) < Self.activityWindow {
            return relayActiveInterval
        }
        return relayIdleInterval
    }

    // MARK: - Heartbeat (multi-hub spec §3.2)

    /// Writes the heartbeat every `heartbeatEvery`, and checks its facts
    /// every `heartbeatFactsEvery` in between; a facts write restarts the
    /// interval.
    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, interval = heartbeatEvery, check = heartbeatFactsEvery] in
            var sinceWrite = Duration.zero
            while !Task.isCancelled {
                let step = min(check, interval - sinceWrite)
                try? await Task.sleep(for: step)
                guard let self, !Task.isCancelled else { return }
                sinceWrite += step
                if sinceWrite >= interval {
                    sinceWrite = .zero
                    await self.heartbeatTick()
                } else if await self.refreshHeartbeatIfFactsChanged() {
                    sinceWrite = .zero
                }
            }
        }
    }

    /// The heartbeat fields the phone's Settings shows that change without
    /// the hub: the accounts' status rows and `sharing`.
    private struct HeartbeatFacts: Equatable {
        let accounts: [HeartbeatAccount]
        let sharing: HubSharing
    }

    /// The facts now; nil when the accounts read failed (a failure is not
    /// an empty list, so it is never compared or written as one). The
    /// accounts are read off the main actor (`HubHostInfo.accounts`).
    private func currentHeartbeatFacts() async -> HeartbeatFacts? {
        do {
            let accounts = try await hostInfo.accounts()
            return HeartbeatFacts(accounts: Array(accounts.prefix(HeartbeatPayload.maxAccounts)), sharing: sharing)
        } catch {
            logger.error("heartbeat accounts read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Rewrites the heartbeat at once when its facts differ from what the
    /// last write carried, so an account's status or `sharing` reaches the
    /// phone without waiting for the 15 min tick; unchanged facts write
    /// nothing. One attempt per change: a failure is logged and left to the
    /// next tick (it does not count toward `maxTickFailures`). A failed
    /// accounts read skips the check (no change seen, nothing written). True
    /// when it wrote.
    @discardableResult
    func refreshHeartbeatIfFactsChanged() async -> Bool {
        guard status == .running, heartbeatFacts != nil else { return false }
        guard let current = await currentHeartbeatFacts(), status == .running,
              let written = heartbeatFacts, current != written else { return false }
        heartbeatFacts = current
        let checkEpoch = epoch
        do {
            return try await writeHeartbeat(hubID: try identity.hubID(), facts: current) {
                status == .running && epoch == checkEpoch
            }
        } catch {
            guard status == .running, epoch == checkEpoch else { return false }
            logger.warning("heartbeat rewrite for changed accounts or sharing failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One heartbeat tick: rewrites this hub's heartbeat (multi-hub spec
    /// §3.2). `maxTickFailures` failures in a row stop the hub as
    /// `.unavailable` (its local store is failing), and the reprobe loop
    /// restarts it.
    func heartbeatTick() async {
        guard status == .running else { return }
        let tickEpoch = epoch
        do {
            let hubID = try identity.hubID()
            await resolveOwnerUser()
            guard status == .running, epoch == tickEpoch else { return }
            let wrote = try await writeHeartbeat(hubID: hubID) { status == .running && epoch == tickEpoch }
            guard wrote else { return }
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
            status = .unavailable("Couldn't write the heartbeat: \(error.localizedDescription)")
            startReprobeLoop()
        }
    }

    /// Writes this hub's heartbeat into its own DataZone, stamped with this
    /// Mac's clock (multi-hub spec §3.2). When the accounts read fails it
    /// carries the accounts the last write carried (none before the first).
    /// `isCurrent` is checked after the accounts read: a stop or disable
    /// meanwhile writes nothing (neither `enabled_at` nor the record), and
    /// false is returned.
    private func writeHeartbeat(
        hubID: String, facts: HeartbeatFacts? = nil, isCurrent: () -> Bool
    ) async throws -> Bool {
        var read = facts
        if read == nil {
            read = await currentHeartbeatFacts()
        }
        guard isCurrent() else { return false }
        let at = now()
        let facts = read ?? HeartbeatFacts(accounts: heartbeatFacts?.accounts ?? [], sharing: sharing)
        let heartbeat = HeartbeatPayload(
            updatedAt: at,
            appVersion: hostInfo.appVersion,
            hubID: hubID,
            macName: hostInfo.macName,
            flavor: hostInfo.flavor,
            lastPublishAt: publisher.lastPublishAt,
            lastRelayAt: lastRelayAt,
            relayBacklog: processor.relayBacklog,
            accounts: facts.accounts,
            enabledAt: try identity.ensureEnabledAt(at),
            ownerUser: ownerUser ?? "",
            sharing: facts.sharing
        )
        let record = try CloudRecordFactory.record(for: heartbeat, modifiedAt: at)
        // Sealed like every DataZone record (spec §2.7: the fixed name `heartbeat` stays).
        try await publisher.saveHeartbeat(record)
        heartbeatFacts = facts
        return true
    }

    /// Looks the iCloud user up once (bounded); retried at the next write
    /// while unknown.
    private func resolveOwnerUser() async {
        guard ownerUser == nil else { return }
        let lookup = hostInfo.ownerUser
        let epoch = ownerEpoch
        if let found = await Self.bounded(cloudTimeout, { await lookup() }), epoch == ownerEpoch {
            ownerUser = found
        }
    }

    /// The account signed out or switched: the heartbeat's `owner_user` and
    /// the link center's are looked up again.
    func accountChanged() {
        ownerUser = nil
        ownerEpoch += 1
        onAccountChanged?()
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

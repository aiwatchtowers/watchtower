import Foundation
import Observation
import os
import UserNotifications
import WatchtowerSync

/// The app's root for its lifetime: one `AppEnvironment` (a session per
/// linked hub, kept for good), the hub registry, and the link flow, which
/// adds, removes and freezes hubs through it (multi-hub spec §5.7, §6). A
/// scan builds the scanned hub's session in its own directories; a link
/// adds its row and puts it on screen; an unlink removes one hub; the
/// Mac's removal freezes that hub read-only until Forget; an iCloud
/// account change removes every hub. Each session seals and opens with
/// this phone's keys for its hub (mobile E2E); the link flow keeps those
/// keys in step with the hub's keybox.
///
/// The demo (unsigned builds) keeps its one environment, linked as
/// `DemoSeed.device`, and never shows onboarding.
@MainActor
@Observable
final class AppRoot {
    /// How an unlink's `unlinked` record is waited for: it goes through the
    /// removed hub's own transport (which holds the record's server state),
    /// and the removal waits until it has left the send queue, `sendNow()`
    /// again every `pause`; `cap` bounds the whole wait, a send that hangs
    /// included; then it goes on whatever happened (best effort).
    struct FarewellDelivery {
        /// Whether `record` still waits in `session`'s send queue.
        let isPending: @MainActor (_ session: HubSession, _ record: CloudRecord) -> Bool
        var cap: Duration = .seconds(10)
        var pause: Duration = .milliseconds(500)
        /// One push of the send queue (`HubSession.sendNow()`); tests
        /// replace it.
        var send: @MainActor (_ session: HubSession) async -> Void = { await $0.sendNow() }

        /// The live app: the send queue of the hub's own transport store
        /// (`TransportStore.isPending`). A session with no store, or a queue
        /// that cannot be read, reads as settled: the removal does not wait
        /// on what it cannot see.
        static var live: Self {
            Self { session, record in
                guard let store = session.transportStore else { return false }
                do {
                    return try store.isPending(recordName: record.recordName, zone: record.zone)
                } catch {
                    AppRoot.logger.warning("send queue unreadable: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        }
    }

    let env: AppEnvironment
    let linking: LinkingViewModel

    @ObservationIgnored private let registry: HubRegistry
    @ObservationIgnored private let paths: HubPaths
    @ObservationIgnored private let factory: HubSessionFactory
    @ObservationIgnored private let identity: DeviceIdentity
    /// Where the hubs' Settings choices are kept (a removal deletes them).
    @ObservationIgnored private let defaults: UserDefaults
    /// Keeps a removal, a freeze or the account-change wipe running, and
    /// the replica usable, when it runs in the background (a push fetch
    /// found it): the hand-over reads the old replica (`BackgroundWork`).
    /// nil holds nothing (tests).
    @ObservationIgnored private let startWork: BackgroundWork.Starter?
    @ObservationIgnored private let farewellDelivery: FarewellDelivery
    /// The removal running per hub: a second one for the same hub waits
    /// for it and counts nothing.
    @ObservationIgnored private var removals: [String: Task<LocalWipe, Never>] = [:]
    /// The link check of each hub's last fetch (`checkLink`); a test awaits
    /// it.
    @ObservationIgnored private(set) var linkChecks: [String: Task<Void, Never>] = [:]
    /// Hubs whose unreadable keybox was logged; a readable one resets it.
    @ObservationIgnored private var loggedUnreadableGrants: Set<String> = []
    /// The seq ceiling (F29) of each hub a removal took off this phone in
    /// this process: a new session for the same hub (a rescan) starts its
    /// seqs above it. A relaunch forgets it; the hub's re-link absorbs a
    /// restart (`HubSyncState.linkDevice`).
    @ObservationIgnored private var seqFloors: [String: UInt64] = [:]
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppRoot")

    init(
        env: AppEnvironment,
        registry: HubRegistry,
        paths: HubPaths,
        factory: HubSessionFactory,
        identity: DeviceIdentity,
        defaults: UserDefaults,
        linking: LinkingViewModel,
        startWork: BackgroundWork.Starter?,
        farewellDelivery: FarewellDelivery
    ) {
        self.env = env
        self.registry = registry
        self.paths = paths
        self.factory = factory
        self.identity = identity
        self.defaults = defaults
        self.linking = linking
        self.startWork = startWork
        self.farewellDelivery = farewellDelivery
        for hubID in env.order {
            if let session = env.session(hubID) {
                wire(session)
            }
        }
        linking.host = self
        // A switch re-evaluates the stale notice for the hub it puts on
        // screen: the old hub's never shows over a healthy Mac.
        env.onActivate = { [weak self] session in
            guard let self, !self.isDemo else { return }
            self.linking.activated(hubID: session.hubID, heartbeat: session.heartbeat)
        }
    }

    var isDemo: Bool { env.transportKind == .inMemoryDemo }

    /// Welcome and the scan instead of the tabs: a live build with no saved
    /// link, or none on screen (the last one was just removed).
    var showsOnboarding: Bool { !isDemo && (linking.links.isEmpty || env.active == nil) }

    /// The app's root: the demo on an unsigned build, else every linked
    /// hub from the registry (an F1 phone's link moved into it first), then
    /// the orphans' clean-up and a link a kill interrupted. Throws
    /// `KeyStoreError.locked` before the first unlock since a restart (the
    /// boot waits for it).
    static func live() throws -> AppRoot {
        let defaults = UserDefaults.standard
        guard CloudKitTransport.entitlementPresent() else {
            return try demo(try AppEnvironment.demo(energy: BatteryDiagnostics.shared.counter), defaults: defaults)
        }
        let store = LinkStore(defaults: defaults)
        let keys = try PhoneKeychain.store()
        // F14: reads the device id (works while locked), never creates it.
        let identity = try DeviceIdentity.current(keys: keys)
        LegacyDeviceID.remove(defaults: defaults)
        let group = try AppEnvironment.appGroupDirectory()
        let paths = HubPaths(
            groupDirectory: group,
            localDirectory: try AppEnvironment.applicationSupportDirectory(),
            recordingsBase: try PhoneRecorderController.defaultDirectory()
        )
        // Resolved (and an earlier build's store moved out of the group)
        // once, before the migration moves it into its hub's directory.
        let legacyTransportStorePath = try AppEnvironment.liveTransportStorePath()
        let registry = try HubRegistry(path: paths.registryPath)
        try HubBoot.migrateF1(
            store: store,
            registry: registry,
            paths: paths,
            legacyGroupDirectory: group,
            legacyTransportStorePath: legacyTransportStorePath,
            legacyRecordings: paths.recordingsBase,
            defaults: defaults,
            now: Date()
        )
        let factory = HubSessionFactory.live(paths: paths, keys: keys)
        let env = try AppEnvironment.live(registry: registry, paths: paths, factory: factory, identity: identity, defaults: defaults)
        let root = AppRoot(
            env: env,
            registry: registry,
            paths: paths,
            factory: factory,
            identity: identity,
            defaults: defaults,
            linking: LinkingViewModel(container: CloudKitLinkContainer(), store: store, identity: identity, keys: keys),
            startWork: BackgroundWork.starter(),
            farewellDelivery: .live
        )
        Task {
            // Links made before E2E go first (their sessions were built
            // stopped), so the orphan pass sees the pending link that is left.
            await root.linking.dropUnencryptedLinks()
            let pendingHubID = store.pending?.link.hubID
            do {
                try await HubBoot.removeOrphans(registry: registry, paths: paths, keeping: pendingHubID, factory: factory)
            } catch {
                logger.error("orphan hub files not removed: \(error.localizedDescription, privacy: .public)")
            }
            await root.resumeLink()
        }
        return root
    }

    /// A root that keeps the demo's environment, linked as
    /// `DemoSeed.device`. The demo supplies its Macs the way a live build
    /// does: an in-memory registry holds a row for each demo hub the
    /// environment has a session for, so `linking.links` drives the chip,
    /// the switcher and Settings → Macs unchanged. The demo never links or
    /// ends a link (its link flow has no transport): reorder and switching
    /// work, Unlink and Forget are not offered (`MacsView.offersRemoval`).
    static func demo(_ env: AppEnvironment, defaults: UserDefaults) throws -> AppRoot {
        let device = DemoSeed.device
        let identity = DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("demo-hubs", isDirectory: true)
        let registry = try HubRegistry.inMemory()
        let now = Date()
        for hub in DemoSeed.hubs where env.session(hub.hubID) != nil {
            try registry.upsert(DemoSeed.link(for: hub, now: now), now: now)
            try registry.noteHeartbeat(flavor: hub.flavor.rawValue, at: now, for: hub.hubID)
        }
        env.nameHubs(try registry.rows())
        return AppRoot(
            env: env,
            registry: registry,
            paths: HubPaths(groupDirectory: base, localDirectory: base, recordingsBase: base),
            factory: HubSessionFactory { _, _, _, _ in throw CocoaError(.featureUnsupported) },
            identity: identity,
            defaults: defaults,
            linking: LinkingViewModel(
                container: CloudKitLinkContainer(), store: LinkStore(defaults: defaults), identity: identity,
                keys: InMemoryPhoneKeyStore()
            ),
            startWork: nil,
            farewellDelivery: FarewellDelivery { _, _ in false }
        )
    }

    /// At launch: links saved before encryption are dropped (scan again),
    /// a link a kill left waiting resumes, then the account check (the
    /// account may have changed while the app was not running).
    func resumeLink() async {
        await linking.dropUnencryptedLinks()
        await linking.resumePendingLink()
        await accountCheck()
    }

    /// A `watchtower://link` URL from the system Camera app. The demo has no
    /// link to change.
    func open(_ url: URL) async {
        guard !isDemo else {
            Self.logger.notice("link URL ignored: the demo build has no link")
            return
        }
        await linking.open(url)
    }

    // MARK: - Sessions

    /// The link flow's hooks on one hub's session: its link signals, the
    /// checks after each fetch, its keybox indexed (a rotation, a removal)
    /// and the unlock (the keybox's epoch keys reconciled with the Keychain,
    /// final review Phone I-1).
    private func wire(_ session: HubSession) {
        let hubID = session.hubID
        session.onLinkSignal = { [weak self] signal in self?.handle(signal, hubID: hubID) }
        session.onFetched = { [weak self] in self?.checkLink(hubID: hubID) }
        session.onKeyboxChanged = { [weak self] in
            guard let self, !self.isDemo else { return }
            let linking = self.linking
            Task { await linking.keyboxChanged(hubID: hubID) }
        }
        session.onKeysAvailable = { [weak self] in
            guard let self, !self.isDemo else { return }
            let linking = self.linking
            Task { await linking.reconcileKeyboxKeys(hubID: hubID) }
        }
    }

    private func handle(_ signal: LinkSignal, hubID: String) {
        Task { [weak self] in
            switch signal {
            case .unlinked: await self?.linking.removedByMac(hubID)
            case .accountChanged: await self?.accountCheck()
            }
        }
    }

    /// The account check, inside one piece of background work: a change
    /// removes every hub, and the hand-overs read the old replicas.
    private func accountCheck() async {
        let endWork = startWork?("hub-remove")
        defer { endWork?() }
        await linking.accountChanged()
    }

    /// After each fetch of `hubID`: its heartbeat noted on its row (flavor,
    /// time), the stale check for the hub on screen, and the Mac's Remove
    /// read from this phone's grant there (#64). The grant is the one of
    /// the device id the link was made with (`LinkRecord.deviceID`), never
    /// the Keychain's current id; a link without it is judged on the
    /// heartbeat only. A hub with no `linked` row (a candidate, a frozen
    /// hub) is not judged. E2E: the grant rides in this phone's keybox
    /// (`ReplicaStore.keybox(deviceID:from:)`, opened with the device's
    /// key), whose epoch keys are reconciled with the Keychain first (final
    /// review Phone I-1); a revoked keybox (D9) reads `linked: false` here
    /// too, though `keyboxChanged` acts on it first.
    private func checkLink(hubID: String) {
        guard !isDemo, let session = env.session(hubID) else { return }
        if let heartbeat = session.heartbeat {
            do {
                try registry.noteHeartbeat(flavor: heartbeat.flavor.rawValue, at: heartbeat.updatedAt, for: hubID)
            } catch {
                Self.logger.error("heartbeat not noted: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let row = linking.links.first(where: { $0.hubID == hubID }), row.state == .linked else { return }
        let store = session.store
        let deviceID = row.link.deviceID.flatMap(UUID.init(uuidString:))
        let heartbeat: HeartbeatPayload?
        let reading: Result<Keybox?, Error>?
        do {
            (heartbeat, reading) = try store.reader.read { db in
                (
                    try SettingsSnapshot.decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db),
                    deviceID.map { id in Result { try store.keybox(deviceID: id, from: db) } }
                )
            }
        } catch {
            Self.logger.error("heartbeat or grant read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let grant = reading.map { readGrant($0, hubID: hubID) } ?? .unreadable
        let keybox: Keybox? = if case let .success(stored)? = reading { stored } else { nil }
        let isActive = env.activeHubID == hubID
        let linking = linking
        linkChecks[hubID] = Task {
            if let keybox { await linking.reconcileKeyboxKeys(hubID: hubID, keybox: keybox) }
            await linking.evaluate(hubID: hubID, heartbeat: heartbeat, isActive: isActive)
            switch grant {
            case .absent: await linking.evaluate(hubID: hubID, grant: nil, heartbeat: heartbeat)
            case let .decoded(value): await linking.evaluate(hubID: hubID, grant: value, heartbeat: heartbeat)
            case .unreadable: break
            }
        }
    }

    /// The linked device's stored grant as the removal check may judge it.
    private enum GrantReading {
        case absent
        case decoded(DeviceGrant)
        /// Stored but not readable (a newer Mac's format, an envelope that
        /// does not open, keys locked), or no device id to read it by: never
        /// judged — unreadable is not absent.
        case unreadable
    }

    /// The keybox read as a grant reading. An unreadable one is logged once
    /// per hub until a readable one comes, not on every fetch.
    private func readGrant(_ reading: Result<Keybox?, Error>, hubID: String) -> GrantReading {
        switch reading {
        case .success(nil):
            return .absent
        case .success(let keybox?):
            loggedUnreadableGrants.remove(hubID)
            return .decoded(keybox.grant)
        case .failure(let error):
            if loggedUnreadableGrants.insert(hubID).inserted {
                Self.logger.warning("unreadable device keybox kept, not judged: \(String(describing: error), privacy: .public)")
            }
            return .unreadable
        }
    }

    /// The hub that takes the screen when `hubID` goes: the next linked
    /// row in order, else the one before it; nil when none is left.
    private func successor(of hubID: String, in rows: [HubRow]) -> String? {
        guard let index = rows.firstIndex(where: { $0.hubID == hubID }) else { return rows.first?.hubID }
        let rest = rows.filter { $0.hubID != hubID && env.session($0.hubID) != nil }
        return rest.first { $0.sortOrder > rows[index].sortOrder }?.hubID ?? rest.last?.hubID
    }

    /// One removal of `hubID` (see `removeHub`). The row goes first, with
    /// no wait before it: a kill anywhere after leaves no row that would
    /// bring the hub back at the next launch (its files, if any are left,
    /// are an orphan the next launch hands over and deletes). An unlink's
    /// `farewell` then goes out through the session's own transport,
    /// before the session stops.
    private func performRemoval(_ hubID: String, keepRecordings: Bool, farewell: CloudRecord?) async -> LocalWipe {
        let endWork = startWork?("hub-remove")
        defer { endWork?() }
        guard HubPaths.isValidHubID(hubID) else {
            // Never a hub this app built: no path is made from it.
            Self.logger.fault("removal of an unusable hub id refused")
            return LocalWipe()
        }
        let rows: [HubRow]
        do {
            rows = try registry.rows()
            try registry.remove(hubID)
        } catch {
            Self.logger.error("hub row not removed: \(error.localizedDescription, privacy: .public)")
            return LocalWipe()
        }
        if env.activeHubID == hubID {
            if let next = successor(of: hubID, in: rows) {
                env.activate(next)
            }
        }
        var outcome = LocalWipe()
        var filesFree = true
        if let session = env.session(hubID) {
            session.onLinkSignal = nil
            session.onFetched = nil
            session.onKeyboxChanged = nil
            session.onKeysAvailable = nil
            if let farewell {
                await deliver(farewell, through: session)
            }
            let stoppedCapture = await session.recorder.stopForWipe()
            // After the shutdown the boot (and its launch recovery) has
            // ended: the hand-over never races it.
            await session.shutDown()
            do {
                seqFloors[hubID] = max(seqFloors[hubID] ?? 0, try session.envelopeSeqCeiling())
            } catch {
                // Unreadable: a new session restarts its own ceiling (logged; the hub's re-link absorbs it).
                Self.logger.error("seq ceiling unreadable at the removal: \(error.localizedDescription, privacy: .public)")
            }
            let handover = await session.handOverRecordings(stoppedCapture: stoppedCapture, keep: keepRecordings)
            outcome = LocalWipe(
                notSent: Self.pendingActionCount(session) + handover.lost,
                stoppedRecording: handover.stoppedCaptureKept,
                problem: handover.problem
            )
            env.remove(hubID)
            // Audio the hold could not take may still be in the hub's
            // folder: its files stay for the next launch's orphan pass.
            filesFree = handover.problem == nil
        } else {
            // A hub whose session could not be built at launch: it leaves
            // the unopened list with its row, and nothing is deleted. Its
            // recordings were never handed over, so its files are an orphan
            // the next launch builds a session on, hands to the hold and
            // only then deletes (`HubBoot.removeOrphans`).
            if env.unopenedHubIDs.contains(hubID) {
                filesFree = false
            }
            env.remove(hubID)
        }
        linkChecks[hubID] = nil
        loggedUnreadableGrants.remove(hubID)
        DeviceSettings.removeChoices(of: hubID, defaults: defaults)
        if filesFree {
            do {
                try paths.removeHubFiles(hubID)
            } catch {
                // The row is gone: the next launch removes them as an orphan.
                Self.logger.error("hub files not removed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            Self.logger.error("hub files kept for the next launch: recordings not handed over")
        }
        for remaining in env.sessions.values {
            remaining.reloadHeldRecordings()
        }
        env.nameHubs(linkedHubs())
        return outcome
    }

    /// Saves `record` through `session`'s own transport and waits until it
    /// has left the send queue (`FarewellDelivery`), sending again while it
    /// waits. The whole wait races the cap: when the cap wins the removal
    /// goes on at once, and a send still running is left to the shutdown's
    /// `transport.stop()` to cancel. A failed save or the cap is logged.
    private func deliver(_ record: CloudRecord, through session: HubSession) async {
        do {
            try await session.linkTransport.save([record])
        } catch {
            Self.logger.warning("unlinked record not queued: \(error.localizedDescription, privacy: .public)")
            return
        }
        let delivery = farewellDelivery
        let race = FirstOf()
        let sending = Task { @MainActor in
            while !Task.isCancelled {
                await delivery.send(session)
                guard delivery.isPending(session, record) else { break }
                do {
                    try await Task.sleep(for: delivery.pause)
                } catch {
                    break
                }
            }
            race.finish(.send)
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: delivery.cap)
            race.finish(.cap)
        }
        let winner = await race.wait()
        sending.cancel()
        timer.cancel()
        if winner == .cap {
            Self.logger.warning("unlinked record still queued when the hub went: not sent")
        }
    }

    /// The first of two main-actor tasks to finish: the send loop or the
    /// cap. Later finishes do nothing.
    @MainActor
    private final class FirstOf {
        enum Winner { case send, cap }

        private var winner: Winner?
        private var waiter: CheckedContinuation<Winner, Never>?

        func finish(_ first: Winner) {
            guard winner == nil else { return }
            winner = first
            waiter?.resume(returning: first)
            waiter = nil
        }

        func wait() async -> Winner {
            if let winner { return winner }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    /// Outbox items still waiting for the Mac: what a removal loses besides
    /// recordings it could not keep ("Not sent").
    private static func pendingActionCount(_ session: HubSession) -> Int {
        do {
            return try session.store.pendingActions().filter { $0.state == .pending }.count
        } catch {
            logger.error("not-sent count failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

// MARK: - LinkHost

extension AppRoot: LinkHost {
    func linkedHubs() -> [HubRow] {
        do {
            return try registry.rows()
        } catch {
            Self.logger.error("hub registry unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Settings → Macs: `hubID` moves to `index` in the registry; the saved
    /// links and the sessions' order follow it.
    func moveHub(_ hubID: String, to index: Int) {
        do {
            try registry.move(hubID, to: index)
        } catch {
            Self.logger.error("hub not moved: \(error.localizedDescription, privacy: .public)")
            return
        }
        linking.refreshLinks()
        env.reorder(linking.links.map(\.hubID))
    }

    func prepare(scope: CloudDatabaseScope, hubID: String, fresh: Bool) async throws -> any CloudSyncTransport {
        guard HubPaths.isValidHubID(hubID) else { throw CocoaError(.fileWriteInvalidFileName) }
        // A removal of this hub still running decides what is left.
        _ = await removals[hubID]?.value
        let frozen = (try registry.row(hubID))?.state == .unlinkedByMac
        if let session = env.session(hubID) {
            if session.databaseScope == scope, !frozen, !fresh {
                return session.linkTransport
            }
            // Another database's zones, a hub the Mac removed, or a new
            // pairing: it starts again from empty files, its recordings held.
            let wipe = await removeHub(hubID, keepRecordings: true, farewell: nil)
            if let problem = wipe.problem {
                Self.logger.error("recordings at a rescan: \(problem, privacy: .public)")
            }
        }
        let session = try factory.make(nil, hubID, scope, nil)
        // Before anything is sealed (no await since the build): the seqs a
        // removal of this hub left in this process are never reused (F29).
        if let floor = seqFloors[hubID] {
            do {
                try session.raiseSeqFloor(floor)
            } catch {
                Self.logger.error("seq floor not carried: \(error.localizedDescription, privacy: .public)")
            }
        }
        wire(session)
        env.add(session)
        return session.linkTransport
    }

    func fetchKeybox(hubID: String, deviceID: String) async -> Keybox? {
        guard let session = env.session(hubID) else { return nil }
        await session.refresh(.link)
        return await storedKeybox(hubID: hubID, deviceID: deviceID)
    }

    func storedKeybox(hubID: String, deviceID: String) async -> Keybox? {
        guard let session = env.session(hubID) else { return nil }
        guard let id = UUID(uuidString: deviceID) else {
            Self.logger.error("keybox read for a device id that is not a UUID")
            return nil
        }
        do {
            return try session.keybox(deviceID: id)
        } catch {
            Self.logger.error("keybox read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func keysMerged(hubID: String) {
        env.session(hubID)?.indexStoredRows()
    }

    func linked(_ record: LinkRecord, device: LinkedDevice) async throws {
        guard let session = env.session(record.hubID) else { throw CancellationError() }
        try registry.upsert(record, now: Date())
        env.nameHubs(linkedHubs())
        session.deviceSettings.adoptUnlinkedChoices()
        // The held recordings of this hub are in its replica before the
        // device goes on: the upload of the waiting ones starts at once.
        _ = await session.adoption?.value
        await session.setLinkedDevice(device, writesAllowed: true)
        env.activate(record.hubID)
    }

    func devicePayload(hubID: String, for device: LinkedDevice, linkNonce: String?, unlinked: Bool, now: Date) -> DevicePayload {
        guard let session = env.session(hubID) else {
            Self.logger.warning("device record of a hub with no session: the default choices")
            return DevicePayload(
                deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion,
                scope: device.scope, userRecordName: device.userRecordName, linkNonce: linkNonce,
                unlinked: unlinked ? true : nil, typingRequested: false, startSessions: true, updatedAt: now
            )
        }
        return session.deviceSettings.devicePayload(for: device, linkNonce: linkNonce, unlinked: unlinked, now: now)
    }

    func removeHub(_ hubID: String, keepRecordings: Bool, farewell: CloudRecord?) async -> LocalWipe {
        if let running = removals[hubID] {
            _ = await running.value
            return LocalWipe()
        }
        let task = Task { await self.performRemoval(hubID, keepRecordings: keepRecordings, farewell: farewell) }
        removals[hubID] = task
        let outcome = await task.value
        removals[hubID] = nil
        return outcome
    }

    func markRemovedByMac(_ hubID: String) async {
        let endWork = startWork?("hub-remove")
        defer { endWork?() }
        let row: HubRow?
        do {
            row = try registry.row(hubID)
            try registry.setState(.unlinkedByMac, for: hubID)
        } catch {
            Self.logger.error("hub not marked removed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let row, let session = env.session(hubID) else { return }
        await session.freeze(as: identity.linkedDevice(for: row.link))
    }

    func setGrantMissingSince(_ date: Date?, hubID: String) {
        do {
            try registry.setGrantMissingSince(date, for: hubID)
        } catch {
            Self.logger.error("removal check's look not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestNotificationPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Self.logger.warning("notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openNow() {
        env.navigation.tab = .now
    }
}

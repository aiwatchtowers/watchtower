import Foundation
import Observation
import os
import UIKit
import UserNotifications
@_spi(DemoTransport) import WatchtowerSync

/// Why the environment could not boot (shown by `BootFailureView`).
enum AppEnvironmentError: LocalizedError {
    /// A signed build without its app group container: the notification
    /// extensions could never read the replica, so the app refuses to boot
    /// instead of silently keeping it somewhere else.
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared app group container is not available. Reinstall Watchtower."
        }
    }
}

/// Root object for the app (multi-hub spec §5.3): the app-wide parts (the
/// tab and the Calendar stack, the recaps seen, the app icon's badge) and
/// one `HubSession` per linked Mac, the one on screen among them. Injected
/// into the view tree with `.environment`; the per-hub API the views read
/// is forwarded to the active session, which the root always has while it
/// shows the tabs.
@MainActor
@Observable
final class AppEnvironment {
    /// The phone's app group (spec §2.1). The replica lives in its container
    /// so the notification extensions can read it.
    nonisolated static let appGroupID = "group.com.aiwatchtowers.watchtower.mobile"

    /// The transport every session runs on (`Boot.make` registers for
    /// pushes on the live one only).
    let transportKind: TransportKind
    /// The selected tab and the Calendar stack.
    let navigation = AppNavigation()
    /// The ready recaps the owner has opened on this phone.
    let recordingsSeen: RecordingsSeenStore
    /// Every hub's session, by hub id.
    private(set) var sessions: [String: HubSession] = [:]
    /// The sessions on screen, in the registry's order.
    private(set) var order: [String] = []
    /// The hub on screen; nil before one is activated.
    private(set) var activeHubID: String?
    /// Registry hubs with no session: one whose session could not be built
    /// (`live`, `AppRoot.reopenHubs`) or whose row cannot be read. Listed
    /// with their problem, offered Forget, never put on screen.
    private(set) var unopenedHubIDs: Set<String> = []

    /// The last active session after `remove` took it off screen with no
    /// hub left to activate: the forwarders read it (shut down, its data
    /// as it was) until another hub activates. Never synced or written.
    @ObservationIgnored private var retained: HubSession?
    /// Told of the hub a switch puts on screen (`activate`): the root
    /// re-evaluates the stale notice for it.
    @ObservationIgnored var onActivate: (@MainActor (HubSession) -> Void)?

    /// Persists the active hub; nil persists nothing (tests, the demo).
    @ObservationIgnored private let registry: HubRegistry?
    @ObservationIgnored private let setBadge: @MainActor (Int) -> Void
    /// The total the badge was last set to, or seeded with at init (the
    /// badge is not written for it: a launch never flashes 0).
    @ObservationIgnored private var badgeTotal: Int?
    /// The scene phase as `setActive` last had it: a session added later
    /// takes it too. nil before the first.
    @ObservationIgnored private var sceneActive: Bool? // swiftlint:disable:this discouraged_optional_boolean

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppEnvironment")

    /// `setBadge` sets the app icon's badge to the open asks across every
    /// hub (`openAskTotal`), called whenever that total changes.
    init(
        transportKind: TransportKind,
        defaults: UserDefaults,
        registry: HubRegistry? = nil,
        setBadge: @escaping @MainActor (Int) -> Void = AppEnvironment.setAppBadge
    ) {
        self.transportKind = transportKind
        self.registry = registry
        self.setBadge = setBadge
        recordingsSeen = RecordingsSeenStore(defaults: defaults)
        observeBadge()
    }

    /// One session, active: the tests and the boot until the registry
    /// holds the hubs.
    static func single(_ session: HubSession, defaults: UserDefaults) -> AppEnvironment {
        let env = AppEnvironment(transportKind: session.transportKind, defaults: defaults)
        env.add(session)
        env.activate(session.hubID)
        return env
    }

    // MARK: - Sessions

    /// The session on screen. The root never shows the tabs without one.
    var active: HubSession? { activeHubID.flatMap { sessions[$0] } }

    func session(_ hubID: String) -> HubSession? { sessions[hubID] }

    /// The switcher's and Settings → Macs' rows for the registry's `rows`
    /// and the hub ids of its `unreadable` ones (`HubListModel.items`), over
    /// these sessions.
    func hubListItems(_ rows: [HubRow], unreadable: [String] = [], now: Date) -> [HubListItem] {
        HubListModel.items(
            rows: rows, unreadable: unreadable, sessions: sessions, unopened: unopenedHubIDs, activeHubID: activeHubID, now: now
        )
    }

    /// Adds (or replaces) `session` at the end of the order, with the
    /// scene phase the others have and its role.
    func add(_ session: HubSession) {
        sessions[session.hubID] = session
        unopenedHubIDs.remove(session.hubID)
        if !order.contains(session.hubID) {
            order.append(session.hubID)
        }
        if let sceneActive {
            session.setActive(sceneActive)
        }
        applyRoles()
    }

    /// Drops a session the caller has already shut down. The caller
    /// activates another hub first when this one is on screen; otherwise
    /// no hub is active afterwards (never a dangling id), and the removed
    /// session is kept as `retained` until another hub activates: views
    /// still on screen while the root turns to onboarding read it through
    /// the forwarders instead of trapping.
    func remove(_ hubID: String) {
        if activeHubID == hubID {
            retained = sessions[hubID]
            activeHubID = nil
        }
        sessions[hubID] = nil
        unopenedHubIDs.remove(hubID)
        order.removeAll { $0 == hubID }
    }

    /// Lets go of the session `remove` kept (`retained`) once nothing reads
    /// it any more: the root calls it when Welcome (or the unopened Macs)
    /// replaced the tabs, so the removed hub's replica closes then rather
    /// than at the next activation (#222).
    func releaseRetained() {
        retained = nil
    }

    /// Whether `remove` keeps a session for the forwarders (tests).
    var holdsRetainedSession: Bool { retained != nil }

    /// Follows the registry's new order (Settings → Macs): the sessions
    /// listed, in that order; a hub missing from `hubIDs` keeps its place
    /// after them.
    func reorder(_ hubIDs: [String]) {
        let known = hubIDs.filter { sessions[$0] != nil }
        order = known + order.filter { !known.contains($0) }
    }

    /// Names every session as the switcher does (`HubDisplayName`), from
    /// the registry's `rows`: the recorder says which Mac a capture is for.
    func nameHubs(_ rows: [HubRow]) {
        let names = HubDisplayName.names(for: rows)
        for (hubID, session) in sessions {
            session.hubName = names[hubID]
        }
    }

    /// Puts `hubID`'s session on screen and keeps it as the active hub. A
    /// switch to another hub resets navigation to the root (multi-hub spec
    /// §5.6): no screen of the old hub stays pushed over the new one, and
    /// `onActivate` hears of the new hub. A hub with no session here (one
    /// whose session could not be built at launch) is never put on screen.
    func activate(_ hubID: String) {
        guard let session = sessions[hubID] else {
            Self.logger.error("a hub with no session was not activated")
            return
        }
        retained = nil
        let switched = activeHubID != hubID
        if switched {
            navigation.resetStacks()
        }
        activeHubID = hubID
        if switched {
            onActivate?(session)
        }
        if let registry {
            do {
                try registry.setActive(hubID)
            } catch {
                Self.logger.error("active hub not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        applyRoles()
    }

    /// The session on screen polls every minute, the others less often
    /// (`SessionCadence`). Before a hub is activated every session keeps
    /// its role, so `single` never flips a running session.
    private func applyRoles() {
        guard activeHubID != nil else { return }
        for (hubID, session) in sessions {
            session.setRole(hubID == activeHubID ? .active : .inactive)
        }
    }

    /// The scene phase, for every session: each pauses its safety poll
    /// while the app is not active and decides on the return whether to
    /// fetch (`HubSession.setActive`).
    func setActive(_ active: Bool) {
        sceneActive = active
        for hubID in order {
            sessions[hubID]?.setActive(active)
        }
    }

    /// One fetch of every session at once; true when any succeeded.
    @discardableResult
    func refreshAll(_ trigger: FetchTrigger) async -> Bool {
        let all = Array(sessions.values)
        return await withTaskGroup(of: Bool.self) { group in
            for session in all {
                group.addTask { await session.refresh(trigger) }
            }
            var fetched = false
            for await success in group where success {
                fetched = true
            }
            return fetched
        }
    }

    /// A silent push from `scope`'s database reaches the sessions linked
    /// there (every session when the scope is unknown, the demo always),
    /// each fetching it at once (`HubSession.handlePush`). The outcome is
    /// `.newData` when any brought something, `.failed` when every one
    /// failed, else `.noData`. The other sessions only note it: a push
    /// launching the app into the background leaves them unfetched until
    /// the first activation (`HubSession.noteForeignPush`).
    func handlePush(at arrival: Date? = nil, inForeground: Bool, scope: PushScope?) async -> FetchOutcome {
        var reached: [HubSession] = []
        for session in sessions.values {
            if let scope, let own = session.databaseScope, PushScope(own) != scope {
                session.noteForeignPush()
            } else {
                reached.append(session)
            }
        }
        guard !reached.isEmpty else { return .noData }
        let outcomes = await withTaskGroup(of: FetchOutcome.self) { group in
            for session in reached {
                group.addTask { await session.handlePush(at: arrival, inForeground: inForeground) }
            }
            var outcomes: [FetchOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
        if outcomes.contains(.newData) { return .newData }
        return outcomes.allSatisfy { $0 == .failed } ? .failed : .noData
    }

    /// Returns once every session's boot has ended.
    func waitForBoot() async {
        for session in sessions.values {
            await session.waitForBoot()
        }
    }

    // MARK: - The badge

    /// The open asks across every hub that can still answer them: the app
    /// icon's badge. A hub the Mac removed (frozen, writes off) cannot, so
    /// its asks are not counted.
    var openAskTotal: Int {
        sessions.values.filter(\.writesAllowed).reduce(0) { $0 + $1.workbenchReplica.openAskCount }
    }

    /// Sets the badge to `openAskTotal` when it changed from the last known
    /// total, and observes it again for the next change. The first call
    /// (the init's, before any session reports) only seeds the total.
    private func observeBadge() {
        let total = withObservationTracking {
            openAskTotal
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeBadge() }
        }
        guard let known = badgeTotal else {
            badgeTotal = total
            return
        }
        guard total != known else { return }
        badgeTotal = total
        setBadge(total)
    }

    /// The app's badge: the notification center's count.
    static func setAppBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                logger.error("badge not set: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - The active session, for the views

    /// What the forwarders below read: the active session, else the one
    /// `remove` took off screen last (`retained`, while the root turns to
    /// onboarding), else the first session (a link being made before any
    /// hub is active). Total once the environment has held a session: the
    /// last hub's removal never traps a view still reading it. Only an
    /// environment that never held one traps, and the root shows no tabs
    /// for it (onboarding reads none of these).
    var activeSession: HubSession {
        if let session = active ?? retained ?? order.first.flatMap({ sessions[$0] }) {
            return session
        }
        preconditionFailure("no hub session")
    }

    var store: ReplicaStore { activeSession.store }
    var outbox: ActionOutbox { activeSession.outbox }
    var reportRequests: SessionReportRequester { activeSession.reportRequests }
    var boardWriter: BoardWriter { activeSession.boardWriter }
    var askDrafts: AskDraftStore { activeSession.askDrafts }
    var askAnswerer: AskAnswerer { activeSession.askAnswerer }
    var sessionStarts: SessionStarter { activeSession.sessionStarts }
    var sessionInputs: SessionInputSender { activeSession.sessionInputs }
    var deviceSettings: DeviceSettings { activeSession.deviceSettings }
    var workbenchReplica: WorkbenchReplicaModel { activeSession.workbenchReplica }
    var calendarReplica: CalendarReplicaModel { activeSession.calendarReplica }
    var phoneRecordings: PhoneRecordingsModel { activeSession.phoneRecordings }
    /// The held recordings the active hub's Recordings list shows: its own
    /// not yet adopted, and those waiting for a Mac the phone no longer has
    /// (no session here) — never another linked hub's, which that hub's
    /// session adopts (multi-hub spec §5.4: the list shows the active hub's
    /// recordings). With one hub this is the whole hold, as before.
    var heldRecordings: [HeldRecording] {
        let active = activeSession
        return active.heldRecordings.filter { $0.hubID == active.hubID || sessions[$0.hubID] == nil }
    }
    var linkedDevice: LinkedDevice? { activeSession.linkedDevice }
    var lastSyncAt: Date? { activeSession.lastSyncAt }
    var isLooping: Bool { activeSession.isLooping }

    /// The session whose recorder owns the microphone or the recorder
    /// screen (`PhoneRecorderController.holdsMicrophoneOrScreen`: starting,
    /// capturing or paused, saving, or showing its result until closed),
    /// if any: a capturing one first, then the active hub's, then any. One
    /// microphone, so a second capture never starts beside it (multi-hub
    /// spec §5.4).
    var capturingSession: HubSession? {
        let all = order.compactMap { sessions[$0] }
        if let capturing = all.first(where: { $0.recorder.isCapturing }) { return capturing }
        if let active, active.recorder.holdsMicrophoneOrScreen { return active }
        return all.first { $0.recorder.holdsMicrophoneOrScreen }
    }

    /// The recorder on screen: the owning one (`capturingSession`),
    /// whichever hub it is for, else the active hub's. A capture started on
    /// one hub stays with it after a switch, through its save and its
    /// result until closed: its session saves it and its uploader sends it
    /// to that Mac, polling while the upload is pending (`SessionCadence`).
    var recorder: PhoneRecorderController { capturingSession?.recorder ?? activeSession.recorder }

    /// No recorder on any hub owns the microphone or the recorder screen:
    /// the Record buttons are on.
    var canStartCapture: Bool { capturingSession == nil }

    /// The Mac a running capture is for when that is not the hub on screen
    /// ("Recording for <name>" on the recorder); nil otherwise. A hub with
    /// no name yet reads "another Mac".
    var captureHubName: String? {
        guard let capturing = capturingSession, capturing.hubID != activeHubID else { return nil }
        return capturing.hubName ?? "another Mac"
    }

    /// Pull to refresh: the session on screen; with none (the last hub just
    /// removed), nothing is fetched.
    @discardableResult
    func refresh(_ trigger: FetchTrigger) async -> Bool {
        guard let active else { return false }
        return await active.refresh(trigger)
    }

    /// The recorder's "See recordings": closes the finished recorder and
    /// opens the Recordings list on the Calendar tab, of the hub the
    /// recording is for: a capture made for another Mac puts that Mac on
    /// screen first, as its list is the one that holds it.
    func showRecordings() {
        let owner = capturingSession
        recorder.close()
        if let owner, owner.hubID != activeHubID, sessions[owner.hubID] != nil {
            activate(owner.hubID)
        }
        navigation.showRecordings()
    }

    /// The active session's queue, sent now (`HubSession.sendNow`); with
    /// no hub on screen, nothing.
    func sendNow() async {
        await active?.sendNow()
    }

    // MARK: - Building the app's environment

    /// The live app on a signed build: one session per registry row, in
    /// the registry's order, each on its own files (`factory`). A row the
    /// Mac removed (`unlinked_by_mac`) is built frozen: stopped before its
    /// boot runs (no engine, no fetch, and no device until the freeze sets
    /// it with writes off), then frozen as a live removal freezes it
    /// (`HubSession.freeze(as:)`), its replica still readable. A row whose
    /// session cannot be built (its replica or transport store will not
    /// open) is logged and gets no session: the other hubs boot, and the
    /// switcher and Settings → Macs list it with its problem and offer
    /// Forget (multi-hub spec §6.3); a row that cannot be read is unopened
    /// too. The registry's active hub goes on screen when it has a session,
    /// else the first row that has one. With none on screen and Macs still
    /// in the registry, the root shows them with Forget and Try Again
    /// (`AppRoot.showsUnopenedMacs`, #222), never Welcome: the links still
    /// exist.
    static func live(
        registry: HubRegistry,
        paths _: HubPaths,
        factory: HubSessionFactory,
        identity: DeviceIdentity,
        defaults: UserDefaults,
        setBadge: @escaping @MainActor (Int) -> Void = AppEnvironment.setAppBadge
    ) throws -> AppEnvironment {
        let env = AppEnvironment(transportKind: .cloudKit, defaults: defaults, registry: registry, setBadge: setBadge)
        let rows = try registry.rows()
        for row in rows {
            do {
                env.add(try makeSession(for: row, factory: factory, identity: identity))
            } catch {
                env.markUnopened(row.hubID, error: error)
            }
        }
        env.unopenedHubIDs.formUnion(try registry.unreadableHubIDs())
        env.nameHubs(rows)
        let saved = try registry.activeHubID
        let opened = rows.filter { env.sessions[$0.hubID] != nil }
        if let active = opened.first(where: { $0.hubID == saved }) ?? opened.first {
            env.activate(active.hubID)
        }
        return env
    }

    /// A registry hub whose session could not be built: logged, listed
    /// unopened.
    func markUnopened(_ hubID: String, error: any Error) {
        Self.logger.error("hub session not built, the hub left unopened: \(error.localizedDescription, privacy: .public)")
        unopenedHubIDs.insert(hubID)
    }

    /// One registry row's session (see `live`; `AppRoot.reopenHubs` builds
    /// an unopened one again the same way).
    static func makeSession(for row: HubRow, factory: HubSessionFactory, identity: DeviceIdentity) throws -> HubSession {
        let device = identity.linkedDevice(for: row.link)
        guard row.state == .unlinkedByMac else {
            let session = try factory.make(row, row.hubID, row.link.databaseScope, device)
            // A hub without stored link keys (made before E2E) is built
            // stopped, before its boot runs: no engine, no fetch, no send;
            // the launch's `dropUnencryptedLinks` removes it.
            if session.transportKind == .cloudKit, !session.startsEngine {
                session.stop()
            }
            return session
        }
        let session = try factory.make(row, row.hubID, row.link.databaseScope, nil)
        session.stop()
        Task { await session.freeze(as: device) }
        return session
    }

    /// The demo on an unsigned build (simulator, CI): one session over the
    /// in-memory transport with DemoSeed, its replica in Application
    /// Support. `recordingsDirectory` is for tests: nil keeps the phone's
    /// own recordings folder.
    static func demoSingle(recordingsDirectory: URL? = nil, energy: EnergyCounter? = nil) throws -> AppEnvironment {
        let session = try demoSession(DemoSeed.primary, recordingsDirectory: recordingsDirectory, energy: energy)
        return single(session, defaults: .standard)
    }

    /// The demo as the app shows it: the two demo Macs (`DemoSeed.hubs`),
    /// each its own session on its own in-memory transport and replica,
    /// the primary on screen (multi-hub spec §7).
    static func demo(recordingsDirectory: URL? = nil, energy: EnergyCounter? = nil) throws -> AppEnvironment {
        let env = AppEnvironment(transportKind: .inMemoryDemo, defaults: .standard)
        for hub in DemoSeed.hubs {
            env.add(try demoSession(hub, recordingsDirectory: recordingsDirectory, energy: energy))
        }
        env.activate(DemoSeed.primary.hubID)
        return env
    }

    /// One demo Mac's session. The primary keeps today's replica file; the
    /// others get their own, and a recordings folder of their own.
    private static func demoSession(_ hub: DemoSeed.Hub, recordingsDirectory: URL?, energy: EnergyCounter?) throws -> HubSession {
        let base = try recordingsDirectory ?? PhoneRecorderController.defaultDirectory()
        let isPrimary = hub == DemoSeed.primary
        let recordings = isPrimary ? base : base.appendingPathComponent(hub.hubID, isDirectory: true)
        let replica = isPrimary ? "replica.sqlite" : "replica-\(hub.hubID).sqlite"
        return try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try applicationSupportDirectory().appendingPathComponent(replica).path,
            transportKind: .inMemoryDemo,
            hubID: hub.hubID,
            recordingsDirectory: recordings,
            hold: RecordingHold(directory: base.appendingPathComponent(".held", isDirectory: true)),
            startsActive: UIApplication.shared.applicationState == .active,
            energy: energy
        )
    }

    /// The CloudKit transport's store file.
    nonisolated static let transportStoreFileName = "cloudkit-transport.sqlite"

    /// The live CloudKit transport's store, in the app's own Application
    /// Support: outside the app group, which no extension reads it from,
    /// because CKSyncEngine writes it from its own callbacks at any moment —
    /// a lock on a file in the shared container when iOS suspends the app
    /// gets it killed (0xdead10cc). A store an earlier build kept in the
    /// app group moves over once (`moveTransportStore`), on the process's
    /// first call: every later call returns the same path without moving,
    /// so no move ever runs under a store this process has opened.
    nonisolated static func liveTransportStorePath() throws -> String {
        try liveTransportStore.path()
    }

    nonisolated private static let liveTransportStore = TransportStorePathResolver {
        try moveTransportStore(from: appGroupDirectory(), to: applicationSupportDirectory())
    }

    /// Moves the transport store (`transportStoreFileName` and its SQLite
    /// `-wal`, `-shm` and `-journal` files) from `old` into `new` unless
    /// `new` already has one, and returns the path to open. The side files
    /// go first and the database last, so a database in `new` means the
    /// move is complete. A failed move puts back what it moved and keeps
    /// the old path for this launch (the next launch tries again). Stashed
    /// asset files (`transport-assets`) stay where they are: the store
    /// refers to them by absolute path, and none is a database.
    nonisolated static func moveTransportStore(from old: URL, to new: URL) -> String {
        let fileManager = FileManager.default
        let name = transportStoreFileName
        let oldMain = old.appendingPathComponent(name)
        let newMain = new.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: oldMain.path) else { return newMain.path }
        guard !fileManager.fileExists(atPath: newMain.path) else {
            logger.warning("transport store in both places: the app's own copy is used")
            return newMain.path
        }
        var moved: [(from: URL, to: URL)] = []
        do {
            for suffix in ["-wal", "-shm", "-journal"] {
                let from = old.appendingPathComponent(name + suffix)
                guard fileManager.fileExists(atPath: from.path) else { continue }
                let target = new.appendingPathComponent(name + suffix)
                // A side file left in `new` by an earlier attempt belongs to
                // no database there: the old one's is the live one.
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.moveItem(at: from, to: target)
                moved.append((from, target))
            }
            try fileManager.moveItem(at: oldMain, to: newMain)
            logger.notice("transport store moved out of the app group")
            return newMain.path
        } catch {
            logger.error("transport store not moved: \(error.localizedDescription, privacy: .public)")
            for file in moved.reversed() {
                do {
                    try fileManager.moveItem(at: file.to, to: file.from)
                } catch {
                    logger.fault("transport store side file not put back: \(error.localizedDescription, privacy: .public)")
                }
            }
            return oldMain.path
        }
    }

    /// The app group container's Application Support directory. A signed
    /// build without it throws instead of falling back silently.
    nonisolated static func appGroupDirectory() throws -> URL {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.fault("app group container \(appGroupID, privacy: .public) is unavailable")
            throw AppEnvironmentError.appGroupUnavailable
        }
        return try prepareLiveDirectory(group.appendingPathComponent("Library/Application Support", isDirectory: true))
    }

    /// Creates the live directory with its class (D8) before any database in it: the replica and the transport
    /// store hold ciphertext that background hydration and the notification extension reach after the first
    /// unlock (class C); every file SQLite creates there inherits it.
    nonisolated static func prepareLiveDirectory(_ directory: URL) throws -> URL {
        try FileProtection.protectDirectory(directory)
        return directory
    }

    /// A live CloudKit transport's store at `path` (`HubPaths.transportStorePath`): its folder and its incoming
    /// asset stash (sealed files) take class C (D8) before the store opens, wherever the store lives.
    static func liveTransportStore(path: String) throws -> TransportStore {
        try FileProtection.protectDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        let store = try TransportStore(path: path)
        if let stash = store.stashDirectory {
            try FileProtection.protectDirectory(stash)
        }
        return store
    }

    /// Unsigned builds keep the replica in Application Support, which an
    /// uninstall removes (spec §10).
    nonisolated static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}

/// Resolves a path once per instance: the first successful `path()` runs
/// `resolve` (the transport store's move), every later call returns its
/// result. A throwing resolve caches nothing.
final class TransportStorePathResolver: Sendable {
    private let resolved = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let resolve: @Sendable () throws -> String

    init(_ resolve: @escaping @Sendable () throws -> String) {
        self.resolve = resolve
    }

    func path() throws -> String {
        try resolved.withLock { cached in
            if let cached { return cached }
            let path = try resolve()
            cached = path
            return path
        }
    }
}

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

    /// Persists the active hub; nil persists nothing (tests, the demo).
    @ObservationIgnored private let registry: HubRegistry?
    @ObservationIgnored private let setBadge: @MainActor (Int) -> Void
    /// The total the badge was last set to.
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

    /// Adds (or replaces) `session` at the end of the order, with the
    /// scene phase the others have and its role.
    func add(_ session: HubSession) {
        sessions[session.hubID] = session
        if !order.contains(session.hubID) {
            order.append(session.hubID)
        }
        if let sceneActive {
            session.setActive(sceneActive)
        }
        applyRoles()
    }

    /// Drops a session the caller has already shut down.
    func remove(_ hubID: String) {
        sessions[hubID] = nil
        order.removeAll { $0 == hubID }
    }

    /// Puts `hubID`'s session on screen and keeps it as the active hub.
    func activate(_ hubID: String) {
        activeHubID = hubID
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
    /// failed, else `.noData`.
    func handlePush(at arrival: Date? = nil, inForeground: Bool, scope: PushScope?) async -> FetchOutcome {
        let reached = sessions.values.filter { session in
            guard let scope, let own = session.databaseScope else { return true }
            return PushScope(own) == scope
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

    /// The open asks across every hub: the app icon's badge.
    var openAskTotal: Int {
        sessions.values.reduce(0) { $0 + $1.workbenchReplica.openAskCount }
    }

    /// Sets the badge to `openAskTotal` when it changed, and observes it
    /// again for the next change.
    private func observeBadge() {
        let total = withObservationTracking {
            openAskTotal
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeBadge() }
        }
        guard total != badgeTotal else { return }
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

    /// `active` where one must exist: the root never shows the tabs, nor
    /// runs the link flow, without an active session.
    var activeSession: HubSession {
        guard let active else { preconditionFailure("no active hub session") }
        return active
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
    var heldRecordings: [HeldRecording] { activeSession.heldRecordings }
    var linkedDevice: LinkedDevice? { activeSession.linkedDevice }
    var lastSyncAt: Date? { activeSession.lastSyncAt }
    var isLooping: Bool { activeSession.isLooping }

    /// The session whose recorder is capturing, if any.
    var capturingSession: HubSession? {
        order.lazy.compactMap { self.sessions[$0] }.first { $0.recorder.isCapturing }
    }

    /// The recorder on screen: a running capture's, else the active hub's.
    var recorder: PhoneRecorderController { capturingSession?.recorder ?? activeSession.recorder }

    /// Pull to refresh: the session on screen.
    @discardableResult
    func refresh(_ trigger: FetchTrigger) async -> Bool {
        await activeSession.refresh(trigger)
    }

    /// The recorder's "See recordings": closes the finished recorder and
    /// opens the Recordings list on the Calendar tab.
    func showRecordings() {
        recorder.close()
        navigation.showRecordings()
    }

    /// The active session's queue, sent now (`HubSession.sendNow`).
    func sendNow() async {
        await activeSession.sendNow()
    }

    // MARK: - Building the app's environment

    /// The live app on a signed build: one session on today's files (the
    /// replica in the app group, the transport store in the app's own
    /// Application Support, `phone-recordings` with its hold), running
    /// `hubID`'s zones in `scope`'s database linked as `linkedDevice`.
    /// `energy` counts the fetches, the CloudKit requests and the upload
    /// attempts (nil counts nothing).
    static func liveSingle(
        scope: CloudDatabaseScope,
        hubID: String,
        linkedDevice: LinkedDevice?,
        energy: EnergyCounter?
    ) throws -> AppEnvironment {
        let directory = try appGroupDirectory()
        let transportStore = try TransportStore(path: try liveTransportStorePath())
        let recordings = try PhoneRecorderController.defaultDirectory()
        let active = UIApplication.shared.applicationState == .active
        let session = try HubSession(
            transport: CloudKitTransport(store: transportStore, scope: scope, hubID: hubID, role: .phone, energy: energy),
            replicaPath: liveReplicaPath(in: directory),
            transportKind: .cloudKit,
            hubID: hubID,
            linkedDevice: linkedDevice,
            recordingsDirectory: recordings,
            hold: RecordingHold(directory: recordings.appendingPathComponent(".held", isDirectory: true)),
            databaseScope: scope,
            startsActive: active,
            uploadRetriesAllowed: active,
            replicaObservesSuspension: true,
            energy: energy,
            startWork: BackgroundWork.starter()
        )
        return single(session, defaults: .standard)
    }

    /// The demo on an unsigned build (simulator, CI): one session over the
    /// in-memory transport with DemoSeed, its replica in Application
    /// Support. `recordingsDirectory` is for tests: nil keeps the phone's
    /// own recordings folder.
    static func demoSingle(recordingsDirectory: URL? = nil, energy: EnergyCounter? = nil) throws -> AppEnvironment {
        let recordings = try recordingsDirectory ?? PhoneRecorderController.defaultDirectory()
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try applicationSupportDirectory().appendingPathComponent("replica.sqlite").path,
            transportKind: .inMemoryDemo,
            recordingsDirectory: recordings,
            hold: RecordingHold(directory: recordings.appendingPathComponent(".held", isDirectory: true)),
            startsActive: UIApplication.shared.applicationState == .active,
            energy: energy
        )
        return single(session, defaults: .standard)
    }

    /// The live replica's file in the app group directory.
    static func liveReplicaPath(in directory: URL) -> String {
        directory.appendingPathComponent("replica.sqlite").path
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
        let directory = group.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

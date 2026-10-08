import Foundation
import Observation
import os
import WatchtowerSync

/// Which transport an `AppEnvironment` runs on: probed in `init()`,
/// injectable through the designated init for tests. `.cloudKit` NEVER
/// seeds: a real install starts empty and hydrates from the user's own zone.
enum TransportKind: String, Sendable {
    case cloudKit
    case inMemoryDemo
}

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

/// Root object for the app: owns the on-device replica, the hydrator that
/// pulls DataZone into it, and the relay pair (`ActionOutbox` out,
/// `RelayFeed` echoes in) over the same transport and store. Injected into
/// the view tree with `.environment`. Owned for the app's lifetime, so its
/// loop and in-flight work survive any navigation.
///
/// One fetch loop drives both consumers: each cycle hydrates DataZone (the
/// hydrator's pull nudges the CKSyncEngine once) and then reads RelayZone.
/// Its cadence follows the selected tab (spec §3) and it pauses while the
/// app is in the background, whatever background mode keeps it alive.
@MainActor
@Observable
final class AppEnvironment {
    /// The phone's app group (spec §2.1). The replica lives in its container
    /// so the notification extensions can read it.
    nonisolated static let appGroupID = "group.com.aiwatchtowers.watchtower.mobile"

    let store: ReplicaStore
    let transportKind: TransportKind
    let outbox: ActionOutbox
    let deviceSettings: DeviceSettings
    /// The Workbench slices as the Now and Workbench tabs and the tab badge
    /// draw them: one observation for the app's lifetime.
    let workbenchReplica = WorkbenchReplicaModel()

    /// This phone's link, nil until the link flow (Task 12) sets one. The
    /// demo transport is linked to `DemoSeed.device`.
    private(set) var linkedDevice: LinkedDevice?

    /// When the phone last fetched from the Mac successfully (Settings →
    /// Your Mac → Last sync); nil before the first successful fetch.
    private(set) var lastSyncAt: Date?

    /// The loop's cadence: 5 s on Now and Workbench, 30 s otherwise.
    private(set) var fetchInterval: Duration = .seconds(30)
    /// false while the app is in the background: the loop is paused.
    private(set) var isActive = true
    /// true while the fetch loop runs.
    var isLooping: Bool { loopTask != nil }

    @ObservationIgnored private let transport: any CloudSyncTransport
    @ObservationIgnored private let hydrator: ReplicaHydrator
    @ObservationIgnored private let feed: RelayFeed
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var stopped = false

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppEnvironment")

    /// TRANSPORT SWITCH: a build carrying the iCloud entitlement (signed
    /// device or TestFlight build) goes live over CloudKit, in the app group
    /// container; anything else (unsigned simulator and CI builds) runs the
    /// in-memory demo transport with DemoSeed.
    convenience init() throws {
        if CloudKitTransport.entitlementPresent() {
            let directory = try Self.appGroupDirectory()
            let transportStore = try TransportStore(path: directory.appendingPathComponent("cloudkit-transport.sqlite").path)
            try self.init(
                transport: CloudKitTransport(store: transportStore),
                replicaPath: directory.appendingPathComponent("replica.sqlite").path,
                transportKind: .cloudKit
            )
        } else {
            try self.init(
                transport: InMemoryCloudTransport(),
                replicaPath: try Self.applicationSupportDirectory().appendingPathComponent("replica.sqlite").path,
                transportKind: .inMemoryDemo
            )
        }
    }

    /// Designated init with an injectable transport and replica path, so
    /// wiring tests build isolated environments. Throws when the replica
    /// cannot open (the app then shows `BootFailureView`).
    init(
        transport: any CloudSyncTransport,
        replicaPath: String,
        transportKind: TransportKind = .inMemoryDemo,
        defaults: UserDefaults = .standard
    ) throws {
        assert(
            !(transport is CloudKitTransport && transportKind == .inMemoryDemo),
            "a CloudKitTransport must not run under the demo kind"
        )
        store = try ReplicaStore(path: replicaPath)
        self.transport = transport
        self.transportKind = transportKind
        let device = transportKind == .inMemoryDemo ? DemoSeed.device : nil
        linkedDevice = device

        // On the live path the hydrator nudges the CKSyncEngine before each
        // cycle; the feed reads what that fetch buffered, so it gets no pull
        // of its own. An in-memory stand-in has no engine and gets nil.
        let pull: (@Sendable () async throws -> Void)? = (transport as? CloudKitTransport)
            .map { cloud in { @Sendable in try await cloud.pull() } }
        let hydrator = ReplicaHydrator(transport: transport, store: store, pull: pull)
        self.hydrator = hydrator
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: device?.deviceID)
        self.outbox = outbox
        // An `applied` echo clears the queued row; hydrating right behind it
        // lands the Mac's authoritative change at the same moment.
        let hydrateAfterEcho: @Sendable () async -> Void = { [hydrator] in
            do {
                _ = try await hydrator.hydrateOnce()
            } catch {
                Self.logger.warning("post-echo hydrate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        feed = RelayFeed(transport: transport, store: store, outbox: outbox, onActionApplied: hydrateAfterEcho)
        let settings = DeviceSettings(transport: transport, defaults: defaults)
        settings.linkedDevice = device
        deviceSettings = settings
        workbenchReplica.start(store: store)

        bootstrapTask = Task { await bootstrap() }
    }

    /// Demo seed or engine start, a first fetch so the screens have content
    /// at once, then the fetch loop.
    private func bootstrap() async {
        switch transportKind {
        case .inMemoryDemo:
            #if DEBUG
            do {
                // Each launch builds a new in-memory transport whose change
                // cursor restarts, so the persisted replica's tokens must be
                // forgotten or the fresh seed never lands.
                try store.resetSyncTokens()
                try await DemoSeed.load(into: transport)
            } catch {
                Self.logger.error("DemoSeed failed: \(error.localizedDescription, privacy: .public)")
            }
            #endif
        case .cloudKit:
            if let cloud = transport as? CloudKitTransport {
                await cloud.start()
            }
        }
        await refresh()
        // An action the Mac never answered within 24 h is failed locally, so
        // the queued count never counts it forever.
        do {
            try await outbox.sweepSilentPending()
        } catch {
            Self.logger.warning("silent-pending sweep failed: \(error.localizedDescription, privacy: .public)")
        }
        bootstrapped = true
        restartLoop()
    }

    /// One fetch: DataZone, then RelayZone echoes. Returns false when the
    /// data fetch failed. Used by the loop, silent pushes and pull to
    /// refresh; every success stamps `lastSyncAt`.
    @discardableResult
    func refresh() async -> Bool {
        do {
            _ = try await hydrator.hydrateOnce()
        } catch {
            Self.logger.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        lastSyncAt = Date()
        do {
            _ = try await feed.pollOnce()
        } catch {
            Self.logger.error("relay fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// The selected tab sets the loop's cadence (spec §3).
    func setFetchInterval(_ interval: Duration) {
        guard interval != fetchInterval else { return }
        fetchInterval = interval
        restartLoop()
    }

    /// Scene phase: the loop pauses in the background and resumes, with an
    /// immediate fetch, when the app is active again.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        restartLoop()
    }

    /// Stops the loop for good (tests' teardown; the app never stops).
    func stop() {
        stopped = true
        bootstrapTask?.cancel()
        loopTask?.cancel()
        loopTask = nil
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        guard bootstrapped, isActive, !stopped else { return }
        let interval = fetchInterval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// The app group container's Application Support directory. A signed
    /// build without it throws instead of falling back silently.
    private static func appGroupDirectory() throws -> URL {
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
    private static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}

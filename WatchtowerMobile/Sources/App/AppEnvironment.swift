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

/// Root object for the app: owns the on-device replica, the hydrator that
/// pulls DataZone into it, and the relay pair (`ActionOutbox` out,
/// `RelayFeed` echoes in) over the same transport and store. Injected into
/// the view tree with `.environment`. Owned for the app's lifetime, so its
/// loops and in-flight work survive any navigation.
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

    /// This phone's link, nil until the link flow (Task 12) sets one. The
    /// demo transport is linked to `DemoSeed.device`.
    private(set) var linkedDevice: LinkedDevice?

    /// When the phone last fetched from the Mac successfully (Settings →
    /// Your Mac → Last sync); nil before the first successful cycle.
    private(set) var lastSyncAt: Date?

    @ObservationIgnored private let transport: any CloudSyncTransport
    @ObservationIgnored private let hydrator: ReplicaHydrator
    @ObservationIgnored private let feed: RelayFeed
    /// The hydrator's cadence (spec §3: 5 s on Now and Workbench, 30 s
    /// otherwise), driven by the selected tab.
    @ObservationIgnored private var fetchInterval: Duration = .seconds(30)
    @ObservationIgnored private var loopsStarted = false

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppEnvironment")

    /// TRANSPORT SWITCH: a build carrying the iCloud entitlement (signed
    /// device or TestFlight build) goes live over CloudKit, in the app group
    /// container; anything else (unsigned simulator and CI builds) runs the
    /// in-memory demo transport with DemoSeed.
    convenience init() throws {
        if CloudKitTransport.entitlementPresent() {
            let directory = Self.storageDirectory(appGroup: true)
            let transportStore = try TransportStore(path: directory.appendingPathComponent("cloudkit-transport.sqlite").path)
            try self.init(
                transport: CloudKitTransport(store: transportStore),
                replicaPath: directory.appendingPathComponent("replica.sqlite").path,
                transportKind: .cloudKit
            )
        } else {
            try self.init(
                transport: InMemoryCloudTransport(),
                replicaPath: Self.storageDirectory(appGroup: false).appendingPathComponent("replica.sqlite").path,
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

        // On the live path both consumers nudge the CKSyncEngine before
        // reading; an in-memory stand-in has no engine and gets nil.
        let pull: (@Sendable () async throws -> Void)? = (transport as? CloudKitTransport)
            .map { cloud in { @Sendable in try await cloud.pull() } }
        let hydrator = ReplicaHydrator(transport: transport, store: store, pull: pull)
        self.hydrator = hydrator
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: device?.deviceID)
        self.outbox = outbox
        feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            pull: pull
        ) { [hydrator] in
            // An `applied` echo clears the queued row; hydrating right behind
            // it lands the Mac's authoritative change at the same moment.
            do {
                _ = try await hydrator.hydrateOnce()
            } catch {
                Self.logger.warning("post-echo hydrate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let settings = DeviceSettings(transport: transport, defaults: defaults)
        settings.linkedDevice = device
        deviceSettings = settings

        Task { await bootstrap() }
    }

    /// Demo seed or engine start, a first fetch so the screens have content
    /// at once, then the background loops.
    private func bootstrap() async {
        switch transportKind {
        case .inMemoryDemo:
            #if DEBUG
            do {
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
        loopsStarted = true
        await hydrator.start(interval: fetchInterval)
        await feed.start()
    }

    /// One fetch on demand (silent push, pull to refresh).
    func refresh() async {
        do {
            _ = try await hydrator.hydrateOnce()
            lastSyncAt = Date()
        } catch {
            Self.logger.error("fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The selected tab sets the foreground fetch cadence (spec §3).
    func setFetchInterval(_ interval: Duration) {
        guard interval != fetchInterval else { return }
        fetchInterval = interval
        guard loopsStarted else { return }
        Task { await hydrator.start(interval: interval) }
    }

    /// Application Support, or the app group container when `appGroup` is
    /// set and the build carries the group entitlement. Unsigned builds stay
    /// in Application Support, which an uninstall removes (spec §10).
    private static func storageDirectory(appGroup: Bool) -> URL {
        if appGroup, let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let directory = group.appendingPathComponent("Library/Application Support", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            } catch {
                logger.error("app group directory unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
    }
}

import Foundation
import Observation
import WatchtowerKit

/// Root object for the app: owns the on-device replica (`ReplicaStore`) and the
/// `ReplicaHydrator` that pulls DataZone changes into it. Injected into the view
/// tree via `.environment` and read by the per-tab view models.
@MainActor
@Observable
public final class AppEnvironment {
    /// The local mirror every tab reads through (`fetchAll` / ValueObservation).
    public let store: ReplicaStore

    /// v1 wiring: an in-memory transport seeded with demo data (`DemoSeed`).
    ///
    /// TRANSPORT SWAP POINT — when the CloudKit entitlements land (packaging
    /// plan), the swap is these four steps, all local to this file:
    ///   1. `let transportStore = try TransportStore(path: …/cloudkit-transport.sqlite)`
    ///   2. `let transport = CloudKitTransport(store: transportStore)`,
    ///      plus `await transport.start()` in `bootstrap`
    ///   3. pass `pull: { try await transport.pull() }` to the ReplicaHydrator
    ///      (the hook exists for exactly this)
    ///   4. update `transportLabel`
    /// Everything downstream already talks to the `CloudSyncTransport`
    /// protocol, not the concrete type. Plan 4 note: the actions producer
    /// will need `save` access into `.relay` — expose the transport (or add
    /// a Kit-side action queue) rather than reaching into this `private let`.
    private let transport: any CloudSyncTransport
    private let hydrator: ReplicaHydrator

    /// Human-readable name of the connected transport, shown in Settings.
    public let transportLabel = "demo"

    /// Result of the most recent hydration cycle (records applied / deleted).
    public private(set) var lastHydrate: (applied: Int, deleted: Int)?
    /// True while a hydration cycle is in flight — drives the sync footer spinner.
    public private(set) var isHydrating = false

    public init() {
        do {
            store = try ReplicaStore(path: Self.replicaPath())
        } catch {
            fatalError("failed to open replica store: \(error)")
        }

        // TRANSPORT SWAP POINT (see the four-step doc comment above).
        let transport = InMemoryCloudTransport()
        self.transport = transport
        hydrator = ReplicaHydrator(transport: transport, store: store)

        Task { await bootstrap(transport: transport) }
    }

    /// Seeds demo data (DEBUG only), runs a first hydration cycle so the tabs
    /// have content immediately, then starts the background poll loop.
    private func bootstrap(transport: any CloudSyncTransport) async {
        #if DEBUG
        do {
            try await DemoSeed.load(into: transport)
        } catch {
            print("DemoSeed failed: \(error)")
        }
        #endif
        await refresh()
        await hydrator.start()
    }

    /// Runs one hydration cycle on demand (also used by pull-to-refresh later).
    public func refresh() async {
        isHydrating = true
        defer { isHydrating = false }
        do {
            lastHydrate = try await hydrator.hydrateOnce()
        } catch {
            print("hydration failed: \(error)")
        }
    }

    private static func replicaPath() -> String {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("replica.sqlite").path
    }
}

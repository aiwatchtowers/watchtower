import Foundation
import Observation
import os
import WatchtowerKit

/// Root object for the app: owns the on-device replica (`ReplicaStore`), the
/// `ReplicaHydrator` that pulls DataZone changes into it, and the relay pair —
/// `ActionOutbox` (quick actions out) + `RelayFeed` (echoes/heartbeat/chat in),
/// both over the SAME transport and store (Plan 4 decision 2: the app never
/// touches the transport directly). Injected into the view tree via
/// `.environment` and read by the per-tab view models.
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
    ///      AND to the RelayFeed (both hooks exist for exactly this)
    ///   4. update `transportLabel`
    /// Everything downstream already talks to the `CloudSyncTransport`
    /// protocol, not the concrete type.
    private let transport: any CloudSyncTransport
    private let hydrator: ReplicaHydrator

    /// The phone's action producer: view models enqueue quick actions here;
    /// the pending overlay rows it writes drive the optimistic UI.
    public let outbox: ActionOutbox

    /// The phone's SINGLE relay consumer (Plan 4 decision 3): routes desktop
    /// action echoes into `outbox.applyEcho` and heartbeats into the store.
    /// Internal so wiring tests can drive a deterministic `pollOnce`; the
    /// chat assembler seam stays nil until Task 7 ships the Chat tab.
    let feed: RelayFeed

    /// Daily silent-pending sweep loop; lives as long as the environment.
    private var sweepTask: Task<Void, Never>?

    /// Human-readable name of the connected transport, shown in Settings.
    public let transportLabel = "demo"

    /// Result of the most recent hydration cycle (records applied / deleted).
    public private(set) var lastHydrate: (applied: Int, deleted: Int)?
    /// True while a hydration cycle is in flight — drives the sync footer spinner.
    public private(set) var isHydrating = false

    // nonisolated: logged from @Sendable hook/sweep closures off the actor.
    private nonisolated static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppEnvironment")

    public convenience init() {
        // TRANSPORT SWAP POINT (see the four-step doc comment above).
        self.init(transport: InMemoryCloudTransport(), replicaPath: Self.replicaPath())
    }

    /// Designated init with an injectable transport + replica path — wiring
    /// tests build isolated environments; production uses `init()` above.
    init(transport: any CloudSyncTransport, replicaPath: String) {
        do {
            store = try ReplicaStore(path: replicaPath)
        } catch {
            fatalError("failed to open replica store: \(error)")
        }

        self.transport = transport
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        self.hydrator = hydrator
        let outbox = ActionOutbox(transport: transport, store: store)
        self.outbox = outbox
        feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            // The flicker-window mitigation: an `applied` echo clears the
            // optimistic overlay, and without a nudge the row would show its
            // STALE pre-action state until the hydrator's next 30 s poll.
            // Hydrating right behind the echo lands the authoritative slice
            // change as the chip disappears. Errors only log — the regular
            // poll loop retries within seconds anyway.
            onActionApplied: { [hydrator] in
                do {
                    _ = try await hydrator.hydrateOnce()
                } catch {
                    Self.logger.warning("post-echo hydrate nudge failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        )

        Task { await bootstrap(transport: transport) }
    }

    /// Seeds demo data (DEBUG only), runs a first hydration cycle so the tabs
    /// have content immediately, then starts the background loops (data-zone
    /// hydration, relay feed, silent-pending sweep).
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
        await feed.start()
        scheduleSilentPendingSweep()
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

    /// Sweep scheduling decision: one sweep at every launch plus a 24 h
    /// in-process loop. The launch sweep is the trigger that actually fires in
    /// practice — iOS suspends the process in the background, so a wall-clock
    /// daily timer would never tick there; the loop only matters for
    /// pathological always-foreground sessions. A sweep flips >24 h silent
    /// pending rows to `failed` locally so the user learns instead of
    /// trusting a stale chip (`ActionOutbox.sweepSilentPending`).
    private func scheduleSilentPendingSweep() {
        guard sweepTask == nil else { return }
        sweepTask = Task { [outbox = self.outbox] in
            while !Task.isCancelled {
                do {
                    let swept = try await outbox.sweepSilentPending()
                    if !swept.isEmpty {
                        Self.logger.notice("silent-pending sweep failed \(swept.count) action(s) locally")
                    }
                } catch {
                    Self.logger.warning("silent-pending sweep failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: .seconds(86_400))
            }
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

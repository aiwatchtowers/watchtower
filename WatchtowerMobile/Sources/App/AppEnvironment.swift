import Foundation
import Observation
import os
import WatchtowerKit

/// Which transport an `AppEnvironment` runs on. Probed in `init()`
/// (Plan 6 Decision 1), injectable through the designated init for tests.
/// Drives `transportLabel`, the Settings "Sync" row, and the DemoSeed gate —
/// `.cloudKit` NEVER seeds (Decision 2: real installs start empty and
/// hydrate from the user's own zone).
public enum TransportKind: String, Sendable {
    case cloudKit
    case inMemoryDemo
}

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

    /// TRANSPORT SWAP POINT — live since Plan 6 Task 2. `init()` probes the
    /// process's iCloud entitlement (`CloudKitTransport.entitlementPresent`)
    /// and picks:
    ///   - entitled (signed device/TestFlight builds): `TransportStore` at
    ///     …/cloudkit-transport.sqlite + `CloudKitTransport`, `start()`ed in
    ///     `bootstrap`, with its `pull` wired into the ReplicaHydrator AND
    ///     the RelayFeed (see the designated init);
    ///   - not entitled (unsigned sim/CI builds): `InMemoryCloudTransport`
    ///     seeded with demo data — the pre-swap behavior, unchanged.
    /// Everything downstream talks to the `CloudSyncTransport` protocol,
    /// not the concrete type; `transportKind` records which branch won.
    private let transport: any CloudSyncTransport

    /// Which branch of the swap this environment runs on — drives
    /// `transportLabel`, the Settings "Sync" row, and the DemoSeed gate.
    public let transportKind: TransportKind
    private let hydrator: ReplicaHydrator

    /// The phone's action producer: view models enqueue quick actions here;
    /// the pending overlay rows it writes drive the optimistic UI.
    public let outbox: ActionOutbox

    /// The recording upload state machine (Workstream 1): the recorder
    /// controller registers finalized captures here; the feed routes hub
    /// acks back; the local file is deleted only on a `received` ack.
    public let recordingUploader: RecordingUploader

    /// Phone audio capture (Recordings tab). Owned HERE for the app's
    /// lifetime (async-ops-survive-navigation rule): an in-flight recording
    /// must survive navigating away from the Recordings screen.
    let phoneRecorder: PhoneRecorderController

    /// The phone's chat endpoint (Plan 4 Tasks 5+7): the Chat composer sends
    /// THROUGH this — the assembler is the ONLY chat-table writer, no view
    /// model touches `chat_sessions`/`chat_messages` directly — and the feed
    /// hands every streamed chunk here for assembly.
    public let chat: ChatAssembler

    /// The phone's SINGLE relay consumer (Plan 4 decision 3): routes desktop
    /// action echoes into `outbox.applyEcho`, chat chunks into `chat` (the
    /// `ChatChunkAssembling` seam, wired since Task 7), and heartbeats into
    /// the store. Internal so wiring tests can drive a deterministic
    /// `pollOnce` and the chat view models can read `isDesktopReachable`.
    let feed: RelayFeed

    /// Local-notification raiser (Plan 6 Task 4): consumes the hydrator's
    /// `onRecordsApplied` hook and alerts on fresh desktop-tagged rows, with
    /// the initial-hydrate storm suppression. Owned HERE for the app's
    /// lifetime (async-ops-survive-navigation rule) — its watermark/permission
    /// state must outlive any view. Internal like `feed`; Settings reads
    /// `permission` through it.
    let notifications: NotificationCoordinator

    /// The BYOK answer loop (Plan 5 Task 6): answers chat turns on-device
    /// against `api.anthropic.com` with the user's own key. Owned HERE for
    /// the app's lifetime — its in-flight answer tasks hold the agent weakly,
    /// so a view-local owner deallocated by navigation would strand a
    /// placeholder row incomplete forever (see the `[weak self]` note at
    /// `DirectAPIAgent.scheduleAnswer`; the project's
    /// async-ops-survive-navigation rule).
    public let directAgent: DirectAPIAgent

    /// Today's default turn-sender: the Mac answers over the relay. The chat
    /// view model picks between this and `directAgent` per session opt-in
    /// (Plan 5 Decision 7) — never a silent switch.
    public let relayBackend: RelayAgentBackend

    /// Model choice for the direct agent (Plan 5 Decision 6), persisted in
    /// UserDefaults — a model NAME is not a secret; the KEY is Keychain-only.
    public var agentModel: AgentModel {
        didSet { UserDefaults.standard.set(agentModel.rawValue, forKey: Self.agentModelKey) }
    }

    /// Whether an Anthropic API key is stored — drives the Settings section
    /// and the Chat opt-in button. Mutate the key ONLY through
    /// `saveAPIKey`/`removeAPIKey` so this flag can never drift from the
    /// Keychain truth.
    public private(set) var hasAPIKey: Bool

    /// Daily silent-pending sweep loop; lives as long as the environment.
    private var sweepTask: Task<Void, Never>?

    /// Human-readable name of the connected transport, shown in Settings.
    public var transportLabel: String {
        switch transportKind {
        case .cloudKit: "iCloud"
        case .inMemoryDemo: "demo"
        }
    }

    /// Result of the most recent hydration cycle (records applied / deleted).
    public private(set) var lastHydrate: (applied: Int, deleted: Int)?
    /// True while a hydration cycle is in flight — drives the sync footer spinner.
    public private(set) var isHydrating = false

    // nonisolated: logged from @Sendable hook/sweep closures off the actor.
    private nonisolated static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppEnvironment")

    /// UserDefaults slot for `agentModel`. nonisolated: read from the
    /// @Sendable `liveAgentModel` provider off the actor.
    private nonisolated static let agentModelKey = "agent.model"

    /// The @Sendable providers handed to `DirectAPIAgent`. STATIC on purpose:
    /// they physically cannot capture @MainActor self, so every call reads
    /// the Keychain / UserDefaults LIVE — saving a key or switching models in
    /// Settings takes effect on the very next turn without rebuilding the
    /// agent (Task 6 no-capture rule, pinned by `AgentSettingsTests`).
    /// Internal (not private) so the wiring tests can call the exact closures
    /// the agent holds.
    nonisolated static let liveAPIKey: @Sendable () -> String? = { APIKeyStore().read() }
    nonisolated static let liveAgentModel: @Sendable () -> AgentModel = {
        UserDefaults.standard.string(forKey: agentModelKey)
            .flatMap(AgentModel.init(rawValue:)) ?? .sonnet5
    }

    public convenience init() throws {
        // TRANSPORT SWAP POINT (see the doc comment on `transport` above):
        // entitled builds go live over CloudKit, everything else stays demo.
        if CloudKitTransport.entitlementPresent() {
            let transportStore = try TransportStore(path: Self.supportPath("cloudkit-transport.sqlite"))
            try self.init(
                transport: CloudKitTransport(store: transportStore),
                replicaPath: Self.supportPath("replica.sqlite"),
                transportKind: .cloudKit
            )
        } else {
            try self.init(
                transport: InMemoryCloudTransport(),
                replicaPath: Self.supportPath("replica.sqlite"),
                transportKind: .inMemoryDemo
            )
        }
    }

    /// Designated init with an injectable transport + replica path — wiring
    /// tests build isolated environments; production uses `init()` above.
    /// `transportKind` is injectable so tests can force either branch without
    /// probing; it defaults to the demo kind every pre-swap test relied on.
    ///
    /// Throws when the replica pool cannot open (the app renders that as the
    /// degraded `BootFailureView` — see `WatchtowerMobileApp.Boot` — instead
    /// of the pre-Task-9 `fatalError`).
    init(
        transport: any CloudSyncTransport,
        replicaPath: String,
        transportKind: TransportKind = .inMemoryDemo
    ) throws {
        store = try ReplicaStore(path: replicaPath)

        // Kind/transport disagreement is only expressible from test code —
        // a real CloudKitTransport under `.inMemoryDemo` would DEBUG-seed
        // demo rows into the live pending store.
        assert(
            !(transport is CloudKitTransport && transportKind == .inMemoryDemo),
            "a CloudKitTransport must not run under the demo kind"
        )
        self.transport = transport
        self.transportKind = transportKind
        // Swap step 3: on the live path both relay-cycle consumers nudge the
        // CKSyncEngine before reading. Derived from the concrete type, not
        // the kind — a kind-forced test env with an InMemory stand-in has no
        // engine to nudge and correctly gets nil.
        let pull: (@Sendable () async throws -> Void)? = (transport as? CloudKitTransport)
            .map { cloud in { try await cloud.pull() } }
        let notifications = NotificationCoordinator(store: store)
        self.notifications = notifications
        let hydrator = ReplicaHydrator(
            transport: transport,
            store: store,
            pull: pull,
            // Fire-and-forget hop onto the coordinator's actor (the hook is
            // synchronous by contract so it can never delay a hydration
            // cycle); the coordinator dedups/suppresses before any alert.
            onRecordsApplied: { records in
                Task { @MainActor in await notifications.recordsApplied(records) }
            }
        )
        self.hydrator = hydrator
        let outbox = ActionOutbox(transport: transport, store: store)
        self.outbox = outbox
        let uploader = RecordingUploader(transport: transport, store: store)
        recordingUploader = uploader
        phoneRecorder = PhoneRecorderController(uploader: uploader)
        let chat = ChatAssembler(transport: transport, store: store)
        self.chat = chat
        directAgent = DirectAPIAgent(
            assembler: chat,
            store: store,
            toolbox: ReplicaToolbox(store: store, outbox: outbox),
            apiKey: Self.liveAPIKey,
            model: Self.liveAgentModel
        )
        relayBackend = RelayAgentBackend(assembler: chat)
        agentModel = Self.liveAgentModel()
        hasAPIKey = APIKeyStore().read() != nil
        feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            assembler: chat,
            uploads: uploader,
            pull: pull,
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

    /// Per-kind setup (demo seed vs engine start), then a first hydration
    /// cycle so the tabs have content immediately, then the background loops
    /// (data-zone hydration, relay feed, silent-pending sweep).
    private func bootstrap(transport: any CloudSyncTransport) async {
        switch transportKind {
        case .inMemoryDemo:
            // Demo data on the demo kind ONLY (Decision 2), and only in
            // DEBUG — a Release demo build simply renders empty tabs.
            #if DEBUG
            do {
                try await DemoSeed.load(into: transport)
                // Canned chat exchange BEFORE feed.start(): the answer chunks
                // sit in the relay zone when the feed's first poll runs, so
                // the Chat tab shows a completed thread within the first cycle.
                try await DemoSeed.loadChatExchange(via: chat, into: transport, store: store)
            } catch {
                Self.logger.error("DemoSeed failed: \(error.localizedDescription, privacy: .public)")
            }
            #endif
        case .cloudKit:
            // Swap step 2, second half: bring the CKSyncEngine up before the
            // first hydrate so the pull hooks have an engine to nudge. Never
            // seeds — a real install starts empty and hydrates from the
            // user's own zone. (A kind-forced test env carries an InMemory
            // stand-in, so the cast is the same no-engine guard as `pull`.)
            if let cloud = transport as? CloudKitTransport {
                await cloud.start()
            }
        }
        await refresh()
        // Relaunch retry (Workstream 1): re-send every recording the hub has
        // not acknowledged yet. Errors only log — the row stays for the next
        // pass, and a stop-triggered upload retries within the session.
        do {
            _ = try await recordingUploader.uploadPending()
        } catch {
            Self.logger.warning("recording upload retry failed: \(error.localizedDescription, privacy: .public)")
        }
        await hydrator.start()
        await feed.start()
        scheduleSilentPendingSweep()
    }

    /// Stores the Anthropic API key in the Keychain and refreshes
    /// `hasAPIKey`. The app's ONLY key-writing path (with `removeAPIKey`).
    public func saveAPIKey(_ key: String) throws {
        try APIKeyStore().save(key)
        hasAPIKey = true
    }

    /// Deletes the stored key and refreshes `hasAPIKey`.
    public func removeAPIKey() throws {
        try APIKeyStore().remove()
        hasAPIKey = false
    }

    /// Runs one hydration cycle on demand (also used by pull-to-refresh later).
    public func refresh() async {
        isHydrating = true
        defer { isHydrating = false }
        do {
            lastHydrate = try await hydrator.hydrateOnce()
        } catch {
            Self.logger.error("hydration failed: \(error.localizedDescription, privacy: .public)")
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

    /// Application Support path for a store file — the replica and the
    /// CloudKit transport buffer live side by side there.
    private static func supportPath(_ fileName: String) -> String {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(fileName).path
    }
}

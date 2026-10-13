import Foundation
import Observation
import os
import UIKit
@_spi(DemoTransport) import WatchtowerSync

/// Which transport an `AppEnvironment` runs on: probed in `init()`,
/// injectable through the designated init for tests. `.cloudKit` NEVER
/// seeds: a real install starts empty and hydrates from the user's own zone.
enum TransportKind: String, Sendable {
    case cloudKit
    case inMemoryDemo
}

/// What started a fetch (`AppEnvironment.refresh(_:)`): counted per day for
/// the battery diagnostics.
enum FetchTrigger: Sendable {
    /// The safety poll's timed cycle.
    case loop
    /// A silent push.
    case push
    /// Pull to refresh.
    case pull
    /// The loop's first cycle on the return to the foreground.
    case foreground
    /// The boot's first fetch.
    case launch
    /// The link flow's grant reads.
    case link

    var energyEvent: EnergyEvent {
        switch self {
        case .loop: .fetchLoop
        case .push: .fetchPush
        case .pull: .fetchPull
        case .foreground: .fetchForeground
        case .launch: .fetchLaunch
        case .link: .fetchLink
        }
    }
}

/// What one fetch brought: a silent push reports it to iOS
/// (`UIBackgroundFetchResult`).
enum FetchOutcome: Sendable, Equatable {
    /// The replica or the relay feed took something in.
    case newData
    case noData
    /// The data fetch failed.
    case failed
}

/// How far a fetch reaches into CloudKit (board #724).
enum RemoteFetchDepth: Sendable, Equatable {
    /// The engine fetch plus the forced zone poll of both zones
    /// (`CloudKitTransport.pull()`): the safety poll, pull to refresh, the
    /// return to the foreground, the launch and the link flow.
    case full
    /// A silent push that arrived at `since`: CKSyncEngine's own run for
    /// it, or a fallback engine fetch (`CloudKitTransport.fetchForPush`),
    /// with the forced zone poll when `pollOnFallback` (a push in the
    /// foreground: the owner is looking) and without it in the background.
    case push(since: Date, pollOnFallback: Bool)
}

/// What the CloudKit transport tells the link flow (spec §9).
enum LinkSignal: Sendable {
    /// `shared` scope: the Mac's zones are gone (`TransportEvent.unlinked`).
    case unlinked
    /// An iCloud account sign-out or switch reset the transport.
    case accountChanged
}

/// A silent push's arrival: how many fetches had begun, when, and whether
/// the app was in the foreground.
struct PushArrival {
    let serial: Int
    let at: Date
    let inForeground: Bool
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
/// Every fetch feeds both consumers: it reaches CloudKit once (`RemoteFetchDepth`),
/// then hydrates DataZone and reads RelayZone from what that buffered.
/// The phone fetches when something changed (board #724): a silent push is
/// fetched at once, pushes landing during a fetch share one follow-up; a
/// 60 s safety poll runs while the app is active and pauses whenever it is
/// not, whatever background mode keeps it alive.
@MainActor
@Observable
final class AppEnvironment {
    /// The phone's app group (spec §2.1). The replica lives in its container
    /// so the notification extensions can read it.
    nonisolated static let appGroupID = "group.com.aiwatchtowers.watchtower.mobile"
    /// The hub a live phone syncs while it has no link (F1 bridge, replaced
    /// by F2's `HubRegistry`): no Mac has zones of this name, so it syncs
    /// nothing.
    nonisolated static let unlinkedHubID = "unlinked"

    let store: ReplicaStore
    let transportKind: TransportKind
    let outbox: ActionOutbox
    /// `session_report_request` on opening a session detail, throttled per
    /// session for the app's lifetime.
    let reportRequests: SessionReportRequester
    /// The phone's board writes (status, priority, comments, new targets).
    let boardWriter: BoardWriter
    /// The owner's unsent ask answers, per ask: they survive navigation.
    let askDrafts = AskDraftStore()
    /// The phone's ask answers and what the Mac did with them.
    let askAnswerer: AskAnswerer
    /// The phone's session starts (with their progress) and stops.
    let sessionStarts: SessionStarter
    let deviceSettings: DeviceSettings
    /// The Workbench slices as the Now and Workbench tabs and the tab badge
    /// draw them: one observation for the app's lifetime.
    let workbenchReplica = WorkbenchReplicaModel()
    /// The calendar slices as the Calendar and Now tabs draw them.
    let calendarReplica = CalendarReplicaModel()
    /// The phone recorder (record a meeting or a voice note), owned for the
    /// app's lifetime so a capture survives any navigation.
    let recorder: PhoneRecorderController
    /// The phone's recordings and their way to the Mac.
    let phoneRecordings = PhoneRecordingsModel()
    /// The ready recaps the owner has opened on this phone.
    let recordingsSeen: RecordingsSeenStore
    /// The selected tab and the Calendar stack.
    let navigation = AppNavigation()

    /// This phone's link, nil until the link flow sets one. The demo
    /// transport is linked to `DemoSeed.device`.
    private(set) var linkedDevice: LinkedDevice?
    /// false while the link stands but nothing may be sent (the hub moved,
    /// spec §9): the outbox and the uploader refuse as if unlinked.
    private(set) var writesAllowed = true

    /// The link flow's hooks (`AppRoot`): the transport's link signals, and
    /// a call after every successful fetch (the heartbeat checks).
    @ObservationIgnored var onLinkSignal: (@MainActor (LinkSignal) -> Void)?
    @ObservationIgnored var onFetched: (@MainActor () -> Void)?

    /// When the phone last fetched from the Mac successfully (Settings →
    /// Your Mac → Last sync); nil before the first successful fetch.
    private(set) var lastSyncAt: Date?

    /// The safety poll's cadence on every tab (owner decision Q1, board
    /// #724): pushes bring changes, the poll is the net under them.
    static let safetyPollInterval: Duration = .seconds(60)
    /// The return to the foreground fetches at once unless the last
    /// successful fetch is younger than this (a Control Center peek).
    static let foregroundRefetchAfter: TimeInterval = 5
    /// How long a push waits for CKSyncEngine's own fetch run to begin
    /// before fetching through the engine itself.
    static let pushEngineGrace: TimeInterval = 2

    /// false while the app is not active (inactive or in the background):
    /// the safety poll is paused.
    private(set) var isActive = true
    /// true while the safety poll runs.
    var isLooping: Bool { loopTask != nil }
    /// The latest finished fetch failed: a silent push's deadline reports
    /// `.failed` rather than `.noData` (`PushCompletion`).
    var lastFetchFailed: Bool { lastFinishedFetch?.outcome == .failed }
    /// Fetch cycles the loop has begun (a cancelled loop begins none).
    @ObservationIgnored private(set) var fetchCycles = 0

    @ObservationIgnored private let transport: any CloudSyncTransport
    @ObservationIgnored private let hydrator: ReplicaHydrator
    @ObservationIgnored private let feed: RelayFeed
    @ObservationIgnored private let uploader: RecordingUploader
    /// Open while the app is active: only then may the uploader re-send a
    /// recording it saved before (board #724) — never on a launch into the
    /// background.
    @ObservationIgnored private let uploadRetries: UploadRetryGate
    /// Counts fetches by trigger (the battery diagnostics); nil counts
    /// nothing.
    @ObservationIgnored private let energy: EnergyCounter?
    /// Reaches CloudKit before each fetch hydrates; nil for a transport
    /// without an engine (the in-memory demo).
    @ObservationIgnored private let remoteFetch: (@Sendable (RemoteFetchDepth) async throws -> Void)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// The safety poll's wait; tests step it by hand.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Fetches begun so far: a push is served by any fetch begun after it.
    @ObservationIgnored private var fetchSerial = 0
    @ObservationIgnored private var runningFetch: (serial: Int, task: Task<FetchOutcome, Never>)?
    @ObservationIgnored private var lastFinishedFetch: (serial: Int, outcome: FetchOutcome)?
    /// The one follow-up fetch for pushes that arrived while a fetch ran,
    /// and the latest of those pushes.
    @ObservationIgnored private var queuedPushTask: Task<FetchOutcome, Never>?
    @ObservationIgnored private var queuedPushArrival: PushArrival?
    /// Pushes waiting on that follow-up (observable in tests).
    @ObservationIgnored private(set) var followUpWaiters = 0
    /// Fetches still waiting on CloudKit (`remoteFetch`): each hydrates
    /// after it, so a local apply meanwhile would only repeat that.
    @ObservationIgnored private var fetchesAwaitingRemote = 0
    /// An engine-run apply was skipped while a fetch waited on CloudKit:
    /// owed if that fetch fails before it hydrates.
    @ObservationIgnored private var applyOwed = false
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    /// The boot (seed or engine start, first fetch, recovery) is done.
    @ObservationIgnored private(set) var isBootstrapped = false
    @ObservationIgnored private var stopped = false

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "AppEnvironment")

    /// TRANSPORT SWITCH: a build carrying the iCloud entitlement (signed
    /// device or TestFlight build) goes live over CloudKit, in the app group
    /// container; anything else (unsigned simulator and CI builds) runs the
    /// in-memory demo transport with DemoSeed. `recordingsDirectory` is for
    /// tests: nil keeps the phone's own recordings folder. A live build
    /// runs `hubID`'s zones in `scope`'s database, linked as `linkedDevice`
    /// (`AppRoot` reads all three from the `LinkStore`). `energy` counts
    /// the fetches, the CloudKit requests and the upload attempts (the app
    /// passes `BatteryDiagnostics.shared.counter`; nil counts nothing).
    convenience init(
        recordingsDirectory: URL? = nil,
        scope: CloudDatabaseScope = .private,
        hubID: String = AppEnvironment.unlinkedHubID,
        linkedDevice: LinkedDevice? = nil,
        energy: EnergyCounter? = nil
    ) throws {
        if CloudKitTransport.entitlementPresent() {
            let directory = try Self.appGroupDirectory()
            let transportStore = try TransportStore(path: Self.liveTransportStorePath(in: directory))
            try self.init(
                transport: CloudKitTransport(
                    store: transportStore, scope: scope, hubID: hubID, role: .phone, energy: energy
                ),
                replicaPath: Self.liveReplicaPath(in: directory),
                transportKind: .cloudKit,
                linkedDevice: linkedDevice,
                recordingsDirectory: recordingsDirectory,
                replicaObservesSuspension: true,
                energy: energy
            )
        } else {
            try self.init(
                transport: InMemoryCloudTransport(),
                replicaPath: try Self.applicationSupportDirectory().appendingPathComponent("replica.sqlite").path,
                transportKind: .inMemoryDemo,
                recordingsDirectory: recordingsDirectory,
                energy: energy
            )
        }
    }

    /// Designated init with an injectable transport and replica path, so
    /// wiring tests build isolated environments. Throws when the replica
    /// cannot open (the app then shows `BootFailureView`). `makeRecorder`
    /// builds the recorder over the environment's uploader; tests pass a
    /// fake audio engine and clock, the app the microphone. `sleep` is the
    /// safety poll's wait, `now` the clock
    /// of the foreground-return rule. `remoteFetch` replaces the CloudKit
    /// reach of each fetch (tests); nil derives it from a
    /// `CloudKitTransport` (none for any other transport). `linkedDevice`
    /// is the saved link (the demo kind is always `DemoSeed.device`).
    /// `energy` counts the fetches and the upload attempts.
    /// `uploadRetriesAllowed` is whether the app starts active (nil reads
    /// `UIApplication`; a cold launch reads not active there, and the
    /// scene's first active phase opens the gate through `setActive`).
    /// `replicaObservesSuspension` is for the live app-group replica, which
    /// `DatabaseSuspension` suspends while the app rests in the background.
    init(
        transport: any CloudSyncTransport,
        replicaPath: String,
        transportKind: TransportKind = .inMemoryDemo,
        linkedDevice: LinkedDevice? = nil,
        defaults: UserDefaults = .standard,
        recordingsDirectory: URL? = nil,
        uploadRetriesAllowed: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        replicaObservesSuspension: Bool = false,
        makeRecorder: ((RecordingUploader) throws -> PhoneRecorderController)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        remoteFetch: (@Sendable (RemoteFetchDepth) async throws -> Void)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        energy: EnergyCounter? = nil
    ) throws {
        assert(
            !(transport is CloudKitTransport && transportKind == .inMemoryDemo),
            "a CloudKitTransport must not run under the demo kind"
        )
        store = try ReplicaStore(path: replicaPath, observesSuspension: replicaObservesSuspension)
        self.sleep = sleep
        self.now = now
        self.energy = energy
        self.transport = transport
        self.transportKind = transportKind
        let device = transportKind == .inMemoryDemo ? DemoSeed.device : linkedDevice
        self.linkedDevice = device

        // Each fetch reaches CloudKit once (`remoteFetch`); the hydrator and
        // the feed then read what that buffered, so neither pulls on its own.
        // An in-memory stand-in has no engine and gets nil.
        let grace = Self.pushEngineGrace
        self.remoteFetch = remoteFetch ?? (transport as? CloudKitTransport).map { cloud in
            { @Sendable depth in
                switch depth {
                case .full:
                    try await cloud.pull()
                case let .push(since, pollOnFallback):
                    try await cloud.fetchForPush(since: since, grace: grace, pollOnFallback: pollOnFallback)
                }
            }
        }
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        self.hydrator = hydrator
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: device?.deviceID)
        self.outbox = outbox
        reportRequests = SessionReportRequester.sending(through: outbox)
        boardWriter = BoardWriter.sending(through: outbox, store: store)
        askAnswerer = AskAnswerer.sending(through: outbox, store: store, drafts: askDrafts)
        sessionStarts = SessionStarter.sending(through: outbox, store: store)
        // An `applied` echo clears the queued row; hydrating right behind it
        // (from what the same fetch buffered) lands the Mac's authoritative
        // change at the same moment.
        let hydrateAfterEcho: @Sendable () async -> Void = { [hydrator] in
            do {
                _ = try await hydrator.hydrateOnce()
            } catch {
                Self.logger.warning("post-echo hydrate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let retries = UploadRetryGate(uploadRetriesAllowed ?? (UIApplication.shared.applicationState == .active))
        uploadRetries = retries
        let uploader = RecordingUploader(
            transport: transport,
            store: store,
            directory: try recordingsDirectory ?? PhoneRecorderController.defaultDirectory(),
            deviceID: device?.deviceID,
            now: now,
            retriesAllowed: { retries.isOpen },
            energy: energy
        )
        self.uploader = uploader
        recorder = try (makeRecorder ?? Self.liveRecorder)(uploader)
        feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            uploads: uploader,
            onActionApplied: hydrateAfterEcho
        )
        let settings = DeviceSettings(transport: transport, defaults: defaults)
        settings.linkedDevice = device
        deviceSettings = settings
        recordingsSeen = RecordingsSeenStore(defaults: defaults)
        workbenchReplica.start(store: store)
        calendarReplica.start(store: store)
        phoneRecordings.start(store: store)

        bootstrapTask = Task { await bootstrap() }
    }

    /// Demo seed or engine start, a first fetch so the screens have content
    /// at once, then the safety poll.
    private func bootstrap() async {
        // Before any fetch, so no applied echo goes unseen: an ask answer's
        // delivery, a start's session id.
        await outbox.setAppliedObserver(Self.appliedObserver(askAnswerer: askAnswerer, sessionStarts: sessionStarts))
        switch transportKind {
        case .inMemoryDemo:
            #if DEBUG
            do {
                // Each launch builds a new in-memory transport whose change
                // cursor restarts, so the persisted replica's tokens must be
                // forgotten or the fresh seed never lands.
                try store.resetSyncTokens()
                try await DemoSeed.load(into: transport)
                try await DemoSeed.loadRecordingDemo(uploader: uploader, store: store, transport: transport, now: Date())
            } catch {
                Self.logger.error("DemoSeed failed: \(error.localizedDescription, privacy: .public)")
            }
            #endif
        case .cloudKit:
            if let cloud = transport as? CloudKitTransport {
                // Before the engine starts, so no signal goes unseen; each
                // reaches whatever hook the link flow set by then.
                await cloud.setEventHandler { [weak self] event in
                    guard event == .unlinked else { return }
                    Task { @MainActor in self?.onLinkSignal?(.unlinked) }
                }
                await cloud.setAccountResetHandler { [weak self] in
                    Task { @MainActor in self?.onLinkSignal?(.accountChanged) }
                }
                // CKSyncEngine's own push-driven fetch run: applied at once
                // while the app is active.
                await cloud.setEngineFetchedHandler { [weak self] in
                    Task { @MainActor in await self?.applyBuffered() }
                }
                await cloud.start()
            }
        }
        await refresh(.launch)
        // An action the Mac never answered within 24 h is failed locally, so
        // the queued count never counts it forever.
        do {
            try await outbox.sweepSilentPending()
        } catch {
            Self.logger.warning("silent-pending sweep failed: \(error.localizedDescription, privacy: .public)")
        }
        // A capture cut short by a kill is finalized from its file, and
        // files without a ledger row are deleted. Then, in the foreground
        // only, the upload pass with the relaunch retry: recordings saved
        // but not yet acknowledged go out again when their backoff is due
        // (the hub's processed set absorbs duplicates). A launch into the
        // background uploads nothing; the first activation runs the pass.
        await recorder.recoverOnLaunch()
        if uploadRetries.isOpen {
            await recorder.uploadPending()
        }
        isBootstrapped = true
        // The launch fetch just ran: the safety poll waits a full interval.
        restartLoop(firstCycle: nil)
    }

    /// The outbox's one applied observer, shared by the app and the tests:
    /// every applied echo goes to both consumers on the main actor, and
    /// each keeps only its own kind.
    nonisolated static func appliedObserver(
        askAnswerer: AskAnswerer,
        sessionStarts: SessionStarter
    ) -> @Sendable (ActionRequestPayload) -> Void {
        { [weak askAnswerer, weak sessionStarts] action in
            Task { @MainActor in
                askAnswerer?.receiveApplied(action)
                sessionStarts?.receiveApplied(action)
            }
        }
    }

    /// The device recorder: the microphone, recordings in Application
    /// Support, and local notifications for the 3-hour cap notice and the
    /// long-pause auto-finish.
    private static func liveRecorder(_ uploader: RecordingUploader) throws -> PhoneRecorderController {
        let recorder = PhoneRecorderController(uploader: uploader, engine: AVAudioCaptureEngine())
        recorder.onCapNotice = { RecorderNotices.postCapNotice() }
        recorder.onAutoFinish = { RecorderNotices.postAutoFinishNotice() }
        // A running capture keeps the app alive in the background and
        // writes the ledger: the replica stays usable while its audio runs.
        var release: (@MainActor () -> Void)?
        recorder.onAudioRunning = { running in
            if running {
                if release == nil { release = DatabaseSuspension.shared.hold() }
            } else {
                release?()
                release = nil
            }
        }
        return recorder
    }

    /// One fetch: CloudKit once (`RemoteFetchDepth.full`), then DataZone
    /// and RelayZone echoes from what it buffered. Returns false when the
    /// data fetch failed. Used by pull to refresh, the launch and the link
    /// flow; every success stamps `lastSyncAt`. `trigger` is counted for the
    /// battery diagnostics.
    @discardableResult
    func refresh(_ trigger: FetchTrigger) async -> Bool {
        await startFetch(trigger).value != .failed
    }

    /// A silent push (`AppDelegate`), fetched at once in the foreground and
    /// the background alike (leading edge): a fetch begun after the push
    /// already serves it, and pushes arriving while a fetch runs share one
    /// follow-up fetch behind it. In the foreground the safety poll restarts
    /// from that fetch, and a fallback fetch polls the zones; the
    /// background keeps the light fetch and starts no poll. Each caller gets
    /// the outcome of the fetch that served its push.
    func handlePush(inForeground: Bool) async -> FetchOutcome {
        await fetch(for: PushArrival(serial: fetchSerial, at: now(), inForeground: inForeground))
    }

    /// The fetch serving `push`: one begun after it, else one follow-up
    /// behind the running fetch, else a new push fetch.
    private func fetch(for push: PushArrival) async -> FetchOutcome {
        if let running = runningFetch {
            if running.serial > push.serial {
                return await running.task.value
            }
            // The follow-up serves the latest push, and polls on its
            // fallback if any push it serves came in the foreground.
            let foreground = push.inForeground || (queuedPushArrival?.inForeground ?? false)
            queuedPushArrival = PushArrival(serial: push.serial, at: push.at, inForeground: foreground)
            followUpWaiters += 1
            defer { followUpWaiters -= 1 }
            if let queued = queuedPushTask {
                return await queued.value
            }
            let queued = Task { [weak self] () -> FetchOutcome in
                _ = await running.task.value
                guard let self, !self.stopped else { return .noData }
                let latest = self.queuedPushArrival ?? push
                self.queuedPushTask = nil
                self.queuedPushArrival = nil
                return await self.fetch(for: latest)
            }
            queuedPushTask = queued
            return await queued.value
        }
        if let last = lastFinishedFetch, last.serial > push.serial {
            return last.outcome
        }
        let outcome = await startFetch(.push, push: push).value
        // The safety poll counts from this fetch: no poll right behind it.
        // In the background there is no poll to restart.
        if isActive {
            restartLoop(firstCycle: nil)
        }
        return outcome
    }

    /// Begins one fetch now and tracks it as the running one. A push
    /// fetch takes the light CloudKit reach, any other the full one.
    private func startFetch(_ trigger: FetchTrigger, push: PushArrival? = nil) -> Task<FetchOutcome, Never> {
        fetchSerial += 1
        let serial = fetchSerial
        let depth: RemoteFetchDepth = push.map { .push(since: $0.at, pollOnFallback: $0.inForeground) } ?? .full
        let task = Task { [weak self] () -> FetchOutcome in
            guard let self else { return .failed }
            let outcome = await self.performFetch(trigger, depth: depth)
            if serial > (self.lastFinishedFetch?.serial ?? 0) {
                self.lastFinishedFetch = (serial, outcome)
            }
            if self.runningFetch?.serial == serial {
                self.runningFetch = nil
            }
            return outcome
        }
        runningFetch = (serial, task)
        return task
    }

    private func performFetch(_ trigger: FetchTrigger, depth: RemoteFetchDepth) async -> FetchOutcome {
        energy?.record(trigger.energyEvent)
        let hydrated: (applied: Int, deleted: Int)
        var remoteError: (any Error)?
        fetchesAwaitingRemote += 1
        do {
            try await remoteFetch?(depth)
        } catch {
            remoteError = error
        }
        fetchesAwaitingRemote -= 1
        // The last fetch off CloudKit settles a skipped engine-run apply:
        // its own hydrate covers it, a failure applies it here.
        let owed = applyOwed && fetchesAwaitingRemote == 0
        if owed {
            applyOwed = false
        }
        if let remoteError {
            Self.logger.error("fetch failed: \(remoteError.localizedDescription, privacy: .public)")
            if owed {
                await applyBuffered()
            }
            return .failed
        }
        do {
            hydrated = try await hydrator.hydrateOnce()
        } catch {
            Self.logger.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        lastSyncAt = now()
        var routed = 0
        do {
            routed = try await feed.pollOnce()
        } catch {
            Self.logger.error("relay fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        onFetched?()
        return hydrated.applied + hydrated.deleted + routed > 0 ? .newData : .noData
    }

    /// What the engine already buffered lands in the replica and the relay
    /// feed, while the app is active: after CKSyncEngine ended a fetch run
    /// of its own (a push), and on a quick return to the foreground that
    /// skips the fetch. Local reads only (neither the hydrator nor the feed
    /// pulls by itself). Skipped while a fetch still waits on CloudKit: it
    /// hydrates right after, or, if it fails first, runs the skipped apply.
    func applyBuffered() async {
        guard isActive, isBootstrapped, !stopped else { return }
        guard fetchesAwaitingRemote == 0 else {
            applyOwed = true
            return
        }
        do {
            _ = try await hydrator.hydrateOnce()
        } catch {
            Self.logger.error("engine fetch apply failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        lastSyncAt = now()
        do {
            _ = try await feed.pollOnce()
        } catch {
            Self.logger.error("relay apply failed: \(error.localizedDescription, privacy: .public)")
        }
        onFetched?()
    }

    /// Scene phase: the safety poll pauses while the app is not active. On
    /// the return it fetches at once, unless the last successful fetch is
    /// under `foregroundRefetchAfter` old (a Control Center peek): then it
    /// only applies what the engine buffered meanwhile (no network).
    func setActive(_ active: Bool) {
        setUploadRetries(active)
        guard active != isActive else { return }
        isActive = active
        // A capture keeps going in the background, but its timer slows.
        recorder.setForeground(active)
        guard active else {
            restartLoop(firstCycle: nil)
            return
        }
        let recent = lastSyncAt.map { now().timeIntervalSince($0) < Self.foregroundRefetchAfter } ?? false
        restartLoop(firstCycle: recent ? nil : .foreground)
        if recent, isBootstrapped {
            Task { await applyBuffered() }
        }
    }

    /// Opens or closes the uploader's retries with the scene phase. Each
    /// opening runs an upload pass once the boot is done: due retries go
    /// out on the return to the foreground (the boot's own pass covers a
    /// gate already open when it runs).
    private func setUploadRetries(_ open: Bool) {
        guard uploadRetries.set(open), open else { return }
        let boot = bootstrapTask
        Task { [weak self] in
            await boot?.value
            guard let self, !self.stopped else { return }
            await self.recorder.uploadPending()
        }
    }

    /// The recorder's "See recordings": closes the finished recorder and
    /// opens the Recordings list on the Calendar tab.
    func showRecordings() {
        recorder.close()
        navigation.showRecordings()
    }

    /// The one place the phone's link changes (the link flow and unlink):
    /// Settings, the action outbox and the recording uploader all take the
    /// new device id, then waiting recordings go out at once. With
    /// `writesAllowed: false` the link stands (Settings still shows it) but
    /// the outbox and the uploader get no device id, so nothing is sent.
    func setLinkedDevice(_ device: LinkedDevice?, writesAllowed: Bool = true) async {
        linkedDevice = device
        self.writesAllowed = writesAllowed
        deviceSettings.linkedDevice = device
        let sendingID = writesAllowed ? device?.deviceID : nil
        await outbox.setDeviceID(sendingID)
        await uploader.setDeviceID(sendingID)
        await recorder.uploadPending()
    }

    /// The transport the link flow writes this phone's `device` record
    /// through.
    var linkTransport: any CloudSyncTransport { transport }

    /// Asks a CloudKit transport to send its queue now (the unlinked record
    /// before a stop), once the boot has started its engine.
    func sendNow() async {
        await bootstrapTask?.value
        await (transport as? CloudKitTransport)?.sendNow()
    }

    /// Stops the loop for good (tests' teardown; the app never stops).
    func stop() {
        stopped = true
        bootstrapTask?.cancel()
        loopTask?.cancel()
        loopTask = nil
    }

    /// Stops the loop and the CloudKit engine for good, after the boot has
    /// ended: the link flow then builds the next environment on the same
    /// files.
    func shutDown() async {
        stop()
        await bootstrapTask?.value
        await (transport as? CloudKitTransport)?.stop()
    }

    /// Restarts the safety poll: `firstCycle` fetches at once (counted as
    /// that trigger), then one `.loop` fetch every `safetyPollInterval`.
    /// The first fetch begins before this returns, so a push waiting on the
    /// return to the foreground finds it running.
    private func restartLoop(firstCycle: FetchTrigger?) {
        loopTask?.cancel()
        loopTask = nil
        guard isBootstrapped, isActive, !stopped else { return }
        var first: Task<FetchOutcome, Never>?
        if let firstCycle {
            fetchCycles += 1
            first = startFetch(firstCycle)
        }
        let sleep = sleep
        loopTask = Task { [weak self, first] in
            _ = await first?.value
            while !Task.isCancelled {
                do {
                    try await sleep(Self.safetyPollInterval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.fetchCycles += 1
                _ = await self.startFetch(.loop).value
            }
        }
    }

    /// The live replica's file in the app group directory.
    static func liveReplicaPath(in directory: URL) -> String {
        directory.appendingPathComponent("replica.sqlite").path
    }

    /// The live CloudKit transport's store in the app group directory.
    static func liveTransportStorePath(in directory: URL) -> String {
        directory.appendingPathComponent("cloudkit-transport.sqlite").path
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

/// Whether the recording uploader may re-send (the app is active). Read by
/// the uploader's actor, written on the main actor.
final class UploadRetryGate: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    init(_ open: Bool) {
        state = OSAllocatedUnfairLock(initialState: open)
    }

    var isOpen: Bool { state.withLock { $0 } }

    /// Sets the gate; true when that changed it.
    func set(_ open: Bool) -> Bool {
        state.withLock { current in
            defer { current = open }
            return current != open
        }
    }
}

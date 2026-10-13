import Foundation
import Observation
import os
import UIKit
@_spi(DemoTransport) import WatchtowerSync

/// Which transport a `HubSession` runs on: chosen by `AppEnvironment`'s
/// live and demo builders, injectable through the designated init for
/// tests. `.cloudKit` NEVER seeds: a real install starts empty and hydrates
/// from the user's own zone.
enum TransportKind: String, Sendable {
    case cloudKit
    case inMemoryDemo
}

/// What started a fetch (`HubSession.refresh(_:)`): counted per day for
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

/// One linked hub's whole object graph (multi-hub spec §5.3): the
/// on-device replica, the hydrator that pulls DataZone into it, and the
/// relay pair (`ActionOutbox` out, `RelayFeed` echoes in) over the same
/// transport and store, with the recorder and the uploader of its own
/// recordings folder. `AppEnvironment` holds one per hub, for the app's
/// lifetime, so its loop and in-flight work survive any navigation.
///
/// Every fetch feeds both consumers: it reaches CloudKit once (`RemoteFetchDepth`),
/// then hydrates DataZone and reads RelayZone from what that buffered.
/// The phone fetches when something changed (board #724): a silent push is
/// fetched at once, pushes landing during a fetch share one follow-up; a
/// safety poll (`SessionCadence`: every minute for the session on screen)
/// runs while the app is active and pauses whenever it is not, whatever
/// background mode keeps it alive.
@MainActor
@Observable
final class HubSession {
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
    /// The phone's lines to sessions and Finish (PROJ-16).
    let sessionInputs: SessionInputSender
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
    /// The hub whose zones this session syncs (`unlinkedHubID` while
    /// unlinked): held recordings of this hub are adopted here.
    let hubID: String
    /// The database this session's link lives in, which a silent push
    /// names (`AppEnvironment.handlePush`); nil for the demo.
    let databaseScope: CloudDatabaseScope?
    /// Recordings a wipe carried over (board #63), outside the replica,
    /// shared by every hub; nil holds nothing.
    @ObservationIgnored let hold: RecordingHold?
    /// Held recordings waiting for another hub than this one (the
    /// Recordings list shows them).
    var heldRecordings: [HeldRecording] = []

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
    /// The Mac's heartbeat as the last successful fetch left it in the
    /// replica; nil before one, or when the replica has none.
    private(set) var heartbeat: HeartbeatPayload?
    /// Why the last fetch failed (multi-hub spec §6.3: the hub's row shows
    /// it); a successful fetch clears it.
    private(set) var lastFetchError: String?
    /// Whether this session is the one on screen (multi-hub spec §5.3): it
    /// sets the safety poll's wait and the foreground-return rule.
    private(set) var role: SessionRole = .active
    /// How long a push waits for CKSyncEngine's own fetch run to begin
    /// before fetching through the engine itself.
    static let pushEngineGrace: TimeInterval = 2

    /// false while the app is not active (inactive or in the background):
    /// the safety poll is paused. Seeded from the app's state at launch, so
    /// a launch into the background (a silent push) never polls; the
    /// scene's first active phase sets it (`setActive`).
    private(set) var isActive: Bool
    /// true while the safety poll runs.
    var isLooping: Bool { loopTask != nil }
    /// Fetch cycles the loop has begun (a cancelled loop begins none).
    @ObservationIgnored private(set) var fetchCycles = 0

    @ObservationIgnored private let transport: any CloudSyncTransport
    @ObservationIgnored private let hydrator: ReplicaHydrator
    @ObservationIgnored private let feed: RelayFeed
    @ObservationIgnored let uploader: RecordingUploader
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
    /// The boot's first fetch, begun as soon as the transport has started
    /// (`beginLaunchFetch`).
    @ObservationIgnored private var launchFetchTask: Task<FetchOutcome, Never>?
    /// The first silent push that arrived before the launch fetch began: a
    /// launch into the background for it takes the light reach.
    @ObservationIgnored private var pushBeforeLaunch: PushArrival?
    /// The launch took the light reach (a push launched the app): the first
    /// activation fetches in full whatever the last fetch's age.
    @ObservationIgnored private var fullFetchOwed = false
    /// Ends the boot's background work (`BackgroundWork`): run once, when the boot ends or the
    /// session stops.
    @ObservationIgnored private var endBootWork: (@MainActor () -> Void)?
    /// The boot's first part: the applied observer set and the CloudKit
    /// engine started (the demo seeded), before the first fetch.
    @ObservationIgnored private var transportStartTask: Task<Void, Never>?
    /// Adopts the held recordings of this session's hub
    /// (`adoptHeld`), started by the init; the launch sweep waits for it.
    @ObservationIgnored private(set) var adoption: Task<HeldAdoption, Never>?
    /// The boot (seed or engine start, first fetch, recovery) is done.
    @ObservationIgnored private(set) var isBootstrapped = false
    @ObservationIgnored private var stopped = false

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "HubSession")

    /// Designated init with an injectable transport and replica path, so
    /// wiring tests build isolated sessions. Throws when the replica
    /// cannot open (the app then shows `BootFailureView`). `makeRecorder`
    /// builds the recorder over the session's uploader; tests pass a
    /// fake audio engine and clock, the app the microphone. `sleep` is the
    /// safety poll's wait, `now` the clock
    /// of the foreground-return rule. `remoteFetch` replaces the CloudKit
    /// reach of each fetch (tests); nil derives it from a
    /// `CloudKitTransport` (none for any other transport). `linkedDevice`
    /// is the saved link (the demo kind is always `DemoSeed.device`).
    /// `energy` counts the fetches and the upload attempts.
    /// `startsActive` seeds `isActive`: the app passes whether it launched
    /// active (`UIApplication`), so a launch into the background starts no
    /// safety poll; tests default to an active app.
    /// `uploadRetriesAllowed` is whether the app starts active (nil reads
    /// `UIApplication`; a cold launch reads not active there, and the
    /// scene's first active phase opens the gate through `setActive`).
    /// `replicaObservesSuspension` is for the live app-group replica, which
    /// `DatabaseSuspension` suspends while the app rests in the background;
    /// `startWork` then keeps the boot running and the replica usable until
    /// the boot ends (a launch into the background by a silent push).
    /// `hold` is the hold folder shared by every hub (nil holds nothing);
    /// `databaseScope` is the link's database, which routes silent pushes.
    init(
        transport: any CloudSyncTransport,
        replicaPath: String,
        transportKind: TransportKind = .inMemoryDemo,
        hubID: String = HubSession.unlinkedHubID,
        linkedDevice: LinkedDevice? = nil,
        defaults: UserDefaults = .standard,
        recordingsDirectory: URL? = nil,
        hold: RecordingHold? = nil,
        databaseScope: CloudDatabaseScope? = nil,
        startsActive: Bool = true,
        uploadRetriesAllowed: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        replicaObservesSuspension: Bool = false,
        makeRecorder: ((RecordingUploader) throws -> PhoneRecorderController)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        remoteFetch: (@Sendable (RemoteFetchDepth) async throws -> Void)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        energy: EnergyCounter? = nil,
        startWork: BackgroundWork.Starter? = nil
    ) throws {
        assert(
            !(transport is CloudKitTransport && transportKind == .inMemoryDemo),
            "a CloudKitTransport must not run under the demo kind"
        )
        store = try ReplicaStore(path: replicaPath, observesSuspension: replicaObservesSuspension)
        self.sleep = sleep
        self.now = now
        self.energy = energy
        isActive = startsActive
        self.transport = transport
        self.transportKind = transportKind
        self.hubID = hubID
        self.hold = hold
        self.databaseScope = databaseScope
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
        sessionInputs = SessionInputSender.sending(through: outbox, store: store)
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
            // The relaunch re-save waits while the Mac sleeps: its upload
            // already waits in CloudKit's queue (no "Upload stuck" for it).
            macOnline: { [store] in RelayFeed.isDesktopReachable(store: store, now: now()) },
            energy: energy
        )
        self.uploader = uploader
        recorder = try (makeRecorder ?? Self.liveRecorder)(uploader)
        if !startsActive {
            recorder.setForeground(false)
        }
        feed = RelayFeed(
            transport: transport,
            store: store,
            outbox: outbox,
            uploads: uploader,
            onActionApplied: hydrateAfterEcho
        )
        let settings = DeviceSettings(transport: transport, defaults: defaults, hubID: hubID)
        settings.linkedDevice = device
        deviceSettings = settings
        workbenchReplica.start(store: store)
        calendarReplica.start(store: store)
        phoneRecordings.start(store: store)

        startBoot(startWork)
    }

    /// Starts the boot. It writes the replica (the held recordings'
    /// adoption, the launch fetch, the outbox sweep, launch recovery): held
    /// from here, before a push can end its own work, until it is done.
    private func startBoot(_ startWork: BackgroundWork.Starter?) {
        endBootWork = startWork?("app-boot")
        adoption = Task { await adoptHeld() }
        let transportStart = Task {
            await startTransport()
            beginLaunchFetch()
        }
        transportStartTask = transportStart
        bootstrapTask = Task {
            await transportStart.value
            await bootstrap()
            finishBootWork()
        }
    }

    /// Ends the boot's background work, once.
    private func finishBootWork() {
        endBootWork?()
        endBootWork = nil
    }

    /// The launch fetch, begun right after the transport started, so a push
    /// that arrived before it is served by it (`handlePush`). In the
    /// foreground it takes the full reach; a launch into the background for
    /// a push takes the push's light reach, without the forced zone poll,
    /// and the first activation then fetches in full.
    private func beginLaunchFetch() {
        guard !stopped else { return }
        var depth = RemoteFetchDepth.full
        if !isActive, let push = pushBeforeLaunch {
            depth = .push(since: push.at, pollOnFallback: false)
            fullFetchOwed = true
        }
        launchFetchTask = startFetch(.launch, depth: depth)
    }

    /// Returns once the boot has ended (a silent push keeps its own work
    /// until then).
    func waitForBoot() async {
        await bootstrapTask?.value
    }

    /// Demo seed or engine start: everything before the first fetch.
    private func startTransport() async {
        // Before any fetch, so no applied echo goes unseen: an ask answer's
        // delivery, a start's session id.
        await outbox.setAppliedObserver(
            Self.appliedObserver(askAnswerer: askAnswerer, sessionStarts: sessionStarts, sessionInputs: sessionInputs)
        )
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
    }

    /// After `startTransport`: a first fetch so the screens have content
    /// at once, the launch sweeps, then the safety poll.
    private func bootstrap() async {
        _ = await launchFetchTask?.value
        // An action the Mac never answered within 24 h is failed locally, so
        // the queued count never counts it forever.
        do {
            try await outbox.sweepSilentPending()
        } catch {
            Self.logger.warning("silent-pending sweep failed: \(error.localizedDescription, privacy: .public)")
        }
        // Held recordings of this hub get their rows first; the rest sit in
        // the hidden hold folder, which the sweep below never reaches.
        _ = await adoption?.value
        // A capture cut short by a kill is finalized from its file, and
        // files without a ledger row are deleted. Then, in the foreground
        // only, the upload pass with the relaunch retry: recordings saved
        // but not yet acknowledged go out again when their backoff is due
        // (the hub's processed set absorbs duplicates). A launch into the
        // background uploads nothing; the first activation runs the pass
        // (`setUploadRetries`; one opened during the boot is covered here).
        await recorder.recoverOnLaunch()
        if uploadRetries.isOpen {
            await recorder.uploadPending()
        }
        isBootstrapped = true
        // The launch fetch just ran: the safety poll waits a full interval.
        // A light launch (a push launched the app) whose scene turned active
        // during the boot still owes the full fetch: `setActive` could not
        // start it before the boot ended, so it runs now.
        restartLoop(firstCycle: fullFetchOwed ? .foreground : nil)
    }

    /// The outbox's one applied observer, shared by the app and the tests:
    /// every applied echo goes to both consumers on the main actor, and
    /// each keeps only its own kind.
    nonisolated static func appliedObserver(
        askAnswerer: AskAnswerer,
        sessionStarts: SessionStarter,
        sessionInputs: SessionInputSender? = nil
    ) -> @Sendable (ActionRequestPayload) -> Void {
        { [weak askAnswerer, weak sessionStarts, weak sessionInputs] action in
            Task { @MainActor in
                askAnswerer?.receiveApplied(action)
                sessionStarts?.receiveApplied(action)
                sessionInputs?.receiveApplied(action)
            }
        }
    }

    /// The device recorder: the microphone, recordings in Application
    /// Support, and local notifications for the 3-hour cap notice and the
    /// long-pause auto-finish (saved, or not saved).
    private static func liveRecorder(_ uploader: RecordingUploader) throws -> PhoneRecorderController {
        let recorder = PhoneRecorderController(uploader: uploader, engine: AVAudioCaptureEngine())
        recorder.onCapNotice = { RecorderNotices.postCapNotice() }
        recorder.onAutoFinish = { RecorderNotices.postAutoFinishNotice() }
        recorder.onAutoFinishFailed = { RecorderNotices.postAutoFinishFailedNotice() }
        holdReplica(for: recorder)
        return recorder
    }

    /// The recorder's holds on the replica: a running capture keeps the app
    /// alive in the background and writes the ledger, so the replica stays
    /// usable while its audio runs; every save runs as background work of
    /// its own (`recording-save`), since a paused capture holds nothing.
    static func holdReplica(
        for recorder: PhoneRecorderController,
        suspension: DatabaseSuspension? = nil,
        startWork: BackgroundWork.Starter? = nil
    ) {
        let suspension = suspension ?? .shared
        let startWork = startWork ?? BackgroundWork.starter(suspension: suspension)
        var release: (@MainActor () -> Void)?
        recorder.onAudioRunning = { running in
            if running {
                if release == nil { release = suspension.hold() }
            } else {
                release?()
                release = nil
            }
        }
        recorder.beginSave = { startWork("recording-save") }
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
    /// the outcome of the fetch that served its push. `at` is when the push
    /// arrived (the `AppDelegate` stamps it before any hop; nil: now): the
    /// CloudKit run that covers it began then or later. A push arriving
    /// before the launch fetch began is served by it, and a launch into the
    /// background for it takes the light reach.
    /// A frozen or stopped session fetches nothing for it.
    func handlePush(at arrival: Date? = nil, inForeground: Bool) async -> FetchOutcome {
        guard !stopped else { return .noData }
        let push = PushArrival(serial: fetchSerial, at: arrival ?? now(), inForeground: inForeground)
        if launchFetchTask == nil {
            if pushBeforeLaunch == nil {
                pushBeforeLaunch = push
            }
            // The launch fetch begins once the engine has started: the push
            // never fetches through an engine not yet built.
            await transportStartTask?.value
        }
        return await fetch(for: push)
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
    /// fetch takes the light CloudKit reach, any other the full one unless
    /// `depth` says otherwise.
    private func startFetch(
        _ trigger: FetchTrigger, push: PushArrival? = nil, depth: RemoteFetchDepth? = nil
    ) -> Task<FetchOutcome, Never> {
        fetchSerial += 1
        let serial = fetchSerial
        let depth = depth ?? push.map { .push(since: $0.at, pollOnFallback: $0.inForeground) } ?? .full
        if depth == .full {
            fullFetchOwed = false
        }
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
            lastFetchError = remoteError.localizedDescription
            let what = "\(trigger), \(Self.describe(depth))"
            Self.logger.error("CloudKit fetch failed (\(what, privacy: .public)): \(remoteError.localizedDescription, privacy: .public)")
            if owed {
                await applyBuffered()
            }
            return .failed
        }
        do {
            hydrated = try await hydrator.hydrateOnce()
        } catch {
            lastFetchError = error.localizedDescription
            let what = "\(trigger), \(Self.describe(depth))"
            Self.logger.error("replica hydrate failed (\(what, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        lastSyncAt = now()
        lastFetchError = nil
        var routed = 0
        do {
            routed = try await feed.pollOnce()
        } catch {
            Self.logger.error("relay fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        readHeartbeat()
        onFetched?()
        return hydrated.applied + hydrated.deleted + routed > 0 ? .newData : .noData
    }

    /// A depth for the log: `full` or `push`.
    nonisolated private static func describe(_ depth: RemoteFetchDepth) -> String {
        switch depth {
        case .full: "full"
        case let .push(_, poll): poll ? "push+poll" : "push"
        }
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
        readHeartbeat()
        onFetched?()
    }

    /// Reads the Mac's heartbeat from the replica into `heartbeat`. A read
    /// that fails keeps the last one: the fetch itself succeeded.
    private func readHeartbeat() {
        do {
            heartbeat = try store.reader.read { [store] db in
                try SettingsSnapshot.decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
            }
        } catch {
            Self.logger.error("heartbeat read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Scene phase: the safety poll pauses while the app is not active. On
    /// the return it fetches at once, unless the last successful fetch is
    /// under `SessionCadence.foregroundRefetchAfter(role:)` old (a Control
    /// Center peek for the session on screen, five minutes for the others):
    /// then it only applies what the engine buffered meanwhile (no network).
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
        let recent = !fullFetchOwed && (lastSyncAt.map { now().timeIntervalSince($0) < SessionCadence.foregroundRefetchAfter(role: role) } ?? false)
        restartLoop(firstCycle: recent ? nil : .foreground)
        if recent, isBootstrapped {
            Task { await applyBuffered() }
        }
    }

    /// Opens or closes the uploader's retries with the scene phase. Each
    /// opening after the boot runs an upload pass: due retries go out on
    /// the return to the foreground. The boot's own pass covers a gate
    /// open when it reaches it, so a cold launch runs one pass, not two.
    private func setUploadRetries(_ open: Bool) {
        guard uploadRetries.set(open), open, isBootstrapped, !stopped else { return }
        Task { [weak self] in
            guard let self, !self.stopped else { return }
            await self.recorder.uploadPending()
        }
    }

    /// Whether this session is the one on screen: the new wait applies
    /// from now, with no fetch of its own.
    func setRole(_ role: SessionRole) {
        guard role != self.role else { return }
        self.role = role
        restartLoop(firstCycle: nil)
    }

    /// Something of this hub's is on its way to the Mac: an action the Mac
    /// has not answered, or a recording it has not acknowledged. An
    /// unreadable ledger counts as pending: the poll then keeps the faster
    /// pace rather than leave an echo unseen.
    var hasPendingWork: Bool {
        get async {
            do {
                if try store.pendingActions().contains(where: { $0.state == .pending }) { return true }
                return try store.phoneRecordings().contains(where: \.needsUpload)
            } catch {
                Self.logger.error("pending work read failed: \(error.localizedDescription, privacy: .public)")
                return true
            }
        }
    }

    /// The one place the phone's link changes (the link flow and unlink):
    /// Settings, the action outbox and the recording uploader all take the
    /// new device id, then waiting recordings go out at once. With
    /// `writesAllowed: false` the link stands (Settings still shows it) but
    /// the outbox, the uploader and the Settings toggles get no device, so
    /// nothing is sent: a toggle meanwhile is only kept, like one made
    /// before linking.
    /// When writes come back for the same link (the moved hub returned),
    /// the current device record is written once, so a toggle kept
    /// meanwhile reaches the Mac.
    func setLinkedDevice(_ device: LinkedDevice?, writesAllowed: Bool = true) async {
        let writesReturn = writesAllowed && !self.writesAllowed && device != nil && device == linkedDevice
        linkedDevice = device
        self.writesAllowed = writesAllowed
        deviceSettings.linkedDevice = writesAllowed ? device : nil
        if writesReturn, let payload = deviceSettings.devicePayload() {
            do {
                try await transport.save([try CloudRecordFactory.record(for: payload, modifiedAt: payload.updatedAt)])
            } catch {
                Self.logger.error("device record not rewritten: \(error.localizedDescription, privacy: .public)")
            }
        }
        let sendingID = writesAllowed ? device?.deviceID : nil
        await outbox.setDeviceID(sendingID)
        await uploader.setDeviceID(sendingID)
        await recorder.uploadPending()
    }

    /// The transport the link flow writes this phone's `device` record
    /// through.
    var linkTransport: any CloudSyncTransport { transport }

    /// Asks a CloudKit transport to send its queue now (the unlinked record
    /// before a stop), once the boot has started its engine: it does not
    /// wait for the first fetch, which a slow network can hold for long.
    func sendNow() async {
        await transportStartTask?.value
        await (transport as? CloudKitTransport)?.sendNow()
    }

    /// Stops the loop for good (tests' teardown; the app never stops).
    func stop() {
        stopped = true
        transportStartTask?.cancel()
        finishBootWork()
        bootstrapTask?.cancel()
        loopTask?.cancel()
        loopTask = nil
    }

    /// Stops the loop and the CloudKit engine for good, after the boot has
    /// ended: the link flow then builds the next session on the same
    /// files.
    func shutDown() async {
        stop()
        await bootstrapTask?.value
        await (transport as? CloudKitTransport)?.stop()
    }

    /// Stops the safety poll and the CloudKit engine for good and turns
    /// writes off, keeping the replica open for reading: later pushes fetch
    /// nothing (`handlePush`), and the screens still show what it holds.
    func freeze() async {
        await shutDown()
        await setLinkedDevice(linkedDevice, writesAllowed: false)
    }

    /// The safety poll's next wait for this session's role and work.
    private func pollWait() async -> Duration {
        SessionCadence.pollInterval(role: role, hasPendingWork: await hasPendingWork)
    }

    /// Restarts the safety poll: `firstCycle` fetches at once (counted as
    /// that trigger), then one `.loop` fetch per `SessionCadence` wait, read
    /// before each cycle (so pending work shortens an inactive session's
    /// wait without a restart).
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
                guard let wait = await self?.pollWait() else { return }
                do {
                    try await sleep(wait)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.fetchCycles += 1
                _ = await self.startFetch(.loop).value
            }
        }
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

extension PhoneRecording {
    /// On its way to the Mac and not yet acknowledged: waiting, or saved
    /// and waiting for the Mac's receipt, while it still retries by itself.
    var needsUpload: Bool {
        (state == .waiting || state == .uploading) && !isUploadStuck
    }
}

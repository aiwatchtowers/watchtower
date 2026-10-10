import Foundation
import Observation
import os
@_spi(DemoTransport) import WatchtowerSync

/// Which transport an `AppEnvironment` runs on: probed in `init()`,
/// injectable through the designated init for tests. `.cloudKit` NEVER
/// seeds: a real install starts empty and hydrates from the user's own zone.
enum TransportKind: String, Sendable {
    case cloudKit
    case inMemoryDemo
}

/// What the CloudKit transport tells the link flow (spec §9).
enum LinkSignal: Sendable {
    /// `shared` scope: the Mac's zones are gone (`TransportEvent.unlinked`).
    case unlinked
    /// An iCloud account sign-out or switch reset the transport.
    case accountChanged
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

    /// The loop's cadence: 5 s on Now and Workbench, 30 s otherwise.
    private(set) var fetchInterval: Duration = .seconds(30)
    /// false while the app is in the background: the loop is paused.
    private(set) var isActive = true
    /// true while the fetch loop runs.
    var isLooping: Bool { loopTask != nil }
    /// Fetch cycles the loop has begun (a cancelled loop begins none).
    @ObservationIgnored private(set) var fetchCycles = 0

    @ObservationIgnored private let transport: any CloudSyncTransport
    @ObservationIgnored private let hydrator: ReplicaHydrator
    @ObservationIgnored private let feed: RelayFeed
    @ObservationIgnored private let uploader: RecordingUploader
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// The loop's wait between cycles; tests step it by hand.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
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
    /// runs `scope`'s database, linked as `linkedDevice` (`AppRoot` reads
    /// both from the `LinkStore`).
    convenience init(
        recordingsDirectory: URL? = nil,
        scope: CloudDatabaseScope = .private,
        linkedDevice: LinkedDevice? = nil
    ) throws {
        if CloudKitTransport.entitlementPresent() {
            let directory = try Self.appGroupDirectory()
            let transportStore = try TransportStore(path: Self.liveTransportStorePath(in: directory))
            try self.init(
                transport: CloudKitTransport(store: transportStore, scope: scope),
                replicaPath: Self.liveReplicaPath(in: directory),
                transportKind: .cloudKit,
                linkedDevice: linkedDevice,
                recordingsDirectory: recordingsDirectory
            )
        } else {
            try self.init(
                transport: InMemoryCloudTransport(),
                replicaPath: try Self.applicationSupportDirectory().appendingPathComponent("replica.sqlite").path,
                transportKind: .inMemoryDemo,
                recordingsDirectory: recordingsDirectory
            )
        }
    }

    /// Designated init with an injectable transport and replica path, so
    /// wiring tests build isolated environments. Throws when the replica
    /// cannot open (the app then shows `BootFailureView`). `makeRecorder`
    /// builds the recorder over the environment's uploader; tests pass a
    /// fake audio engine and clock, the app the microphone. `sleep` is the
    /// fetch loop's wait between cycles. `linkedDevice` is the saved link
    /// (the demo kind is always `DemoSeed.device`).
    init(
        transport: any CloudSyncTransport,
        replicaPath: String,
        transportKind: TransportKind = .inMemoryDemo,
        linkedDevice: LinkedDevice? = nil,
        defaults: UserDefaults = .standard,
        recordingsDirectory: URL? = nil,
        makeRecorder: ((RecordingUploader) throws -> PhoneRecorderController)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        assert(
            !(transport is CloudKitTransport && transportKind == .inMemoryDemo),
            "a CloudKitTransport must not run under the demo kind"
        )
        store = try ReplicaStore(path: replicaPath)
        self.sleep = sleep
        self.transport = transport
        self.transportKind = transportKind
        let device = transportKind == .inMemoryDemo ? DemoSeed.device : linkedDevice
        self.linkedDevice = device

        // On the live path the hydrator nudges the CKSyncEngine before each
        // cycle; the feed reads what that fetch buffered, so it gets no pull
        // of its own. An in-memory stand-in has no engine and gets nil.
        let pull: (@Sendable () async throws -> Void)? = (transport as? CloudKitTransport)
            .map { cloud in { @Sendable in try await cloud.pull() } }
        let hydrator = ReplicaHydrator(transport: transport, store: store, pull: pull)
        self.hydrator = hydrator
        let outbox = ActionOutbox(transport: transport, store: store, deviceID: device?.deviceID)
        self.outbox = outbox
        reportRequests = SessionReportRequester.sending(through: outbox)
        boardWriter = BoardWriter.sending(through: outbox, store: store)
        askAnswerer = AskAnswerer.sending(through: outbox, store: store, drafts: askDrafts)
        sessionStarts = SessionStarter.sending(through: outbox, store: store)
        // An `applied` echo clears the queued row; hydrating right behind it
        // lands the Mac's authoritative change at the same moment.
        let hydrateAfterEcho: @Sendable () async -> Void = { [hydrator] in
            do {
                _ = try await hydrator.hydrateOnce()
            } catch {
                Self.logger.warning("post-echo hydrate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let uploader = RecordingUploader(
            transport: transport,
            store: store,
            directory: try recordingsDirectory ?? PhoneRecorderController.defaultDirectory(),
            deviceID: device?.deviceID
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
    /// at once, then the fetch loop.
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
        // A capture cut short by a kill is finalized from its file, and
        // files without a ledger row are deleted. Then the relaunch retry:
        // recordings saved but not yet acknowledged go out again (the hub's
        // processed set absorbs duplicates).
        await recorder.recoverOnLaunch()
        await recorder.uploadPending()
        isBootstrapped = true
        restartLoop()
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
    /// Support, and a local notification for the 3-hour cap notice.
    private static func liveRecorder(_ uploader: RecordingUploader) throws -> PhoneRecorderController {
        let recorder = PhoneRecorderController(uploader: uploader, engine: AVAudioCaptureEngine())
        recorder.onCapNotice = { RecorderNotices.postCapNotice() }
        return recorder
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
        onFetched?()
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
        // A capture keeps going in the background, but its timer slows.
        recorder.setForeground(active)
        restartLoop()
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

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        guard isBootstrapped, isActive, !stopped else { return }
        let interval = fetchInterval
        let sleep = sleep
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.fetchCycles += 1
                await self.refresh()
                try? await sleep(interval)
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
    static func appGroupDirectory() throws -> URL {
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

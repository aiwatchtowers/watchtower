import AppKit
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// Settings → Mobile drives the toggle and reads the hub through these.
extension AppState: MobileSettingsHost {}

extension AppState {
    /// "Keep this Mac awake for the iPhone": on unless the owner turned it off (ask #614).
    var isMobileKeepAwakeEnabled: Bool {
        get { mobileSyncDefaults.object(forKey: Constants.mobileKeepAwakeKey) as? Bool ?? true }
        set { mobileSyncDefaults.set(newValue, forKey: Constants.mobileKeepAwakeKey) }
    }

    /// Whether Mobile is on, from `watchtower hub status --json` (the Go hub
    /// holds the owner's toggle since the hand-over, go hub plan 3 Task 22),
    /// outvoted by the organization's `MobileSync = off` (#608).
    var isMobileSyncEnabled: Bool {
        guard managedPolicy.policy.mobileSyncMode != "off" else { return false }
        guard swiftHubRetired else { return legacySwiftHubToggle }
        return hubCenter?.status.map(Self.hubIsOn) ?? false
    }

    /// A Go hub status the owner left on: anything but off for no reason or
    /// switched off (`disabled`); a hub off for another reason (locked, a
    /// start that failed) is still on for the owner.
    nonisolated static func hubIsOn(_ status: WatchtowerCore.HubStatus) -> Bool {
        guard status.state == "off" else { return true }
        return status.reason != nil && status.reason != "disabled" && status.reason != "policy_off"
    }

    /// The Swift hub's own toggle (`mobileSyncEnabled` in the defaults),
    /// read only by the Swift hub's code until go hub plan 3 Task 24 deletes
    /// it, and once by the hand-over (`hubAdoptSettings`).
    var legacySwiftHubToggle: Bool {
        mobileSyncDefaults.bool(forKey: Constants.mobileSyncEnabledKey) && managedPolicy.policy.mobileSyncMode != "off"
    }

    /// The Settings → Mobile toggle: on starts the hub (building it on first
    /// use), off stops it. The hub object is kept, so toggling never opens a
    /// second transport.
    func setMobileSyncEnabled(_ enabled: Bool) {
        // MobileSync = off (#608) cannot be turned on from here, whatever
        // the view shows; the stored toggle is left as it was.
        if enabled, mobileSyncLockedByPolicy { return }
        // The Go hub holds the toggle now (Task 23 drives it): inert, and
        // `mobileSyncEnabled` is never written back.
        if swiftHubRetired { return }
        // Moved to a newer Watchtower: nothing turns on here; off still goes through.
        if enabled, resolveMobileHubMoved() { return }
        mobileSyncDefaults.set(enabled, forKey: Constants.mobileSyncEnabledKey)
        guard enabled else {
            mobileHub?.disable()
            return
        }
        if let hub = mobileHub {
            Task { await hub.start() }
        } else if let pool = mobileHubPool {
            initMobileHub(dbPool: pool)
        }
    }

    var mobileSyncLockedByPolicy: Bool { managedPolicy.policy.mobileSyncMode == "off" }

    var mobileToggleRetired: Bool { swiftHubRetired }

    /// Reads the downgrade guard's `MOVED` note into `isMobileHubMoved` and
    /// returns it: a newer Watchtower runs the phone hub, so this app starts
    /// none and Settings → Mobile shows only that (spec §12.1).
    @discardableResult
    func resolveMobileHubMoved() -> Bool {
        let moved = MobileHubMovedGuard.isMoved(mobileHubDir: mobileHubDirectory)
        if moved != isMobileHubMoved { isMobileHubMoved = moved }
        return moved
    }

    /// Every policy tick: a wipe under `MobileSync = off` whose hub could not
    /// be built (no storage yet) is tried again (`wipeHubForPolicyOff` runs
    /// once per run).
    func retryPolicyOffWipe() {
        guard mobileSyncPolicy.current == "off", mobileHub == nil, let pool = mobileHubPool else { return }
        wipeHubForPolicyOff(dbPool: pool)
    }

    /// Follows a changed policy on the hub: `off` stops it and removes what
    /// it published (`disable`); leaving `off` starts it again only when the
    /// owner's toggle is on; `workbench_only` empties the other kinds at the
    /// next cycle (`mobileSyncPolicy`). Nothing is turned on by itself.
    func managedPolicyChanged(_ policy: ManagedPolicy) {
        let previous = mobileSyncPolicy.current
        let mode = policy.mobileSyncMode
        mobileSyncPolicy.store(mode)
        guard mode != previous else { return }
        if mode == "off" {
            if let hub = mobileHub {
                hub.disable()
            } else if let pool = mobileHubPool {
                wipeHubForPolicyOff(dbPool: pool)
            }
        } else if previous == "off", !swiftHubRetired, legacySwiftHubToggle, !resolveMobileHubMoved() {
            if let hub = mobileHub {
                Task { await hub.start() }
            } else if let pool = mobileHubPool {
                initMobileHub(dbPool: pool)
            }
        }
    }
}

extension AppState {
    /// A phone start with "Bring the window forward" (mobile POC spec §6.5):
    /// the workbench's page on the main window, the app in front — before
    /// the start, so its Work on it placement lands on that page.
    func bringWorkbenchForward(projectID: Int64) {
        selectedDestination = .workbench
        workbenchesViewModel?.drill(into: projectID)
        (NSApp.delegate as? TrayAppDelegate)?.endLoginLaunchClosing()
        ActivationPolicyDecision.becomeRegularAndActivate()
        let shown = NSApp.windows.first { TrayAppDelegate.isMainWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        if let shown {
            if shown.isMiniaturized { shown.deminiaturize(nil) }
            shown.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// B registers its slice sources and dispatcher handlers here.
    func buildMobileHub(storage: MobileHubStorage, dbPool: DatabasePool) throws -> MobileHubService {
        let dispatcher = MobileHubCommandDispatcher()
        registerWorkbenchHandlers(on: dispatcher, storage: storage, dbPool: dbPool)
        // Without a linked phone only the link flow's answer is published,
        // and the CLI companions run nothing (board #724).
        let sidecar = storage.sidecar
        let hasPhone: @Sendable () -> Bool = { MobileLinkCenter.hasLinkedPhone(sidecar) }
        let inputs = makeSessionInputs(storage: storage, dbPool: dbPool)
        inputs?.register(on: dispatcher)
        // The folder's git status goes through the CLI (PROJ-10's git); no
        // CLI, no refresher, and the workbench records carry no branch.
        let gitRefresher = workbenchesViewModel?.cli.map { WorkbenchGitRefresher.live(cli: $0, dbPool: dbPool, isActive: hasPhone) }
        // The terminals' liveness, copied by the fast lane for the session
        // projection's off-main resolution.
        let liveness = SessionLivenessBox()
        let summaries = workbenchesViewModel?.cli.map {
            SessionReportSummaryRunner.live($0.runner, dbPool: dbPool, liveness: liveness, isActive: hasPhone)
        }
        let recordings = try PhoneRecordingJobs.live(sidecar: storage.sidecar, dbPool: dbPool, recorder: meetingRecorderCenter)
        let phoneUpload: @Sendable (Int64) -> String? = { [recordings] in recordings.uploadID(forTranscript: $0) }
        let hidden = HiddenSessionIDsBox()
        let sessions = TerminalSessionSlice(
            liveness: { liveness.current },
            reportSummary: { summaries?.summary(workbenchID: $0, sessionID: $1) },
            hiddenIDs: { hidden.current }
        )
        // Each session's own report (`--session S --json`, scoped by the CLI,
        // PROJ-14) and the timeline's state milestones; no CLI, no reports.
        let reports = workbenchesViewModel?.cli.map {
            SessionReportRunner.live($0.runner, dbPool: dbPool, sessions: sessions, sidecar: sidecar, isActive: hasPhone)
        }
        if let reports { SessionReportRequestHandler(dbPool: dbPool, runner: reports, sessions: sessions).register(on: dispatcher) }
        // The chat of a session the phone watches (`session-feed --json`);
        // no CLI, no chat.
        let chats = workbenchesViewModel?.cli.map {
            SessionChatRunner.live($0.runner, isLive: { liveness.current.liveIDs.contains($0) }, isActive: hasPhone)
        }
        if let chats { SessionChatRequestHandler(dbPool: dbPool, runner: chats, sessions: sessions).register(on: dispatcher) }
        let sources: [any SliceSource] = [
            WorkbenchSlice(
                gitStatus: { gitRefresher?.status(for: $0) }, sessionCounts: { try sessions.sessionCounts($0) },
                defaultAgent: { ConfigService.readWorkbenchDefaultAgent() }
            ),
            WorkbenchTargetSlice(),
            WorkbenchCommentSlice(),
            sessions,
            OwnerAskSlice(),
            WorkAlertSlice(
                sidecar: storage.sidecar, isAway: { [box = ownerAwayBox] in box.read() }, liveness: { liveness.current },
                hiddenIDs: { hidden.current }
            ),
            PermissionRequestSlice { liveness.current },
            CalendarEventSlice(),
            MeetingTranscriptSlice(phoneRecordingID: phoneUpload),
            RecordingJobSlice(sidecar: storage.sidecar),
            SessionTimelineSlice(sessions: sessions, sidecar: sidecar),
            DeviceGrantSlice(sidecar: sidecar, hubID: try sidecar.ensureHubID(), keyring: storage.keyring)
        ] + (reports == nil ? [] : [SessionReportSlice(sessions: sessions, sidecar: sidecar)])
            + (chats.map { [SessionChatSlice(runner: $0)] } ?? [])
        let transport = storage.transport
        // The publisher seals through the storage's secure transport; without hub keys (nil) it publishes nothing.
        let publisher = SlicePublisher(
            dbPool: dbPool, state: storage.sidecar, transport: storage.secure, sources: sources, assets: storage.sliceAssets,
            isLinked: hasPhone,
            allowedKinds: { [mobileSyncPolicy] in mobileSyncPolicy.allowedKinds },
            // Labelled: a trailing closure would bind to `clock`, the first
            // closure parameter.
            sendNow: { await transport.sendNow() }
        )
        followPendingDeletes(into: hidden)
        // The companions' changes (git status, summaries, reports, phone
        // recording jobs) are normal kinds: the next full tick diffs them.
        let fastLane = FastLane(
            dbPool: dbPool, agentStates: sessionAgentStateCenter, terminalCenter: terminalCenter, liveness: liveness,
            ownerAway: ownerAwayCenter,
            nudge: { [weak publisher] in publisher?.nudge(kinds: $0) },
            sessionStateChanged: { [weak gitRefresher, weak summaries] workbench in
                gitRefresher?.sessionStateChanged(workbenchID: workbench)
                summaries?.sessionStateChanged(workbenchID: workbench)
            },
            sessionStatesChanged: { [weak reports] in reports?.sessionStatesChanged() }
        )
        // A changed watched chat goes out within seconds, not on the next tick.
        chats?.onChange = { [weak publisher] in publisher?.nudge(kinds: [.sessionChat]) }
        let keepAwake = makeKeepAwake(dbPool: dbPool, sidecar: sidecar, liveness: liveness, hasPhone: hasPhone)
        let optional: [(any HubCompanion)?] = [gitRefresher, summaries, reports, chats, inputs]
        let companions: [any HubCompanion] = optional.compactMap { $0 } + [fastLane, recordings, keepAwake]
        let hub = try assembleMobileHub(
            storage: storage, dbPool: dbPool, dispatcher: dispatcher, publisher: publisher, companions: companions,
            recordingUploads: .init { [recordings, mobileSyncPolicy] upload, audio in
                try mobileSyncPolicy.checkRecordingAllowed() // #608: not workbench data
                try await recordings.ingest(upload, audio: audio)
            }
        )
        wireTyping(hub.linkCenter, inputs: inputs)
        return hub
    }

    /// The Mac stays awake while a session runs and the phone has been in touch (ask #614).
    private func makeKeepAwake(
        dbPool: DatabasePool, sidecar: HubSyncState, liveness: SessionLivenessBox, hasPhone: @escaping @Sendable () -> Bool
    ) -> KeepAwakeCompanion {
        let defaults = mobileSyncDefaults
        return KeepAwakeCompanion(
            assertion: MacAwakeAssertion(),
            enabled: { defaults.object(forKey: Constants.mobileKeepAwakeKey) as? Bool ?? true },
            liveBoardSessions: { KeepAwakeCompanion.liveBoardSessions(dbPool, liveIDs: liveness.current.liveIDs) },
            lastPhoneContact: { hasPhone() ? sidecar.lastPhoneContact() : nil }
        )
    }

    /// The Undo batch's sessions (PROJ-17) into `hidden` now and on every
    /// change. Session and workbench records are normal kinds (board #724):
    /// the next full tick drops the hidden sessions, no nudge.
    private func followPendingDeletes(into hidden: HiddenSessionIDsBox) {
        hidden.store(workbenchesViewModel?.pendingDeletes.ids ?? [])
        workbenchesViewModel?.onPendingDeletesChanged = { ids in hidden.store(ids) }
    }

    /// The asks', board writes' and session starts' handlers (spec §6).
    private func registerWorkbenchHandlers(
        on dispatcher: MobileHubCommandDispatcher, storage: MobileHubStorage, dbPool: DatabasePool
    ) {
        if let asks = workbenchesViewModel?.asks {
            let askAnswers = AskAnswerHandler(dbPool: dbPool, sidecar: storage.sidecar) { [weak asks] ask, answer in
                // A rebuilt workbench state rebuilds the hub too; until then
                // nothing is written.
                await asks?.answer(ask, with: answer) ?? .failed("The workbench is reloading on the Mac")
            }
            dispatcher.register(.askAnswer) { try await askAnswers.handle($0) }
        }
        // Board writes report through the board's own onOwnerWrite, so the
        // Mac never announces the owner's phone edit (spec §6.1).
        BoardHandlers(
            dbPool: dbPool, cli: workbenchesViewModel?.cli,
            isReporting: { [weak vm = workbenchesViewModel] in vm?.onOwnerWrite != nil },
            publishSoon: { [weak self] in self?.mobileHub?.publishSoon(kinds: $0) },
            onOwnerWrite: { [weak vm = workbenchesViewModel] projectID, subject in
                vm?.onOwnerWrite?(projectID, subject)
            }
        ).register(on: dispatcher)
        // Starts take the Desktop's own start (Work on it's path) and stops
        // `TerminalCenter.close` (spec §6.5), under the linked phone's own
        // grants (`devices`, A8).
        SessionStartStopHandlers(
            dbPool: dbPool, workbenches: workbenchesViewModel, terminalCenter: terminalCenter,
            deviceGrant: { [sidecar = storage.sidecar] in MobileLinkCenter.sessionGrant(sidecar, deviceID: $0) },
            bringForward: { [weak self] in self?.bringWorkbenchForward(projectID: $0) }
        ).register(on: dispatcher)
        // Automation runs take quick run's path under the start-sessions grant (ask #692).
        AutomationRunHandler(
            dbPool: dbPool, quickRun: { [weak self] in self?.quickRunCenter },
            deviceGrant: { [sidecar = storage.sidecar] in MobileLinkCenter.sessionGrant(sidecar, deviceID: $0) },
            publishSoon: { [weak self] in self?.mobileHub?.publishSoon(kinds: $0) }
        ).register(on: dispatcher)
        // Permission answers decide the waiting hook's row (its own grant)
        // and interrupts send one Esc (the typing grant), #517.
        PermissionAnswerHandlers(
            dbPool: dbPool, terminalCenter: terminalCenter,
            status: { [weak agentStates = sessionAgentStateCenter] in agentStates?.statuses[$0] },
            deviceGrant: { [sidecar = storage.sidecar] in MobileLinkCenter.sessionGrant(sidecar, deviceID: $0) },
            deviceName: { [sidecar = storage.sidecar] in MobileLinkCenter.deviceName(sidecar, deviceID: $0) },
            control: workbenchesViewModel?.sessionControl
        ).register(on: dispatcher)
    }

    /// A line from the phone goes through the asks' own delivery
    /// (`SessionLineDelivery`, PROJ-12) under PROJ-16's gate; no workbench
    /// state, no session input.
    private func makeSessionInputs(storage: MobileHubStorage, dbPool: DatabasePool) -> SessionInputHandlers? {
        workbenchesViewModel.map { vm in
            SessionInputHandlers(
                dbPool: dbPool, sidecar: storage.sidecar, lineDelivery: vm.lineDelivery, terminalCenter: terminalCenter,
                status: { [weak agentStates = sessionAgentStateCenter] in agentStates?.statuses[$0] },
                deviceGrant: { [sidecar = storage.sidecar] in MobileLinkCenter.sessionGrant(sidecar, deviceID: $0) },
                lateEcho: RelayProcessor.lateEcho(transport: storage.secure, sidecar: storage.sidecar),
                control: vm.sessionControl
            )
        }
    }

    /// The phones' typing grants (spec §10): a revoke fails the phone's held
    /// lines; a request asks the owner — Settings → Mobile shows it, and a
    /// macOS notice asks while the app is in the background (OD-2).
    private func wireTyping(_ linkCenter: MobileLinkCenter?, inputs: SessionInputHandlers?) {
        linkCenter?.onTypingRevoked = { [weak inputs] in inputs?.revoked(deviceID: $0) }
        linkCenter?.onTypingRequested = { device in
            guard NSApp?.isActive == false else { return }
            NotificationService.shared.sendMobileTypingRequestNotification(deviceID: device.deviceID, name: device.name)
        }
    }

    /// The last step of `buildMobileHub`: the run's link center (when the
    /// storage has a share service), the relay processor that hands it the
    /// phones' `device` records, and the hub it hangs on.
    func assembleMobileHub(
        storage: MobileHubStorage,
        dbPool: DatabasePool,
        dispatcher: MobileHubCommandDispatcher,
        publisher: SlicePublisher,
        companions: [any HubCompanion],
        recordingUploads: RelayProcessor.RecordingUploads
    ) throws -> MobileHubService {
        let hostInfo = HubHostInfo.live(dbPool: dbPool, ownerUser: storage.ownerUser)
        let linkCenter = mobileLinkCenter ?? MobileLinkCenter.forRun(storage: storage, macName: hostInfo.macName)
        mobileLinkCenter = linkCenter
        let processor = RelayProcessor(
            transport: storage.secure, sidecar: storage.sidecar, dispatcher: dispatcher,
            hubID: try storage.sidecar.ensureHubID(), recordingUploads: recordingUploads,
            deviceRecords: linkCenter?.relayRoute
        )
        let hub = MobileHubService(
            transport: storage.transport, publisher: publisher, processor: processor, sidecar: storage.sidecar,
            hostInfo: hostInfo, keyring: storage.keyring, companions: companions
        ) { [weak self] in self?.legacySwiftHubToggle ?? false }
        linkCenter?.attach(to: hub)
        return hub
    }
}

extension AppState {
    private static let mobileHubLogger = Logger(subsystem: Constants.bundleID, category: "MobileHub")

    /// Tears down the previous hub and, while the toggle is on, builds and
    /// starts a new one over the run's one transport and sidecar. Called at
    /// the end of `initWorkbenches`. With the toggle off nothing is opened —
    /// unless the organization's `MobileSync = off` must still wipe the
    /// phone (`wipeHubForPolicyOff`).
    func initMobileHub(dbPool: DatabasePool) {
        let previous = mobileHub
        previous?.dispose()
        mobileHub = nil
        mobileHubPool = dbPool
        guard legacySwiftHubToggle else {
            wipeHubForPolicyOff(dbPool: dbPool)
            return
        }
        guard let hub = buildRunHub(dbPool: dbPool) else { return }
        Task {
            // The replaced hub's relay pass ends first: two never overlap.
            await previous?.waitUntilStopped()
            await hub.start()
        }
    }

    /// `MobileSync = off` (#608) found the owner's toggle on and no hub
    /// running (a profile installed while the app was quit): the hub is
    /// built once and disabled, so what the phone held is removed. Once per
    /// run; the toggle itself is kept.
    func wipeHubForPolicyOff(dbPool: DatabasePool) {
        guard mobileSyncPolicy.current == "off", mobileHub == nil, !policyOffWipeDone,
              mobileSyncDefaults.bool(forKey: Constants.mobileSyncEnabledKey) else { return }
        guard let hub = buildRunHub(dbPool: dbPool, forPolicyWipe: true) else {
            // Moved to a newer Watchtower: that app owns the phone now; the
            // policy tick does not retry.
            if isMobileHubMoved { policyOffWipeDone = true }
            return
        }
        policyOffWipeDone = true
        hub.disable()
    }

    /// Builds the run's hub over its one storage (opened on first use) into
    /// `mobileHub`; nil (the error kept) when it cannot be built, and nil with
    /// no error once a newer Watchtower runs the hub (spec §12.1).
    /// Once the Go hub owns Mobile (`swiftHubRetired`) it is built only to
    /// wipe for `MobileSync = off` (POLICY-03) a Swift state that still waits
    /// for adoption, and never started: never two hubs.
    private func buildRunHub(dbPool: DatabasePool, forPolicyWipe: Bool = false) -> MobileHubService? {
        guard !swiftHubRetired || (forPolicyWipe && hubAdoption?.swiftStatePending == true) else { return nil }
        guard !resolveMobileHubMoved() else {
            Self.mobileHubLogger.notice("mobile hub moved to a newer Watchtower; not starting")
            return nil
        }
        do {
            let directory = mobileHubDirectory
            // The retired branch's wipe never touches the hub's keys: a
            // missing or partial identity must reach the hand-over's probe
            // as it is (no_keys / keys_partial), never be created or repaired.
            let keyless = forPolicyWipe && swiftHubRetired
            var storage = try mobileHubStorage
                ?? (makeMobileHubStorage ?? { try MobileHubStorage.live(directory: directory, withKeys: !keyless) })()
            if keyless { (storage.keyring, storage.secure) = (nil, nil) }
            if mobileHubStorage == nil, !keyless {
                // Once per run, with the storage: CKSyncEngine learns of
                // remote changes from pushes (the relay poll is the backstop).
                storage.registerForPushes?()
            }
            mobileHubStorage = storage
            mobileHub = try buildMobileHub(storage: storage, dbPool: dbPool)
            mobileHubInitError = nil
            return mobileHub
        } catch {
            mobileHubInitError = error.localizedDescription
            Self.mobileHubLogger.error("mobile hub unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension AppState {
    /// Mobile at the end of `initWorkbenches`: the hand-over to the Go hub,
    /// or (under XCTest only) the Swift hub its own suites still build.
    func startMobile(dbPool: DatabasePool) {
        if swiftHubRetired {
            mobileHubPool = dbPool // for the POLICY-03 wipe only (`buildRunHub`)
            startHubAdoption()
        } else {
            initMobileHub(dbPool: dbPool)
        }
    }

    /// Starts the one-time hand-over of Mobile to the Go hub (go hub plan 3
    /// Task 22), once per app run, in its own task: it first waits for the
    /// v1-host restart, and neither the launch nor the UI waits for it.
    func startHubAdoption() {
        guard hubAdoption == nil else { return }
        let driver = liveHubAdoptionDriver()
        hubAdoption = driver
        Task { _ = await driver.run() }
    }

    /// Settings → Mobile's **Retry** after a failed hand-over.
    func retryHubAdoption() {
        guard let driver = hubAdoption else { return }
        Task { _ = await driver.retry() }
    }

    /// Settings → Mobile's **Set up Mobile again**, once the owner confirmed.
    func setUpMobileAgain() {
        guard let driver = hubAdoption else { return }
        Task { _ = await driver.setUpAgain() }
    }

    private func liveHubAdoptionDriver() -> HubAdoptionDriver {
        let deps = hubAdoptionDeps ?? HubAdoptionDeps(
            runner: Constants.findCLIPath().map { ProcessHubAdoptRunner(binaryPath: $0) },
            keyStore: KeychainHubKeyStore(backend: SecItemKeychainBackend())
        )
        let recorder = meetingRecorderCenter
        return HubAdoptionDriver(seams: .init(
            waitForHostRestart: { [weak self] in await self?.hostRestart?.waitUntilSettled() },
            policyOffWipe: { [weak self] in await self?.wipeSwiftStateForPolicyOff() },
            stopSwiftHub: { [weak self] in await self?.stopSwiftHubForAdoption() ?? false },
            cancelPhoneRecordings: { await recorder.cancelPhoneRecordingJobs(audioNames: $0) },
            phoneRecordingsAdopted: { await recorder.forgetPhoneRecordings(audioNames: $0) },
            releasePhoneRecordings: { await recorder.releasePhoneRecordings(audioNames: $0) },
            deps: deps,
            settings: { [weak self] in
                self?.hubAdoptSettings() ?? HubAdoptSettings(enabled: false, startSessionAllows: [:])
            },
            settingsDelivered: { [weak self] in
                self?.mobileSyncDefaults.removeObject(forKey: Constants.mobileSyncEnabledKey)
            }
        ))
    }

    /// The owner's settings the Go hub takes at the hand-over: the stored
    /// toggle as the owner left it (the Go hub applies `MobileSync` itself),
    /// read once. The phones' start-sessions grants live in the Swift hub's
    /// own state, which the Go hub copies, so Desktop adds none.
    func hubAdoptSettings() -> HubAdoptSettings {
        HubAdoptSettings(enabled: mobileSyncDefaults.bool(forKey: Constants.mobileSyncEnabledKey), startSessionAllows: [:])
    }

    /// POLICY-03 before the hand-over: `MobileSync = off`, the owner's toggle
    /// on and a Swift state not adopted yet: the Swift hub is built only to be
    /// disabled (what it published is removed), exactly as before the Go hub.
    func wipeSwiftStateForPolicyOff() async {
        guard let pool = mobileHubPool else { return }
        wipeHubForPolicyOff(dbPool: pool)
        await mobileHub?.waitUntilStopped()
    }

    /// Stops the Swift hub for the hand-over; true once its storage is
    /// closed (`hub adopt` needs its files closed and cannot see an idle
    /// open handle). A close that fails is tried once more after a second;
    /// still failing, false (the driver fails with `swift_busy`, the storage
    /// is kept for Retry). Nothing builds the hub again in this run.
    func stopSwiftHubForAdoption() async -> Bool {
        swiftHubRetired = true
        mobileHubPool = nil
        let hub = mobileHub
        mobileHub = nil
        hub?.dispose()
        await hub?.waitUntilStopped()
        guard let storage = mobileHubStorage else { return true }
        for attempt in 0..<2 {
            do {
                try storage.close()
                mobileHubStorage = nil
                return true
            } catch {
                Self.mobileHubLogger.error("the Swift hub's storage did not close (attempt \(attempt + 1))")
                if attempt == 0 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        return false
    }
}

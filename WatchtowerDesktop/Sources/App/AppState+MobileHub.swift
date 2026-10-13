import AppKit
import GRDB
import WatchtowerCore

/// Settings → Mobile drives the toggle and reads the hub through these.
extension AppState: MobileSettingsHost {}

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
        // The folder's git status goes through the CLI (PROJ-10's git); no
        // CLI, no refresher, and the workbench records carry no branch.
        let gitRefresher = workbenchesViewModel?.cli.map { cli in
            WorkbenchGitRefresher(
                fetch: { try await cli.gitStatus(projectID: $0) },
                workbenchIDs: { try await dbPool.read { try WorkbenchSlice.publishedWorkbenches($0).map(\.id) } }
            )
        }
        // The terminals' liveness, copied by the fast lane for the session
        // projection's off-main resolution.
        let liveness = SessionLivenessBox()
        let summaries = workbenchesViewModel?.cli.map { SessionReportSummaryRunner.live($0.runner, dbPool: dbPool, liveness: liveness) }
        let recordings = try PhoneRecordingJobs.live(sidecar: storage.sidecar, dbPool: dbPool, recorder: meetingRecorderCenter)
        let phoneUpload: @Sendable (Int64) -> String? = { [recordings] in recordings.uploadID(forTranscript: $0) }
        let sessions = TerminalSessionSlice(
            liveness: { liveness.current },
            reportSummary: { summaries?.summary(workbenchID: $0, sessionID: $1) }
        )
        // Each session's own report (`--session S --json`, scoped by the CLI,
        // PROJ-14) and the timeline's state milestones; no CLI, no reports.
        let sidecar = storage.sidecar
        let reports = workbenchesViewModel?.cli.map { SessionReportRunner.live($0.runner, dbPool: dbPool, sessions: sessions, sidecar: sidecar) }
        if let reports { SessionReportRequestHandler(dbPool: dbPool, runner: reports, sessions: sessions).register(on: dispatcher) }
        let sources: [any SliceSource] = [
            WorkbenchSlice(
                gitStatus: { gitRefresher?.status(for: $0) }, sessionCounts: { try sessions.sessionCounts($0) },
                defaultAgent: { ConfigService.readWorkbenchDefaultAgent() }
            ),
            WorkbenchTargetSlice(),
            WorkbenchCommentSlice(),
            sessions,
            OwnerAskSlice(),
            AskAlertSlice(sidecar: storage.sidecar),
            CalendarEventSlice(),
            MeetingTranscriptSlice(phoneRecordingID: phoneUpload),
            RecordingJobSlice(sidecar: storage.sidecar),
            SessionTimelineSlice(sessions: sessions, sidecar: sidecar),
            DeviceGrantSlice(sidecar: sidecar, hubID: try sidecar.ensureHubID())
        ] + (reports == nil ? [] : [SessionReportSlice(sessions: sessions, sidecar: sidecar)])
        let transport = storage.transport
        let publisher = SlicePublisher(
            dbPool: dbPool, state: storage.sidecar, transport: transport, sources: sources, assets: storage.sliceAssets,
            // Labelled: a trailing closure would bind to `clock`, the first
            // closure parameter.
            sendNow: { await transport.sendNow() } // swiftlint:disable:this trailing_closure
        )
        gitRefresher?.setOnChange { [weak publisher] in publisher?.nudge(kinds: [.workbench]) }
        summaries?.setOnChange { [weak publisher] in publisher?.nudge(kinds: [.terminalSession]) }
        reports?.setOnChange { [weak publisher] in publisher?.nudge(kinds: [.sessionReport, .sessionTimeline]) }
        recordings.setOnChange { [weak publisher] in publisher?.nudge(kinds: $0) }
        let fastLane = FastLane(
            dbPool: dbPool, agentStates: sessionAgentStateCenter, terminalCenter: terminalCenter, liveness: liveness,
            nudge: { [weak publisher] in publisher?.nudge(kinds: $0) },
            sessionStateChanged: { [weak gitRefresher, weak summaries] workbench in
                gitRefresher?.sessionStateChanged(workbenchID: workbench)
                summaries?.sessionStateChanged(workbenchID: workbench)
            },
            sessionStatesChanged: { [weak reports] in reports?.sessionStatesChanged() }
        )
        let optional: [(any HubCompanion)?] = [gitRefresher, summaries, reports]
        let companions: [any HubCompanion] = optional.compactMap { $0 } + [fastLane, recordings]
        return try assembleMobileHub(
            storage: storage, dbPool: dbPool, dispatcher: dispatcher, publisher: publisher, companions: companions,
            recordingUploads: .init { [recordings] in try await recordings.ingest($0, audio: $1) }
        )
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
            transport: storage.transport, sidecar: storage.sidecar, dispatcher: dispatcher,
            hubID: try storage.sidecar.ensureHubID(), recordingUploads: recordingUploads,
            deviceRecords: linkCenter?.relayRoute
        )
        let hub = MobileHubService(
            transport: storage.transport, publisher: publisher, processor: processor, sidecar: storage.sidecar,
            hostInfo: hostInfo, companions: companions
        ) { [weak self] in self?.isMobileSyncEnabled ?? false }
        linkCenter?.attach(to: hub)
        return hub
    }
}

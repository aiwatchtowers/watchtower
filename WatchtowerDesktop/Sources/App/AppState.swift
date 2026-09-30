import SwiftUI
import GRDB
import Observation
import WatchtowerCore

@MainActor
@Observable
final class AppState {
    /// The one app-wide instance. The App struct seeds its `@State` from it,
    /// so "the SwiftUI-managed AppState" and "the one the app delegate
    /// bootstraps before any window exists" are the same object by
    /// construction — the stale-`@State`-copy trap the H5 note in
    /// `WatchtowerApp` describes cannot arise. Tests still construct their own
    /// `AppState()` instances.
    static let shared = AppState()

    var selectedDestination: SidebarDestination = .inbox

    /// Which feature ids are currently disabled — drives sidebar visibility,
    /// navigation fallback, and the Dashboard banner. Populated by the
    /// Feature Manager service (wired in separately); empty until then.
    let featureVisibility = FeatureVisibilityStore()

    var databaseManager: DatabaseManager?
    var errorMessage: String?
    /// Workspaces the launch-time DB open refused to choose between (no
    /// `active_workspace`, several databases). Non-empty → `NavigationRoot`
    /// shows `AmbiguousWorkspaceView` instead of the app.
    var ambiguousWorkspaces: [String] = []
    /// Non-nil when the CLI binary store could not be synced this launch. The
    /// path resolver rejects a store copy that does not match the bundled CLI,
    /// so this launch runs the CLI (daemon included) straight from the app
    /// bundle instead — correct, but a rebuild of the app while it runs can
    /// then invalidate a live process's code signature.
    var cliStoreError: String?

    /// The app's one daemon handle: the tray status line, Settings' read-only
    /// status section, and the launch-time `ensureDaemonRunning()` all read and
    /// write this instance, so a start/stop failure is visible wherever the
    /// daemon is shown (house rule: state behind surviving surfaces lives in
    /// AppState). Its path lookup is deliberately deferred until after the CLI
    /// binary store has been synced — see `initialize()`.
    let daemonManager = DaemonManager()
    var isDBAvailable: Bool { databaseManager != nil }

    /// The install's owner identity (`OwnerQueries.resolve`, OWNER-01). While
    /// it is unknown, Day Plan and Briefings show `NoOwnerEmptyState` instead
    /// of Generate (OWNER-02). Resolved on DB open, after every Slack/Google/
    /// Jira account reload, and whenever either screen appears — the daemon
    /// fills a Jira owner cross-process, which no GRDB observation sees.
    private(set) var owner: Owner = .unknown

    /// The Settings window's selected tab, so an in-app link can open
    /// Settings on a given tab (the no-owner empty state → Connections).
    var settingsTab: SettingsTab = .connections

    /// The Connections tab's selected service, held here for the same reason
    /// as `settingsTab` (the Inbox cheat sheet → Slack's reaction dictionary).
    var settingsConnection: ConnectionService = .slack

    /// True while initialize() is running (before DB and onboarding check complete).
    var isLoading: Bool = true

    /// Whether the user needs to complete the onboarding chat flow.
    var needsOnboarding: Bool = false

    /// Persistent onboarding state machine — tracks which step the user is on across app restarts.
    let onboarding = OnboardingStateMachine()

    /// Cache for custom workspace emoji images.
    let emojiImageCache = EmojiImageCache()
    /// Map of custom emoji name → image URL, loaded from DB.
    var customEmojiMap: [String: String] = [:]

    /// App-wide registry of in-flight custom-track scans, so the "scanning"
    /// indicator survives navigating away from a track's detail.
    let trackScanCenter = TrackScanCenter()

    /// App-wide, single-slot registry for the "Extract with AI" target
    /// extraction call, so its state survives the New Target sheet being
    /// closed mid-extraction.
    let targetExtractCenter = TargetExtractCenter()

    /// App-wide registry of target assistant tab containers, so a chat turn
    /// started on a target keeps streaming after the operator navigates away
    /// from (and back to) that target's detail screen. Bounded LRU; a container
    /// is never evicted while one of its tabs is working.
    let targetAssistantCenter = TargetAssistantCenter()

    /// App-wide, single-slot registry for the creation-time "brief the
    /// secretary" chat run, so the send + streaming + execute-mode auto-apply
    /// survive the composer sheet being dismissed and any navigation away.
    /// Its chat-VM factory is wired below once the DB pool opens.
    let targetBriefCenter = TargetBriefCenter()

    /// App-wide, single-slot registry for meeting recording + transcription, so
    /// an in-flight recording and its transcription survive navigating away from
    /// the calendar event that started it.
    let meetingRecorderCenter = MeetingRecorderCenter()

    /// App-wide, single-slot registry for voice dictation. Shares one physical
    /// engine slot with `meetingRecorderCenter` — wired to it below via
    /// `meetingBusy`/`captureWillStart` (`initialize()`).
    let dictationCenter = DictationCenter()

    /// Opens the Quick Capture window. Set once, from `rootContent.onAppear`,
    /// where `@Environment(\.openWindow)` is actually available — the tray
    /// button and the global hotkey handler both call through this instead of
    /// needing their own `openWindow` (the hotkey's C callback has no
    /// SwiftUI environment to read one from at all).
    var openQuickCapture: (() -> Void)?

    /// Opens the Voices window (the `openQuickCapture` shape). Set by the
    /// scene once `@Environment(\.openWindow)` is available — wiring the
    /// window itself is Task 12; this call just exposes the hook.
    var openVoicesWindow: (() -> Void)?

    /// App-wide, single-slot registry for meeting-recording audio playback, so
    /// only one recording's audio plays at a time regardless of how many
    /// transcript rows are expanded across the app.
    let audioPlaybackCenter = AudioPlaybackCenter()

    /// App-wide, single-slot-per-transcript registry for "generate meeting
    /// notes" runs, so the "generating…" flag survives navigating away from
    /// and back to a recording's detail (feedback: async ops need
    /// navigation-surviving state).
    let transcriptNotesCenter = TranscriptNotesCenter()

    /// App-wide per-event registry of meeting-prep runs and results, so a
    /// `meeting-prep` CLI run started from Day Plan or Calendar survives
    /// navigating away and back (same surviving-state contract).
    let meetingPrepCenter = MeetingPrepCenter()

    /// Same pattern for "generate chapters" runs (Recap tab).
    let transcriptChaptersCenter = TranscriptChaptersCenter()

    /// App-wide, single-slot registry for the Voices window: the owner's
    /// voice-labeling queue, confirm/dismiss/relabel transactions, and the
    /// automatic catch-up pass. Attached to the DB pool in
    /// `wireMeetingRecorderLoaders` (same wiring moment as the registry
    /// loader/writer below, which need the same pool).
    let voiceRegistryCenter = VoiceRegistryCenter()
    /// Embedded Claude Code terminals, one per project. No DB needed; closed
    /// on quit by `QuitCoordinator` (via `TrayAppDelegate`).
    let projectTerminalCenter = ProjectTerminalCenter()

    /// Diarizer models are prefetched only while speaker roles are on; a
    /// failure is fine — the post-pass retries the download and degrades to a
    /// role-less transcript.
    @Sendable private static func prefetchDiarizerModels() async {
        guard TranscriptionConfig.fromDefaults().diarization else { return }
        try? await FluidAudioDiarizer.prefetchModels()
    }

    /// App-wide registry of in-flight/failed WhisperKit model-file prefetches,
    /// so download progress is visible (and retryable) from anywhere,
    /// independent of whether a recording is in progress.
    let transcriptionModelProvisioner = TranscriptionModelProvisioner(prefetchExtras: AppState.prefetchDiarizerModels)

    /// Provider/model registry from `watchtower ai models --json`, shared by
    /// the chat model picker and Settings suggestions. Loaded lazily.
    let aiModelCatalog = AIModelCatalog()

    /// Persistent chat ViewModels — survive tab switches.
    private(set) var chatViewModel: ChatViewModel?
    private(set) var chatHistoryViewModel: ChatHistoryViewModel?
    /// App-wide warm chat sessions (spec §1.4) — owns every running main-chat
    /// turn, so turns survive navigation. Created once the DB is open.
    private(set) var chatSessionPool: ChatSessionPool?

    /// Calendar ViewModel — persists across tab switches.
    private(set) var calendarViewModel: CalendarViewModel?

    /// Briefings ViewModel — persists across tab switches so an in-flight
    /// "Generate" run (and its error) survives navigating away and back.
    private(set) var briefingViewModel: BriefingViewModel?

    /// Day Plan ViewModel — persists across tab switches.
    private(set) var dayPlanViewModel: DayPlanViewModel?

    /// Catch-Up ViewModel — persists across tab switches.
    private(set) var catchUpViewModel: CatchUpViewModel?

    /// Memory browser ViewModel — persists across tab switches.
    private(set) var memoryViewModel: MemoryViewModel?

    /// Ideas & Decisions registry ViewModel — persists across tab switches so
    /// filters and selection survive navigating away from and back to the tab.
    private(set) var ideasViewModel: IdeasViewModel?

    /// Secretary Profile ViewModel — persists across tab switches so an
    /// in-flight "Generate" style-sample run survives navigating away from
    /// and back to the Profile tab.
    private(set) var secretaryProfileViewModel: SecretaryProfileViewModel?

    /// Sidebar badge counts — created during initialize() before the splash hides,
    /// so badges are visible the moment the main UI appears.
    private(set) var sidebarCountsViewModel: SidebarCountsViewModel?

    /// Email Accounts ViewModel (multi-account IMAP/Outlook) — persists across
    /// tab switches so an in-flight connect (Outlook OAuth or IMAP add) survives
    /// navigating away from the Settings window. Gmail keeps its own separate
    /// single-account flow (`GoogleConnectFlow.shared`) and is not covered here.
    private(set) var emailAccountsViewModel: EmailAccountsViewModel?

    /// Calendar Accounts ViewModel (multi-account CalDAV/ICS) — persists across
    /// tab switches so an in-flight connect survives navigating away from the
    /// Settings window. Google Calendar keeps its own separate single-account
    /// flow (`GoogleConnectFlow.shared`) and is not covered here.
    private(set) var calendarAccountsViewModel: CalendarAccountsViewModel?

    /// Google Accounts ViewModel (multi-account Calendar/Gmail) — persists
    /// across tab switches so an in-flight OAuth connect survives navigating
    /// away from the Settings window.
    private(set) var googleAccountsViewModel: GoogleAccountsViewModel?

    /// Slack Accounts ViewModel (multi-workspace) — persists across tab
    /// switches so an in-flight OAuth connect survives navigating away from the
    /// Settings window.
    private(set) var slackAccountsViewModel: SlackAccountsViewModel?

    /// Jira Accounts ViewModel (multi-site) — persists across tab switches so
    /// an in-flight OAuth connect survives navigating away from the Settings
    /// window.
    private(set) var jiraAccountsViewModel: JiraAccountsViewModel?

    /// Confluence spaces pickers (Settings → Jira), one per Jira account id —
    /// held here so a select/unselect or re-consent still running when the
    /// Settings pane goes away finishes and is visible on return.
    private(set) var confluenceSpacesViewModels: [Int64: ConfluenceSpacesViewModel] = [:]

    /// External Connections ("Quick Connections") ViewModel — persists across
    /// tab switches so an in-flight add/remove survives navigating away from
    /// the Settings window.
    private(set) var externalConnectionsViewModel: ExternalConnectionsViewModel?

    /// Reaction Dictionary ViewModel (Settings → Slack "Reaction commands"
    /// editor) — persists across tab switches like its sibling account VMs
    /// above.
    private(set) var reactionDictionaryViewModel: ReactionDictionaryViewModel?

    /// Dashboard action strip (pending agent-action proposals + due reminders)
    /// — persists across tab switches like its siblings above.
    private(set) var actionStripViewModel: ActionStripViewModel?

    /// Projects tab (spec §6). Owned here so create/repair and the selection
    /// survive navigation.
    private(set) var projectsViewModel: ProjectsViewModel?
    /// Owner notifications for project activity; polls every 30 s.
    private(set) var projectNotificationCenter: ProjectNotificationCenter?
    /// Set by `navigateToProject`; `ProjectsView` consumes and clears it.
    var pendingProjectRoute: ProjectRoute?

    /// Whether legacy people analytics is enabled (analysis.legacy_mode in config).
    var analysisLegacyMode: Bool = false

    /// Whether the user has completed onboarding (profile exists and onboarding_done == true).
    var profileComplete: Bool = true

    /// Set to navigate to a specific digest from anywhere in the app.
    var pendingDigestID: Int?

    /// Set to navigate to a specific decisions-ledger entry from anywhere in
    /// the app. Lands on the same `.digests` destination as `pendingDigestID`
    /// — the Decisions segment lives inside `DigestListView`, not its own
    /// sidebar tab.
    var pendingDecisionID: Int?

    /// Set to navigate to a specific target from anywhere in the app.
    var pendingTargetID: Int?

    /// Set to navigate to a specific briefing from anywhere in the app.
    var pendingBriefingID: Int?

    /// Set to navigate to the day plan for a specific date from anywhere in the app.
    var pendingDayPlanDate: String?

    /// Set to focus a specific track from anywhere in the app.
    var pendingTrackID: Int?

    /// Set to focus a specific person card from anywhere in the app.
    var pendingPersonUserID: String?

    /// Watches for new digests and sends notifications.
    private(set) var digestWatcher: DigestWatcher?

    /// Drives all meeting-reminder surfaces: the pre-meeting push, the
    /// stop-recording push, and the global countdown banner. Created with the
    /// DB (not gated on notification permission — the in-app banner needs
    /// none; the pushes silently no-op without it).
    private(set) var meetingReminderCenter: MeetingReminderCenter?

    /// Manages app updates from GitHub Releases.
    let updateService = UpdateService()

    /// Desktop-side manager for the Settings → Features panel. Unlike the
    /// DB-gated ViewModels built in `initFeatureViewModels`, it has no DB
    /// dependency at all (it is backed entirely by the `watchtower features`
    /// CLI), so it can live as a plain, always-constructed `let` here and
    /// load independently of the DB-open Task in `initialize()`.
    let featureManager = FeatureManagerService()

    /// Manages background pipeline tasks (digests, people) started after onboarding sync.
    let backgroundTaskManager = BackgroundTaskManager()

    /// Ensures chat ViewModels exist (lazy init, called from ChatView).
    func ensureChatViewModels() {
        guard let db = databaseManager, chatViewModel == nil else { return }
        let provider = AIProvider.fromConfig(ConfigService().aiProvider)
        let cvm = ChatViewModel(
            dbManager: db,
            pool: ensureChatSessionPool(db),
            provider: provider,
            cliRunner: ProcessCLIRunner.makeDefault()
        )
        // Once per launch, before anything is shown or listed.
        cvm.cleanUpUntouchedConversations()
        let hvm = ChatHistoryViewModel(dbManager: db)
        hvm.load()
        Self.wireChat(cvm, history: hvm)
        chatViewModel = cvm
        chatHistoryViewModel = hvm
    }

    /// The main chat's two view models: the history list follows the chat's
    /// writes, and the landing's first turn becomes the history selection.
    static func wireChat(_ cvm: ChatViewModel, history hvm: ChatHistoryViewModel) {
        cvm.onConversationsChanged = { [weak hvm] in hvm?.load() }
        cvm.onLandingTurnStarted = { [weak hvm] id in hvm?.selectedConversationID = id }
    }

    @discardableResult
    func ensureChatSessionPool(_ db: DatabaseManager) -> ChatSessionPool {
        if let chatSessionPool { return chatSessionPool }
        let pool = ChatSessionPool(dbPool: db.dbPool)
        // CHAT-03: an idle session dies within TTL + one 30 s poll.
        pool.startPolicy()
        chatSessionPool = pool
        return pool
    }

    func navigateToDigest(_ digestID: Int) {
        pendingDigestID = digestID
        selectedDestination = .digests
    }

    func navigateToDecision(_ ideaID: Int) {
        pendingDecisionID = ideaID
        selectedDestination = .digests
    }

    /// Unlike its siblings there is no pending field: `ideasViewModel` is
    /// AppState-owned and exists whenever the DB is open, so the selection is
    /// set on it directly and survives the Ideas view not being mounted yet.
    func navigateToIdea(_ ideaID: Int) {
        ideasViewModel?.reveal(ideaID)
        selectedDestination = .ideas
    }

    func navigateToTarget(_ targetID: Int) {
        pendingTargetID = targetID
        selectedDestination = .targets
    }

    func navigateToBriefing(_ briefingID: Int) {
        pendingBriefingID = briefingID
        selectedDestination = .briefings
    }

    func navigateToDayPlan(_ date: String? = nil) {
        pendingDayPlanDate = date
        selectedDestination = .dayPlan
    }

    func navigateToTrack(_ trackID: Int) {
        pendingTrackID = trackID
        selectedDestination = .tracks
    }

    func navigateToPerson(_ userID: String) {
        pendingPersonUserID = userID
        selectedDestination = .people
    }

    func navigateToProject(_ route: ProjectRoute) {
        pendingProjectRoute = route
        selectedDestination = .projects
    }

    private var isInitializing = false
    private var terminateObserver: NSObjectProtocol?

    /// Brief-run chat VMs need the open DB; wired once it opens rather than
    /// at construction (centers exist before the pool opens). Each run gets
    /// its own TargetsViewModel — the ad-hoc-VM precedent from
    /// CreateTargetSheet's promote path.
    private func wireTargetBriefCenter() {
        targetBriefCenter.makeChatVM = { [weak self] target in
            guard let self, let manager = self.databaseManager else { return nil }
            // Route through the assistant center so the detail screen
            // later resolves the SAME container (and tab VM) — never
            // two VMs on one conversation.
            let container = self.targetAssistantCenter.container(
                for: target,
                viewModel: TargetsViewModel(dbManager: manager),
                dbManager: manager
            )
            return container.activeChat
        }
        targetBriefCenter.targetExists = { [weak self] id in
            guard let manager = self?.databaseManager else { return true }
            do {
                return try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) } != nil
            } catch {
                // A failed read must not silently drop the owner's
                // brief — let it run and fail visibly if it must.
                return true
            }
        }
    }

    /// Hands the MeetingRecorderCenter its voice-registry closures once the
    /// shared pool opens (the Center is created before the DB). Both degrade
    /// on failure instead of throwing — voice naming is a progressive
    /// enhancement like roles themselves: a failed read → nil, identification
    /// off for that recording (plain "Speaker N" labels, nothing queued or
    /// learned — spec §2.6); a failed write → nothing queued (the transcript
    /// is already saved).
    /// Failures are printed, never silent (the renderRoles diagnostics
    /// convention). `func`, not `private func`, so @testable tests can wire a
    /// test DB through it (the initSecretaryProfile precedent).
    func wireMeetingRecorderLoaders(dbPool: DatabasePool) {
        meetingRecorderCenter.registryLoader = { eventID in
            do {
                return try await dbPool.read { db in try Self.loadVoiceRegistry(db, eventID: eventID) }
            } catch {
                print("[AppState] voice registry load failed, identification disabled for this run: "
                      + error.localizedDescription)
                return nil
            }
        }
        meetingRecorderCenter.registryWriter = { transcriptID, outcome in
            do {
                return try await dbPool.write { db -> Int in
                    for sample in outcome.autoSamples {
                        var sample = sample
                        sample.transcriptID = transcriptID
                        try VoiceSampleQueries.insertAuto(db, sample)
                    }
                    for task in outcome.tasks {
                        try VoiceLabelQueueQueries.enqueue(
                            db, transcriptID: transcriptID, clusterLabel: task.label, reason: task.reason,
                            suggestedPersonID: task.personID, score: task.score)
                    }
                    return outcome.tasks.count
                }
            } catch {
                print("[AppState] voice registry write failed for transcript \(transcriptID), nothing queued: "
                      + error.localizedDescription)
                return 0
            }
        }

        voiceRegistryCenter.attach(dbPool: dbPool)
        // Launch catch-up: the one full retro pass (spec §4.1), skipped with
        // "Voice recognition" off (spec §6).
        let voiceRecognition = TranscriptionConfig.fromDefaults().voiceRecognition
        Task { await voiceRegistryCenter.catchUp(voiceRecognition: voiceRecognition) }
        observeVoiceRegistryCatchUp()
    }

    /// Keeps `voiceRegistryCenter` in sync with every meeting-recorder save
    /// (`MeetingRecorderCenter.savedTick`) via manual Observation tracking —
    /// there's no view guaranteed to stay mounted for the app's whole
    /// lifetime to drive a SwiftUI `.onChange` here, so AppState re-arms its
    /// own tracking closure after each fire.
    private func observeVoiceRegistryCatchUp() {
        withObservationTracking {
            _ = meetingRecorderCenter.savedTick
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.handleMeetingRecorderSaved()
                self.observeVoiceRegistryCatchUp()
            }
        }
    }

    /// What a meeting-recorder save tells `voiceRegistryCenter`: NOT a full
    /// retro pass (spec §4.1 — a new meeting's freshly-minted auto samples
    /// are not one of retro's three triggers), just
    /// `refreshAfterSave`'s housekeeping. `func`, not `private func`, so
    /// `@testable` tests can call it directly instead of driving the full
    /// recorder pipeline for real just to bump `savedTick`.
    func handleMeetingRecorderSaved() async {
        await voiceRegistryCenter.refreshAfterSave()
    }

    /// One registry snapshot for a recording. The owner's people are those
    /// keyed by a `google_accounts` email — deliberately unfiltered by
    /// status (a revoked account does not change who owns the machine) and
    /// IMAP identities excluded (people are keyed by Calendar attendee
    /// emails; owner-reviewed 2026-08-08). `invited` is nil for ad-hoc
    /// recordings AND for an event whose identity set is empty (swept by
    /// retention, no human guests, undecodable attendees) — the stricter
    /// no-event threshold applies then, never an empty invite list that
    /// would demote every colleague to unsure.
    nonisolated static func loadVoiceRegistry(_ db: Database, eventID: String?) throws -> VoiceRegistrySnapshot {
        let people = Dictionary(uniqueKeysWithValues: try VoicePrintQueries.fetchAll(db).compactMap { person in
            person.id.map { ($0, person) }
        })
        let ownerEmails = Set(try GoogleAccountQueries.fetchAll(db).map { $0.email.lowercased() }.filter { !$0.isEmpty })
        let owners = Set(people.values.filter { VoicePrintQueries.isOwner($0, ownerEmails: ownerEmails) }.compactMap(\.id))
        var invited: Set<Int64>?
        if let eventID {
            if let event = try CalendarQueries.fetchEvent(db, id: eventID) {
                let identities = event.attendeesIncludingOrganizer
                if identities.isEmpty, event.parsedAttendees.isEmpty,
                   !event.attendees.isEmpty, event.attendees != "[]" {
                    // Absent-vs-undecodable: a corrupt attendees blob folds
                    // into the same no-event fallback as "no guests" — safe,
                    // but it must leave a trace.
                    print("[AppState] event \(eventID) has an undecodable attendees JSON, voice matching treats it as ad-hoc")
                }
                if !identities.isEmpty {
                    invited = try VoicePrintQueries.personIDs(db, matching: identities)
                }
            } else {
                // Delayed jobs (FIFO backlog, crash recovery, sidecar retry)
                // can outlive the ~24h event retention — the silent fall to
                // ad-hoc matching must not be indistinguishable from ad-hoc.
                print("[AppState] event \(eventID) not found, voice matching treats it as ad-hoc")
            }
        }
        return VoiceRegistrySnapshot(samples: try VoiceSampleQueries.fetchUsable(db), people: people,
                                     invited: invited, ownerPersonIDs: owners)
    }

    func initialize() {
        guard !isInitializing else { return }
        isInitializing = true
        isLoading = true
        // Surface a recording captured before a crash/relaunch so the global
        // indicator can offer to (re-)transcribe it. No DB needed.
        meetingRecorderCenter.restorePendingOnLaunch()
        // Neither direction of this handshake needs the DB, so it is wired
        // unconditionally rather than inside the DB-dependent Task below.
        dictationCenter.meetingBusy = { [meetingRecorderCenter] in meetingRecorderCenter.isBusy }
        meetingRecorderCenter.captureWillStart = { [dictationCenter] in dictationCenter.meetingCaptureWillStart() }
        meetingRecorderCenter.dictationEngineResident = { [dictationCenter] in dictationCenter.hasResidentEngine }
        dictationCenter.engineReleased = { [meetingRecorderCenter] in meetingRecorderCenter.dictationEngineDidRelease() }
        // Once per process: initialize() re-runs on every retry
        // (reinitializeAfterOnboarding), which must not stack observers.
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.backgroundTaskManager.terminateProcessesSync()
            }
        }
        Task {
            await syncCLIBinaryStore()
            // Only now resolve the CLI path and start polling: before the sync
            // the store copy may still be the stale one, and DaemonManager
            // caches whatever path it first resolves.
            daemonManager.startPolling()
            do {
                let manager = try await Task.detached {
                    // Run Go CLI to apply any pending DB migrations before opening
                    DatabaseManager.runCLIMigrations()
                    let dbPath = try DatabaseManager.resolveDBPath()
                    return try DatabaseManager(path: dbPath)
                }.value
                databaseManager = manager
                errorMessage = nil
                ambiguousWorkspaces = []
                // Before the splash hides, so Day Plan / Briefings never flash
                // the no-owner state on an install that has one.
                await refreshOwner()
                wireMeetingRecorderLoaders(dbPool: manager.dbPool)
                wireTargetBriefCenter()
                // Sync state machine with DB: if profile says done, mark complete
                if onboarding.currentStep != .complete {
                    let dbDone = await checkNeedsOnboarding(dbPool: manager.dbPool)
                    if !dbDone {
                        onboarding.markComplete()
                    } else {
                        onboarding.skipCompleted()
                    }
                }
                needsOnboarding = onboarding.currentStep != .complete
                profileComplete = !needsOnboarding
                analysisLegacyMode = ConfigService().analysisLegacyMode
                // Pre-load sidebar badge counts so they're already visible when the splash hides.
                // Skipped when onboarding is needed — the OnboardingView replaces the sidebar entirely.
                if !needsOnboarding {
                    await initSidebarCounts(dbPool: manager.dbPool)
                }
                isLoading = false
                loadCustomEmoji(from: manager)
                initFeatureViewModels(manager: manager)
                // Resume pipelines if app was closed mid-generation
                if !needsOnboarding && !UserDefaults.standard.bool(forKey: Constants.pipelinesCompletedKey) {
                    backgroundTaskManager.startPipelines(legacyPeople: analysisLegacyMode, disabledFeatures: featureManager.disabledFeatureIDs)
                } else if !needsOnboarding {
                    // Ensure a fresh daemon is running (rebuild-safe): stop any existing
                    // one (possibly from an older binary), then start the current binary.
                    ensureDaemonRunning()
                }
            } catch {
                print("[AppState] database open failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                databaseManager = nil
                if case WatchtowerDatabaseError.ambiguousWorkspace(let names) = error {
                    ambiguousWorkspaces = names
                } else {
                    ambiguousWorkspaces = []
                }
                // No DB available — if state machine not complete, onboarding needed
                needsOnboarding = onboarding.currentStep != .complete
                if needsOnboarding {
                    onboarding.skipCompleted()
                }
                isLoading = false
            }
        }
        // Check for updates in background (once per 24h)
        Task { await updateService.checkIfNeeded() }
        // No DB dependency, so this does not wait on the DB-open Task above
        // (Settings → Features may be reached before that Task resolves).
        // Every successful service load (launch, post-apply, failure-path
        // reload) pushes the fresh disabled set into the visibility store
        // the sidebar/navigation/banner read.
        featureManager.onDisabledChanged = { [featureVisibility] ids in
            featureVisibility.disabledFeatureIDs = ids
        }
        Task { await featureManager.load() }
    }

    /// Sync the out-of-bundle CLI copy before anything spawns the CLI, so
    /// migrations, the daemon, and OAuth logins all run from the store,
    /// never from the (rebuild-overwritten) bundle binary.
    private func syncCLIBinaryStore() async {
        guard let bundled = Constants.bundledCLIPath() else { return }
        // Bounded stop: this runs before the splash gives way to the UI, so an
        // unresponsive `sync stop` must not hang the launch forever.
        let outcome = await CLIBinaryStore.sync(bundleBinary: bundled) {
            await DaemonManager.stopDaemonBounded()
        }
        if case .failed(let reason) = outcome {
            cliStoreError = reason
            // Honest about the consequence: the resolver rejects a store copy
            // that does not match the bundle, so the CLI runs from the bundle
            // for this launch — including the daemon.
            NSLog("CLIBinaryStore: sync failed (%@); the CLI runs from the app bundle this launch", reason)
        }
        // The OCR helper travels next to the CLI copy, validated on its own:
        // a failure here only means attachment OCR is unavailable to the
        // store CLI, never that the CLI itself is unusable — so it is logged,
        // not surfaced as cliStoreError.
        if case .failed(let reason) = CLIBinaryStore.syncOCRHelper(bundleHelper: Constants.bundledOCRHelperPath()) {
            NSLog("CLIBinaryStore: OCR helper sync failed (%@); attachment OCR is unavailable to the store CLI", reason)
        }
    }

    /// Check if onboarding chat is needed (profile missing or onboarding_done == false).
    private func checkNeedsOnboarding(dbPool: DatabasePool) async -> Bool {
        do {
            return try await dbPool.read { db in
                guard let profile = try ProfileQueries.fetchCurrentProfile(db) else {
                    return true
                }
                return !profile.onboardingDone
            }
        } catch {
            return false // On error, don't block — skip onboarding
        }
    }

    /// Called when onboarding flow completes successfully.
    func completeOnboarding() {
        onboarding.markComplete()
        needsOnboarding = false
        profileComplete = true
        // The initialize() path skips sidebar counts while onboarding is pending, so build
        // them now — otherwise the first run shows all-zero badges (incl. Catch-Up) until restart.
        if sidebarCountsViewModel == nil, let pool = databaseManager?.dbPool {
            Task { await initSidebarCounts(dbPool: pool) }
        }
    }

    /// Re-runs the full launch bootstrap after onboarding completes or is skipped,
    /// but only when the launch-time bootstrap left the app without a database —
    /// the one case where the DB, feature view models, and daemon are still
    /// unwired. When the app initialized normally (e.g. a Settings-triggered
    /// onboarding redo), everything is already wired and a re-run would only
    /// restart the daemon mid-cycle and stack a duplicate terminate observer.
    /// `initialize()` latches on `isInitializing` to keep window-reopen
    /// `onAppear` calls idempotent; this is the one legitimate re-entry point.
    func reinitializeAfterOnboarding() {
        guard databaseManager == nil else { return }
        isInitializing = false
        initialize()
    }

    /// Builds the sidebar counts view model, pre-loads counts, and starts observing.
    private func initSidebarCounts(dbPool: DatabasePool) async {
        let countsVM = SidebarCountsViewModel(dbPool: dbPool)
        await countsVM.loadInitial()
        countsVM.startObserving()
        sidebarCountsViewModel = countsVM
    }

    /// Re-triggers the onboarding flow (from Settings).
    /// Resets to the chat step since connect/settings/claude are already done.
    func startOnboarding() {
        onboarding.reset(to: .chat)
        needsOnboarding = true
        profileComplete = false
        UserDefaults.standard.removeObject(forKey: Constants.pipelinesCompletedKey)
    }

    /// Wipe all LLM-generated data, stop daemon, and re-run post-onboarding pipelines.
    func resetLLMData() async throws {
        guard let db = databaseManager else { return }

        // 1. Stop running pipelines (if any) — await ensures process exits and releases file locks
        await backgroundTaskManager.stopAll()

        // 2. Stop daemon
        daemonManager.resolvePathIfNeeded()
        if DaemonManager.checkDaemonRunning() {
            await daemonManager.stopDaemon()
            try? await Task.sleep(for: .milliseconds(500))
        }

        // 3. Wipe LLM-generated tables
        try db.wipeLLMData()

        // 4. Reset pipelines flag and re-run
        UserDefaults.standard.removeObject(forKey: Constants.pipelinesCompletedKey)
        backgroundTaskManager.tasks.removeAll()
        backgroundTaskManager.startPipelines(legacyPeople: analysisLegacyMode, disabledFeatures: featureManager.disabledFeatureIDs)
    }

    /// Ensure the daemon is running against the current CLI binary.
    /// If an old instance is already running (e.g. from a stale dev rebuild), stop it first,
    /// then start a fresh one. Paired with the QuitCoordinator daemon stop on app terminate
    /// so UI quit/launch cycles the daemon lifecycle.
    private func ensureDaemonRunning() {
        Task {
            daemonManager.resolvePathIfNeeded()
            if DaemonManager.checkDaemonRunning() {
                await daemonManager.stopDaemon()
                try? await Task.sleep(for: .milliseconds(500))
            }
            await daemonManager.startDaemon()
        }
    }

    /// Builds every feature ViewModel and starts their sync-tolerant polling,
    /// once the DB is open and splash has decided to hand off to the main UI.
    /// Pulled out of `initialize()` to keep that function under the lint limit.
    private func initFeatureViewModels(manager: DatabaseManager) {
        initCalendar(dbPool: manager.dbPool)
        initDayPlan(dbPool: manager.dbPool)
        initCatchUp(dbPool: manager.dbPool)
        initMemory(dbPool: manager.dbPool)
        initIdeas(dbManager: manager)
        initBriefings(dbManager: manager)
        initSecretaryProfile(dbManager: manager)
        initEmailAccounts(dbPool: manager.dbPool)
        initCalendarAccounts(dbPool: manager.dbPool)
        initGoogleAccounts(dbPool: manager.dbPool)
        initSlackAccounts(dbPool: manager.dbPool)
        initJiraAccounts(dbPool: manager.dbPool)
        initExternalConnections(dbPool: manager.dbPool)
        initReactionDictionary(dbPool: manager.dbPool)
        initActionStrip(dbPool: manager.dbPool)
        initProjects(dbPool: manager.dbPool)
        startDigestWatcher(dbPool: manager.dbPool)
        startMeetingReminders(dbPool: manager.dbPool)
        startWarmEnginePolicy(dbPool: manager.dbPool)
        // So the quit path always has a pool to close, even before the Chat
        // tab was ever opened — `closeAll()` on an empty pool is a no-op, and
        // creating the pool here only starts its idle-eviction poll; it never
        // spawns a session process (that happens on select/prewarm/send).
        ensureChatSessionPool(manager)
    }

    private func initCalendar(dbPool: DatabasePool) {
        calendarViewModel = CalendarViewModel(dbPool: dbPool)
    }

    private func initDayPlan(dbPool: DatabasePool) {
        guard let runner = ProcessCLIRunner.makeDefault() else { return }
        dayPlanViewModel = DayPlanViewModel(databasePool: dbPool, cliRunner: runner)
    }

    private func initCatchUp(dbPool: DatabasePool) {
        let vm = CatchUpViewModel(dbPool: dbPool)
        // Catch-Up builds recaps in a CLI child process, whose writes the sidebar's
        // ValueObservation cannot see, so the badge is refreshed explicitly once a
        // run (or an acknowledge) has finished. The counts VM is resolved at call
        // time, not captured: with onboarding pending it is built later still.
        vm.onRecapsChanged = { [weak self] in
            await self?.sidebarCountsViewModel?.refresh()
        }
        catchUpViewModel = vm
    }

    private func initMemory(dbPool: DatabasePool) {
        memoryViewModel = MemoryViewModel(dbPool: dbPool)
    }

    /// Not marked `private` (mirrors `initSecretaryProfile` below), leaving the
    /// same XCTest entry point open for `ideasViewModel` (used by
    /// `IdeaNavigationTests` to drive `navigateToIdea`).
    func initIdeas(dbManager: DatabaseManager) {
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.startObserving()
        ideasViewModel = vm
    }

    /// Not marked `private` (the `initSecretaryProfile` precedent) so XCTest can
    /// prove `briefingViewModel` identity — and its in-flight generate state —
    /// persists across tab switches (`BriefingViewModelTests`).
    func initBriefings(
        dbManager: DatabaseManager,
        cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault()
    ) {
        let vm = BriefingViewModel(dbManager: dbManager, cliRunner: cliRunner)
        vm.startObserving()
        briefingViewModel = vm
    }

    /// Not marked `private` (unlike most of its siblings above) so XCTest can call it
    /// directly via `@testable import` to prove `secretaryProfileViewModel` identity
    /// persists across accesses, without going through the real-filesystem/CLI-subprocess
    /// machinery in `initialize()` (`SecretaryProfileViewModelTests`).
    func initSecretaryProfile(dbManager: DatabaseManager) {
        secretaryProfileViewModel = SecretaryProfileViewModel(dbManager: dbManager)
    }

    func initEmailAccounts(dbPool: DatabasePool) {
        let vm = EmailAccountsViewModel(dbPool: dbPool)
        vm.refresh()
        emailAccountsViewModel = vm
    }

    func initCalendarAccounts(dbPool: DatabasePool) {
        let vm = CalendarAccountsViewModel(dbPool: dbPool)
        vm.refresh()
        calendarAccountsViewModel = vm
    }

    func initSlackAccounts(dbPool: DatabasePool) {
        let vm = SlackAccountsViewModel(dbPool: dbPool)
        vm.onAccountsChanged = { [weak self] in await self?.refreshOwner() }
        vm.refresh()
        slackAccountsViewModel = vm
    }

    func initJiraAccounts(dbPool: DatabasePool) {
        let vm = JiraAccountsViewModel(dbPool: dbPool)
        vm.onAccountsChanged = { [weak self] in await self?.refreshOwner() }
        vm.refresh()
        jiraAccountsViewModel = vm
        // Pickers built over a previous pool would read a stale database.
        confluenceSpacesViewModels = [:]
        // Browse-URL resolution reads jira_accounts.site_url — wire the pool
        // here, the same point the sibling VM gets its pool, so per-issue
        // links resolve from the DB instead of the frozen config keys.
        JiraConfigHelper.configure(dbPool: dbPool)
    }

    /// The Confluence spaces picker for `accountID`, created on first use
    /// (nil until the DB is open). `runner` and `syncNow` (default: the
    /// daemon's Sync Now, run after a successful select) only matter on that
    /// first call; tests pass fakes.
    /// "Grant Confluence access" runs the Jira account's own login flow with
    /// `--with-confluence` on `jiraAccountsViewModel`, so its in-flight state
    /// and errors land where every other Jira re-login's do.
    @discardableResult
    func confluenceSpacesViewModel(
        forJiraAccount accountID: Int64,
        runner: CLIRunnerProtocol? = ProcessCLIRunner.makeDefault(),
        syncNow: (@MainActor () async -> Void)? = nil
    ) -> ConfluenceSpacesViewModel? {
        if let existing = confluenceSpacesViewModels[accountID] { return existing }
        guard let pool = databaseManager?.dbPool else { return nil }
        let vm = ConfluenceSpacesViewModel(
            accountID: accountID,
            dbPool: pool,
            runner: runner,
            onReconsent: { [weak self] id in
                guard let jira = self?.jiraAccountsViewModel else { return "Jira accounts are not loaded yet." }
                await jira.reloginWithConfluence(accountID: Int(id))
                return jira.error
            },
            // Best-effort, the tray's Sync Now: a failure only means the
            // daemon picks the space up on its next poll instead.
            onSelected: syncNow ?? { [weak self] in await self?.daemonManager.syncNow() }
        )
        confluenceSpacesViewModels[accountID] = vm
        return vm
    }

    func initExternalConnections(dbPool: DatabasePool) {
        let vm = ExternalConnectionsViewModel(dbPool: dbPool)
        vm.refresh()
        externalConnectionsViewModel = vm
    }

    func initReactionDictionary(dbPool: DatabasePool) {
        let vm = ReactionDictionaryViewModel(dbPool: dbPool)
        vm.refresh()
        reactionDictionaryViewModel = vm
    }

    func initActionStrip(dbPool: DatabasePool) {
        let vm = ActionStripViewModel(dbPool: dbPool)
        vm.refresh()
        actionStripViewModel = vm
    }

    /// Not `private`: tests build the VM on a test pool (the
    /// `initSecretaryProfile` precedent) to prove it survives navigation.
    func initProjects(
        dbPool: DatabasePool,
        cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault(),
        notifier: ProjectNotifying = NotificationService.shared
    ) {
        let vm = ProjectsViewModel(dbPool: dbPool, cli: cliRunner.map { ProjectCLI(runner: $0) })
        vm.closeTerminal = { [weak self] id in await self?.projectTerminalCenter.close(projectID: id) }
        let notices = ProjectNotificationCenter(dbPool: dbPool, notifier: notifier)
        vm.onProjectCreated = { [weak self, weak notices] project, installed in
            notices?.seedBaseline(project: project)
            if installed { self?.projectTerminalCenter.start(project: project, firstRun: true) }
        }
        vm.onOwnerWrite = { [weak notices] projectID, subject in
            notices?.recordOwnerWrite(projectID: projectID, subject: subject)
        }
        vm.isTabOnScreen = { [weak self] in
            self?.selectedDestination == .projects
                && NSApp.windows.contains { TrayAppDelegate.isMainWindow($0) && $0.isVisible && $0.occlusionState.contains(.visible) }
        }
        notices.onPolled = { [weak vm] in await vm?.refreshOnPoll() }
        projectsViewModel = vm
        projectNotificationCenter = notices
        // The first poll also loads the list (onPolled → reload).
        notices.start()
    }

    func initGoogleAccounts(dbPool: DatabasePool) {
        let vm = GoogleAccountsViewModel(dbPool: dbPool)
        vm.onAccountsChanged = { [weak self] in await self?.refreshOwner() }
        vm.refresh()
        googleAccountsViewModel = vm
        // GoogleConnectFlow.shared is a singleton constructed before any
        // dbPool exists (Navigation.swift / SidebarView.swift reference its
        // `calendar` service directly) — wire it here, the same point its
        // sibling VM above gets its pool, so isConnected reads google_accounts
        // instead of staying permanently false.
        GoogleConnectFlow.shared.configure(dbPool: dbPool)
    }

    /// Re-resolves `owner` off the main thread. A failed read keeps the last
    /// known value (logged): flipping a known owner to unknown on a transient
    /// error would hide Generate for no reason.
    func refreshOwner() async {
        guard let pool = databaseManager?.dbPool else { return }
        do {
            owner = try await pool.read { db in try OwnerQueries.resolve(db) }
        } catch {
            print("[AppState] owner resolve failed, keeping the last value: \(error.localizedDescription)")
        }
    }

    private func startMeetingReminders(dbPool: DatabasePool) {
        let center = MeetingReminderCenter(dbPool: dbPool, recorderCenter: meetingRecorderCenter)
        meetingReminderCenter = center
        center.start()
    }

    /// Hands the recorder Center its real meetings provider (the Center is
    /// created before the dbPool exists — the `wireMeetingRecorderLoaders`
    /// precedent) and starts the warm-engine policy poll. A read failure is
    /// treated as "no meetings" and logged (the MeetingReminder convention):
    /// the worst outcome is a missed prewarm or a one-tick-late unload, both
    /// self-correcting — never a crash, never an unload mid-recording (the
    /// policy never touches a busy engine regardless of the window).
    private func startWarmEnginePolicy(dbPool: DatabasePool) {
        meetingRecorderCenter.configureWarmPolicy { now in
            do {
                // Candidate events overlapping the prewarm lookahead:
                // fetchEvents matches start_time <= to AND end_time >= from,
                // so this returns both ongoing meetings and ones starting
                // within the lead; the pure logic sorts out which is which.
                let events = try dbPool.read { db in
                    try CalendarQueries.fetchEvents(
                        db,
                        from: now,
                        to: now.addingTimeInterval(WarmEnginePolicy.prewarmLead)
                    )
                }
                return WarmEnginePolicy.window(events: events, now: now)
            } catch {
                print("[AppState] warm-policy event read failed, treating as no meetings: "
                      + error.localizedDescription)
                return .noMeetings
            }
        }
        meetingRecorderCenter.startWarmPolicy()
    }

    private func startDigestWatcher(dbPool: DatabasePool) {
        Task {
            let granted = await NotificationService.shared.requestPermission()
            guard granted else { return }
            let watcher = DigestWatcher(dbPool: dbPool)
            self.digestWatcher = watcher
            watcher.start()
        }
    }

    private func loadCustomEmoji(from manager: DatabaseManager) {
        Task.detached {
            let map = try? await manager.dbPool.read { db in
                try CustomEmojiQueries.fetchEmojiMap(db)
            }
            await MainActor.run {
                self.customEmojiMap = map ?? [:]
            }
        }
    }
}

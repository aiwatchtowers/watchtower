import SwiftUI
import GRDB
import Observation
import os
import WatchtowerCore
import WatchtowerSync

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

    /// Whether onboarding (Goals → Connect → About you) is on screen.
    var needsOnboarding: Bool = false

    /// Persistent onboarding state machine — tracks which step the user is on across app restarts.
    let onboarding: OnboardingStateMachineV2

    /// Onboarding's Goals step (goals, feature selection, language, CLI
    /// check), held here so it survives the Customize screen.
    let onboardingGoals: OnboardingGoalsModel

    /// Onboarding's background Slack roster load, started from Connect and
    /// read by About you.
    let peopleRoster: PeopleRosterLoad

    /// Onboarding's About you answers, kept across Back and return.
    let onboardingAboutYou = OnboardingAboutYouModel()

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

    /// App-wide home of the embedded assistant chats' engines (track, idea,
    /// meeting, …), so a reply keeps streaming after its screen closes or its
    /// section collapses; at most three such turns run at once.
    @ObservationIgnored private let embeddedChats = EmbeddedChatEngineFactory()
    /// Once a minute: idle embedded chats and code indexes are released.
    @ObservationIgnored private var idleReleaseSweep: Timer?
    var embeddedChatCenter: EmbeddedChatCenter { embeddedChats.center }

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

    /// Opens the Settings window (the `openQuickCapture` shape) for callers
    /// with no SwiftUI environment — the update notification's click handler.
    /// Set by the scene once `@Environment(\.openSettings)` is available.
    var openSettingsWindow: (() -> Void)?

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
    let terminalCenter = TerminalCenter()
    /// The Workbench code viewer's symbol index, per workbench: survives
    /// navigation, released 5 minutes after its last view (spec §7).
    let codeIndexCenter = CodeIndexCenter()
    /// Open Quickly (⇧⇧, ⇧⌘O, ⇧⌘F) for the workbench page on screen.
    @ObservationIgnored private(set) lazy var openQuicklyCenter = OpenQuicklyCenter(codeIndex: codeIndexCenter)
    /// Go to definition (⌘-click, ⌃⌘J) and the Files pane's back/forward
    /// history (⌃⌘← / ⌃⌘→), per workbench.
    @ObservationIgnored private(set) lazy var codeNavigationCenter = CodeNavigationCenter(codeIndex: codeIndexCenter)
    /// Usages (⇧⌘U) and the Files pane's inspector, per workbench.
    let codeUsagesCenter = CodeUsagesCenter()
    /// Code questions at the editor's selection (✦, ⌘I): the popover's
    /// question per workbench; its conversation lives in `embeddedChatCenter`.
    let codeQuestionCenter = CodeQuestionCenter()
    /// Hand to Claude Code (⌥⌘↩): the hand-off sheet's request per workbench.
    let codeHandoffCenter = CodeHandoffCenter()

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

    /// Workbench tab (spec §6). Owned here so create/repair and the selection
    /// survive navigation.
    private(set) var workbenchesViewModel: WorkbenchesViewModel?
    /// Owner notifications for project activity; polls every 30 s.
    private(set) var workbenchNotificationCenter: WorkbenchNotificationCenter?
    /// The live workbench sessions' agent states (board #312), polled while
    /// a `claude` session runs, whatever tab is shown.
    private(set) var sessionAgentStateCenter: SessionAgentStateCenter?
    /// The session rows' report lines and the shown session's full report
    /// (session report spec, Part 7), kept across navigation.
    private(set) var sessionReportCenter: SessionReportCenter?
    /// Set by `navigateToWorkbench`; `WorkbenchesView` consumes and clears it.
    var pendingWorkbenchRoute: WorkbenchRoute?

    /// The opt-in mobile hub (mobile POC spec §6.1): nil while
    /// `mobileSyncEnabled` is off. Rebuilt whenever `initWorkbenches` re-runs,
    /// because it holds the centers that function replaces.
    private(set) var mobileHub: MobileHubService?
    /// Why the hub's storage could not be opened, for Settings → Mobile.
    private(set) var mobileHubInitError: String?
    /// Where the toggle lives; tests pass a throwaway suite.
    @ObservationIgnored var mobileSyncDefaults: UserDefaults = .standard
    /// Opens the hub's transport and sidecar; tests pass a stub.
    @ObservationIgnored var makeMobileHubStorage: () throws -> MobileHubStorage = { try MobileHubStorage.live() }
    /// Built once per run and kept across hub rebuilds and toggles.
    @ObservationIgnored private var mobileHubStorage: MobileHubStorage?
    @ObservationIgnored private var mobileHubPool: DatabasePool?

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
    let featureManager: FeatureManagerService

    /// `onboardingDefaults` backs the onboarding step and goals — tests pass
    /// an isolated suite.
    @ObservationIgnored private let onboardingDefaults: UserDefaults

    /// Opens (and migrates) the workspace database.
    @ObservationIgnored private let openDatabase: @Sendable () throws -> DatabaseManager

    /// Test seams for the two steps of finishing onboarding that spawn CLI
    /// children or ask macOS for permissions; nil runs the real thing
    /// (`daemonManager`, `wireAppDatabase`'s body).
    @ObservationIgnored var daemonControlOverride: (any DaemonControl)?
    @ObservationIgnored var wireAppDatabaseOverride: ((DatabaseManager) -> Void)?

    /// `onboardingDefaults` backs the onboarding step and goals, `openDatabase`
    /// the database open, `peopleRosterRun` the people load, `featureManager`
    /// the Feature Manager — tests pass an isolated suite and fakes.
    init(
        onboardingDefaults: UserDefaults = .standard,
        openDatabase: @escaping @Sendable () throws -> DatabaseManager = { try DatabaseManager.migrateAndOpen() },
        peopleRosterRun: @escaping PeopleRosterLoad.Run = PeopleRosterLoad.cliRun,
        featureManager: FeatureManagerService? = nil,
        onboardingGoals: OnboardingGoalsModel? = nil
    ) {
        let features = featureManager ?? FeatureManagerService()
        self.featureManager = features
        onboarding = OnboardingStateMachineV2(defaults: onboardingDefaults)
        self.onboardingDefaults = onboardingDefaults
        self.onboardingGoals = onboardingGoals ?? .production(defaults: onboardingDefaults, featureManager: features)
        peopleRoster = PeopleRosterLoad(run: peopleRosterRun)
        self.openDatabase = openDatabase
        // A daemon that came up after all (a later poll, a Settings start)
        // takes the "did not start" banner with it.
        daemonManager.onRunningChanged = { [weak self] running in
            if running { self?.daemonStartFailure = nil }
        }
    }

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

    func navigateToWorkbench(_ route: WorkbenchRoute) {
        pendingWorkbenchRoute = route
        selectedDestination = .workbench
    }

    private var isInitializing = false
    /// `initialize()`'s launch work and its daemon (re)start — held so tests
    /// can await them.
    @ObservationIgnored private(set) var launchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var ensureDaemonTask: Task<Void, Never>?
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

    /// Once per process: initialize() re-runs on every retry
    /// (reinitializeAfterOnboarding), which must not stack observers.
    private func installLifecycleHooks() {
        targetAssistantCenter.embeddedChats = embeddedChatCenter
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A reply streaming in an embedded chat keeps what it has, as `partial`.
                    self?.embeddedChatCenter.finishAllAsPartial()
                    // Edits in the code viewer not yet on disk are written now.
                    self?.workbenchesViewModel?.codeFiles.flushAll()
                    self?.stopCodeNavigationChildren()
                    // Onboarding's people load: its child gets SIGTERM.
                    self?.peopleRoster.stop()
                    // Best-effort: the removal may not finish before exit;
                    // the next launch removes what is left.
                    self?.sessionAgentStateCenter?.withdrawAllNotices()
                    // A session-report child gets SIGTERM.
                    self?.sessionReportCenter?.stop()
                    self?.mobileHub?.stop()
                }
            }
        }
        if idleReleaseSweep == nil {
            idleReleaseSweep = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.embeddedChatCenter.sweep()
                    self?.codeIndexCenter.releaseIdleIndexes()
                }
            }
        }
    }

    /// App quit: no `watchtower code …` child outlives the app — the index
    /// children, and the searches of Open Quickly, go to definition, Usages
    /// and "Where is it used?" (rulings R34, R45; each runs in a process
    /// group of its own).
    private func stopCodeNavigationChildren() {
        Self.stopCodeNavigationChildren(
            index: codeIndexCenter, openQuickly: openQuicklyCenter, navigation: codeNavigationCenter, usages: codeUsagesCenter,
            questions: codeQuestionCenter
        )
    }

    static func stopCodeNavigationChildren(
        index: CodeIndexCenter,
        openQuickly: OpenQuicklyCenter,
        navigation: CodeNavigationCenter,
        usages: CodeUsagesCenter,
        questions: CodeQuestionCenter
    ) {
        index.stopAll()
        openQuickly.stopOpenQuicklySearch()
        navigation.stopDefinitionSearches()
        usages.stopUsagesSearches()
        questions.stopQuestionSearches()
    }

    func initialize() {
        guard !isInitializing else { return }
        isInitializing = true
        isLoading = true
        Constants.prewarmResolvedEnvironment()
        // Surface a recording captured before a crash/relaunch so the global
        // indicator can offer to (re-)transcribe it. No DB needed.
        meetingRecorderCenter.restorePendingOnLaunch()
        // Neither direction of this handshake needs the DB, so it is wired
        // unconditionally rather than inside the DB-dependent Task below.
        dictationCenter.meetingBusy = { [meetingRecorderCenter] in meetingRecorderCenter.isBusy }
        meetingRecorderCenter.captureWillStart = { [dictationCenter] in dictationCenter.meetingCaptureWillStart() }
        meetingRecorderCenter.dictationEngineResident = { [dictationCenter] in dictationCenter.hasResidentEngine }
        dictationCenter.engineReleased = { [meetingRecorderCenter] in meetingRecorderCenter.dictationEngineDidRelease() }
        installLifecycleHooks()
        launchTask = Task {
            await syncCLIBinaryStore()
            // Only now resolve the CLI path and start polling: before the sync
            // the store copy may still be the stale one, and DaemonManager
            // caches whatever path it first resolves.
            daemonManager.startPolling()
            do {
                // Off the concurrency pool: the migrate child may run for up
                // to 30 s (see ProcessPipes).
                let opened = await ProcessPipes.offPool { [openDatabase] in Result { try openDatabase() } }
                let manager = try opened.get()
                ambiguousWorkspaces = []
                // Before the splash hides, so Day Plan / Briefings never flash
                // the no-owner state on an install that has one.
                await wireOnboardingDatabase(manager)
                await reconcileOnboarding(dbPool: manager.dbPool)
                profileComplete = !needsOnboarding
                // Pre-load sidebar badge counts so they're already visible when the splash hides.
                // Skipped when onboarding is needed — the onboarding view replaces the sidebar entirely.
                if !needsOnboarding {
                    await initSidebarCounts(dbPool: manager.dbPool)
                }
                isLoading = false
                // During onboarding only the account view models run (above):
                // the rest (watchers that ask for notification permission,
                // meeting reminders, polling) waits for completeOnboarding().
                if !needsOnboarding {
                    wireAppDatabase(manager)
                }
                // The daemon's cycle generates everything itself: a launch
                // needs nothing more than a running daemon.
                if !needsOnboarding {
                    // Ensure a fresh daemon is running (rebuild-safe): stop any existing
                    // one (possibly from an older binary), then start the current binary.
                    ensureDaemonRunning()
                }
            } catch {
                await handleLaunchDatabaseFailure(error)
            }
            // Any launch that lands in onboarding (a fresh install, or one
            // relaunched before finishing it) may let the transcription
            // langset follow the Mac's languages; "Run setup again" from
            // Settings does not, it never goes through here. An install that
            // finished onboarding keeps the "ru,uk,en" default it has been
            // transcribing with. Whisper's codes: it is the default engine.
            if needsOnboarding {
                TranscriptionLangsetSeed.seedIfUntouched(.standard, supported: WhisperKitEngine.languageCodes)
            }
        }
        // Check for updates now and every UpdateService.checkInterval while
        // running (a no-op for builds without an update channel).
        updateService.startPeriodicChecks()
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
        // Prime the resolver's verdict off the main actor: the first resolution
        // hashes the 35 MB CLI twice and checks its signature, and the next
        // callers (DaemonManager, onboarding, view models) run on the main actor.
        let resolved = await Task.detached(priority: .userInitiated) { CLIBinaryStore.resolvedInstalledPath() }.value
        if resolved == nil, cliStoreError == nil {
            NSLog("CLIBinaryStore: the store copy did not verify (hash, signature, or a build without a Team ID); the CLI runs from the app bundle")
        }
    }

    @ObservationIgnored private var onboardingDatabaseOpen: Task<String?, Never>?

    /// The completion sequence is running: every step's Continue is off, so
    /// a second click cannot run it (or Goals' writes) again.
    private(set) var isFinishingOnboarding = false
    /// Why the last step exit failed (the database, the completion
    /// sequence); cleared on the next exit and on Back.
    private(set) var onboardingStepError: String?

    func clearOnboardingStepError() {
        onboardingStepError = nil
    }

    /// Moves past `step`: to the next step `route` runs — opening the
    /// database first when that is Connect, whose account sheets need it —
    /// or, when none is left, through `OnboardingCompletion.finish`, which
    /// writes `onboarding_done` with About you's answers when given
    /// (`OnboardingProfileWriter.done`), else alone (`.later`).
    func leaveOnboardingStep(
        _ step: OnboardingV2Step,
        route: OnboardingRoute,
        about: OnboardingAboutYou? = nil,
        onRetry: () -> Void
    ) async {
        // Finishing, or finished: a late click must not run it again.
        guard !isFinishingOnboarding, onboarding.currentStep != .complete else { return }
        onboardingStepError = nil
        let next = route.step(after: step)
        if next == .connect, let failure = await openDatabaseForOnboarding() {
            onboardingStepError = "Could not open the database: \(failure)"
            return
        }
        guard next == .complete else {
            onboarding.advance(route: route)
            return
        }
        isFinishingOnboarding = true
        defer { isFinishingOnboarding = false }
        let isRerun = isOnboardingRerun
        let finished = await OnboardingCompletion.finish(
            markOnboardingDone: {
                if let failure = await openDatabaseForOnboarding() {
                    onboardingStepError = "Could not open the database: \(failure)"
                    return false
                }
                guard let manager = databaseManager else { return false }
                do {
                    try await manager.dbPool.write { db in
                        if let about {
                            try OnboardingProfileWriter.done(db, about: about)
                        } else {
                            try OnboardingProfileWriter.later(db)
                        }
                    }
                    return true
                } catch {
                    onboardingStepError = "Could not finish setup: \(error.localizedDescription)"
                    return false
                }
            },
            startDaemon: {
                // One daemon start (or restart) instead of one-shot CLI
                // generators racing its first cycle. In the background: a
                // restart may wait up to a minute for the old daemon to die,
                // and Continue must not. It starts only after the
                // onboarding_done write above.
                // A re-run that changed nothing needs no restart — only a
                // daemon, if none runs.
                bringUpDaemonInBackground(startOnly: isRerun && !rerunChangedSomething)
                // The landing reads the sources the steps just connected.
                await refreshConnectedSources()
            },
            completeOnboarding: {
                completeOnboarding()
                // Landing is for the first run; a re-run goes back to where
                // the owner was.
                if !isRerun { land(after: route) }
            },
            onRetry: onRetry
        )
        // About you was answered (or deferred) here: no later sheet.
        if finished, step == .aboutYou {
            markAboutYouShown()
        }
    }

    /// Opens the database for onboarding's Connect step, whose account
    /// sheets need the account view models — on a fresh install launch could
    /// not open it (no workspace until Goals' Continue). Only what the steps
    /// need (`wireOnboardingDatabase`); completion wires the rest. A no-op
    /// when the database is open; concurrent calls share one open. Returns
    /// the failure to show, nil on success.
    func openDatabaseForOnboarding() async -> String? {
        if databaseManager != nil { return nil }
        if let onboardingDatabaseOpen { return await onboardingDatabaseOpen.value }
        let open = Task<String?, Never> { [openDatabase] in
            let opened = await ProcessPipes.offPool { Result { try openDatabase() } }
            switch opened {
            case .failure(let error):
                return error.localizedDescription
            case .success(let manager):
                await wireOnboardingDatabase(manager)
                return nil
            }
        }
        onboardingDatabaseOpen = open
        let failure = await open.value
        onboardingDatabaseOpen = nil
        return failure
    }

    /// `initialize()` when the database could not be opened: on a fresh
    /// install (no workspace yet) that is onboarding's starting point.
    func handleLaunchDatabaseFailure(_ error: Error) async {
        print("[AppState] database open failed: \(error.localizedDescription)")
        errorMessage = error.localizedDescription
        databaseManager = nil
        if case WatchtowerDatabaseError.ambiguousWorkspace(let names) = error {
            ambiguousWorkspaces = names
        } else {
            ambiguousWorkspaces = []
        }
        // No DB available — if state machine not complete, onboarding needed
        await reconcileOnboarding(dbPool: nil)
        if needsOnboarding {
            // Nothing is connected without a database; only the sidebar of
            // a finished install keeps failing open.
            featureVisibility.connectedSources = .none
        }
        isLoading = false
    }

    /// Launch-time onboarding state: the DB's `onboarding_done` wins over a
    /// local step that is not complete (no UserDefaults — a new Mac, a wiped
    /// defaults domain — must not re-run onboarding on a finished install);
    /// then a resumed step the route now skips moves on. When nothing is
    /// left after it, it goes back to Goals instead: settling straight into
    /// `.complete` would skip the completion sequence (`onboarding_done`,
    /// the pipelines), which Goals' Continue then runs. `dbPool` is nil when
    /// the database could not be opened. Needs `refreshConnectedSources` to
    /// have run: the route reads whether Slack is connected.
    func reconcileOnboarding(dbPool: DatabasePool?) async {
        // An unreadable profile skips onboarding for this launch only — not
        // persisted, so the next launch checks again.
        var skipThisLaunch = false
        if let dbPool, onboarding.currentStep != .complete {
            switch await checkProfileOnboarding(dbPool: dbPool) {
            case .done: onboarding.goTo(.complete)
            case .unreadable: skipThisLaunch = true
            case .pending: break
            }
        }
        let route = onboardingRoute
        if onboarding.currentStep != .complete, route.skips(onboarding.currentStep),
           route.step(after: onboarding.currentStep) == .complete {
            onboarding.goTo(.purpose)
        }
        onboarding.settle(route: route)
        needsOnboarding = !skipThisLaunch && onboarding.currentStep != .complete
    }

    /// The route onboarding follows: the goals of the last Continue and
    /// whether a Slack account is connected.
    var onboardingRoute: OnboardingRoute {
        onboardingGoals.route(hasSlackAccount: onboardingHasSlackAccount)
    }

    /// Settings' account changes (Add, Remove, re-login) while onboarding is
    /// on screen leave the daemon to its finish.
    var accountDaemonPolicy: DaemonRestartPolicy {
        needsOnboarding ? .deferred : .restart
    }

    /// Whether a Slack account is connected, for onboarding's decisions
    /// (workspace init, the route). Never the sidebar's fail-open value:
    /// with no database there is no account, whatever `connectedSources`
    /// says.
    var onboardingHasSlackAccount: Bool {
        databaseManager != nil && featureVisibility.connectedSources.slack
    }

    private enum ProfileOnboarding {
        /// Profile missing or onboarding_done == false.
        case pending
        case done
        /// The read failed (logged).
        case unreadable
    }

    private func checkProfileOnboarding(dbPool: DatabasePool) async -> ProfileOnboarding {
        do {
            return try await dbPool.read { db in
                guard let profile = try ProfileQueries.fetchCurrentProfile(db) else { return .pending }
                return profile.onboardingDone ? .done : .pending
            }
        } catch {
            print("[AppState] onboarding check failed: \(error.localizedDescription)")
            return .unreadable
        }
    }

    /// Finish's daemon bring-up, held so tests can await it.
    @ObservationIgnored private(set) var onboardingDaemonStart: Task<Void, Never>?

    /// Starts (or, with `startOnly` false, restarts) the daemon in the
    /// background, after any earlier bring-up still running: two restarts
    /// overlapping would read as a failed start.
    private func bringUpDaemonInBackground(startOnly: Bool) {
        let daemon = daemonControl
        let previous = onboardingDaemonStart
        onboardingDaemonStart = Task {
            await previous?.value
            let up = startOnly && daemon.daemonIsRunning()
                ? true
                : await OnboardingFinishPlan.bringUpDaemon(daemon)
            if up {
                daemonStartFailure = nil
            } else {
                daemonStartFailure = Self.daemonStartFailureText(daemonManager.errorMessage)
            }
        }
    }

    /// The background sync did not come up after setup: shown over the tab
    /// setup landed on, not only in the tray.
    private(set) var daemonStartFailure: String?

    func dismissDaemonStartFailure() {
        daemonStartFailure = nil
    }

    static func daemonStartFailureText(_ detail: String?) -> String {
        let reason = detail.map { ": \($0)." } ?? "."
        return "The background sync did not start\(reason) Open Settings → System to retry."
    }

    // MARK: - Features for a source connected from Settings

    /// What `refreshConnectedSources` last read; nil before the first read.
    @ObservationIgnored private var lastReadConnectedSources: ConnectedSources?
    /// The check a new source kicked off — held so tests can await it.
    @ObservationIgnored private(set) var featureSuggestionCheck: Task<Void, Never>?

    /// Features the goals of a just-connected source would turn on, off
    /// now, waiting for the owner's yes.
    private(set) var featureSuggestion: [FeatureInfo] = []
    private(set) var isApplyingFeatureSuggestion = false
    private(set) var featureSuggestionError: String?

    /// The offer shows in Settings after the late About you sheet and once
    /// no Add account sheet is up.
    var showsFeatureSuggestion: Bool {
        !featureSuggestion.isEmpty && !showsLateAboutYou && !lateAboutYouPending && !isAddingAccount
    }

    /// Settings' one sheet slot: About you always first, the feature offer
    /// queued behind it.
    var settingsSheet: SettingsSheet? {
        if showsLateAboutYou { return .aboutYou }
        return showsFeatureSuggestion ? .featureSuggestion : nil
    }

    /// The slot was closed from outside its buttons (Esc on About you); the
    /// feature offer closes only through its own.
    func settingsSheetDismissed(_ sheet: SettingsSheet) {
        if sheet == .aboutYou { showsLateAboutYou = false }
    }

    /// Waits for the account view models' own daemon restarts (an Add or
    /// Remove in Settings) still in flight.
    private func awaitAccountDaemonRestarts() async {
        await slackAccountsViewModel?.daemonRestartTask?.value
        await googleAccountsViewModel?.daemonRestartTask?.value
        await jiraAccountsViewModel?.daemonRestartTask?.value
    }

    static let featureChangesBusy = "Feature changes are being applied in Settings — try again"
    static let featureStagedInSettings =
        "This feature has an unsaved change in Settings → Features — apply or discard it first"

    /// Offered while an apply runs: merged once it is over.
    @ObservationIgnored private var deferredSuggestion: [FeatureInfo] = []

    private func suggestFeatures(for goals: [OnboardingGoal]) async {
        await featureManager.load()
        if let error = featureManager.loadError {
            print("[AppState] related features not offered, the feature list failed: \(error)")
            return
        }
        let features = featureManager.features
        let ids = SourceConnectPrompt.suggestedFeatureIDs(
            for: goals,
            disabled: featureManager.disabledFeatureIDs,
            registryOrder: features.map(\.id)
        )
        let suggested = features.filter { ids.contains($0.id) }
        guard !suggested.isEmpty else { return }
        if isApplyingFeatureSuggestion {
            deferredSuggestion = Self.union(deferredSuggestion, suggested)
            return
        }
        featureSuggestionError = nil
        featureSuggestion = Self.union(featureSuggestion, suggested)
    }

    private static func union(_ lhs: [FeatureInfo], _ rhs: [FeatureInfo]) -> [FeatureInfo] {
        lhs + rhs.filter { new in !lhs.contains { $0.id == new.id } }
    }

    /// Yes: enables the offered features right away (`features enable`,
    /// never through Settings → Features' staged changes) and restarts the
    /// daemon once. After a failed restart a retry finds them already on
    /// and only restarts.
    func acceptFeatureSuggestion() async {
        guard !featureSuggestion.isEmpty, !isApplyingFeatureSuggestion else { return }
        isApplyingFeatureSuggestion = true
        defer {
            isApplyingFeatureSuggestion = false
            featureSuggestion = Self.union(featureSuggestion, deferredSuggestion)
            deferredSuggestion = []
        }
        let ids = featureSuggestion.map(\.id)
        let daemon = daemonControl
        // The connect that raised the offer may still be restarting the
        // daemon itself: one restart at a time.
        await awaitAccountDaemonRestarts()
        let result = await featureManager.enableNow(ids) { try await daemon.restartWaiting() }
        if result.busy {
            // Settings → Features is applying its own batch.
            featureSuggestionError = Self.featureChangesBusy
            return
        }
        let stillOff = Set(ids).intersection(featureManager.disabledFeatureIDs)
        if result.enabled.isEmpty, stillOff.isEmpty {
            // Everything is on already (a retry after a failed restart): the
            // daemon still has to pick it up.
            do {
                try await daemon.restartWaiting()
                featureManager.loadError = nil
            } catch {
                featureSuggestionError = error.localizedDescription
                return
            }
        } else if let error = featureManager.loadError {
            // An enable or the restart failed: the offer stays, its retry
            // enables what is still off and restarts.
            featureSuggestionError = error
            return
        }
        // What came on is done; what is still off stays offered.
        featureSuggestion.removeAll { ids.contains($0.id) && !stillOff.contains($0.id) }
        if !stillOff.isEmpty {
            // Off only through a change staged in Settings → Features (on
            // live, so `features enable` skips it), or nothing ran at all.
            featureSuggestionError = stillOff.contains { featureManager.pending[$0] == false }
                ? Self.featureStagedInSettings
                : Self.featureChangesBusy
            return
        }
        featureSuggestionError = nil
    }

    func declineFeatureSuggestion() {
        featureSuggestion = []
        featureSuggestionError = nil
    }

    /// The Slack, Google and Jira account ids when a re-run started: an
    /// account added or removed meanwhile (the Connect sheets defer the
    /// daemon restart to finish) counts as a change.
    @ObservationIgnored private var rerunAccountsAtStart: [Int] = []

    private var accountFingerprint: [Int] {
        (slackAccountsViewModel?.accounts.map(\.id) ?? []).sorted()
            + [-1] + (googleAccountsViewModel?.accounts.map(\.id) ?? []).sorted()
            + [-1] + (jiraAccountsViewModel?.accounts.map(\.id) ?? []).sorted()
    }

    /// The re-run wrote something the daemon must pick up.
    private var rerunChangedSomething: Bool {
        onboardingGoals.wroteChanges || accountFingerprint != rerunAccountsAtStart
    }

    private var daemonControl: any DaemonControl { daemonControlOverride ?? daemonManager }

    /// Opens the tab the goals point at (`OnboardingFinishPlan.landing`).
    private func land(after route: OnboardingRoute) {
        let catchUpVisible = SidebarDestination.catchUp.isVisible(
            disabledFeatures: featureVisibility.disabledFeatureIDs,
            connected: featureVisibility.connectedSources
        )
        switch OnboardingFinishPlan.landing(goals: route.goals, catchUpVisible: catchUpVisible) {
        case .catchUp: selectedDestination = .catchUp
        case .workbench: selectedDestination = .workbench
        case .chat: selectedDestination = .chat
        }
    }

    /// Called when onboarding flow completes successfully.
    func completeOnboarding() {
        isOnboardingRerun = false
        onboarding.goTo(.complete)
        needsOnboarding = false
        profileComplete = true
        if let manager = databaseManager {
            wireAppDatabase(manager)
        }
        // The initialize() path skips sidebar counts while onboarding is pending, so build
        // them now — otherwise the first run shows all-zero badges (incl. Catch-Up) until restart.
        if sidebarCountsViewModel == nil, let pool = databaseManager?.dbPool {
            Task { await initSidebarCounts(dbPool: pool) }
        }
        // Sources onboarding connected (its account sheets may write through
        // the CLI without a VM reload) must reach the sidebar now — as a new
        // baseline: onboarding picked their features, so they raise no
        // related-features offer.
        lastReadConnectedSources = nil
        connectedSourcesRefresh = Task { await refreshConnectedSources() }
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

    /// The onboarding on screen was started from Settings: it can be
    /// cancelled back to the main window.
    private(set) var isOnboardingRerun = false
    /// Why the last "Run setup again" did not start, for both of its
    /// buttons (Settings → Profile's line, the chat's alert).
    private(set) var rerunError: String?
    /// The re-run is reading the features and config.
    private(set) var isPreparingRerun = false

    func clearRerunError() {
        rerunError = nil
    }

    /// "Run setup again" (Settings → Profile, the chat's profile button):
    /// reads what is in effect now — the feature set from the Feature
    /// Manager, the assistant language from the config — and starts the
    /// flow from it. Returns the failure to show instead of starting with a
    /// guess (a reverted feature, the macOS language over the configured
    /// one).
    func rerunOnboarding(readConfig: @MainActor () -> ConfigService = { ConfigService() }) async {
        guard !needsOnboarding, !isPreparingRerun else { return }
        isPreparingRerun = true
        defer { isPreparingRerun = false }
        rerunError = nil
        await featureManager.load()
        if let error = featureManager.loadError {
            rerunError = "Could not read the features: \(error)"
            return
        }
        let config = readConfig()
        if let error = config.parseError {
            rerunError = "Could not read the config: \(error)"
            return
        }
        let enabled = Set(featureManager.features.filter { $0.state == "enabled" }.map(\.id))
        startOnboarding(enabledFeatureIDs: enabled, configuredLanguage: config.digestLanguage)
    }

    /// Re-triggers the onboarding flow back at Goals, seeded from
    /// `enabledFeatureIDs` and `configuredLanguage` (absent: English, what
    /// the pipelines use). Nothing is written until a step's Continue.
    func startOnboarding(enabledFeatureIDs: Set<String>, configuredLanguage: String?) {
        let language = configuredLanguage?.trimmingCharacters(in: .whitespaces) ?? ""
        onboarding.reset()
        onboardingGoals.seedForRerun(
            enabledFeatureIDs: enabledFeatureIDs,
            language: language.isEmpty ? AssistantLanguageCatalog.fallbackName : language
        )
        onboardingAboutYou.prepareForRerun()
        onboardingStepError = nil
        isOnboardingRerun = true
        rerunAccountsAtStart = accountFingerprint
        needsOnboarding = true
        profileComplete = false
    }

    /// Cancel on a re-run: back to the main window, nothing more written.
    /// What a step's Continue already wrote stays and reaches the daemon (a
    /// restart in the background).
    func cancelOnboardingRerun() {
        guard isOnboardingRerun, !isFinishingOnboarding, !onboardingGoals.isContinuing else { return }
        if rerunChangedSomething {
            bringUpDaemonInBackground(startOnly: false)
        }
        isOnboardingRerun = false
        onboarding.goTo(.complete)
        onboardingStepError = nil
        needsOnboarding = false
        profileComplete = true
    }

    /// Wipe all LLM-generated data, stop the daemon, and start it again to
    /// rebuild them: its stamps go too, so the first cycle regenerates
    /// people cards and the briefing at once instead of on their cadence.
    /// A failed restart is thrown for the Settings error line.
    func resetLLMData(workspaceDir: String? = Constants.activeWorkspaceDir()) async throws {
        guard let db = databaseManager else { return }

        // 1. Stop the daemon so nothing writes while the tables are wiped —
        // after a finish still bringing one up, and only once its process is
        // really gone (a timeout wipes nothing).
        await onboardingDaemonStart?.value
        let daemon = daemonControl
        if daemon.daemonIsRunning() {
            await daemon.stopDaemonNow()
        }
        var failure: Error?
        do {
            try await daemon.waitUntilStopped()
            // 2. Wipe LLM-generated tables and the daemon's stamps.
            try db.wipeLLMData()
            if let workspaceDir {
                try DaemonStampFiles.clear(in: workspaceDir)
            }
        } catch {
            failure = error
        }

        // 3. Restart — also after a failure above, so the reset never leaves
        // the app without a daemon; the first error is what is reported.
        do {
            try await daemon.restartWaiting()
        } catch {
            failure = failure ?? error
        }
        if let failure { throw failure }
    }

    /// Ensure the daemon is running against the current CLI binary.
    /// If an old instance is already running (e.g. from a stale dev rebuild), stop it first,
    /// then start a fresh one. Paired with the QuitCoordinator daemon stop on app terminate
    /// so UI quit/launch cycles the daemon lifecycle.
    private func ensureDaemonRunning() {
        let daemon = daemonControl
        ensureDaemonTask = Task {
            daemonManager.resolvePathIfNeeded()
            if daemon.daemonIsRunning() {
                await daemon.stopDaemonNow()
                try? await Task.sleep(for: .milliseconds(500))
            }
            _ = await daemon.startDetached()
        }
    }

    /// What onboarding's steps need once the database is open: the database
    /// itself, the owner, the connected sources and the account view models
    /// behind the Connect sheets. Nothing here asks macOS for anything.
    private func wireOnboardingDatabase(_ manager: DatabaseManager) async {
        databaseManager = manager
        errorMessage = nil
        await refreshOwner()
        await refreshConnectedSources()
        guard slackAccountsViewModel == nil else { return }
        initEmailAccounts(dbPool: manager.dbPool)
        initCalendarAccounts(dbPool: manager.dbPool)
        initGoogleAccounts(dbPool: manager.dbPool)
        initSlackAccounts(dbPool: manager.dbPool)
        initJiraAccounts(dbPool: manager.dbPool)
    }

    @ObservationIgnored private var appDatabaseWired = false

    /// Mirrors Go's `DefaultInitialHistDays`.
    static let defaultInitialHistoryDays = 2

    /// The rest of the database wiring, once per process: on launch when no
    /// onboarding is pending, else at its completion.
    private func wireAppDatabase(_ manager: DatabaseManager) {
        guard !appDatabaseWired else { return }
        appDatabaseWired = true
        if let override = wireAppDatabaseOverride {
            override(manager)
            return
        }
        embeddedChats.dbPool = manager.dbPool
        wireMeetingRecorderLoaders(dbPool: manager.dbPool)
        wireTargetBriefCenter()
        loadCustomEmoji(from: manager)
        initFeatureViewModels(manager: manager)
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
        initExternalConnections(dbPool: manager.dbPool)
        initReactionDictionary(dbPool: manager.dbPool)
        initActionStrip(dbPool: manager.dbPool)
        initWorkbenches(dbPool: manager.dbPool)
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
        vm.onAccountsChanged = { [weak self] in await self?.refreshConnectedSources() }
        vm.refresh()
        emailAccountsViewModel = vm
    }

    func initCalendarAccounts(dbPool: DatabasePool) {
        let vm = CalendarAccountsViewModel(dbPool: dbPool)
        vm.onAccountsChanged = { [weak self] in await self?.refreshConnectedSources() }
        vm.refresh()
        calendarAccountsViewModel = vm
    }

    func initSlackAccounts(dbPool: DatabasePool) {
        let vm = SlackAccountsViewModel(dbPool: dbPool)
        vm.onAccountsChanged = { [weak self, weak vm] in
            if let vm { self?.slackAccountsDidChange(vm.accounts) }
            await self?.accountsChanged()
        }
        vm.refresh()
        slackAccountsViewModel = vm
    }

    /// The active Slack accounts at the last refresh; nil before the first.
    @ObservationIgnored private var knownSlackAccountIDs: Set<Int>?

    /// A Slack account that appeared since the last refresh starts the
    /// people load — however its Add sheet was left (closed mid-sign-in, the
    /// connect finishing afterwards, included) — and, outside onboarding,
    /// offers About you once. The first refresh records what is already
    /// there, and during onboarding an account already connected (a
    /// relaunch mid-onboarding) resumes the load.
    func slackAccountsDidChange(_ accounts: [SlackAccount]) {
        let active = accounts.filter { $0.status != "removed" }.map(\.id)
        defer { knownSlackAccountIDs = Set(active) }
        guard let known = knownSlackAccountIDs else {
            if needsOnboarding { resumePeopleRosterIfNeeded() }
            return
        }
        guard let added = OnboardingConnectPlan.newlyConnected(before: known, after: active) else { return }
        if needsOnboarding {
            peopleRoster.start(accountID: added)
        } else if known.isEmpty, lateAboutYouCheck == nil {
            // The first Slack account after onboarding; a second workspace
            // is not "connecting Slack".
            lateAboutYouCheck = Task {
                await offerLateAboutYou(accountID: added)
                lateAboutYouCheck = nil
            }
        }
    }

    // MARK: - About you after a later Slack connect

    /// UserDefaults key: About you was shown — the onboarding step left
    /// through Done or Later, or the sheet after a later Slack connect. The
    /// sheet is offered only while it is unset.
    static let lateAboutYouShownKey = "about_you_after_slack_shown"

    /// The sheet waits for Settings: set once the offer passed its checks,
    /// turned into `showsLateAboutYou` by `presentLateAboutYouIfReady()`.
    private(set) var lateAboutYouPending = false
    /// The About you sheet over the Settings window.
    var showsLateAboutYou = false
    /// One of Settings' Add account sheets is up: the late About you sheet
    /// and the feature suggestion wait for it.
    var isAddingAccount = false {
        didSet { presentLateAboutYouIfReady() }
    }
    private(set) var isSavingLateAboutYou = false
    private(set) var lateAboutYouError: String?
    /// The check `slackAccountsDidChange` kicked off — held so tests can
    /// await it; a second one does not start while it runs.
    @ObservationIgnored private(set) var lateAboutYouCheck: Task<Void, Never>?

    private var lateAboutYouShown: Bool {
        onboardingDefaults.bool(forKey: Self.lateAboutYouShownKey)
    }

    /// The first Slack account connected after onboarding (say a
    /// Development-only setup, Slack added in Settings later): offer About
    /// you once, unless it was shown or the profile already names people.
    /// Only then does the people load start, for the pickers.
    private func offerLateAboutYou(accountID: Int) async {
        guard !lateAboutYouShown, let pool = databaseManager?.dbPool else { return }
        do {
            let answers = try await pool.read { db in try OnboardingProfileWriter.currentAnswers(db) }
            guard answers.manager.isEmpty, answers.reports.isEmpty, answers.peers.isEmpty else { return }
        } catch {
            print("[AppState] About you check failed: \(error.localizedDescription)")
            return
        }
        // Shown meanwhile (the onboarding step, another offer)?
        guard !lateAboutYouShown else { return }
        peopleRoster.start(accountID: accountID)
        onboardingAboutYou.prepareForRerun()
        lateAboutYouError = nil
        lateAboutYouPending = true
        presentLateAboutYouIfReady()
    }

    /// Shows the pending sheet unless the Add Slack sheet is still up (its
    /// dismissal calls this again).
    func presentLateAboutYouIfReady() {
        guard lateAboutYouPending, !isAddingAccount else { return }
        lateAboutYouPending = false
        showsLateAboutYou = true
    }

    /// The sheet appeared: it counts as shown from now on.
    func markAboutYouShown() {
        onboardingDefaults.set(true, forKey: Self.lateAboutYouShownKey)
    }

    /// The sheet's Done (`about`) writes the answers — the profile alone, no
    /// daemon, no onboarding state; the sheet stays up on a failure. Later
    /// (nil) only closes it.
    func finishLateAboutYou(_ about: OnboardingAboutYou?) async {
        guard let about else {
            showsLateAboutYou = false
            return
        }
        guard !isSavingLateAboutYou, let pool = databaseManager?.dbPool else { return }
        isSavingLateAboutYou = true
        defer { isSavingLateAboutYou = false }
        do {
            try await pool.write { db in try OnboardingProfileWriter.done(db, about: about) }
            lateAboutYouError = nil
            showsLateAboutYou = false
        } catch {
            lateAboutYouError = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Connect or About you on a relaunch: the load did not survive the quit,
    /// so an already connected Slack account starts it once.
    func resumePeopleRosterIfNeeded() {
        guard peopleRoster.state == .idle,
              let account = slackAccountsViewModel?.accounts.first(where: { $0.status != "removed" }) else { return }
        peopleRoster.start(accountID: account.id)
    }

    /// Re-consents one Slack account from a failed send's card ("sign in
    /// again to grant send"): the same `slack login --account <id>` flow as
    /// Settings → Slack → Reconnect. Returns why it failed (nil on success or
    /// a cancelled sign-in) so the card can say so.
    func reconnectSlack(accountID: Int64) async -> String? {
        guard let vm = slackAccountsViewModel else {
            return "Slack accounts are not loaded yet — open Settings → Slack."
        }
        if vm.accounts.isEmpty { await vm.refreshAsync() }
        guard let account = vm.accounts.first(where: { $0.id == accountID }) else {
            return "Slack account #\(accountID) is no longer connected."
        }
        await vm.relogin(account)
        return vm.error
    }

    func initJiraAccounts(dbPool: DatabasePool) {
        let vm = JiraAccountsViewModel(dbPool: dbPool)
        vm.onAccountsChanged = { [weak self] in await self?.accountsChanged() }
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
    /// and errors land where every other Jira re-login's do; "Allow editing"
    /// does the same with `--with-confluence-write`.
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
            onAllowEditing: { [weak self] id in
                guard let jira = self?.jiraAccountsViewModel else { return "Jira accounts are not loaded yet." }
                await jira.reloginWithConfluenceWrite(accountID: Int(id))
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
    func initWorkbenches(
        dbPool: DatabasePool,
        cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault(),
        notifier: WorkbenchNotifying = NotificationService.shared,
        sessionNotifier: SessionAgentNotifying = NotificationService.shared
    ) {
        let agentStates = SessionAgentStateCenter(
            dbPool: dbPool, terminalCenter: terminalCenter, notifier: sessionNotifier
        )
        let vm = WorkbenchesViewModel(
            dbPool: dbPool, cli: cliRunner.map { WorkbenchCLI(runner: $0) }, terminalCenter: terminalCenter,
            agentStates: agentStates
        )
        vm.codeFiles.codeIndex = codeIndexCenter
        openQuicklyCenter.workbenches = vm
        codeNavigationCenter.workbenches = vm
        vm.codeFiles.navigation = codeNavigationCenter
        codeUsagesCenter.useWorkspace(dbPool.path)
        codeUsagesCenter.workbenches = vm
        codeUsagesCenter.navigation = codeNavigationCenter
        codeNavigationCenter.usages = codeUsagesCenter
        vm.codeFiles.usages = codeUsagesCenter
        codeQuestionCenter.workbenches = vm
        codeQuestionCenter.navigation = codeNavigationCenter
        codeQuestionCenter.codeIndex = codeIndexCenter
        codeQuestionCenter.embeddedChats = embeddedChatCenter
        codeQuestionCenter.dbPool = dbPool
        codeQuestionCenter.dictation = dictationCenter
        codeQuestionCenter.modelSuggestions = { [aiModelCatalog] in aiModelCatalog.suggestions(for: $0.rawValue) }
        codeQuestionCenter.usages = codeUsagesCenter
        openQuicklyCenter.questions = codeQuestionCenter
        vm.codeFiles.questions = codeQuestionCenter
        codeHandoffCenter.workbenches = vm
        codeHandoffCenter.terminalCenter = terminalCenter
        codeHandoffCenter.dbPool = dbPool
        codeQuestionCenter.handoff = codeHandoffCenter
        openQuicklyCenter.onHandToClaude = { [weak self] query, project in
            guard let self else { return }
            codeHandoffCenter.handQuery(query, project: project, origin: codeQuestionCenter.openFileOrigin(project))
        }
        vm.onWorkbenchRemoved = { [weak codeQuestionCenter, weak codeUsagesCenter] in
            codeQuestionCenter?.workbenchRemoved($0)
            codeUsagesCenter?.workbenchRemoved($0)
        }
        vm.closeTerminal = { [weak self] projectID in
            guard let center = self?.terminalCenter else { return }
            let ids = center.sessionIDs(ofWorkbench: projectID)
            await center.closeAll { ids.contains($0) }
        }
        let notices = WorkbenchNotificationCenter(dbPool: dbPool, notifier: notifier)
        vm.onWorkbenchCreated = { [weak notices] project, _ in
            notices?.seedBaseline(project: project)
        }
        vm.onOwnerWrite = { [weak notices] projectID, subject in
            notices?.recordOwnerWrite(projectID: projectID, subject: subject)
        }
        vm.isTabOnScreen = { [weak self] in
            self?.selectedDestination == .workbench
                && NSApp.windows.contains { TrayAppDelegate.isMainWindow($0) && $0.isVisible && $0.occlusionState.contains(.visible) }
        }
        notices.onPolled = { [weak vm] in await vm?.refreshOnPoll() }
        let reports = SessionReportCenter(runner: cliRunner ?? UnresolvedCLIRunner())
        reports.isTabOnScreen = { [weak vm] in vm?.isTabOnScreen() ?? false }
        reports.watchedWorkbenchID = { [weak vm] in vm?.selectedWorkbenchID }
        reports.agentState = { [weak agentStates] id in agentStates?.statuses[id]?.state }
        vm.sessionReports = reports
        workbenchesViewModel?.asks.stop()
        workbenchesViewModel = vm
        workbenchNotificationCenter = notices
        sessionAgentStateCenter?.stop()
        sessionAgentStateCenter = agentStates
        sessionReportCenter?.stop()
        sessionReportCenter = reports
        // The first poll also loads the list (onPolled → reload).
        notices.start()
        vm.startTitleRefresh()
        vm.asks.start()
        agentStates.start()
        reports.start()
        initMobileHub(dbPool: dbPool)
    }

    private static let mobileHubLogger = Logger(subsystem: Constants.bundleID, category: "MobileHub")

    var isMobileSyncEnabled: Bool {
        mobileSyncDefaults.bool(forKey: Constants.mobileSyncEnabledKey)
    }

    /// Tears down the previous hub and, while the toggle is on, builds and
    /// starts a new one over the run's one transport and sidecar. Called at
    /// the end of `initWorkbenches`. With the toggle off nothing is opened.
    func initMobileHub(dbPool: DatabasePool) {
        let previous = mobileHub
        previous?.dispose()
        mobileHub = nil
        mobileHubPool = dbPool
        guard isMobileSyncEnabled else { return }
        let storage: MobileHubStorage
        do {
            storage = try mobileHubStorage ?? makeMobileHubStorage()
            mobileHubStorage = storage
            mobileHub = try buildMobileHub(storage: storage, dbPool: dbPool)
            mobileHubInitError = nil
        } catch {
            mobileHubInitError = error.localizedDescription
            Self.mobileHubLogger.error("mobile hub unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let hub = mobileHub
        Task {
            // The replaced hub's relay pass ends first: two never overlap.
            await previous?.waitUntilStopped()
            await hub?.start()
        }
    }

    /// The Settings → Mobile toggle: on starts the hub (building it on first
    /// use), off stops it. The hub object is kept, so toggling never opens a
    /// second transport.
    func setMobileSyncEnabled(_ enabled: Bool) {
        mobileSyncDefaults.set(enabled, forKey: Constants.mobileSyncEnabledKey)
        guard enabled else {
            mobileHub?.stop()
            return
        }
        if let hub = mobileHub {
            Task { await hub.start() }
        } else if let pool = mobileHubPool {
            initMobileHub(dbPool: pool)
        }
    }

    /// B registers its slice sources and dispatcher handlers here.
    private func buildMobileHub(storage: MobileHubStorage, dbPool: DatabasePool) throws -> MobileHubService {
        let dispatcher = MobileHubCommandDispatcher()
        let publisher = SlicePublisher(dbPool: dbPool, state: storage.sidecar, transport: storage.transport, sources: [])
        let processor = RelayProcessor(
            transport: storage.transport, sidecar: storage.sidecar, dispatcher: dispatcher,
            hubID: try storage.sidecar.ensureHubID()
        )
        return MobileHubService(
            transport: storage.transport, publisher: publisher, processor: processor, sidecar: storage.sidecar
        ) { [weak self] in self?.isMobileSyncEnabled ?? false }
    }

    func initGoogleAccounts(dbPool: DatabasePool) {
        let vm = GoogleAccountsViewModel(dbPool: dbPool)
        vm.onAccountsChanged = { [weak self] in await self?.accountsChanged() }
        vm.refresh()
        googleAccountsViewModel = vm
        // GoogleConnectFlow.shared is a singleton constructed before any
        // dbPool exists (Navigation.swift / SidebarView.swift reference its
        // `calendar` service directly) — wire it here, the same point its
        // sibling VM above gets its pool, so isConnected reads google_accounts
        // instead of staying permanently false.
        GoogleConnectFlow.shared.configure(dbPool: dbPool)
    }

    @ObservationIgnored private var connectedSourcesGeneration = 0
    @ObservationIgnored private var appliedConnectedSourcesGeneration = 0
    /// The refresh `completeOnboarding()` kicked off — held so tests can
    /// await it.
    @ObservationIgnored private(set) var connectedSourcesRefresh: Task<Void, Never>?

    /// A Slack/Google/Jira account-list reload: re-resolves the owner
    /// (OWNER-02) and the connected sources the sidebar gates on.
    private func accountsChanged() async {
        await refreshOwner()
        await refreshConnectedSources()
    }

    /// Re-reads which sources are connected, so a tab whose source was just
    /// connected (or removed) in Settings shows (or hides) at once. A failed
    /// read keeps the last value (logged), like `refreshOwner()`.
    ///
    /// Reads run off the main actor and can finish out of order; each one
    /// takes a generation number and writes only if no later-started read
    /// has written yet, so an older read never overwrites a newer one.
    func refreshConnectedSources() async {
        guard let pool = databaseManager?.dbPool else { return }
        connectedSourcesGeneration += 1
        let wasOnboarding = needsOnboarding
        let generation = connectedSourcesGeneration
        do {
            let sources = try await pool.read { db in try ConnectedSources.fetch(db) }
            guard generation > appliedConnectedSourcesGeneration else { return }
            appliedConnectedSourcesGeneration = generation
            featureVisibility.connectedSources = sources
            let previous = lastReadConnectedSources
            lastReadConnectedSources = sources
            // Onboarding's own connects (before or after the read) pick
            // their features there.
            if let previous, !wasOnboarding, !needsOnboarding {
                let goals = SourceConnectPrompt.goals(newlyConnectedFrom: previous, to: sources)
                if !goals.isEmpty {
                    featureSuggestionCheck = Task { await suggestFeatures(for: goals) }
                }
            }
        } catch {
            print("[AppState] connected sources read failed, keeping the last value: \(error.localizedDescription)")
        }
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

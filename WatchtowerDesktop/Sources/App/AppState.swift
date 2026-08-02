import SwiftUI
import GRDB

@MainActor
@Observable
final class AppState {
    var selectedDestination: SidebarDestination = .inbox
    var databaseManager: DatabaseManager?
    var errorMessage: String?
    var isDBAvailable: Bool { databaseManager != nil }

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

    /// App-wide, single-slot registry for meeting recording + transcription, so
    /// an in-flight recording and its transcription survive navigating away from
    /// the calendar event that started it.
    let meetingRecorderCenter = MeetingRecorderCenter()

    /// App-wide, single-slot registry for meeting-recording audio playback, so
    /// only one recording's audio plays at a time regardless of how many
    /// transcript rows are expanded across the app.
    let audioPlaybackCenter = AudioPlaybackCenter()

    /// App-wide, single-slot-per-transcript registry for "generate meeting
    /// notes" runs, so the "generating…" flag survives navigating away from
    /// and back to a recording's detail (feedback: async ops need
    /// navigation-surviving state).
    let transcriptNotesCenter = TranscriptNotesCenter()

    /// App-wide, single-slot-per-transcript registry for "Suggest speaker
    /// names" runs and their suggestion chips (same surviving-state contract
    /// as TranscriptNotesCenter).
    let speakerGuessCenter = SpeakerGuessCenter()
    /// Same pattern for "generate chapters" runs (Recap tab).
    let transcriptChaptersCenter = TranscriptChaptersCenter()

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

    /// Persistent chat ViewModels — survive tab switches.
    private(set) var chatViewModel: ChatViewModel?
    private(set) var chatHistoryViewModel: ChatHistoryViewModel?

    /// Calendar ViewModel — persists across tab switches.
    private(set) var calendarViewModel: CalendarViewModel?

    /// Day Plan ViewModel — persists across tab switches.
    private(set) var dayPlanViewModel: DayPlanViewModel?

    /// Catch-Up ViewModel — persists across tab switches.
    private(set) var catchUpViewModel: CatchUpViewModel?

    /// Memory browser ViewModel — persists across tab switches.
    private(set) var memoryViewModel: MemoryViewModel?

    /// Dashboard ViewModel — persists across tab switches so an in-flight
    /// "Generate" run (and its `isGenerating` flag) survives navigating away
    /// from and back to the Dashboard tab, instead of being orphaned when a
    /// view-local instance was torn down.
    private(set) var dashboardViewModel: DashboardViewModel?

    /// Feed ViewModel — persists across tab switches so filters and
    /// selection survive navigating away from and back to the feed.
    private(set) var feedViewModel: FeedViewModel?

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

    /// Whether legacy people analytics is enabled (analysis.legacy_mode in config).
    var analysisLegacyMode: Bool = false

    /// Whether the user has completed onboarding (profile exists and onboarding_done == true).
    var profileComplete: Bool = true

    /// Set to navigate to a specific digest from anywhere in the app.
    var pendingDigestID: Int?

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

    /// Manages background pipeline tasks (digests, people) started after onboarding sync.
    let backgroundTaskManager = BackgroundTaskManager()

    /// Ensures chat ViewModels exist (lazy init, called from ChatView).
    func ensureChatViewModels() {
        guard let db = databaseManager, chatViewModel == nil else { return }
        let configProvider = ConfigService().aiProvider
        let provider: AIProvider = configProvider == "codex" ? .codex : .claude
        let service = WatchtowerAIService()
        let cvm = ChatViewModel(aiService: service, dbManager: db, provider: provider)
        let hvm = ChatHistoryViewModel(dbManager: db)
        hvm.load { [weak self, weak cvm, weak hvm] in
            self?.maybeCreateWelcomeChat(chatVM: cvm, historyVM: hvm)
        }

        cvm.onConversationUpdated = { [weak hvm] convID, title, sessionID in
            guard let hvm else { return }
            if let title { hvm.updateTitle(convID, title: title) }
            if let sessionID { hvm.updateSessionID(convID, sessionID: sessionID) }
            if title == nil && sessionID == nil { hvm.touch(convID) }
        }

        chatViewModel = cvm
        chatHistoryViewModel = hvm
    }

    /// Creates a welcome chat with AI greeting when no conversations exist and user profile is available.
    private func maybeCreateWelcomeChat(chatVM: ChatViewModel?, historyVM: ChatHistoryViewModel?) {
        guard let chatVM, let historyVM, let db = databaseManager else { return }
        guard historyVM.conversations.isEmpty else { return }

        // Load user profile
        let profile: UserProfile? = try? db.dbPool.read { db in
            try ProfileQueries.fetchCurrentProfile(db)
        }
        guard let profile, profile.onboardingDone else { return }

        let language = ConfigService().digestLanguage ?? "English"

        // Create conversation and send welcome message
        guard let conv = historyVM.createConversation() else { return }
        chatVM.newChat()
        chatVM.bind(to: conv)
        historyVM.updateTitle(conv.id, title: "Welcome")
        chatVM.sendWelcomeMessage(profile: profile, language: language)
    }

    func navigateToDigest(_ digestID: Int) {
        pendingDigestID = digestID
        selectedDestination = .digests
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

    private var isInitializing = false

    func initialize() {
        guard !isInitializing else { return }
        isInitializing = true
        isLoading = true
        // Surface a recording captured before a crash/relaunch so the global
        // indicator can offer to (re-)transcribe it. No DB needed.
        meetingRecorderCenter.restorePendingOnLaunch()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.backgroundTaskManager.terminateProcessesSync()
            DaemonManager.stopDaemonSync()
        }
        Task {
            let splashStart = ContinuousClock.now
            do {
                let manager = try await Task.detached {
                    // Run Go CLI to apply any pending DB migrations before opening
                    DatabaseManager.runCLIMigrations()
                    let dbPath = try DatabaseManager.resolveDBPath()
                    return try DatabaseManager(path: dbPath)
                }.value
                databaseManager = manager
                errorMessage = nil
                // Voice matching needs the DB at diarization time; the Center
                // is created before the DB opens, so hand it a loader now. A
                // read failure degrades to "no voice prints" (plain Speaker N
                // labels), never a thrown error.
                meetingRecorderCenter.voicePrintsLoader = { [dbPool = manager.dbPool] in
                    do {
                        return try await dbPool.read { try VoicePrintQueries.fetchAll($0) }
                    } catch {
                        // Documented degradation, but never a silent one
                        // (the renderRoles diagnostics convention).
                        print("[AppState] voice-print load failed, matching disabled for this run: \(error.localizedDescription)")
                        return []
                    }
                }
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
                // Hold splash for at least 2 seconds
                let elapsed = ContinuousClock.now - splashStart
                if elapsed < .seconds(2) {
                    try? await Task.sleep(for: .seconds(2) - elapsed)
                }
                isLoading = false
                loadCustomEmoji(from: manager)
                initCalendar(dbPool: manager.dbPool)
                initDayPlan(dbPool: manager.dbPool)
                initCatchUp(dbPool: manager.dbPool)
                initMemory(dbPool: manager.dbPool)
                initDashboard(dbManager: manager)
                initSecretaryProfile(dbManager: manager)
                initEmailAccounts(dbPool: manager.dbPool)
                initCalendarAccounts(dbPool: manager.dbPool)
                initGoogleAccounts(dbPool: manager.dbPool)
                initSlackAccounts(dbPool: manager.dbPool)
                initJiraAccounts(dbPool: manager.dbPool)
                startDigestWatcher(dbPool: manager.dbPool)
                startMeetingReminders(dbPool: manager.dbPool)
                // Resume pipelines if app was closed mid-generation
                if !needsOnboarding && !UserDefaults.standard.bool(forKey: Constants.pipelinesCompletedKey) {
                    backgroundTaskManager.startPipelines(legacyPeople: analysisLegacyMode)
                } else if !needsOnboarding {
                    // Ensure a fresh daemon is running (rebuild-safe): stop any existing
                    // one (possibly from an older binary), then start the current binary.
                    ensureDaemonRunning()
                }
            } catch {
                errorMessage = error.localizedDescription
                databaseManager = nil
                // No DB available — if state machine not complete, onboarding needed
                needsOnboarding = onboarding.currentStep != .complete
                if needsOnboarding {
                    onboarding.skipCompleted()
                }
                isLoading = false
            }
        }
        // Check for updates in background (once per 24h)
        Task {
            await updateService.checkIfNeeded()
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
        let daemon = DaemonManager()
        daemon.resolvePathIfNeeded()
        if DaemonManager.checkDaemonRunning() {
            await daemon.stopDaemon()
            try? await Task.sleep(for: .milliseconds(500))
        }

        // 3. Wipe LLM-generated tables
        try db.wipeLLMData()

        // 4. Reset pipelines flag and re-run
        UserDefaults.standard.removeObject(forKey: Constants.pipelinesCompletedKey)
        backgroundTaskManager.tasks.removeAll()
        backgroundTaskManager.startPipelines(legacyPeople: analysisLegacyMode)
    }

    /// Ensure the daemon is running against the current CLI binary.
    /// If an old instance is already running (e.g. from a stale dev rebuild), stop it first,
    /// then start a fresh one. Paired with `DaemonManager.stopDaemonSync()` on app terminate
    /// so UI quit/launch cycles the daemon lifecycle.
    private func ensureDaemonRunning() {
        Task {
            let daemon = DaemonManager()
            daemon.resolvePathIfNeeded()
            if DaemonManager.checkDaemonRunning() {
                await daemon.stopDaemon()
                try? await Task.sleep(for: .milliseconds(500))
            }
            await daemon.startDaemon()
        }
    }

    private func initCalendar(dbPool: DatabasePool) {
        calendarViewModel = CalendarViewModel(dbPool: dbPool)
    }

    private func initDayPlan(dbPool: DatabasePool) {
        guard let runner = ProcessCLIRunner.makeDefault() else { return }
        dayPlanViewModel = DayPlanViewModel(databasePool: dbPool, cliRunner: runner)
    }

    private func initCatchUp(dbPool: DatabasePool) {
        catchUpViewModel = CatchUpViewModel(dbPool: dbPool)
    }

    private func initMemory(dbPool: DatabasePool) {
        memoryViewModel = MemoryViewModel(dbPool: dbPool)
    }

    /// Not marked `private` (unlike its siblings above) so XCTest can call it directly via
    /// `@testable import` to prove `dashboardViewModel` identity persists across accesses,
    /// without going through the real-filesystem/CLI-subprocess machinery in `initialize()`.
    func initDashboard(dbManager: DatabaseManager) {
        let vm = DashboardViewModel(dbManager: dbManager)
        vm.startObserving()
        dashboardViewModel = vm
        let feedVM = FeedViewModel(dbManager: dbManager)
        feedVM.startObserving()
        feedViewModel = feedVM
    }

    /// Not marked `private` (mirrors `initDashboard` above) so XCTest can call it
    /// directly via `@testable import` to prove `secretaryProfileViewModel`
    /// identity persists across accesses.
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
        vm.refresh()
        slackAccountsViewModel = vm
    }

    func initJiraAccounts(dbPool: DatabasePool) {
        let vm = JiraAccountsViewModel(dbPool: dbPool)
        vm.refresh()
        jiraAccountsViewModel = vm
        // Browse-URL resolution reads jira_accounts.site_url — wire the pool
        // here, the same point the sibling VM gets its pool, so per-issue
        // links resolve from the DB instead of the frozen config keys.
        JiraConfigHelper.configure(dbPool: dbPool)
    }

    func initGoogleAccounts(dbPool: DatabasePool) {
        let vm = GoogleAccountsViewModel(dbPool: dbPool)
        vm.refresh()
        googleAccountsViewModel = vm
        // GoogleConnectFlow.shared is a singleton constructed before any
        // dbPool exists (Navigation.swift / SidebarView.swift reference its
        // `calendar` service directly) — wire it here, the same point its
        // sibling VM above gets its pool, so isConnected reads google_accounts
        // instead of staying permanently false.
        GoogleConnectFlow.shared.configure(dbPool: dbPool)
    }

    private func startMeetingReminders(dbPool: DatabasePool) {
        let center = MeetingReminderCenter(dbPool: dbPool, recorderCenter: meetingRecorderCenter)
        meetingReminderCenter = center
        center.start()
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

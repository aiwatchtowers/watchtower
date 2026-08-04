import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettings()
                .environment(appState)
                .tabItem { Label("General", systemImage: "gear") }

            ProfileSettings()
                .environment(appState)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }

            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }

            DaemonSettings()
                .tabItem { Label("Daemon", systemImage: "arrow.triangle.2.circlepath") }

            LogsSettings()
                .tabItem { Label("Logs", systemImage: "doc.text") }

            DataSettings()
                .environment(appState)
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 700, height: 550)
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var appState
    @State private var config = ConfigService()
    @State private var saveError: String?
    @State private var showSaved = false
    @State private var connectionTestRunning = false
    @State private var connectionTestResult: String?
    @State private var connectionTestSuccess = false
    @State private var daemonManager = DaemonManager()
    @State private var slackReconnecting = false
    @State private var slackReconnectResult: String?
    @State private var slackReconnectSuccess = false
    @State private var slackAuthProcess: Process?
    @State private var slackAuth = SlackAuthService()
    @State private var slackDisconnecting = false
    @State private var showSlackDisconnectConfirm = false
    @State private var jiraAuth = JiraAuthService()
    @State private var showAddEmailAccountSheet = false
    @State private var accountPendingRemoval: EmailAccount?
    @State private var showAddCalendarAccountSheet = false
    @State private var calendarAccountPendingRemoval: CalendarAccount?
    @State private var showAddGoogleAccountSheet = false
    @State private var googleAccountPendingRemoval: GoogleAccount?
    @State private var showAddSlackAccountSheet = false
    @State private var slackAccountPendingRemoval: SlackAccount?

    @AppStorage("transcription.provider") private var transcriptionProvider = "whisperkit"
    @AppStorage("transcription.model") private var transcriptionModel = "large-v3-v20240930"
    @AppStorage("transcription.langset") private var transcriptionLangset = "ru,uk,en"
    @AppStorage("transcription.windowSec") private var transcriptionWindowSec = 20.0
    @AppStorage("transcription.langThreshold") private var transcriptionLangThreshold = 0.6
    @AppStorage("transcription.margin") private var transcriptionMargin = 0.2
    @AppStorage("transcription.forceLang") private var transcriptionForceLang = ""
    @AppStorage("transcription.diarization") private var transcriptionDiarization = true
    @AppStorage("transcription.diarizationThreshold") private var transcriptionDiarizationThreshold = 0.6
    @AppStorage(JoinMeetingAction.autoRecordKey) private var autoRecordOnJoin = true
    @State private var showAdvancedTranscription = false

    var body: some View {
        Form {
            workspaceSection
            slackAccountsSection
            syncSection
            digestSection
            briefingSection
            dayPlanSection
            aiSection
            calendarSettingsSection
            googleAccountsSection
            calendarAccountsSection
            calendarSelectionSection
            gmailSettingsSection
            emailAccountsSection
            transcriptionSection
            jiraSettingsSection

            if let error = config.parseError {
                Section("Parse Error") {
                    Text(error).foregroundStyle(.red)
                }
            }

            if let error = saveError {
                Section("Save Error") {
                    Text(error).foregroundStyle(.red)
                }
            }

            usageLinkSection
            updateSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .onAppear {
            // Re-stat tokens/config: a connect or disconnect may have happened
            // outside this window (Calendar tab, Inbox banner, CLI).
            jiraAuth.checkStatus()
            slackAuth.checkStatus()
            appState.slackAccountsViewModel?.refresh()
            appState.emailAccountsViewModel?.refresh()
            appState.calendarAccountsViewModel?.refresh()
            appState.googleAccountsViewModel?.refresh()
        }
    }

    private var workspaceSection: some View {
        Section("Workspace") {
            LabeledContent("Active Workspace") {
                Text(config.activeWorkspace ?? "None")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Image(systemName: slackAuth.isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                    .foregroundStyle(slackAuth.isConnected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Text(slackAuth.isConnected ? "Slack connected" : "Slack not connected")
                Spacer()

                Button {
                    reconnectSlack()
                } label: {
                    HStack(spacing: 4) {
                        if slackReconnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(slackReconnecting
                            ? "Connecting..."
                            : (slackAuth.isConnected ? "Reconnect Slack" : "Connect Slack"))
                    }
                }
                .disabled(slackReconnecting || slackDisconnecting)

                if slackReconnecting {
                    Button("Cancel") {
                        cancelSlackReconnect()
                    }
                }

                if slackAuth.isConnected {
                    Button(role: .destructive) {
                        showSlackDisconnectConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            if slackDisconnecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(slackDisconnecting ? "Disconnecting..." : "Disconnect")
                        }
                    }
                    .disabled(slackReconnecting || slackDisconnecting)
                }
            }

            if let result = slackReconnectResult {
                HStack {
                    Image(systemName: slackReconnectSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(slackReconnectSuccess ? .green : .red)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(slackReconnectSuccess ? .green : .red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            if let err = slackAuth.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Disconnect Slack?",
            isPresented: $showSlackDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect Slack", role: .destructive) {
                disconnectSlack()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the Slack connection and stops syncing. Already-synced Slack messages and the AI "
                    + "products built on them (digests, tracks, people cards, inbox items, situations) are kept "
                    + "and stay queryable. Gmail, Calendar, and Jira data are unaffected."
            )
        }
    }

    private func disconnectSlack() {
        slackDisconnecting = true
        Task {
            // Stop the daemon first so it isn't mid-sync when the token is
            // removed, then restart it — without a token it skips the Slack
            // phase. Synced data is kept (non-destructive, matches `slack
            // remove` / `auth logout` semantics).
            await daemonManager.stopDaemon()
            await slackAuth.disconnect()
            if slackAuth.error == nil {
                config.reload()
                slackReconnectResult = nil
            }
            await daemonManager.startDaemon()
            slackDisconnecting = false
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            TextField(
                "Poll Interval",
                text: Binding(
                    get: { config.syncInterval ?? "" },
                    set: { config.syncInterval = $0 }
                ),
                prompt: Text("15m")
            )
            .help("e.g. 15m, 1h, 30s")

            TextField(
                "Workers",
                value: Binding(
                    get: { config.syncWorkers },
                    set: { config.syncWorkers = $0 }
                ),
                format: .number,
                prompt: Text("1")
            )

            TextField(
                "Initial History Days",
                value: Binding(
                    get: { config.initialHistoryDays },
                    set: { config.initialHistoryDays = $0 }
                ),
                format: .number,
                prompt: Text("30")
            )

            Toggle("Sync Threads", isOn: $config.syncThreads)
        }
    }

    private var digestSection: some View {
        Section("Digest") {
            Toggle("Enabled", isOn: $config.digestEnabled)

            TextField(
                "Model",
                text: Binding(
                    get: { config.digestModel ?? "" },
                    set: { config.digestModel = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("claude-haiku-4-5-20251001")
            )

            TextField(
                "Min Messages",
                value: Binding(
                    get: { config.digestMinMessages },
                    set: { config.digestMinMessages = $0 }
                ),
                format: .number,
                prompt: Text("5")
            )

            TextField(
                "Language",
                text: Binding(
                    get: { config.digestLanguage ?? "" },
                    set: { config.digestLanguage = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("English")
            )
        }
    }

    private var briefingSection: some View {
        Section("Briefing") {
            Picker(
                "Briefing Hour",
                selection: $config.briefingHour
            ) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
            .help("Hour of day when daily briefing should be generated (0-23)")
        }
    }

    private var dayPlanSection: some View {
        Section("Day Plan") {
            Toggle("Enable day plan", isOn: $config.dayPlanEnabled)

            Picker("Generate at hour", selection: $config.dayPlanHour) {
                ForEach(5..<13, id: \.self) { h in
                    Text(String(format: "%02d:00", h)).tag(h)
                }
            }
            .help("Hour of day when the day plan should be generated (5-12)")

            HStack {
                Text("Working hours:")
                TextField(
                    "Start",
                    text: $config.workingHoursStart,
                    prompt: Text("09:00")
                )
                .frame(width: 70)
                Text("–")
                TextField(
                    "End",
                    text: $config.workingHoursEnd,
                    prompt: Text("19:00")
                )
                .frame(width: 70)
            }
            .help("Working window used when scheduling time blocks (HH:MM)")

            Stepper(
                "Max timeblocks: \(config.maxTimeblocks)",
                value: $config.maxTimeblocks,
                in: 1...5
            )
            .help("Maximum number of focused time blocks per day")

            HStack {
                Stepper(
                    "Backlog min: \(config.minBacklog)",
                    value: $config.minBacklog,
                    in: 1...10
                )
                Stepper(
                    "Backlog max: \(config.maxBacklog)",
                    value: $config.maxBacklog,
                    in: 1...15
                )
            }
            .help("Minimum and maximum backlog items shown in the day plan")
        }
    }

    private var aiSection: some View {
        Section(header: Text("AI")) {
            Picker(
                "AI Provider",
                selection: Binding(
                    get: { config.aiProvider ?? "claude" },
                    set: { newProvider in
                        let oldProvider = config.aiProvider ?? "claude"
                        config.aiProvider = newProvider
                        // Reset model when switching providers so it doesn't carry over
                        if newProvider != oldProvider {
                            config.aiModel = nil
                            connectionTestResult = nil
                        }
                    }
                )
            ) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
            }

            TextField(
                "Model",
                text: Binding(
                    get: { config.aiModel ?? "" },
                    set: { config.aiModel = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text(config.aiProvider == "codex" ? "gpt-5.4" : "claude-sonnet-4-6")
            )

            TextField(
                "Workers",
                value: Binding(
                    get: { config.aiWorkers },
                    set: { config.aiWorkers = $0 }
                ),
                format: .number,
                prompt: Text("5")
            )
            .help("Max parallel LLM calls across all pipelines")

            HStack {
                TextField(
                    "Claude CLI Path",
                    text: Binding(
                        get: { config.claudePath ?? "" },
                        set: { config.claudePath = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text("auto-detect")
                )

                if let path = Constants.findInPath("claude") {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Found: \(path)")
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .help("Claude CLI not found")
                }
            }
            .help("Override auto-detection. Run 'which claude' in terminal to find the path.")

            if config.aiProvider == "codex" {
                HStack {
                    TextField(
                        "Codex CLI Path",
                        text: Binding(
                            get: { config.codexPath ?? "" },
                            set: { config.codexPath = $0.isEmpty ? nil : $0 }
                        ),
                        prompt: Text("auto-detect")
                    )

                    if let path = Constants.findInPath("codex") {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Found: \(path)")
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .help("Codex CLI not found")
                    }
                }
                .help("Override auto-detection. Run 'which codex' in terminal to find the path.")
            }

            HStack {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 4) {
                        if connectionTestRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(connectionTestRunning ? "Testing..." : "Test Connection")
                    }
                }
                .disabled(connectionTestRunning)

                if let result = connectionTestResult {
                    Image(systemName: connectionTestSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(connectionTestSuccess ? .green : .red)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(connectionTestSuccess ? .green : .red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Global calendar-sync toggles only — connect/disconnect for individual
    /// Google accounts now lives in `googleAccountsSection` below, since a
    /// workspace can have more than one Google account granting Calendar
    /// access.
    private var calendarSettingsSection: some View {
        Section("Google Calendar") {
            Toggle("Enable calendar sync", isOn: $config.calendarEnabled)
                .onChange(of: config.calendarEnabled) { _, _ in saveConfig() }

            Picker("Sync days ahead", selection: $config.calendarSyncDaysAhead) {
                Text("2 days").tag(2)
                Text("3 days").tag(3)
                Text("5 days").tag(5)
                Text("7 days").tag(7)
                Text("14 days").tag(14)
            }
        }
    }

    /// Global Gmail-sync toggle only — connect/disconnect for individual
    /// Google accounts now lives in `googleAccountsSection` below, since a
    /// workspace can have more than one Google account granting Gmail access.
    private var gmailSettingsSection: some View {
        Section("Gmail") {
            Toggle("Enable Gmail sync", isOn: $config.gmailEnabled)
                .onChange(of: config.gmailEnabled) { _, _ in saveConfig() }
        }
    }

    /// Slack Workspaces section — the multi-account Slack connections
    /// (`slack_accounts` table, migration 00048), each independently granting
    /// access via its own OAuth consent and carrying its own namespaced
    /// identity. Modeled on `googleAccountsSection` below. Placed near the top
    /// of the sources group since Slack is Watchtower's primary data source.
    ///
    /// The removal confirmation copy explicitly states data is KEPT — unlike
    /// Google's removal, `slack remove` is non-destructive: it drops the token
    /// and marks the row removed/disabled but leaves already-synced messages,
    /// digests, and situations in place. The legacy single-account Slack
    /// "Disconnect" in `workspaceSection` now shares the same non-destructive
    /// semantics (`auth logout` → `removeSlackAccount`).
    private var slackAccountsSection: some View {
        Section("Slack Workspaces") {
            if let vm = appState.slackAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No Slack workspaces connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.displayName)
                                if !account.teamDomain.isEmpty {
                                    Text("\(account.teamDomain).slack.com")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Circle()
                                .fill(slackAccountStatusColor(account))
                                .frame(width: 8, height: 8)
                                .help(account.isOK ? "Connected" : (account.error.isEmpty ? account.status : account.error))
                            Toggle("Enabled", isOn: Binding(
                                get: { account.enabled },
                                set: { newValue in
                                    Task { await vm.setEnabled(account, enabled: newValue) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(vm.isConnecting)
                            if !account.isOK {
                                Button("Re-login") {
                                    Task { await vm.relogin(account) }
                                }
                                .disabled(vm.isConnecting)
                            }
                            Button("Remove") {
                                slackAccountPendingRemoval = account
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(vm.isConnecting)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Slack Workspace") {
                    showAddSlackAccountSheet = true
                }
                .disabled(vm.isConnecting)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddSlackAccountSheet) {
            AddSlackAccountView()
                .environment(appState)
        }
        .confirmationDialog(
            "Remove \(slackAccountPendingRemoval?.displayName ?? "this workspace")?",
            isPresented: Binding(
                get: { slackAccountPendingRemoval != nil },
                set: { if !$0 { slackAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Workspace", role: .destructive) {
                if let account = slackAccountPendingRemoval {
                    Task { await appState.slackAccountsViewModel?.remove(account) }
                }
                slackAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Disconnects the workspace. Already-synced messages, digests, and "
                    + "situations stay in Watchtower."
            )
        }
    }

    private func slackAccountStatusColor(_ account: SlackAccount) -> Color {
        if account.isOK { return .green }
        if account.isRevoked { return .red }
        return .orange
    }

    /// Google Accounts section — the multi-account Calendar/Gmail
    /// connections (`google_accounts` table), each independently granting
    /// Calendar and/or Gmail access via its own OAuth consent. Modeled on
    /// `emailAccountsSection`/`calendarAccountsSection` below, placed before
    /// `calendarAccountsSection` since Google usually comes first for a new
    /// user.
    private var googleAccountsSection: some View {
        Section("Google Accounts") {
            if let vm = appState.googleAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No Google accounts connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.displayName)
                                HStack(spacing: 8) {
                                    if account.calendarEnabled {
                                        Label("Calendar", systemImage: "calendar")
                                    }
                                    if account.gmailEnabled {
                                        Label("Gmail", systemImage: "envelope")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(googleAccountStatusColor(account))
                                .frame(width: 8, height: 8)
                                .help(account.isOK ? "Connected" : account.error)
                            if !account.isOK {
                                Button("Re-login") {
                                    vm.relogin(account)
                                }
                                .disabled(vm.isConnecting)
                            }
                            Button("Remove") {
                                googleAccountPendingRemoval = account
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(vm.isConnecting)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Google Account") {
                    showAddGoogleAccountSheet = true
                }
                .disabled(vm.isConnecting)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddGoogleAccountSheet) {
            AddGoogleAccountView()
                .environment(appState)
        }
        .confirmationDialog(
            "Remove \(googleAccountPendingRemoval?.displayName ?? "this account")?",
            isPresented: Binding(
                get: { googleAccountPendingRemoval != nil },
                set: { if !$0 { googleAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                if let account = googleAccountPendingRemoval {
                    Task { await appState.googleAccountsViewModel?.remove(account) }
                }
                googleAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the connection and stops syncing this account's Calendar and Gmail data. "
                    + "Already-synced events/messages and AI products built on them are kept."
            )
        }
    }

    private func googleAccountStatusColor(_ account: GoogleAccount) -> Color {
        if account.isOK { return .green }
        if account.isRevoked { return .red }
        return .orange
    }

    /// Email Accounts section — the multi-account IMAP/Outlook connections,
    /// distinct from Gmail's single-account section above. Each row is a DB row
    /// (`email_accounts`), not a token file, so status can be ok/error/revoked
    /// per account rather than a single connected/disconnected flag.
    private var emailAccountsSection: some View {
        Section("Email Accounts") {
            if let vm = appState.emailAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No IMAP or Outlook accounts connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            Image(systemName: account.isOutlook ? "envelope.badge.fill" : "server.rack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                Text(account.isOutlook ? "Outlook" : "IMAP \u{00B7} \(account.host)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(emailAccountStatusColor(account))
                                .frame(width: 8, height: 8)
                            Button("Remove") {
                                accountPendingRemoval = account
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Account") {
                    showAddEmailAccountSheet = true
                }
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddEmailAccountSheet) {
            AddEmailAccountView()
                .environment(appState)
        }
        .confirmationDialog(
            "Remove \(accountPendingRemoval?.displayName ?? "this account")?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                if let account = accountPendingRemoval {
                    Task { await appState.emailAccountsViewModel?.remove(account) }
                }
                accountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the connection and stops syncing this mailbox. "
                    + "Already-synced messages and AI products built on them are kept."
            )
        }
    }

    private func emailAccountStatusColor(_ account: EmailAccount) -> Color {
        if account.isOK { return .green }
        if account.isRevoked { return .orange }
        return .red
    }

    /// Calendar Accounts section — the multi-account CalDAV/ICS connections,
    /// distinct from Google Calendar's single-account section above. Each row
    /// is a DB row (`calendar_accounts`), so status can be ok/error per
    /// account rather than a single connected/disconnected flag.
    private var calendarAccountsSection: some View {
        Section("Calendar Accounts") {
            if let vm = appState.calendarAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No CalDAV or ICS calendars connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            Image(systemName: account.isICS ? "link" : "server.rack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                Text(account.isICS ? "ICS feed" : "CalDAV \u{00B7} \(account.url)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(account.isOK ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Button("Remove") {
                                calendarAccountPendingRemoval = account
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Calendar") {
                    showAddCalendarAccountSheet = true
                }
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddCalendarAccountSheet) {
            AddCalendarAccountView()
                .environment(appState)
        }
        .confirmationDialog(
            "Remove \(calendarAccountPendingRemoval?.displayName ?? "this calendar")?",
            isPresented: Binding(
                get: { calendarAccountPendingRemoval != nil },
                set: { if !$0 { calendarAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Calendar", role: .destructive) {
                if let account = calendarAccountPendingRemoval {
                    Task { await appState.calendarAccountsViewModel?.remove(account) }
                }
                calendarAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the connection and stops syncing this calendar. "
                    + "Already-synced events and AI products built on them are kept."
            )
        }
    }

    /// Per-calendar sync selection — the Desktop twin of `watchtower calendar
    /// select <id>`. Grouped under one Section per connected Google account
    /// (using `GoogleAccountsViewModel.accounts` for the header label) plus a
    /// trailing group for CalDAV/ICS calendars (`account_id IS NULL`), so a
    /// multi-account workspace can tell which calendar belongs to which
    /// connection. `@ViewBuilder` because the group count varies with how
    /// many accounts have synced calendars — unlike this file's other
    /// section properties, which always render exactly one `Section`.
    @ViewBuilder
    private var calendarSelectionSection: some View {
        if let calVM = appState.calendarViewModel, !calVM.calendars.isEmpty {
            ForEach(appState.googleAccountsViewModel?.accounts ?? []) { account in
                let calendars = calVM.calendars.filter { $0.accountID == account.id }
                if !calendars.isEmpty {
                    Section("Calendars \u{00B7} \(account.displayName)") {
                        calendarSelectionRows(calendars, calVM: calVM)
                    }
                }
            }
            let otherCalendars = calVM.calendars.filter { $0.accountID == nil }
            if !otherCalendars.isEmpty {
                Section("Calendars \u{00B7} CalDAV/ICS") {
                    calendarSelectionRows(otherCalendars, calVM: calVM)
                }
            }
        } else {
            Section("Synced Calendars") {
                Text("No calendars synced yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func calendarSelectionRows(_ calendars: [CalendarCalendarItem], calVM: CalendarViewModel) -> some View {
        ForEach(calendars) { cal in
            Toggle(isOn: Binding(
                get: { cal.isSelected },
                set: { calVM.setCalendarSelected(cal.id, selected: $0) }
            )) {
                HStack(spacing: 4) {
                    Text(cal.name)
                    if cal.isPrimary {
                        Text("Primary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Engine", selection: $transcriptionProvider) {
                ForEach(TranscriptionProviderRegistry.availableProviders(), id: \.displayName) { p in
                    Text(p.displayName).tag(type(of: p).id)
                }
            }
            .help("On-device transcription engine")
            .onChange(of: transcriptionProvider) { _, id in
                // Reset the model to the new provider's default, then prefetch.
                let provider = TranscriptionProviderRegistry.resolve(providerID: id)
                transcriptionModel = provider.models.first?.id ?? transcriptionModel
                appState.transcriptionModelProvisioner.ensureDownloaded(providerID: id, model: transcriptionModel)
            }

            Picker("Model", selection: $transcriptionModel) {
                ForEach(TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider).models) { m in
                    Text(m.label).tag(m.id)
                }
            }
            .help("Model used for on-device transcription")
            .onChange(of: transcriptionModel) { _, newValue in
                appState.transcriptionModelProvisioner.ensureDownloaded(providerID: transcriptionProvider, model: newValue)
            }

            engineCapabilityCaption

            if let supported = TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider)
                .supportedLanguages(model: transcriptionModel) {
                let missing = transcriptionLangset.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !supported.contains($0) }
                if !missing.isEmpty {
                    Label("This engine does not support: \(missing.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            TextField(
                "Languages",
                text: $transcriptionLangset,
                prompt: Text("ru,uk,en")
            )
            .help("Comma-separated language codes to detect per window")

            Toggle("Speaker roles", isOn: $transcriptionDiarization)
                .help("Label transcript lines with who was speaking ([Я] / [Speaker N]) using on-device diarization")

            Toggle("Auto-record on join", isOn: $autoRecordOnJoin)
                .help("Pressing Join on a calendar event also starts an event-linked recording (unless one is already running)")

            Stepper(
                "Delete audio after \(config.transcriptAudioRetentionDays) days",
                value: $config.transcriptAudioRetentionDays,
                in: 0...365
            )
            .help("Recording audio is deleted after this many days; transcript text is kept forever. 0 disables cleanup.")

            DisclosureGroup("Advanced", isExpanded: $showAdvancedTranscription) {
                LabeledContent("Window (seconds)") {
                    TextField("", value: $transcriptionWindowSec, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Language threshold") {
                    TextField("", value: $transcriptionLangThreshold, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Runner-up margin") {
                    TextField("", value: $transcriptionMargin, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Diarization threshold") {
                    TextField("", value: $transcriptionDiarizationThreshold, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                .help("Speaker clustering strictness (0.3–0.9). Lower = more distinct speakers. "
                    + "Try lowering when different people get merged into one Speaker N.")
                TextField(
                    "Force language",
                    text: $transcriptionForceLang,
                    prompt: Text("auto-detect")
                )
                .help("Set a language code (e.g. ru) to skip detection entirely")
            }
        }
    }

    /// One-line summary of what the selected engine/model can do, so the
    /// live-vs-batch difference is visible right where the engine is chosen
    /// (batch engines show no live panel while recording — that's expected,
    /// not a bug).
    private var engineCapabilityCaption: some View {
        let provider = TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider)
        var parts = [
            provider.supportsLive
                ? "Live transcript while recording"
                : "No live transcript — text appears after Stop"
        ]
        if let langs = provider.supportedLanguages(model: transcriptionModel) {
            parts.append("\(langs.count) languages")
        } else {
            parts.append("any language")
        }
        return Label(parts.joined(separator: " · "),
                     systemImage: provider.supportsLive ? "waveform.badge.mic" : "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var jiraSettingsSection: some View {
        Section("Jira") {
            if jiraAuth.isConnected {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected")
                        if let site = jiraAuth.siteURL {
                            Text(site)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let user = jiraAuth.userDisplayName {
                            Text(user)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Disconnect") {
                        jiraAuth.disconnect()
                    }
                }
            } else {
                HStack {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                    Text("Not connected")
                    Spacer()

                    if jiraAuth.isAuthenticating {
                        ProgressView().controlSize(.small)
                        Button("Cancel") {
                            jiraAuth.cancelConnect()
                        }
                    } else {
                        Button("Connect") { jiraAuth.connect() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            if let err = jiraAuth.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        if jiraAuth.isConnected {
            Section {
                Button {
                    appState.selectedDestination = .boards
                } label: {
                    HStack {
                        Label(
                            "Manage Boards",
                            systemImage: "rectangle.on.rectangle.angled"
                        )
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Open in Editor") {
                    config.openInEditor()
                }

                Button("Reveal in Finder") {
                    config.revealInFinder()
                }

                Spacer()

                if showSaved {
                    Text("Saved")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button("Reload") {
                    config.reload()
                    saveError = nil
                }

                Button("Save") {
                    do {
                        try config.save()
                        saveError = nil
                        withAnimation { showSaved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showSaved = false }
                        }
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func saveConfig() {
        do {
            try config.save()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Usage Link

    private var usageLinkSection: some View {
        Section {
            Button {
                NSApp.keyWindow?.close()
                appState.selectedDestination = .usage
            } label: {
                Label("View Usage & Pipeline Progress", systemImage: "chart.bar")
            }
        }
    }

    // MARK: - Update Section

    @ViewBuilder
    private var updateSection: some View {
        Section("Update") {
            let service = appState.updateService

            LabeledContent("Current Version") {
                Text(Constants.appVersion)
                    .foregroundStyle(.secondary)
            }

            switch service.state {
            case .idle:
                HStack {
                    Text("No updates available")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates") {
                        Task { await service.checkForUpdates() }
                    }
                }

            case .checking:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates...")
                        .foregroundStyle(.secondary)
                }

            case let .available(version, notes, _):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Version \(version) available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Spacer()
                        Button("Download") {
                            Task { await service.downloadUpdate() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }

            case .downloading(let progress):
                HStack {
                    ProgressView(value: progress)
                        .frame(maxWidth: 200)
                    Text("Downloading...")
                        .foregroundStyle(.secondary)
                }

            case .readyToInstall:
                HStack {
                    Label("Ready to install", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Install & Restart") {
                        Task { await service.install(daemonManager: daemonManager) }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .installing:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing update...")
                        .foregroundStyle(.secondary)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Update error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await service.checkForUpdates() }
                    }
                }
            }
        }
    }

    private func reconnectSlack() {
        guard let cliPath = Constants.findCLIPath() else {
            slackReconnectResult = "watchtower CLI not found"
            slackReconnectSuccess = false
            return
        }

        slackReconnecting = true
        slackReconnectResult = nil
        slackReconnectSuccess = false

        Task.detached {
            // Ensure TLS cert is trusted first
            let trustResult = await Self.runCLIProcess(path: cliPath, arguments: ["auth", "trust-cert"])
            if trustResult.exitCode != 0 {
                await MainActor.run {
                    slackReconnecting = false
                    slackReconnectResult = trustResult.stderr.isEmpty
                        ? "Failed to set up secure connection"
                        : String(trustResult.stderr.prefix(200))
                }
                return
            }

            await MainActor.run {
                slackReconnectResult = "Complete authorization in your browser..."
            }

            // Run auth login (opens browser) — keep reference to process for cancellation
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["auth", "login"]
            process.environment = Constants.resolvedEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    slackReconnecting = false
                    slackReconnectResult = "Failed to launch: \(error.localizedDescription)"
                }
                return
            }

            await MainActor.run {
                slackAuthProcess = process
            }

            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _ = String(data: stdoutData, encoding: .utf8) // consume stdout

            await MainActor.run {
                slackAuthProcess = nil
                slackReconnecting = false

                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    slackReconnectSuccess = true
                    slackReconnectResult = "Connected"
                    config.reload()
                    slackAuth.checkStatus()
                } else if exitCode == 15 || exitCode == 9 {
                    // SIGTERM / SIGKILL — user cancelled
                    slackReconnectResult = nil
                } else {
                    slackReconnectResult = stderr.isEmpty
                        ? "Authentication failed (exit \(exitCode))"
                        : String(stderr.prefix(200))
                }
            }
        }
    }

    private func cancelSlackReconnect() {
        if let process = slackAuthProcess, process.isRunning {
            process.terminate()
        }
        slackAuthProcess = nil
        slackReconnecting = false
        slackReconnectResult = nil
    }

    private static func runCLIProcess(path: String, arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    private func testConnection() {
        let isCodex = (config.aiProvider ?? "claude") == "codex"
        let cliPath: String? = isCodex ? Constants.findInPath("codex") : Constants.findInPath("claude")
        let providerName = isCodex ? "Codex" : "Claude"
        let defaultModel = isCodex ? "gpt-5.4" : "claude-sonnet-4-6"

        guard let path = cliPath else {
            connectionTestResult = "\(providerName) CLI not found"
            connectionTestSuccess = false
            return
        }

        connectionTestRunning = true
        connectionTestResult = nil

        let model = (config.aiModel ?? "").isEmpty ? defaultModel : (config.aiModel ?? defaultModel)

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)

            if isCodex {
                process.arguments = ["exec", "--model", model, "--json", "--skip-git-repo-check", "-c", "approval_policy=never", "respond with: OK"]
            } else {
                process.arguments = ["-p", "respond with: OK", "--output-format", "text", "--model", model]
            }

            process.environment = Constants.resolvedEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    connectionTestRunning = false
                    connectionTestSuccess = false
                    connectionTestResult = "Failed to launch: \(error.localizedDescription)"
                }
                return
            }

            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            await MainActor.run {
                connectionTestRunning = false
                if process.terminationStatus == 0 && !stdout.isEmpty {
                    connectionTestSuccess = true
                    connectionTestResult = "Connected (\(model))"
                } else {
                    connectionTestSuccess = false
                    connectionTestResult = Self.diagnoseError(stderr: stderr, exitCode: process.terminationStatus)
                }
            }
        }
    }

    private static func diagnoseError(stderr: String, exitCode: Int32) -> String {
        let lower = stderr.lowercased()
        if lower.contains("not authenticated") || lower.contains("unauthorized")
            || lower.contains("api key") || lower.contains("log in") || lower.contains("login") {
            return "Not authenticated. Run 'claude' in Terminal."
        }
        if lower.contains("model") && (lower.contains("access") || lower.contains("available") || lower.contains("permission")) {
            return "Model not available for your account."
        }
        if lower.contains("rate limit") || lower.contains("overloaded") {
            return "API overloaded. Try again later."
        }
        if lower.contains("network") || lower.contains("connection") || lower.contains("timed out") {
            return "Network error."
        }
        if !stderr.isEmpty {
            let short = stderr.count > 200 ? String(stderr.prefix(200)) + "..." : stderr
            return "Error (exit \(exitCode)): \(short)"
        }
        return "Failed (exit code \(exitCode))"
    }
}

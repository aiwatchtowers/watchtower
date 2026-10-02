import SwiftUI
import WatchtowerCore

struct NavigationRoot: View {
    @Environment(AppState.self) private var appState

    enum Screen: Equatable {
        case splash, ambiguousWorkspace, onboarding, main
    }

    /// Which top-level screen launch state selects. The ambiguous-workspace
    /// screen wins over onboarding: with no workspace picked there is no
    /// database to onboard into.
    static func screen(isLoading: Bool, ambiguousWorkspaces: [String], needsOnboarding: Bool) -> Screen {
        if isLoading { return .splash }
        if !ambiguousWorkspaces.isEmpty { return .ambiguousWorkspace }
        return needsOnboarding ? .onboarding : .main
    }

    var body: some View {
        switch Self.screen(
            isLoading: appState.isLoading,
            ambiguousWorkspaces: appState.ambiguousWorkspaces,
            needsOnboarding: appState.needsOnboarding
        ) {
        case .splash:
            SplashView()
        case .ambiguousWorkspace:
            AmbiguousWorkspaceView(candidates: appState.ambiguousWorkspaces) {
                appState.reinitializeAfterOnboarding()
            }
        case .onboarding:
            OnboardingView {
                appState.reinitializeAfterOnboarding()
            }
        case .main:
            MainNavigationView()
        }
    }
}

struct SplashView: View {
    @State private var opacity: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            BannerImage(maxWidth: 360)

            ProgressView()
                .scaleEffect(0.8)
                .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.4)) {
                opacity = 1
            }
        }
    }
}

struct MainNavigationView: View {
    @Environment(AppState.self) private var appState
    @State private var showMenu = true
    /// Reuses `GoogleConnectFlow.shared.calendar` (rather than a locally-
    /// constructed `GoogleAuthService()`) so this reconnect flow gets its
    /// DB-derived `isConnected` from the same wiring — `AppState.
    /// initGoogleAccounts` calls `GoogleConnectFlow.shared.configure(dbPool:)`
    /// — instead of a second instance with no DB access.
    private let googleAuth = GoogleConnectFlow.shared.calendar
    @State private var dismissedAuthTimestamp: String = UserDefaults.standard.string(forKey: "dismissedCalendarAuthAt") ?? ""

    /// Show the reconnect popup when the daemon has flagged the calendar auth as broken
    /// AND the user hasn't already dismissed this specific revocation.
    private var shouldShowReconnectAlert: Bool {
        guard let auth = appState.calendarViewModel?.authState else { return false }
        guard auth.status == "revoked" else { return false }
        return auth.updatedAt != dismissedAuthTimestamp
    }

    /// Menu column widths: the full menu, and the icon rail ⌘B folds it into.
    private static let menuWidth: CGFloat = 180
    private static let railWidth: CGFloat = 52

    /// The fold/unfold toggle at the top of the menu column — leading in the
    /// full menu, centred as the rail's first item.
    private var sidebarToggleRow: some View {
        HStack(spacing: 8) {
            if !showMenu { Spacer(minLength: 0) }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMenu.toggle()
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(showMenu ? "Collapse Menu (⌘B)" : "Expand Menu (⌘B)")
            .keyboardShortcut("b", modifiers: [.command])

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            // Content
            HStack(spacing: 0) {
                // Menu column: the full menu, or the icon rail when folded (⌘B).
                VStack(spacing: 0) {
                    sidebarToggleRow

                    SidebarView(selection: $state.selectedDestination, compact: !showMenu)
                }
                .frame(width: showMenu ? Self.menuWidth : Self.railWidth)
                .clipped()
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .detailBackground()
            }

            StatusBarView()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Google Calendar disconnected",
            isPresented: Binding(
                get: { shouldShowReconnectAlert },
                set: { newValue in
                    if !newValue, let auth = appState.calendarViewModel?.authState {
                        dismissedAuthTimestamp = auth.updatedAt
                        UserDefaults.standard.set(auth.updatedAt, forKey: "dismissedCalendarAuthAt")
                    }
                }
            )
        ) {
            Button("Reconnect") {
                appState.selectedDestination = .calendar
                reconnectAndRestartDaemon()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Your Google authorization expired or was revoked. Reconnect to resume calendar sync.")
        }
        .onAppear { applyFeatureFallback() }
        .onChange(of: appState.featureVisibility.disabledFeatureIDs) { _, _ in applyFeatureFallback() }
        .onChange(of: appState.featureVisibility.connectedSources) { _, _ in applyFeatureFallback() }
        // Direct writes (deep links, Day Plan, the action strip, Catch-Up
        // cards) must not land on a hidden tab either.
        .onChange(of: appState.selectedDestination) { _, _ in applyFeatureFallback() }
    }

    /// Redirects away from the current tab when it becomes hidden — a
    /// feature was just disabled, or a persisted selection from a previous
    /// launch points at a tab that's now gated off. Runs once at appear
    /// (stale persisted selection), on every live feature-list or
    /// connected-source change, and on every selection change, sharing the
    /// same pure `fallbackDestination` rule.
    private func applyFeatureFallback() {
        if let fallback = SidebarDestination.fallbackDestination(
            current: appState.selectedDestination,
            disabled: appState.featureVisibility.disabledFeatureIDs,
            connected: appState.featureVisibility.connectedSources
        ) {
            appState.selectedDestination = fallback
        }
    }

    /// Runs the OAuth flow and, on success, restarts the daemon so the in-memory
    /// refresh token is replaced with the freshly saved one. Targets the
    /// SPECIFIC account `authState` flagged as broken (N2) — without this,
    /// `connect()` falls back to the CLI's generic "account #1" alias, which
    /// in a multi-account workspace may be a completely different, healthy
    /// account, leaving the actually-broken one (and the alert) stuck forever.
    private func reconnectAndRestartDaemon() {
        googleAuth.connect(accountID: appState.calendarViewModel?.authState?.accountID)
        Task {
            while googleAuth.isAuthenticating {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard googleAuth.isConnected else { return }
            let daemon = DaemonManager()
            daemon.resolvePathIfNeeded()
            guard DaemonManager.checkDaemonRunning() else { return }
            await daemon.stopDaemon()
            try? await Task.sleep(for: .milliseconds(500))
            await daemon.startDaemon()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedDestination {
        case .chat:
            ChatView()
        case .catchUp:
            if let vm = appState.catchUpViewModel {
                CatchUpView(vm: vm)
            } else {
                Text("Catch Up unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .briefings:
            if let vm = appState.briefingViewModel {
                BriefingsListView(vm: vm)
            } else {
                Text("Briefings unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .dayPlan:
            if let vm = appState.dayPlanViewModel {
                DayPlanView(vm: vm)
            } else {
                Text("Day Plan unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .inbox:
            ActionStripView()
        case .ideas:
            if let vm = appState.ideasViewModel {
                IdeasView(vm: vm)
            } else {
                Text("Ideas unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .calendar:
            CalendarEventsView()
        case .targets:
            TargetsListView()
        case .tracks:
            TracksListView()
        case .workbench:
            if let vm = appState.workbenchesViewModel {
                WorkbenchesView(vm: vm)
            } else {
                Text("Workbench unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .digests:
            DigestListView()
        case .people:
            PeopleListView()
        case .memory:
            if let vm = appState.memoryViewModel {
                MemoryView(vm: vm)
            } else {
                Text("Memory unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .workload:
            WorkloadView()
        case .blockers:
            BlockerMapView()
        case .projectMap:
            ProjectMapView()
        case .releases:
            ReleaseDashboardView()
        case .statistics:
            StatisticsView()
        case .search:
            SearchView()
        case .boards:
            BoardsView()
        case .usage:
            UsageView()
        case .mcpServer:
            MCPServerView()
        }
    }
}

// MARK: - Onboarding



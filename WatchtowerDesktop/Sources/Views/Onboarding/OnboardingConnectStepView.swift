import SwiftUI
import WatchtowerCore

/// Onboarding step 2: one card per source the saved goals need, each opening
/// the Settings Add sheet. Everything is skippable. A newly connected Slack
/// account starts the background people load (`AppState.peopleRoster`,
/// started by `AppState.slackAccountsDidChange`). With a harness offered,
/// each card offers **Connect with <harness>** first (agent connect spec
/// §7): the assistant's panel opens beside the step (`OnboardingV2View`),
/// and its **Set up by hand** comes back here as the source's sheet.
struct OnboardingConnectStepView: View {
    /// Every sheet and remove on this step: the daemon starts at completion,
    /// not mid-setup.
    static let daemonPolicy: DaemonRestartPolicy = .deferred

    static func slackSheet() -> AddSlackAccountView {
        AddSlackAccountView(daemonPolicy: daemonPolicy)
    }

    /// A13: a build with no Slack app of its own (`builtin_app` false) opens
    /// the connect section instead of the Add sheet, which would have no app
    /// to sign in with. `flags` nil (never read, even after the card's own
    /// read): the connect section, which works on every build. No connect
    /// flow (its listener did not start) keeps the Add sheet.
    static func slackOpensConnectSection(flags: SlackAccountsDocument?, hasConnectFlow: Bool) -> Bool {
        hasConnectFlow && flags?.builtinApp != true
    }

    /// A clicked About link (or any flow step) opens the Slack sheet once no
    /// sheet is up, so its confirm is seen on this step: at once, or when
    /// another source's sheet closes.
    static func sheet(_ current: Sheet?, flowShowsSheet: Bool) -> Sheet? {
        current ?? (flowShowsSheet ? .slackConnect : nil)
    }

    /// The Slack sheet itself closed (swipe, Esc, Skip): its finished flow
    /// is dismissed as **Done**/**Close** would, so the result does not
    /// reopen. Any other sheet closing retries a queued link instead.
    static func closingDismissesFlow(from old: Sheet?, to new: Sheet?) -> Bool {
        old == .slackConnect && new == nil
    }

    /// The card's choice after its flags read: a sheet that opened meanwhile
    /// (a link's confirm) stays.
    static func sheet(_ current: Sheet?, afterFlagsRead chosen: Sheet) -> Sheet {
        current ?? chosen
    }

    /// Opens with every service its client may ask for checked, whatever the
    /// goals: Calendar, and Gmail only on a flavored build (D11).
    static func googleSheet() -> AddGoogleAccountView {
        AddGoogleAccountView(daemonPolicy: daemonPolicy)
    }

    static func jiraSheet() -> AddJiraAccountView {
        AddJiraAccountView(daemonPolicy: daemonPolicy)
    }

    static func linearSheet() -> AddLinearAccountView {
        AddLinearAccountView(daemonPolicy: daemonPolicy)
    }

    /// The connect service a source's agent button opens.
    static func connectService(_ source: OnboardingConnectSource) -> ConnectionService {
        switch source {
        case .slack: .slack
        case .google: .google
        case .jira: .jira
        case .linear: .linear
        }
    }

    /// The step's sheet for the assistant's **Set up by hand** (or **Open
    /// it**) on `service`; nil for a service the step has no sheet for.
    /// Slack picks its sheet after the flags read (`openSlackSheet`).
    static func addRequestSheet(_ service: ConnectionService) -> Sheet? {
        switch service {
        case .slack: .slack
        case .google: .google
        case .jira: .jira
        case .linear: .linear
        case .email, .calendar, .quickConnections, .companySetup: nil
        }
    }

    let onBack: () -> Void
    let onContinue: () async -> Void

    @Environment(AppState.self) private var appState
    @State private var sheet: Sheet?
    @State private var databaseError: String?
    @State private var isContinuing = false

    enum Sheet: Identifiable {
        case slack
        case slackConnect
        case google
        case jira
        case linear

        var id: String {
            switch self {
            case .slack: "slack"
            case .slackConnect: "slackConnect"
            case .google: "google"
            case .jira: "jira"
            case .linear: "linear"
            }
        }
    }

    private var sources: [OnboardingConnectSource] {
        OnboardingConnectPlan.sources(for: appState.onboardingGoals.savedGoals, policy: appState.managedPolicy.policy)
    }

    private var activeSlackAccounts: [SlackAccount] {
        appState.slackAccountsViewModel?.accounts.filter { !$0.isGone } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your sources").font(.headline)
                Text("Only what your goals need. Skip any of them and connect later in the Connections tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: Spacing.small) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    row(source)
                }
            }

            Label(ConnectAssistantPresentation.onboardingFootnote(offeredHarness), systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let databaseError {
                HStack {
                    Text("Could not open the database: \(databaseError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Retry") { Task { await openDatabase() } }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Back", action: onBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("You can continue without any")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task {
                        isContinuing = true
                        await onContinue()
                        isContinuing = false
                    }
                } label: {
                    Text("Continue").fontWeight(.semibold).frame(minWidth: 120)
                }
                .onboardingPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(isContinuing || appState.isFinishingOnboarding)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .slack: Self.slackSheet()
            case .slackConnect: slackConnectSheet
            case .google: Self.googleSheet()
            case .jira: Self.jiraSheet()
            case .linear: Self.linearSheet()
            }
        }
        .task {
            await openDatabase()
            appState.resumePeopleRosterIfNeeded()
            showFlowSheetIfNeeded() // a link that arrived on an earlier step
            consumeAddRequest()
        }
        // The agent buttons wait for the harness CLIs Go finds; onboarding
        // never shows the Connections tab, which reads them otherwise.
        .task(id: appState.connectProviders().map(\.id)) { await appState.refreshConnectReadyProviders() }
        .onChange(of: appState.connectionAddRequest) { consumeAddRequest() }
        .onChange(of: appState.slackConnectFlow?.showsSheet) { _, _ in showFlowSheetIfNeeded() }
        .onChange(of: sheet) { old, new in
            if Self.closingDismissesFlow(from: old, to: new) {
                appState.slackConnectFlow?.dismiss() // only a connected or failed flow; a running one cannot close
            } else {
                showFlowSheetIfNeeded()
            }
        }
    }

    /// Reads the flags first when no read has succeeded yet, then picks the sheet.
    private func openSlackSheet() async {
        if let vm = appState.slackAccountsViewModel, vm.accountFlags == nil { await vm.refreshFlags() }
        let chosen: Sheet = Self.slackOpensConnectSection(
            flags: appState.slackAccountsViewModel?.accountFlags,
            hasConnectFlow: appState.slackConnectFlow != nil) ? .slackConnect : .slack
        sheet = Self.sheet(sheet, afterFlagsRead: chosen)
    }

    /// The assistant's **Set up by hand**: its source's sheet, once no
    /// sheet is up (a sheet already up stays; the request is spent).
    private func consumeAddRequest() {
        guard let request = appState.connectionAddRequest else { return }
        appState.connectionAddRequest = nil
        guard sheet == nil, let chosen = Self.addRequestSheet(request) else { return }
        if chosen == .slack {
            Task { await openSlackSheet() }
        } else {
            sheet = chosen
        }
    }

    /// The harness the agent buttons name, when any source offers one.
    private var offeredHarness: ConnectHarness? {
        sources.lazy.compactMap { appState.connectAssistantButton(for: Self.connectService($0).rawValue) }.first
    }

    private func agent(_ source: OnboardingConnectSource) -> (harness: ConnectHarness, open: () -> Void)? {
        let service = Self.connectService(source).rawValue
        return appState.connectAssistantButton(for: service).map { harness in
            (harness, { appState.openConnectAssistant(service: service) })
        }
    }

    private func showFlowSheetIfNeeded() {
        let next = Self.sheet(sheet, flowShowsSheet: appState.slackConnectFlow?.showsSheet ?? false)
        if next != sheet { sheet = next }
    }

    /// The connect section in a sheet (A13); a written account reloads the
    /// list through the flow's `onConnected` (deferred restart in onboarding).
    @ViewBuilder private var slackConnectSheet: some View {
        if let flow = appState.slackConnectFlow {
            SlackOnboardingConnectSheet(
                section: SlackModePresentation.ConnectSection(
                    display: .off,
                    portBusy: appState.slackConnectListener?.state == .portBusy,
                    expanded: true,
                    organizationApps: appState.managedPolicy.policy.slackApps,
                    accounts: appState.slackAccountsViewModel?.accounts ?? [],
                    builtinApp: false),
                flow: flow,
                setupPresented: appState.slackAppSetup.isPresented,
                blocked: !appState.managedPolicy.policy.sourceAllowed("slack"),
                setUpForCompany: { appState.slackAppSetup.present() },
                close: { sheet = nil })
                .frame(width: 520)
                .interactiveDismissDisabled(flow.isRunning)
                .onAppear { appState.slackConnectListener?.ensureRunning() } // A10: retry a busy port
                .sheet(isPresented: Bindable(appState.slackAppSetup).isPresented) {
                    SlackAppSetupSheet(model: appState.slackAppSetup).frame(width: 520)
                }
        }
    }

    /// The database launch could not open on a fresh install; Goals'
    /// Continue opened it, this covers a relaunch that failed to.
    private func openDatabase() async {
        databaseError = await appState.openDatabaseForOnboarding()
    }

    @ViewBuilder
    private func row(_ source: OnboardingConnectSource) -> some View {
        switch source {
        case .slack:
            OnboardingConnectSourceRow(
                letter: "S", title: "Slack",
                subtitle: "Messages, mentions, threads · for work communication",
                // v1: the first active account, whatever its status.
                connected: activeSlackAccounts.first?.displayName,
                available: appState.slackAccountsViewModel != nil,
                error: appState.slackAccountsViewModel?.error,
                connect: { Task { await openSlackSheet() } },
                remove: activeSlackAccounts.first.map { account in
                    { await appState.slackAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                },
                agent: agent(source),
                roster: AnyView(rosterLine)
            )
        case .google:
            // v1: the first account, whatever its status or scopes.
            let account = appState.googleAccountsViewModel?.accounts.first
            OnboardingConnectSourceRow(
                letter: "G", title: "Google",
                subtitle: CompanyConnectionsPresentation.onboardingGoogleSubtitle(
                    offersGmail: appState.sharedGoogleOffersGmail),
                connected: account?.displayName,
                available: appState.googleAccountsViewModel != nil,
                error: appState.googleAccountsViewModel?.error,
                connect: { sheet = .google },
                remove: account.map { account in
                    { await appState.googleAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                },
                agent: agent(source)
            )
        case .jira:
            // v1: the first active account, whatever its status.
            let account = appState.jiraAccountsViewModel?.accounts.first { !$0.isGone }
            OnboardingConnectSourceRow(
                letter: "J", title: "Jira",
                subtitle: "Issues and boards · for tasks",
                connected: account?.displayName,
                available: appState.jiraAccountsViewModel != nil,
                error: appState.jiraAccountsViewModel?.error,
                connect: { sheet = .jira },
                remove: account.map { account in
                    { await appState.jiraAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                },
                agent: agent(source)
            )
        case .linear:
            // v1: the first workspace, whatever its status.
            let account = appState.linearAccountsViewModel?.accounts.first
            OnboardingConnectSourceRow(
                letter: "L", title: "Linear",
                subtitle: "Issues, cycles and projects · for tasks",
                connected: account?.displayName,
                available: appState.linearAccountsViewModel != nil,
                error: appState.linearAccountsViewModel?.error,
                connect: { sheet = .linear },
                remove: account.map { account in
                    { await appState.linearAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                },
                agent: agent(source)
            )
        }
    }

    @ViewBuilder
    private var rosterLine: some View {
        let roster = appState.peopleRoster
        if let text = roster.state.progressText {
            HStack(spacing: 6) {
                if case .loading = roster.state {
                    ProgressView().controlSize(.mini)
                }
                Text(text)
                    .foregroundStyle(roster.state.isFailure ? .red : .secondary)
                    .lineLimit(2)
                if roster.state.isFailure {
                    Button("Retry") { roster.retry() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
        }
    }
}

/// One source on the onboarding Connect step: its letter, name and line,
/// then the account once connected (with Remove), else the way in. With
/// `agent`, **Connect with <harness>** comes first and today's **Connect**
/// (the same sheet as in Settings) is the quiet link beside it (agent
/// connect spec §7); without one, today's button.
struct OnboardingConnectSourceRow: View {
    let letter: String
    let title: String
    let subtitle: String
    var connected: String?
    var available = true
    var error: String?
    let connect: () -> Void
    var remove: (() async -> Void)?
    var agent: (harness: ConnectHarness, open: () -> Void)?
    /// The people load's line under a Slack row.
    var roster: AnyView?

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Text(letter)
                .fontWeight(.bold)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Fill.hover))
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if let roster { roster }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let connected {
                Label(connected, systemImage: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Tone.success)
                if let remove {
                    Menu {
                        Button("Remove") { Task { await remove() } }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("More for \(title)")
                }
            } else if let agent {
                // Side by side, else stacked: the panel beside the step narrows it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.regular) { agentPair(agent) }
                    VStack(alignment: .trailing, spacing: Spacing.small) { agentPair(agent) }
                }
            } else {
                Button(ConnectAssistantPresentation.connectByHand, action: connect)
                    .disabled(!available)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .card()
    }

    @ViewBuilder
    private func agentPair(_ agent: (harness: ConnectHarness, open: () -> Void)) -> some View {
        ConnectAgentButton(title: ConnectAssistantPresentation.connectWith(agent.harness), action: agent.open)
        Button(ConnectAssistantPresentation.connectByHand, action: connect)
            .buttonStyle(.kitQuiet)
            .disabled(!available)
    }
}

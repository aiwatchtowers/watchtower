import SwiftUI
import WatchtowerCore

/// Onboarding step 2: one card per source the saved goals need, each opening
/// the Settings Add sheet. Everything is skippable. A newly connected Slack
/// account starts the background people load (`AppState.peopleRoster`,
/// started by `AppState.slackAccountsDidChange`).
struct OnboardingConnectStepView: View {
    /// Every sheet and remove on this step: the daemon starts at completion,
    /// not mid-setup.
    static let daemonPolicy: DaemonRestartPolicy = .deferred

    static func slackSheet() -> AddSlackAccountView {
        AddSlackAccountView(daemonPolicy: daemonPolicy)
    }

    static func googleSheet(mail: Bool, calendar: Bool) -> AddGoogleAccountView {
        AddGoogleAccountView(daemonPolicy: daemonPolicy, calendar: calendar, mail: mail)
    }

    static func jiraSheet() -> AddJiraAccountView {
        AddJiraAccountView(daemonPolicy: daemonPolicy)
    }

    let onBack: () -> Void
    let onContinue: () async -> Void

    @Environment(AppState.self) private var appState
    @State private var sheet: Sheet?
    @State private var databaseError: String?
    @State private var isContinuing = false

    private enum Sheet: Identifiable {
        case slack
        case google(mail: Bool, calendar: Bool)
        case jira

        var id: String {
            switch self {
            case .slack: "slack"
            case .google: "google"
            case .jira: "jira"
            }
        }
    }

    private var sources: [OnboardingConnectSource] {
        OnboardingConnectPlan.sources(for: appState.onboardingGoals.savedGoals)
    }

    private var activeSlackAccounts: [SlackAccount] {
        appState.slackAccountsViewModel?.accounts.filter { $0.status != "removed" } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your sources").font(.headline)
                Text("Only what your goals need. Skip any of them and connect later in Settings → Connections.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    if index > 0 { Divider() }
                    row(source)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))

            Label("Everything stays on your Mac. Connect opens the same sheet as in Settings.", systemImage: "lock")
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
            case let .google(mail, calendar): Self.googleSheet(mail: mail, calendar: calendar)
            case .jira: Self.jiraSheet()
            }
        }
        .task {
            await openDatabase()
            appState.resumePeopleRosterIfNeeded()
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
            sourceRow(
                letter: "S", title: "Slack",
                subtitle: "Messages, mentions, threads · for work communication",
                // v1: the first active account, whatever its status.
                connected: activeSlackAccounts.first?.displayName,
                available: appState.slackAccountsViewModel != nil,
                error: appState.slackAccountsViewModel?.error,
                connect: { sheet = .slack },
                remove: activeSlackAccounts.first.map { account in
                    { await appState.slackAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                },
                showsRoster: true
            )
        case let .google(mail, calendar):
            // v1: the first account, whatever its status or scopes.
            let account = appState.googleAccountsViewModel?.accounts.first
            sourceRow(
                letter: "G", title: "Google",
                subtitle: Self.googleSubtitle(mail: mail, calendar: calendar),
                connected: account?.displayName,
                available: appState.googleAccountsViewModel != nil,
                error: appState.googleAccountsViewModel?.error,
                connect: { sheet = .google(mail: mail, calendar: calendar) },
                remove: account.map { account in
                    { await appState.googleAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                }
            )
        case .jira:
            // v1: the first active account, whatever its status.
            let account = appState.jiraAccountsViewModel?.accounts.first { $0.status != "removed" }
            sourceRow(
                letter: "J", title: "Jira",
                subtitle: "Issues and boards · for tasks",
                connected: account?.displayName,
                available: appState.jiraAccountsViewModel != nil,
                error: appState.jiraAccountsViewModel?.error,
                connect: { sheet = .jira },
                remove: account.map { account in
                    { await appState.jiraAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                }
            )
        }
    }

    static func googleSubtitle(mail: Bool, calendar: Bool) -> String {
        switch (mail, calendar) {
        case (true, true): "Mail and calendar · for work communication and meetings"
        case (true, false): "Mail · for work communication"
        default: "Calendar · for meetings"
        }
    }

    private func sourceRow(
        letter: String,
        title: String,
        subtitle: String,
        connected: String?,
        available: Bool,
        error: String?,
        connect: @escaping () -> Void,
        remove: (() async -> Void)?,
        showsRoster: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            Text(letter)
                .fontWeight(.bold)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if showsRoster { rosterLine }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let connected {
                Label(connected, systemImage: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
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
            } else {
                Button("Connect", action: connect)
                    .disabled(!available)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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

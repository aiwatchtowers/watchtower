import SwiftUI
import WatchtowerCore

/// Onboarding step 2: one card per source the saved goals need, each opening
/// the Settings Add sheet. Everything is skippable. A newly connected Slack
/// account starts the background people load (`AppState.peopleRoster`).
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
    /// The Slack accounts before the Slack sheet opened, to spot the one it
    /// connected.
    @State private var slackBefore: Set<Int> = []
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
                    Text("Continue").frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isContinuing)
            }
        }
        .sheet(item: $sheet, onDismiss: sheetDismissed) { sheet in
            switch sheet {
            case .slack: Self.slackSheet()
            case let .google(mail, calendar): Self.googleSheet(mail: mail, calendar: calendar)
            case .jira: Self.jiraSheet()
            }
        }
        .task { await openDatabase() }
    }

    /// The database launch could not open on a fresh install; Goals'
    /// Continue opened it, this covers a relaunch that failed to.
    private func openDatabase() async {
        databaseError = await appState.openDatabaseForOnboarding()
    }

    private func sheetDismissed() {
        guard let vm = appState.slackAccountsViewModel else { return }
        let before = slackBefore
        Task {
            await vm.refreshAsync()
            let after = vm.accounts.filter { $0.status != "removed" }.map(\.id)
            if let id = OnboardingConnectPlan.newlyConnected(before: before, after: after) {
                appState.peopleRoster.start(accountID: id)
            }
        }
    }

    @ViewBuilder
    private func row(_ source: OnboardingConnectSource) -> some View {
        switch source {
        case .slack:
            sourceRow(
                letter: "S", title: "Slack",
                subtitle: "Messages, mentions, threads · for work communication",
                connected: activeSlackAccounts.first?.displayName,
                available: appState.slackAccountsViewModel != nil,
                connect: {
                    slackBefore = Set(activeSlackAccounts.map(\.id))
                    sheet = .slack
                },
                remove: activeSlackAccounts.first.map { account in
                    { await appState.slackAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                },
                showsRoster: true
            )
        case let .google(mail, calendar):
            let account = appState.googleAccountsViewModel?.accounts.first
            sourceRow(
                letter: "G", title: "Google",
                subtitle: Self.googleSubtitle(mail: mail, calendar: calendar),
                connected: account?.displayName,
                available: appState.googleAccountsViewModel != nil,
                connect: { sheet = .google(mail: mail, calendar: calendar) },
                remove: account.map { account in
                    { await appState.googleAccountsViewModel?.remove(account, daemonPolicy: Self.daemonPolicy) }
                }
            )
        case .jira:
            let account = appState.jiraAccountsViewModel?.accounts.first { $0.status != "removed" }
            sourceRow(
                letter: "J", title: "Jira",
                subtitle: "Issues and boards · for tasks",
                connected: account?.displayName,
                available: appState.jiraAccountsViewModel != nil,
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
        switch appState.peopleRoster.state {
        case .idle:
            EmptyView()
        case let .loading(fetched, saved):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(saved == 0 ? "Loading people… \(fetched)" : "Loading people… \(saved) of \(fetched)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .done(let count):
            Text("\(count) people loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            HStack(spacing: 6) {
                Text("Couldn't load people: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                if let account = activeSlackAccounts.first {
                    Button("Retry") { appState.peopleRoster.start(accountID: account.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

import DesignKit
import SwiftUI
import WatchtowerCore

/// Jira detail pane in the Connections tab — the multi-account Atlassian
/// connections (`jira_accounts` table, migration 00049) grouped by company
/// (company screens spec §4.2) under the retired-shared-app banner (§7),
/// the §6.4 empty state with no site and no company — and, once a site is
/// connected, its boards, Confluence spaces, features, user mapping and
/// sync (the Boards tab until #899). A board's profile and the features
/// detail open in place, with a way back.
///
/// A new site signs in through a company's Atlassian app or with an API
/// token (§6, `AtlassianTokenSheet`): the shared app is retired (D15
/// amended, ask #1600), so there is no plain "Add Jira Site" here;
/// onboarding keeps its add sheet. While the organization forbids API
/// tokens (§6.5) the token offers are gone, token sites read "Stopped by
/// your organization" under the lock card, and an open token sheet closes.
///
/// Like Slack (and unlike Google), removal is non-destructive: `jira remove`
/// drops the token and marks the row removed/disabled but leaves
/// already-synced issues, boards, and releases in place.
struct JiraConnectionDetail: View {
    @Environment(AppState.self) private var appState
    /// The organization's policy forbids this source (#608): nothing new
    /// connects; existing accounts keep their data.
    private var sourceBlocked: Bool { !appState.managedPolicy.policy.sourceAllowed("jira") }
    @State private var jiraAccountPendingRemoval: JiraAccount?
    @State private var accountBeingRenamed: AccountRenameTarget?
    @State private var drillIn: JiraDetailItem?

    private var hasSites: Bool { appState.jiraAccountsViewModel?.accounts.isEmpty == false }

    var body: some View {
        if let drillIn {
            drillInContent(drillIn)
        } else {
            settingsForm
        }
    }

    private var settingsForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                jiraAccountsSections
                if hasSites {
                    JiraBoardsSettingsView { board in withAnimation(Motion.panel) { drillIn = .board(board) } }
                }
                confluenceSections
                if hasSites {
                    JiraFeaturesSettingsView { withAnimation(Motion.panel) { drillIn = .features } }
                    JiraUserMappingSettingsView()
                    JiraSyncInfoView()
                }
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .detailBackground()
        .sheet(isPresented: Binding(
            get: { appState.atlassianToken.isPresented },
            set: { if !$0 { appState.atlassianToken.close() } }
        )) {
            AtlassianTokenSheet(model: appState.atlassianToken).frame(width: 520)
        }
        .onChange(of: appState.companyLocks.contains(.atlassianAPIToken), initial: true) { _, locked in
            if locked { appState.atlassianToken.policyLocked() }
        }
        .accountRenameAlert($accountBeingRenamed) { target, name in
            Task { await appState.jiraAccountsViewModel?.rename(accountID: target.id, to: name) }
        }
        .confirmationDialog(
            "Remove \(jiraAccountPendingRemoval?.displayName ?? "this site")?",
            isPresented: Binding(
                get: { jiraAccountPendingRemoval != nil },
                set: { if !$0 { jiraAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Site", role: .destructive) {
                if let account = jiraAccountPendingRemoval {
                    Task { await appState.jiraAccountsViewModel?.remove(account, daemonPolicy: appState.accountDaemonPolicy) }
                }
                jiraAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountPurgeStatus.removeDialogMessage(
                "Disconnects the site. Already-synced issues, boards, and "
                    + "releases stay in Watchtower.",
                status: appState.accountPurgeCenter?.status
            ))
        }
    }

    private func drillInContent(_ item: JiraDetailItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.regular) {
                Button {
                    withAnimation(Motion.panel) { drillIn = nil }
                } label: {
                    Label("Jira", systemImage: "chevron.left")
                }
                .buttonStyle(.kitQuiet)
                Text(item.title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, Spacing.medium)
            switch item {
            case .board(let board):
                JiraBoardProfileView(board: board)
                    .scrollContentBackground(.hidden)
            case .features:
                JiraFeaturesDetailView()
                    .scrollContentBackground(.hidden)
            }
        }
    }

    /// The retired-app banner, then the sites grouped by company (or the
    /// loading, read-failed or empty state), then Add an account.
    private var jiraAccountsSections: some View {
        let vm = appState.jiraAccountsViewModel
        return CompanyAccountsSections(
            vendor: .atlassian,
            banner: appState.companyBanner(.atlassian),
            list: appState.companyAccountsList(.atlassian),
            emptyActions: appState.companyDetailActions(.atlassian, empty: true),
            addActions: appState.companyDetailActions(.atlassian, empty: false),
            connect: appState.companyGroupConnect(blocked: sourceBlocked || vm?.isConnecting == true),
            blocked: sourceBlocked,
            busy: appState.companyDetailBusy(.atlassian),
            error: vm?.error,
            locks: appState.companyLocks,
            agent: appState.connectAgentEntry,
            perform: { appState.performCompanyDetailAction($0, vendor: .atlassian) },
            bannerAction: { appState.performCompanyBannerAction($0) },
            tryAgain: { vm?.refresh() },
            row: { ref in
                if let vm, let account = vm.accounts.first(where: { $0.id == ref.accountID }) {
                    accountRow(vm, account: account, ref: ref)
                }
            }
        )
    }

    private func accountRow(_ vm: JiraAccountsViewModel, account: JiraAccount, ref: AccountRef) -> some View {
        let status = appState.companyRowStatus(ref)
        let waiting = vm.isConnecting && vm.signInAccountID == account.id
        // While its Re-login waits, the row's status gives way to the waiting
        // lines under a grey dot.
        return CompanyAccountRow(
            title: account.displayName,
            tag: CompanyConnectionsPresentation.tag(ref),
            status: waiting ? nil : status,
            line: CompanyConnectionsPresentation.jiraRowLine(ref, title: account.displayName, enabled: account.enabled,
                                                             email: account.ownerEmail),
            dot: waiting ? Tone.status("gray") : statusColor(account),
            extra: AnyView(rowExtra(account, hasStatus: status != nil, waiting: waiting))
        ) {
            if waiting {
                // Its Re-login waits in the browser: only the spinner and Cancel.
                SignInWaitCancel(cancelTitle: SignInWaitCopy.atlassian.cancelTitle) { vm.cancelConnect() }
            } else {
                rowControls(vm, account: account, ref: ref, status: status)
            }
        }
    }

    /// The row's toggle and buttons when no Re-login of it waits.
    @ViewBuilder
    private func rowControls(
        _ vm: JiraAccountsViewModel, account: JiraAccount, ref: AccountRef, status: RowStatus?
    ) -> some View {
        Toggle("Enabled", isOn: Binding(
            get: { account.enabled },
            set: { newValue in Task { await vm.setEnabled(account, enabled: newValue) } }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(vm.isConnecting || account.isPurged)
        if status?.action == .pasteCode {
            CompanyRowStatusButton(action: .pasteCode, disabled: sourceBlocked) { action in
                appState.companyRowAction(action, account: ref)
            }
        } else if ref.isAPIToken {
            // A token site takes a new token, never an OAuth sign-in; a stopped one takes nothing.
            if CompanyConnectionsPresentation.offersNewToken(ref, status: status) {
                CompanyRowStatusButton(action: .pasteNewToken,
                                       disabled: vm.isConnecting || appState.atlassianToken.isChecking
                                           || reloginBlocked(account.id) != nil) { action in
                    appState.companyRowAction(action, account: ref)
                }
                .managedByOrganization(sourceBlocked)
                .help(reloginBlocked(account.id) ?? "")
            }
        } else if !account.isOK || status?.action == .relogin {
            // `jira login --account` signs in through the site's own client (its company's after a Replace).
            Button(RowStatus.Action.relogin.title) { Task { await vm.relogin(account) } }
                .buttonStyle(.kitSecondary)
                .managedByOrganization(sourceBlocked)
                .help(reloginBlocked(account.id) ?? "")
                .disabled(vm.isConnecting || reloginBlocked(account.id) != nil)
        }
        Button("Rename…") {
            accountBeingRenamed = AccountRenameTarget(id: account.id, currentName: account.displayName)
        }
        .buttonStyle(.kitQuiet)
        .disabled(vm.isConnecting)
        // A token check still running (its sheet may be closed) could write the row back after a remove.
        Button("Remove") { jiraAccountPendingRemoval = account }
            .buttonStyle(KitQuietButtonStyle(label: Tone.error))
            .disabled(vm.isConnecting || appState.atlassianToken.isChecking)
    }

    /// The row's own lines under its status: the site's error (when no §4.3
    /// status says it), the purge line, and the waiting sign-in's two lines.
    @ViewBuilder
    private func rowExtra(_ account: JiraAccount, hasStatus: Bool, waiting: Bool) -> some View {
        if !hasStatus, !waiting, !account.isOK, !account.error.isEmpty {
            Text(account.error)
                .font(.caption)
                .foregroundStyle(Tone.error)
                .lineLimit(2)
        }
        if let line = AccountPurgeLine.make(
            center: appState.accountPurgeCenter, source: "jira", accountID: Int64(account.id),
            isPurged: account.isPurged
        ) {
            line
        }
        if waiting {
            SignInWaitText(line: SignInWaitCopy.atlassian.line, hint: SignInWaitCopy.atlassian.hint)
        }
    }

    /// One Confluence spaces picker per enabled site — Confluence rides the
    /// Jira account's grant. The site name joins the header only when there
    /// is more than one to tell apart.
    @ViewBuilder
    private var confluenceSections: some View {
        let sites = appState.jiraAccountsViewModel?.accounts.filter(\.enabled) ?? []
        ForEach(sites) { account in
            ConfluenceSpacesSection(
                account: account,
                title: sites.count > 1 ? "Confluence — \(account.displayName)" : "Confluence"
            )
        }
    }

    /// Why Re-login is off for the account (its purge is running), or nil.
    private func reloginBlocked(_ id: Int) -> String? {
        AccountPurgeLine.reloginBlockedReason(
            center: appState.accountPurgeCenter, source: "jira", accountID: Int64(id))
    }

    private func statusColor(_ account: JiraAccount) -> Color {
        if account.isOK { return Tone.success }
        if account.isRevoked { return Tone.error }
        if account.isPurged { return Tone.status("gray") }
        return Tone.warning
    }
}

/// What opens in place of the Jira detail: a board's profile or the features detail.
enum JiraDetailItem: Hashable {
    case board(JiraBoard)
    case features

    var title: String {
        switch self {
        case .board(let board): board.name
        case .features: "Jira Features"
        }
    }
}

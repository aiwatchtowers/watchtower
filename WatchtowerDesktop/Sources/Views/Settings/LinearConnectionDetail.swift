import DesignKit
import SwiftUI
import WatchtowerCore

/// Linear detail pane in the Connections tab: the connected workspaces
/// (`watchtower linear accounts --json`) grouped by company (company screens
/// spec §4.2), each with its sign-in kind, an Enabled switch, Re-login,
/// Remove and its teams to sync. Removal is non-destructive like Jira's:
/// the token goes, synced issues stay. A stored company with Linear and no
/// workspace shows a **Not connected** row whose Connect signs in through
/// the company's app.
struct LinearConnectionDetail: View {
    @Environment(AppState.self) private var appState
    /// The organization's policy forbids this source (#608): nothing new
    /// connects; existing accounts keep their data.
    private var sourceBlocked: Bool { !appState.managedPolicy.policy.sourceAllowed("linear") }
    @State private var showAddSheet = false
    @State private var pendingRemoval: LinearAccount?
    /// The API-key account whose key is being replaced.
    @State private var replacingKeyFor: LinearAccount?
    @State private var replacementKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                if let vm = appState.linearAccountsViewModel {
                    workspaces(vm)
                    ForEach(vm.accounts.filter(\.enabled)) { account in
                        teamsSection(vm, account: account, titled: vm.accounts.filter(\.enabled).count > 1)
                    }
                } else {
                    SettingsSection(title: Self.workspacesTitle) {
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .detailBackground()
        .sheet(isPresented: $showAddSheet) {
            AddLinearAccountView(daemonPolicy: appState.accountDaemonPolicy)
                .environment(appState)
                .marksAccountSheet(appState)
        }
        .sheet(item: $replacingKeyFor) { account in
            replaceKeySheet(account)
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "this workspace")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Workspace", role: .destructive) {
                if let account = pendingRemoval {
                    Task {
                        await appState.linearAccountsViewModel?.remove(account, daemonPolicy: appState.accountDaemonPolicy)
                    }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountPurgeStatus.removeDialogMessage(
                pendingRemoval?.usesAPIKey == true
                    ? "Disconnects the workspace. Already-synced issues stay in Watchtower. Delete the API key in Linear's settings to revoke it."
                    : "Disconnects the workspace and revokes Watchtower's access. Already-synced issues stay in Watchtower.",
                status: appState.accountPurgeCenter?.status
            ))
        }
    }

    static let workspacesTitle = "Linear Workspaces"
    static let noWorkspaces = "No Linear workspaces connected."

    /// The workspaces grouped by company, then Add with the last command's error.
    @ViewBuilder
    private func workspaces(_ vm: LinearAccountsViewModel) -> some View {
        let groups = appState.companyAccountGroups(.linear)
        if groups.isEmpty {
            SettingsSection(title: Self.workspacesTitle) {
                Text(Self.noWorkspaces)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        CompanyAccountGroups(groups: groups, connect: appState.companyGroupConnect(blocked: sourceBlocked)) { ref in
            if let account = vm.accounts.first(where: { $0.id == Int64(ref.accountID) }) {
                accountRow(vm, account: account, ref: ref)
            }
        }
        SettingsSection(title: CompanyConnectionsPresentation.addAccountTitle) {
            if let error = vm.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
            }
            HStack(spacing: Spacing.regular) {
                Button("Add Linear Workspace") { showAddSheet = true }
                    .buttonStyle(.kitSecondary)
                    .managedByOrganization(sourceBlocked)
                    .disabled(vm.isBusy)
                if vm.isBusy, !showAddSheet {
                    ProgressView().controlSize(.small)
                    if vm.isAuthorizing {
                        Button("Cancel") { vm.cancelConnect() }
                            .buttonStyle(.kitQuiet)
                    }
                }
            }
        }
    }

    private func accountRow(_ vm: LinearAccountsViewModel, account: LinearAccount, ref: AccountRef) -> some View {
        let status = appState.companyRowStatus(ref)
        return CompanyAccountRow(
            title: account.displayName,
            tag: CompanyConnectionsPresentation.tag(ref),
            status: status,
            line: account.url.isEmpty ? account.authLabel : "\(account.url) · \(account.authLabel)",
            dot: statusColor(account),
            extra: AnyView(rowExtra(account, hasStatus: status != nil))
        ) {
            Toggle("Enabled", isOn: Binding(
                get: { account.enabled },
                set: { value in Task { await vm.setEnabled(account, enabled: value) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(vm.isBusy || account.isPurged)
            if let action = status?.action, action == .pasteCode {
                CompanyRowStatusButton(action: action, disabled: sourceBlocked) { _ in
                    appState.companyRowAction(action, account: ref)
                }
            } else if !account.isOK || account.auth == "error" || status?.action == .relogin {
                Button(RowStatus.Action.relogin.title) { relogin(vm, account: account) }
                    .buttonStyle(.kitSecondary)
                    .managedByOrganization(sourceBlocked)
                    .help(reloginBlocked(account.id) ?? "")
                    .disabled(vm.isBusy || reloginBlocked(account.id) != nil)
            }
            Button("Remove") { pendingRemoval = account }
                .buttonStyle(KitQuietButtonStyle(label: Tone.error))
                .disabled(vm.isBusy)
        }
    }

    /// The row's own lines under its status: the account's error (when no
    /// §4.3 status says it) and the purge line.
    @ViewBuilder
    private func rowExtra(_ account: LinearAccount, hasStatus: Bool) -> some View {
        if !hasStatus, !account.isOK, !account.error.isEmpty {
            Text(account.error)
                .font(.caption)
                .foregroundStyle(Tone.error)
                .lineLimit(2)
        }
        if let line = AccountPurgeLine.make(
            center: appState.accountPurgeCenter, source: "linear", accountID: account.id,
            isPurged: account.isPurged
        ) {
            line
        }
    }

    /// Re-login: an API-key account asks for a new key; any other re-logs
    /// this very workspace (`linear login --account`, which signs in through
    /// its company's app when it has one) — never the add chain, which could
    /// connect another workspace or refuse a purged one.
    private func relogin(_ vm: LinearAccountsViewModel, account: LinearAccount) {
        if account.usesAPIKey {
            replacingKeyFor = account
        } else {
            Task { await vm.relogin(account) }
        }
    }

    @ViewBuilder
    private func teamsSection(_ vm: LinearAccountsViewModel, account: LinearAccount, titled: Bool) -> some View {
        SettingsSection(title: titled ? "Teams — \(account.displayName)" : "Teams") {
            if let error = vm.teamErrors[account.id] {
                HStack(spacing: Spacing.regular) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                    Button("Try Again") { Task { await vm.loadTeams(for: account) } }
                        .buttonStyle(.kitSecondary)
                }
            } else if let teams = vm.teams[account.id] {
                if teams.isEmpty {
                    Text("Teams appear after the workspace's first sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(teams) { team in
                    Toggle(isOn: Binding(
                        get: { team.selected },
                        set: { value in Task { await vm.setTeam(team, selected: value, for: account) } }
                    )) {
                        HStack(spacing: Spacing.regular) {
                            Text(team.name)
                            Text(team.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(vm.isBusy)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: account.id) { await vm.loadTeams(for: account) }
    }

    private func replaceKeySheet(_ account: LinearAccount) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("New API key for \(account.displayName)")
                .font(.headline)
            SecureField("lin_api_…", text: $replacementKey)
                .textFieldStyle(.kit)
            if let error = appState.linearAccountsViewModel?.error {
                Text(error).font(.caption).foregroundStyle(Tone.error)
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel") {
                    replacementKey = ""
                    replacingKeyFor = nil
                }
                .buttonStyle(.kitSecondary)
                Button("Save") {
                    Task {
                        let saved = await appState.linearAccountsViewModel?.reloginWithAPIKey(account, key: replacementKey) ?? false
                        if saved {
                            replacementKey = ""
                            replacingKeyFor = nil
                        }
                    }
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(replacementKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || appState.linearAccountsViewModel?.isBusy == true)
            }
        }
        .padding(Spacing.page)
        .frame(width: 380)
    }

    /// Why Re-login is off for the account (its purge is running), or nil.
    private func reloginBlocked(_ id: Int64) -> String? {
        AccountPurgeLine.reloginBlockedReason(
            center: appState.accountPurgeCenter, source: "linear", accountID: id)
    }

    private func statusColor(_ account: LinearAccount) -> Color {
        if account.isOK { return Tone.success }
        if account.status == "revoked" { return Tone.error }
        if account.isPurged { return Tone.status("gray") }
        return Tone.warning
    }
}

import SwiftUI
import WatchtowerCore

/// Linear detail pane in the Connections tab: the connected workspaces
/// (`watchtower linear accounts --json`), each with its sign-in kind, an
/// Enabled switch, Re-login, Remove and its teams to sync. Removal is
/// non-destructive like Jira's: the token goes, synced issues stay.
struct LinearConnectionDetail: View {
    @Environment(AppState.self) private var appState
    @State private var showAddSheet = false
    @State private var pendingRemoval: LinearAccount?
    /// The API-key account whose key is being replaced.
    @State private var replacingKeyFor: LinearAccount?
    @State private var replacementKey = ""

    var body: some View {
        Form {
            if let vm = appState.linearAccountsViewModel {
                workspacesSection(vm)
                ForEach(vm.accounts.filter(\.enabled)) { account in
                    teamsSection(vm, account: account, titled: vm.accounts.filter(\.enabled).count > 1)
                }
            } else {
                Section("Linear Workspaces") {
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
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
            Text(pendingRemoval?.usesAPIKey == true
                 ? "Disconnects the workspace. Already-synced issues stay in Watchtower. Delete the API key in Linear's settings to revoke it."
                 : "Disconnects the workspace and revokes Watchtower's access. Already-synced issues stay in Watchtower.")
        }
    }

    @ViewBuilder
    private func workspacesSection(_ vm: LinearAccountsViewModel) -> some View {
        Section("Linear Workspaces") {
            if vm.accounts.isEmpty {
                Text("No Linear workspaces connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(vm.accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName)
                        Text(account.url.isEmpty ? account.authLabel : "\(account.url) · \(account.authLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !account.isOK, !account.error.isEmpty {
                            Text(account.error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(statusColor(account))
                        .frame(width: 8, height: 8)
                        .help(account.isOK ? "Connected" : account.status)
                    Toggle("Enabled", isOn: Binding(
                        get: { account.enabled },
                        set: { value in Task { await vm.setEnabled(account, enabled: value) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(vm.isBusy)
                    if !account.isOK || account.auth == "error" {
                        Button("Re-login") {
                            if account.usesAPIKey {
                                replacingKeyFor = account
                            } else {
                                Task { await vm.relogin(account) }
                            }
                        }
                        .disabled(vm.isBusy)
                    }
                    Button("Remove") { pendingRemoval = account }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .disabled(vm.isBusy)
                }
            }

            if let error = vm.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Add Linear Workspace") { showAddSheet = true }
                    .disabled(vm.isBusy)
                if vm.isBusy, !showAddSheet {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { vm.cancelConnect() }
                }
            }
        }
    }

    @ViewBuilder
    private func teamsSection(_ vm: LinearAccountsViewModel, account: LinearAccount, titled: Bool) -> some View {
        Section(titled ? "Teams — \(account.displayName)" : "Teams") {
            if let error = vm.teamErrors[account.id] {
                HStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Try Again") { Task { await vm.loadTeams(for: account) } }
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
                        HStack {
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
        VStack(alignment: .leading, spacing: 14) {
            Text("New API key for \(account.displayName)")
                .font(.headline)
            SecureField("lin_api_…", text: $replacementKey)
                .textFieldStyle(.roundedBorder)
            if let error = appState.linearAccountsViewModel?.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    replacementKey = ""
                    replacingKeyFor = nil
                }
                Button("Save") {
                    Task {
                        let saved = await appState.linearAccountsViewModel?.reloginWithAPIKey(account, key: replacementKey) ?? false
                        if saved {
                            replacementKey = ""
                            replacingKeyFor = nil
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(replacementKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || appState.linearAccountsViewModel?.isBusy == true)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func statusColor(_ account: LinearAccount) -> Color {
        if account.isOK { return .green }
        if account.status == "revoked" { return .red }
        return .orange
    }
}

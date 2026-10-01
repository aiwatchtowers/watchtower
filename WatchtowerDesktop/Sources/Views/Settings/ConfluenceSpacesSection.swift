import SwiftUI
import WatchtowerCore

/// Settings → Jira → Confluence: pick which Confluence spaces of one Jira
/// account's Atlassian site sync into knowledge search. Reads the
/// AppState-owned `ConfluenceSpacesViewModel` for the account, so a toggle
/// or re-consent still running when this pane goes away finishes anyway.
struct ConfluenceSpacesSection: View {
    static let featureID = "knowledge-connectors"
    /// The daemon writes sync state from another process (nothing observes
    /// it live), so a visible section re-reads it from the DB this often.
    static let statusPollSeconds: UInt64 = 15

    @Environment(AppState.self) private var appState
    let account: JiraAccount
    let title: String
    @State private var search = ""
    /// A selected space whose toggle was switched off, awaiting confirmation:
    /// unselecting drops its synced content (a large backfill can take hours
    /// to redo).
    @State private var pendingUnselect: ConfluenceSpacesViewModel.SpaceRow?

    private var accountID: Int64 { Int64(account.id) }

    /// Off only when the Feature Manager list says so; not loaded yet (or a
    /// CLI predating the feature) shows the picker.
    private var featureOff: Bool {
        appState.featureManager.features.first { $0.id == Self.featureID }?.state == "disabled"
    }

    var body: some View {
        Section(title) {
            if featureOff {
                featureOffContent
            } else if let vm = appState.confluenceSpacesViewModels[accountID] {
                if vm.needsConsent {
                    consentContent(vm)
                } else {
                    spacesContent(vm)
                }
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(account.id)-\(featureOff)") {
            guard !featureOff,
                  let vm = appState.confluenceSpacesViewModel(forJiraAccount: accountID) else { return }
            await vm.load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.statusPollSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await vm.refreshStatuses()
            }
        }
    }

    // MARK: - Feature off

    @ViewBuilder
    private var featureOffContent: some View {
        Text("Confluence sync is turned off. Turn it on to pick spaces for knowledge search.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if let error = appState.featureManager.loadError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        Button(appState.featureManager.isApplying ? "Enabling…" : "Enable") {
            let manager = appState.featureManager
            Task {
                await manager.enableNow(Self.featureID) {
                    try await DaemonManager.restart()
                }
            }
        }
        .disabled(appState.featureManager.isApplying)
    }

    // MARK: - Consent

    @ViewBuilder
    private func consentContent(_ vm: ConfluenceSpacesViewModel) -> some View {
        Text("Watchtower can't read Confluence on this site yet. Signing in again asks Atlassian for read access to Confluence.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let message = vm.consentMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        if let error = vm.reconsentError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        Button("Grant Confluence access") {
            vm.reconsent()
        }
        .disabled(vm.isReconsenting || appState.jiraAccountsViewModel?.isConnecting == true)
    }

    // MARK: - Spaces

    @ViewBuilder
    private func spacesContent(_ vm: ConfluenceSpacesViewModel) -> some View {
        if vm.spaces.isEmpty {
            if vm.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if vm.errorMessage == nil {
                Text("No Confluence spaces found on this site.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            TextField("Search spaces", text: $search)
                .textFieldStyle(.roundedBorder)
            let rows = filtered(vm.spaces)
            if rows.isEmpty {
                Text("No spaces match “\(search)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                spaceRow(row, vm: vm)
            }
        }
        if let error = vm.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        editingContent(vm)
        Button("Reload") {
            Task { await vm.load() }
        }
        .disabled(vm.isLoading)
        .confirmationDialog(
            "Stop syncing \(pendingUnselect?.name ?? "this space")?",
            isPresented: Binding(
                get: { pendingUnselect != nil },
                set: { if !$0 { pendingUnselect = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop Syncing", role: .destructive) {
                if let row = pendingUnselect {
                    Task { await vm.setSelected(row.key, false) }
                }
                pendingUnselect = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its synced pages, comments and attachment text are removed from Watchtower and leave search on the next index cycle.")
        }
    }

    // MARK: - Editing

    /// Page editing from the chat (spec 2026-09-30 §2): "Allow editing" when
    /// the grant reads Confluence but cannot write it; a note once it can.
    @ViewBuilder
    private func editingContent(_ vm: ConfluenceSpacesViewModel) -> some View {
        if vm.showsAllowEditing {
            Text(
                "The assistant can read this site's pages but not edit them. Allowing editing signs in again "
                    + "and asks Atlassian for write access; every edit still waits for your Approve."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = vm.reconsentError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Button("Allow editing") {
                vm.allowEditing()
            }
            .disabled(vm.isReconsenting || appState.jiraAccountsViewModel?.isConnecting == true)
        } else if vm.canEdit {
            Text("The assistant can propose page edits in chat; each one waits for your Approve.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spaceRow(_ row: ConfluenceSpacesViewModel.SpaceRow, vm: ConfluenceSpacesViewModel) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                Text(row.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.selected {
                    Text(row.statusLine())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !row.error.isEmpty {
                        Text(row.error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
            Toggle("Sync", isOn: Binding(
                get: { row.selected },
                set: { on in
                    if on {
                        Task { await vm.setSelected(row.key, true) }
                    } else {
                        pendingUnselect = row
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(vm.busyKeys.contains(row.key))
        }
    }

    private func filtered(_ rows: [ConfluenceSpacesViewModel.SpaceRow]) -> [ConfluenceSpacesViewModel.SpaceRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query)
        }
    }
}

import SwiftUI
import WatchtowerCore

/// Google detail pane in the Connections tab — the multi-account Calendar/Gmail
/// connections (`google_accounts` table) plus the global Calendar/Gmail sync
/// toggles, which apply across every connected Google account.
struct GoogleConnectionDetail: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    @State private var saveError: String?
    @State private var showAddGoogleAccountSheet = false
    @State private var googleAccountPendingRemoval: GoogleAccount?

    var body: some View {
        Form {
            googleAccountsSection
            calendarSettingsSection
            gmailSettingsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Google Accounts section — the multi-account Calendar/Gmail
    /// connections (`google_accounts` table), each independently granting
    /// Calendar and/or Gmail access via its own OAuth consent.
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

    /// Global calendar-sync toggles only — connect/disconnect for individual
    /// Google accounts lives in `googleAccountsSection` above, since a
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

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Global Gmail-sync toggle only — connect/disconnect for individual
    /// Google accounts lives in `googleAccountsSection` above, since a
    /// workspace can have more than one Google account granting Gmail access.
    private var gmailSettingsSection: some View {
        Section("Gmail") {
            Toggle("Enable Gmail sync", isOn: $config.gmailEnabled)
                .onChange(of: config.gmailEnabled) { _, _ in saveConfig() }

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func saveConfig() {
        do {
            try config.save()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

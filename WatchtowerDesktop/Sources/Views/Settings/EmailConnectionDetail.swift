import SwiftUI
import WatchtowerCore

/// Email detail pane in the Connections tab — the multi-account IMAP/Outlook
/// connections, distinct from Gmail's single-account Google connections.
/// Each row is a DB row (`email_accounts`), not a token file, so status can be
/// ok/error/revoked per account rather than a single connected/disconnected flag.
struct EmailConnectionDetail: View {
    @Environment(AppState.self) private var appState
    @State private var showAddEmailAccountSheet = false
    @State private var accountPendingRemoval: EmailAccount?

    var body: some View {
        Form {
            emailAccountsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
    }

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
}

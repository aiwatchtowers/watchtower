import DesignKit
import SwiftUI
import WatchtowerCore

/// Email detail pane in the Connections tab — the multi-account IMAP/Outlook
/// connections, distinct from Gmail's single-account Google connections.
/// Each row is a DB row (`email_accounts`), not a token file, so status can be
/// ok/error/revoked per account rather than a single connected/disconnected flag.
/// Outlook accounts are grouped by company (company screens spec §4.2: a
/// company's Microsoft 365 app, Watchtower's Microsoft app, other accounts);
/// IMAP mailboxes sign in with a password and keep their own section.
struct EmailConnectionDetail: View {
    @Environment(AppState.self) private var appState
    /// A Not connected row's Connect: that vendor's login through the company's app.
    private var groupConnect: CompanyGroupConnect {
        CompanyGroupConnect(disabled: sourceBlocked || appState.companyFlowBusy) { slug, vendor in
            appState.reloginCompany(slug: slug, vendors: [vendor])
        }
    }

    /// The organization's policy forbids this source (#608): nothing new
    /// connects; existing accounts keep their data.
    private var sourceBlocked: Bool { !appState.managedPolicy.policy.sourceAllowed("imap") }
    @State private var showAddEmailAccountSheet = false
    @State private var accountPendingRemoval: EmailAccount?
    @State private var accountBeingRenamed: AccountRenameTarget?

    static let accountsTitle = "Email Accounts"
    static let imapTitle = "IMAP mailboxes"
    static let noAccounts = "No IMAP or Outlook accounts connected."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                if let vm = appState.emailAccountsViewModel {
                    accounts(vm)
                } else {
                    SettingsSection(title: Self.accountsTitle) {
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
        .sheet(isPresented: $showAddEmailAccountSheet) {
            AddEmailAccountView()
                .environment(appState)
                .marksAccountSheet(appState)
        }
        .accountRenameAlert($accountBeingRenamed) { target, name in
            Task { await appState.emailAccountsViewModel?.rename(accountID: target.id, to: name) }
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

    @ViewBuilder
    private func accounts(_ vm: EmailAccountsViewModel) -> some View {
        let groups = appState.companyAccountGroups(.microsoft)
        let imap = vm.accounts.filter { !$0.isOutlook }
        if groups.isEmpty, imap.isEmpty {
            SettingsSection(title: Self.accountsTitle) {
                Text(Self.noAccounts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        CompanyAccountGroups(groups: groups, connect: groupConnect) { ref in
            if let account = vm.accounts.first(where: { $0.id == ref.accountID }) {
                row(vm, account: account, status: appState.companyRowStatus(ref))
            }
        }
        if !imap.isEmpty {
            SettingsSection(title: Self.imapTitle) {
                ForEach(imap) { account in row(vm, account: account, status: nil) }
            }
        }
        SettingsSection(title: CompanyConnectionsPresentation.addAccountTitle) {
            if let err = vm.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
            }
            Button("Add Account") {
                showAddEmailAccountSheet = true
            }
            .buttonStyle(.kitSecondary)
            .managedByOrganization(sourceBlocked)
        }
    }

    private func row(_ vm: EmailAccountsViewModel, account: EmailAccount, status: RowStatus?) -> some View {
        CompanyAccountRow(
            title: account.displayName,
            status: status,
            line: account.isOutlook ? "Outlook" : "IMAP \u{00B7} \(account.host)",
            dot: emailAccountStatusColor(account),
            extra: account.isStoppedForCleartext
                ? AnyView(Text(CleartextRefusal.mailStopped)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true))
                : nil
        ) {
            if let action = status?.action {
                CompanyRowStatusButton(action: action, disabled: sourceBlocked || appState.companyFlowBusy) { action in
                    if action == .relogin, !account.companySlug.isEmpty {
                        appState.reloginCompany(slug: account.companySlug, vendors: [.microsoft])
                    } else {
                        appState.pasteCompanyCode()
                    }
                }
            }
            Button("Rename…") {
                accountBeingRenamed = AccountRenameTarget(id: account.id, currentName: account.displayName)
            }
            .buttonStyle(.kitQuiet)
            .disabled(vm.isRunning)
            Button("Remove") {
                accountPendingRemoval = account
            }
            .buttonStyle(.kitQuiet)
            .foregroundStyle(Tone.error)
        }
    }

    private func emailAccountStatusColor(_ account: EmailAccount) -> Color {
        if account.isOK { return Tone.success }
        if account.isRevoked { return Tone.warning }
        return Tone.error
    }
}

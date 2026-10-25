import SwiftUI
import WatchtowerCore

/// Settings → System → Privacy (board #601): the purge on revoked access
/// switch. The shown value is the owner's unsaved or saved choice, else the
/// effective one Go reports (`accounts purges --json`: policy > setting >
/// build default); Save writes `privacy.purge_revoked_data` through
/// `ConfigSaveBar`.
struct PrivacySettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService

    @ViewBuilder var body: some View {
        PrivacySettingsContent(
            isOn: Binding(
                get: { config.purgeRevokedData ?? appState.accountPurgeCenter?.status?.enabled ?? false },
                set: { config.purgeRevokedData = $0 }
            ),
            status: appState.accountPurgeCenter?.status,
            statusError: appState.accountPurgeCenter?.statusError
        )
        .task { await appState.accountPurgeCenter?.reloadStatus() }
        OrganizationPolicySection(policy: appState.managedPolicy.policy)
    }
}

/// Environment-free half (the `DaemonSettingsContent` split, for ViewInspector).
struct PrivacySettingsContent: View {
    @Binding var isOn: Bool
    let status: AccountPurgeStatus?
    let statusError: String?

    var body: some View {
        Section {
            SettingRow(title: "Delete an account's data when its access is revoked", caption: caption) {
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .disabled(status?.isSetByPolicy ?? false)
            }
            Text(Self.footnote(status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Privacy")
        }
    }

    private var caption: String? {
        if status?.isSetByPolicy == true { return "Set by your organisation" }
        return statusError
    }

    /// The grace and lease numbers come from Go; the defaults stand in until it answers.
    static func footnote(_ status: AccountPurgeStatus?) -> String {
        let grace = status?.graceHours ?? 72
        let lease = status?.leaseDays ?? 30
        return "When a company revokes your access, or Watchtower has not reached a source for \(lease) days, "
            + "the account's synced messages, mail, events and issues are deleted \(grace) hours later "
            + "unless you reconnect. A removed account's data goes the same way \(lease) days after it was last reached. "
            + "Briefings, recaps, ideas, memory, chats and meeting transcripts are kept."
    }
}

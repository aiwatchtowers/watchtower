import SwiftUI
import WatchtowerCore

/// Settings → System → Privacy (board #601): the purge on revoked access
/// switch. The shown value is the owner's unsaved or saved choice, else the
/// effective one Go reports (`accounts purges --json`), else off
/// (`AccountPurgeStatus.shownValue`); Save writes `privacy.purge_revoked_data` through
/// `ConfigSaveBar`.
struct PrivacySettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService

    @ViewBuilder var body: some View {
        let policy = appState.managedPolicy.policy.purgeRevokedData
        let status = appState.accountPurgeCenter?.status
        PrivacySettingsContent(
            isOn: Binding(
                // A forced PurgeRevokedData (#608) shows its value; the
                // owner's stored setting is kept, outvoted.
                get: {
                    AccountPurgeStatus.shownValue(policy: policy, setting: config.purgeRevokedData, status: status)
                },
                set: { config.purgeRevokedData = $0 }
            ),
            lockedByPolicy: appState.managedPolicy.policy.isLocked(.purgeRevokedData),
            status: status,
            statusError: appState.accountPurgeCenter?.statusError,
            policy: appState.managedPolicy.policy,
            origin: AccountPurgeStatus.shownOrigin(policy: policy, setting: config.purgeRevokedData, status: status)
        )
        .task { await appState.accountPurgeCenter?.reloadStatus() }
        Section { FileVaultLine() }
        OrganizationPolicySection(policy: appState.managedPolicy.policy)
    }
}

/// Environment-free half (the `DaemonSettingsContent` split, for ViewInspector).
struct PrivacySettingsContent: View {
    @Binding var isOn: Bool
    var lockedByPolicy = false
    let status: AccountPurgeStatus?
    let statusError: String?
    /// The organization's policy: its PurgeGraceHours sets the footnote's notice.
    var policy: ManagedPolicy = .none
    /// Where the shown value comes from (`AccountPurgeStatus.shownOrigin`);
    /// nil: the CLI status's origin.
    var origin: String?

    var body: some View {
        Section {
            SettingRow(title: AccountPurgeStatus.switchTitle, caption: caption) {
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .managedByOrganization(lockedByPolicy || (status?.isSetByPolicy ?? false))
            }
            Text(AccountPurgeStatus.footnote(status, policy: policy, shown: isOn))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Privacy")
        }
    }

    /// A failed status read wins (the owner should see it); else "Off by
    /// default" while off by its default origin.
    private var caption: String? {
        statusError ?? AccountPurgeStatus.caption(status, shown: isOn, origin: origin)
    }
}

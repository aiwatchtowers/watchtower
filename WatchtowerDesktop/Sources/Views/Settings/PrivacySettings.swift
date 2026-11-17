import SwiftUI
import WatchtowerCore

/// Settings → System → Privacy (board #601): the purge on revoked access
/// switch. The shown value is the owner's unsaved or saved choice, else the
/// effective one Go reports (`accounts purges --json`), else on
/// (`AccountPurgeStatus.shownValue`, #1769); Save writes `privacy.purge_revoked_data` through
/// `ConfigSaveBar`.
struct PrivacySettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService

    @ViewBuilder var body: some View {
        PrivacySettingsContent(
            isOn: Binding(
                // A forced PurgeRevokedData (#608) shows its value; the
                // owner's stored setting is kept, outvoted.
                get: {
                    AccountPurgeStatus.shownValue(
                        policy: appState.managedPolicy.policy.purgeRevokedData,
                        setting: config.purgeRevokedData,
                        status: appState.accountPurgeCenter?.status)
                },
                set: { config.purgeRevokedData = $0 }
            ),
            lockedByPolicy: appState.managedPolicy.policy.isLocked(.purgeRevokedData),
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
    var lockedByPolicy = false
    let status: AccountPurgeStatus?
    let statusError: String?

    var body: some View {
        Section {
            SettingRow(title: AccountPurgeStatus.switchTitle, caption: caption) {
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .managedByOrganization(lockedByPolicy || (status?.isSetByPolicy ?? false))
            }
            Text(AccountPurgeStatus.footnote(status, shown: isOn))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Privacy")
        }
    }

    /// "On by default" while on by its default origin; otherwise a failed
    /// status read, if any.
    private var caption: String? {
        AccountPurgeStatus.caption(status, shown: isOn) ?? statusError
    }
}

import SwiftUI
import WatchtowerCore

/// Settings → System → Privacy → Organization policy (#608): what the
/// company's configuration profile forces, in plain words. Shown only while a
/// profile is installed.
struct OrganizationPolicySection: View {
    let policy: ManagedPolicy

    var body: some View {
        if policy.managed {
            Section {
                ForEach(OrganizationPolicyPresentation.lines(policy), id: \.label) { line in
                    SettingRow(title: line.label) {
                        Text(line.value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                ManagedByOrganizationBadge()
            } header: {
                Text("Organization policy")
            } footer: {
                Text("Your organization sets these through a configuration profile. They outvote your own settings, "
                    + "which come back when the profile is removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

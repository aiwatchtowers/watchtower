import SwiftUI
import WatchtowerCore

/// Settings → System → Privacy → Organization policy (#608): what the
/// company's configuration profile forces, in plain words, then the IT guide
/// row (D21). Shown only while a profile is installed.
struct OrganizationPolicySection: View {
    static let title = "Organization policy"
    static let footer = "Your organization sets these through a configuration profile. They outvote your own settings, "
        + "which come back when the profile is removed."

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
                SettingRow(title: ManagedPolicyHelp.rowTitle, caption: ManagedPolicyHelp.rowCaption) {
                    ITGuideLink()
                }
                ManagedByOrganizationBadge()
            } header: {
                Text(Self.title)
            } footer: {
                Text(Self.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// **What IT can set**, opening the IT guide (D21) in the browser.
struct ITGuideLink: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(ManagedPolicyHelp.label) { openURL(ManagedPolicyHelp.itGuideURL) }
            .buttonStyle(.kitQuiet)
    }
}

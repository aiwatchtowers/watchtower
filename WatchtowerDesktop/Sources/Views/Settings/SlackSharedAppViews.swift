import SwiftUI
import WatchtowerCore
import DesignKit

/// The banner at the top of Connections → Slack while an account syncs
/// through Watchtower's retired shared Slack app (screens spec §5). Strings
/// from `SlackModePresentation.SharedAppBanner`; no dismiss.
struct SlackSharedAppBanner: View {
    let banner: SlackModePresentation.SharedAppBanner
    /// The organization's policy forbids the Slack source (#608).
    var blocked = false
    let setUpForCompany: () -> Void
    let pasteLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Tone.warning)
                Text(banner.title).font(.headline)
            }
            Text(banner.body).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                Button(banner.setUpForCompany, action: setUpForCompany)
                    .buttonStyle(.kitSecondary)
                    .managedByOrganization(blocked)
                Button(banner.pasteLink, action: pasteLink)
                    .buttonStyle(.kitQuiet)
                    .managedByOrganization(blocked)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }
}

/// A Slack workspace row's left side: the name (with the **Shared app** tag
/// on the retired app), the domain, the shared-app line and a sync note.
struct SlackAccountTitle: View {
    let account: SlackAccount
    /// "Syncing through the shared app · …" for an account on the retired
    /// app; nil for any other.
    var sharedAppLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.regular) {
                Text(account.displayName)
                if sharedAppLine != nil { OutlineTag(text: SlackModePresentation.sharedAppTag) }
            }
            if !account.teamDomain.isEmpty {
                Text("\(account.teamDomain).slack.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let sharedAppLine {
                Text(sharedAppLine).font(.caption).foregroundStyle(.secondary)
            }
            if let note = account.syncNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Under the Workspaces list: **Add Slack Workspace** while the build has
/// its own Slack app, and in Full **Connect another workspace…**, which opens
/// the folded connect section (plan B A8).
struct SlackWorkspacesAddRow: View {
    /// nil: no connect flow (the listener did not start): Add only.
    let section: SlackModePresentation.ConnectSection?
    var blocked = false
    var addDisabled = false
    let add: () -> Void
    let openFold: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            if section?.showsAddAccount ?? true {
                Button("Add Slack Workspace", action: add)
                    .buttonStyle(.kitSecondary)
                    .managedByOrganization(blocked)
                    .disabled(addDisabled)
            }
            if let section, section.showsFoldButton, section.isFolded {
                Button(section.foldButton, action: openFold)
                    .buttonStyle(.kitQuiet)
            }
        }
    }
}

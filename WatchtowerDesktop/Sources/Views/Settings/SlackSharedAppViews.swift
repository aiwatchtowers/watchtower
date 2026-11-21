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
    /// nil (no connect flow: the listener did not start) hides the button.
    let pasteLink: (() -> Void)?

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
                if let pasteLink {
                    Button(banner.pasteLink, action: pasteLink)
                        .buttonStyle(.kitQuiet)
                        .managedByOrganization(blocked)
                }
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
    /// Accounts Go reports on the retired shared app.
    var sharedAppAccountIDs: Set<Int> = []
    var lastSync: Date?
    /// A fixed clock for the shots; nil re-reads it every minute.
    var now: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.regular) {
                Text(account.displayName)
                if SlackModePresentation.showsSharedAppTag(account, sharedAppAccountIDs: sharedAppAccountIDs) {
                    OutlineTag(text: SlackModePresentation.sharedAppTag)
                }
            }
            if !account.teamDomain.isEmpty {
                Text("\(account.teamDomain).slack.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if SlackModePresentation.showsSharedAppLine(account, sharedAppAccountIDs: sharedAppAccountIDs) {
                TimelineView(.everyMinute) { context in
                    Text(SlackModePresentation.sharedAppAccountLine(lastSync: lastSync, now: now ?? context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    /// The connect assistant's **Connect with <harness>** (agent connect
    /// spec §7), first and only where a manual add path is offered: the
    /// agent offers no more than the manual path. It waits while a sign-in
    /// runs.
    var agent: (harness: ConnectHarness, open: () -> Void)?
    let add: () -> Void
    let openFold: () -> Void

    /// A manual way to add a workspace is on screen: **Add Slack
    /// Workspace** (a build with its own app), or Full's connect section
    /// (**Connect another workspace…**, folded or open) — the code/link
    /// flow the assistant's Slack driver also runs.
    var offersManualAdd: Bool {
        guard let section else { return true }
        return section.showsAddAccount || section.showsFoldButton
    }

    var body: some View {
        HStack(spacing: Spacing.regular) {
            if offersManualAdd, let agent {
                ConnectAgentButton(title: ConnectAssistantPresentation.connectWith(agent.harness), action: agent.open)
                    .disabled(addDisabled)
            }
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

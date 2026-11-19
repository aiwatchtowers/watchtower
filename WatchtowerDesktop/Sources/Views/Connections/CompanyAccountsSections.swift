import DesignKit
import SwiftUI
import WatchtowerCore

/// The accounts half of the Google and Jira details (company screens spec
/// §4.2, §5.3, §6.4, §7): the retirement banner, then the list — loading,
/// read failed with **Try again**, the empty state with its buttons, or the
/// company groups followed by **Add an account**. Every string and button
/// comes from `CompanyConnectionsPresentation`; the detail draws its rows.
struct CompanyAccountsSections<Row: View>: View {
    let vendor: CompanyVendor
    let banner: CompanyBanner?
    let list: AccountsListState
    let emptyActions: [DetailAction]
    let addActions: [DetailAction]
    let connect: CompanyGroupConnect
    /// The organization's policy forbids the source (#608).
    var blocked = false
    /// A sign-in or command of the detail runs: its buttons wait.
    var busy = false
    /// The last command's failure, under the buttons.
    var error: String?
    let perform: (DetailAction.Kind) -> Void
    let bannerAction: (CompanyBanner.Action) -> Void
    let tryAgain: () -> Void
    @ViewBuilder let row: (AccountRef) -> Row

    var body: some View {
        if let banner {
            CompanyBannerView(banner: banner, blocked: blocked, perform: bannerAction)
        }
        switch list {
        case .loading(let text):
            SettingsSection(title: CompanyConnectionsPresentation.accountsTitle) {
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .readFailed(let text):
            SettingsSection(title: CompanyConnectionsPresentation.accountsTitle) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(CompanyConnectionsPresentation.tryAgain, action: tryAgain)
                    .buttonStyle(.kitSecondary)
            }
        case .empty(let text):
            SettingsSection(title: vendor == .google ? CompanyConnectionsPresentation.googleTitle
                                : CompanyConnectionsPresentation.jiraTitle) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                buttons(emptyActions)
            }
        case .groups(let groups):
            CompanyAccountGroups(groups: groups, connect: connect, row: row)
            SettingsSection(title: CompanyConnectionsPresentation.addAccountTitle) {
                buttons(addActions)
            }
        }
    }

    @ViewBuilder
    private func buttons(_ actions: [DetailAction]) -> some View {
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(Tone.error)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.regular) { buttonRow(actions) }
            VStack(alignment: .leading, spacing: Spacing.regular) { buttonRow(actions) }
        }
    }

    @ViewBuilder
    private func buttonRow(_ actions: [DetailAction]) -> some View {
        ForEach(actions) { action in
            DetailActionButton(action: action, disabled: busy, blocked: blocked) { perform(action.kind) }
        }
        if busy { ProgressView().controlSize(.small) }
    }
}

/// One empty-state or add-section button in its emphasis.
private struct DetailActionButton: View {
    let action: DetailAction
    let disabled: Bool
    let blocked: Bool
    let run: () -> Void

    var body: some View {
        let button = Button(action.title, action: run)
        Group {
            switch action.emphasis {
            case .prominent: button.buttonStyle(.kitPrimary)
            case .secondary: button.buttonStyle(.kitSecondary)
            case .quiet: button.buttonStyle(.kitQuiet)
            }
        }
        .managedByOrganization(blocked)
        .disabled(disabled)
    }
}

/// §7's retirement banner: `Tone.warning` tint, no dismiss, never an
/// attention item (the overview card's line names it instead).
struct CompanyBannerView: View {
    let banner: CompanyBanner
    var blocked = false
    let perform: (CompanyBanner.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Tone.warning)
                Text(banner.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            Text(banner.body).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                ForEach(banner.actions, id: \.self) { action in
                    let button = Button(action.title) { perform(action) }
                    Group {
                        if action.isQuiet { button.buttonStyle(.kitQuiet) } else { button.buttonStyle(.kitSecondary) }
                    }
                    .managedByOrganization(blocked)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }
}

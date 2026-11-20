import DesignKit
import SwiftUI
import WatchtowerCore

/// A service detail's accounts split by company (company screens spec
/// §4.2): one `SettingsSection` per `AccountGroup` in the presentation's
/// order, an empty group left out. The detail draws its own account rows;
/// a stored company's vendor with no account is a **Not connected** row
/// whose **Connect** runs that vendor's login with the company's client.
struct CompanyAccountGroups<Row: View>: View {
    let groups: [AccountGroup]
    let connect: CompanyGroupConnect
    /// The policy locks in force: a locked group ends with its lock card (§5.4, §6.5).
    var locks: Set<LockKey> = []
    @ViewBuilder let row: (AccountRef) -> Row

    var body: some View {
        ForEach(groups) { group in
            SettingsSection(title: group.title, caption: group.caption) {
                rows(group)
                if let key = group.kind.lockKey, locks.contains(key) {
                    CompanyLockCard(card: CompanyConnectionsPresentation.lockCard(key))
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ group: AccountGroup) -> some View {
        ForEach(group.rows) { item in
            switch item {
            case .account(let account):
                row(account)
            case .notConnected(let vendor):
                CompanyAccountRow(
                    title: CompanyConnectionsPresentation.serviceName(vendor),
                    status: CompanyConnectionsPresentation.notConnectedStatus
                ) {
                    Button(RowStatus.Action.connect.title) {
                        if case .company(let slug) = group.kind { connect.run(slug, vendor) }
                    }
                    .buttonStyle(.kitSecondary)
                    .disabled(connect.disabled)
                }
            }
        }
    }
}

/// A policy lock under its group (§5.4, §6.5): the card, **What IT can
/// set** and **Managed by your organization**.
struct CompanyLockCard: View {
    let card: LockCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            WizardNotice(icon: "lock.fill", tone: Tone.status("gray"), text: card.text)
            Button(card.helpLabel) { openURL(card.helpURL) }.buttonStyle(.kitQuiet)
            ManagedByOrganizationBadge()
        }
    }
}

/// A Not connected row's **Connect**: runs with the group's company slug
/// and the vendor; off while a flow runs or the source is blocked.
struct CompanyGroupConnect {
    var disabled = false
    let run: (String, CompanyVendor) -> Void
}

/// One account row of a grouped detail: the state dot, the name with its
/// outline tag, the status line (a §4.3 status in its tone, else the
/// detail's own line), an optional note, and the detail's controls.
struct CompanyAccountRow<Trailing: View>: View {
    let title: String
    var tag: String?
    /// A §4.3 status; nil shows `line` in secondary under a dot of `dot`.
    var status: RowStatus?
    var line: String?
    var dot: Color = Tone.success
    /// Lines under the status (the detail's own: an error, a purge line).
    var extra: AnyView?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Circle().fill(dotColor).frame(width: IconSize.stateDot, height: IconSize.stateDot)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.small) {
                    Text(title).font(.callout)
                    if let tag { OutlineTag(text: tag) }
                }
                if let text = status?.text ?? line {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(lineStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = status?.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let extra { extra }
            }
            Spacer(minLength: Spacing.regular)
            trailing()
        }
        .padding(.vertical, Spacing.small)
    }

    private var dotColor: Color {
        guard let status else { return dot }
        return switch status.tone {
        case .error: Tone.error
        case .gray: Tone.status("gray")
        case .secondary: dot
        }
    }

    private var lineStyle: AnyShapeStyle {
        status?.tone == .error ? AnyShapeStyle(Tone.error) : AnyShapeStyle(.secondary)
    }
}

/// A §4.3 status's own action button (**Re-login**, **Paste a company code**, …).
struct CompanyRowStatusButton: View {
    let action: RowStatus.Action
    var disabled = false
    let perform: (RowStatus.Action) -> Void

    var body: some View {
        let button = Button(action.title) { perform(action) }.disabled(disabled)
        switch action {
        case .relogin, .pasteNewToken: button.buttonStyle(.kitPrimary)
        case .pasteCode, .connect: button.buttonStyle(.kitSecondary)
        }
    }
}

import SwiftUI
import WatchtowerCore
import DesignKit

/// The connect flow's sheet (screens spec §4.3): the confirm of a clicked
/// link, the browser wait, the result. Every string comes from
/// `SlackConnectSheetContent` (`SlackConnectFlowModel.sheet`); this view only
/// lays it out and hands each button's action back.
struct SlackConnectSheet: View {
    let content: SlackConnectSheetContent
    /// The browser step's "Waiting for Slack since …" (past 5 min), or nil.
    var waitingLine: String?
    /// The confirm's Connect is off while another sign-in runs.
    var connectEnabled = true
    let perform: (SlackConnectSheetContent.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            if let title = content.title, content.icon == nil {
                Text(title).font(.title3.weight(.semibold))
            }
            message
            if let disclosure = content.disclosure { disclosureLine(disclosure) }
            HStack(spacing: Spacing.regular) {
                Spacer()
                ForEach(content.buttons, id: \.action) { button in
                    if button.isPrimary {
                        Button(button.title) { perform(button.action) }
                            .buttonStyle(.kitPrimary)
                            .keyboardShortcut(.defaultAction)
                            .disabled(button.action == .connect && !connectEnabled)
                    } else {
                        Button(button.title) { perform(button.action) }
                            .buttonStyle(.kitSecondary)
                            .keyboardShortcut(button.action == .cancel ? .cancelAction : nil)
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    @ViewBuilder private var message: some View {
        if let icon = content.icon {
            HStack(alignment: .top, spacing: Spacing.regular) {
                iconView(icon)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    if let title = content.title { Text(title).font(.headline) }
                    Text(content.body).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let note = content.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let waitingLine {
                        Text(waitingLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text(content.body).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func iconView(_ icon: SlackConnectSheetContent.Icon) -> some View {
        switch icon {
        case .progress: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
        case .denied: Image(systemName: "xmark.circle").foregroundStyle(Tone.status("gray"))
        }
    }

    private func disclosureLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let link = content.privacyLink {
                    Link(link, destination: content.privacyURL).font(.caption)
                }
            }
        }
    }
}

/// Connections → Slack, **Connect your workspace's app** (screens spec §4.2,
/// §4.4): the MDM rows, the port-busy line, the link-or-code field and the
/// setup entry. Strings from `SlackModePresentation.ConnectSection` and
/// `SlackConnectFlowModel`.
struct SlackConnectSection: View {
    let section: SlackModePresentation.ConnectSection
    @Bindable var flow: SlackConnectFlowModel
    /// The organization's policy forbids the Slack source (#608).
    var blocked = false
    /// Opens the company setup (Task 13); nil hides its line.
    var setUpForCompany: (() -> Void)?
    @FocusState.Binding var fieldFocused: Bool

    var body: some View {
        SettingsSection(title: section.title, caption: section.caption) {
            SlackConnectFields(section: section, flow: flow, blocked: blocked, setUpForCompany: setUpForCompany,
                               fieldFocused: $fieldFocused)
        }
    }
}

/// The connect section's rows without its header: Connections → Slack puts
/// them in a `SettingsSection`, onboarding's Slack sheet in a card (A13).
struct SlackConnectFields: View {
    let section: SlackModePresentation.ConnectSection
    @Bindable var flow: SlackConnectFlowModel
    var blocked = false
    var setUpForCompany: (() -> Void)?
    @FocusState.Binding var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            disclosureLine
            if !section.organizationRows.isEmpty { organizationRows }
            if let busy = section.portBusyLine {
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                    Text(busy).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Spacing.regular) {
                TextField(section.fieldPlaceholder, text: $flow.pasteText)
                    .textFieldStyle(.kit)
                    .focused($fieldFocused)
                    .onSubmit { flow.connectPasted() }
                Button(section.connect) { flow.connectPasted() }
                    .buttonStyle(.kitSecondary)
                    .disabled(flow.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !flow.canStart)
                    .managedByOrganization(blocked)
            }
            if let error = flow.pasteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let setUpForCompany {
                HStack(spacing: Spacing.regular) {
                    Text(section.noAppYet).font(.caption).foregroundStyle(.secondary)
                    Button(section.setUpForCompany, action: setUpForCompany)
                        .buttonStyle(.kitQuiet)
                        .managedByOrganization(blocked)
                }
            }
        }
    }

    /// What connecting means for the workspace's data, above every way to
    /// connect here (paste, MDM rows; Reconnect and Start again land here too).
    private var disclosureLine: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(section.disclosure).font(.caption).fixedSize(horizontal: false, vertical: true)
                Link(section.privacyLink, destination: section.privacyURL).font(.caption)
            }
        }
    }

    private var organizationRows: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(section.organizationTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(section.organizationRows) { row in
                HStack {
                    Label(row.title, systemImage: "building.2").font(.callout)
                    Spacer(minLength: Spacing.medium)
                    Button(section.connect) { flow.start(row.target) }
                        .buttonStyle(.kitPrimary)
                        .disabled(!flow.canStart)
                        .managedByOrganization(blocked)
                }
            }
        }
    }
}

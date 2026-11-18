import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore

/// **Set up for my company** (screens spec §3.2–§3.3): the token form with
/// the Slack data disclosure above it, the steps while a run goes, and the
/// outcome. Every string and every choice comes from `SlackAppSetupModel`;
/// the run lives there (on `AppState`), so closing this sheet keeps it going.
struct SlackAppSetupSheet: View {
    let model: SlackAppSetupModel
    /// The pasted configuration token; handed to the model per run.
    @State private var token: String
    @State private var appID = ""
    @State private var clientID = ""
    @Environment(\.openURL) private var openURL

    /// `token` pre-fills the field (the design shots only).
    init(model: SlackAppSetupModel, token: String = "") {
        self.model = model
        _token = State(initialValue: token)
    }

    private typealias Model = SlackAppSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(model.title).font(.title3.weight(.semibold))
                Text(model.intro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.showsDisclosure { disclosure }
            if model.showsTokenForm { tokenForm }
            if model.showsProgress { progress }
            if let line = model.busyLine { busy(line) }
            if let notice = model.notice { noticeCard(notice) }
            if model.showsAppIDField { appIDField }
            if model.showsPendingFields { pendingFields }
            if model.adminNoteCopied {
                Text(Model.adminNoteCopiedLine).font(.caption).foregroundStyle(.secondary)
            }
            buttons
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    /// What Watchtower does with the workspace's data (#1769), above the token.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(SlackDisclosureCopy.setupTitle).font(.subheadline.weight(.semibold))
            ForEach(SlackDisclosureCopy.setupLines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(verbatim: "•").foregroundStyle(.secondary)
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(SlackDisclosureCopy.privacyLink) { openURL(SlackDisclosureCopy.privacyURL) }
                .buttonStyle(.kitQuiet)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Model.step1Title).font(.headline)
                Text(Model.step1Help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Model.openTokenPage) { openURL(Model.slackAppsURL) }.buttonStyle(.kitSecondary)
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Model.step2Title).font(.headline)
                SecureField(Model.tokenPlaceholder, text: $token)
                    .textFieldStyle(.kit)
                    .disabled(model.isRunning)
                Text(Model.tokenNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(model.steps) { step in
                HStack(spacing: Spacing.regular) {
                    mark(step.mark).frame(width: ListLayout.markColumn)
                    Text(step.label)
                        .font(.callout)
                        .foregroundStyle(step.mark == .waiting ? .secondary : .primary)
                }
            }
            Text(Model.progressCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private func mark(_ mark: Model.StepMark) -> some View {
        switch mark {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
        case .running: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Tone.warning)
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func busy(_ line: String) -> some View {
        HStack(spacing: Spacing.regular) {
            ProgressView().controlSize(.small)
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func noticeCard(_ notice: Model.Notice) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: notice.icon).foregroundStyle(notice.tone.color)
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let title = notice.title { Text(title).font(.headline) }
                Text(notice.body)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var appIDField: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            TextField(Model.appIDLabel, text: $appID).textFieldStyle(.kit)
            Text(Model.appIDHelp).font(.caption).foregroundStyle(.secondary)
            if let problem = model.appIDProblemLine {
                Text(problem).font(.caption).foregroundStyle(Tone.error)
            }
        }
    }

    private var pendingFields: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button(Model.openAppsPage) { openURL(Model.slackAppsURL) }.buttonStyle(.kitQuiet)
            TextField(Model.appIDLabel, text: $appID).textFieldStyle(.kit)
            TextField(Model.clientIDLabel, text: $clientID).textFieldStyle(.kit)
        }
    }

    private var buttons: some View {
        HStack(spacing: Spacing.regular) {
            Spacer()
            ForEach(model.actions) { button in
                actionButton(button)
                    .disabled(!model.isEnabled(button.action, token: token, appID: appID, clientID: clientID))
            }
        }
    }

    @ViewBuilder private func actionButton(_ button: Model.ActionButton) -> some View {
        if button.prominent {
            Button(button.label) { perform(button.action) }.buttonStyle(.kitPrimary)
        } else {
            Button(button.label) { perform(button.action) }.buttonStyle(.kitSecondary)
        }
    }

    private func perform(_ action: Model.Action) {
        var fields = Model.Fields(token: token, appID: appID, clientID: clientID)
        if let text = model.perform(action, fields: &fields) { copy(text) }
        token = fields.token
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Connections → Slack: one row per unfinished company setup (screens spec
/// §3.4), above the connect section. Its button reopens the sheet on that
/// setup (never a second create); the text and the choice are the model's.
struct SlackSetupRecordRows: View {
    let model: SlackAppSetupModel
    var blocked = false

    var body: some View {
        ForEach(model.recordRows) { row in
            HStack(alignment: .center, spacing: Spacing.medium) {
                Image(systemName: row.waiting ? "hourglass" : "wrench.and.screwdriver").foregroundStyle(Tone.warning)
                Text(row.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.medium)
                button(row)
                    .disabled(model.isRunning)
                    .managedByOrganization(blocked)
            }
            .padding(Spacing.medium)
            .card()
        }
    }

    private func button(_ row: SlackAppSetupModel.RecordRow) -> some View {
        // The row's one prominent action, the approval's Check again too (§3.4).
        Button(row.label) { model.open(row.record) }.buttonStyle(.kitPrimary)
    }
}

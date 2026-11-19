import DesignKit
import SwiftUI
import WatchtowerCore

/// Connect Jira with an API token (company screens spec §6.2): the guide,
/// the three fields, the check's busy or problem line, and the connected
/// summary; replace mode keeps the email and site read-only. Every string
/// comes from `AtlassianTokenFormModel`; this view lays it out and hands each
/// button back to the model.
struct AtlassianTokenSheet: View {
    @Bindable var model: AtlassianTokenFormModel
    @Environment(\.openURL) private var openURL

    private typealias Model = AtlassianTokenFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            header
            if case let .done(host, email) = model.phase {
                WizardNotice(icon: "checkmark.circle.fill", tone: Tone.success,
                             title: Model.connected(host, email), text: Model.doneBody)
            } else {
                form
            }
            buttons
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(model.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if let intro = model.intro { WizardCaption(intro) }
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(Model.step1).font(.callout.weight(.medium))
            WizardCaption(Model.step1Help)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.regular) { guideButtons }
                VStack(alignment: .leading, spacing: Spacing.regular) { guideButtons }
            }
        }
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(Model.step2).font(.callout.weight(.medium))
            field(Model.emailLabel, text: $model.email, editable: model.fieldsEditable)
            field(Model.siteLabel, text: $model.site, editable: model.fieldsEditable)
            WizardField(label: Model.tokenLabel, text: $model.token, secure: true, prompt: Model.tokenLabel)
                .disabled(model.isChecking)
        }
        if let busy = model.busyLine {
            WizardBusy(text: busy)
        } else if let problem = model.problemLine {
            WizardProblem(text: problem)
        } else if model.showsScopedHint {
            WizardCaption(Model.scopedHint)
        }
    }

    @ViewBuilder private var guideButtons: some View {
        Button(Model.openTokenPage) { openURL(Model.tokenPageURL) }.buttonStyle(.kitSecondary)
        Button(Model.copyScopes) { WizardPasteboard.copy(Model.scopes.joined(separator: " ")) }.buttonStyle(.kitQuiet)
    }

    private func field(_ label: String, text: Binding<String>, editable: Bool) -> some View {
        WizardField(label: label, text: text, prompt: label)
            .disabled(!editable || model.isChecking)
    }

    private var buttons: some View {
        HStack(spacing: Spacing.regular) {
            Spacer(minLength: Spacing.regular)
            if case .done = model.phase {
                Button(model.primaryTitle) { model.close() }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(Model.cancelTitle) { model.close() }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(model.primaryTitle) { Task { await model.submit() } }
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
        }
    }
}

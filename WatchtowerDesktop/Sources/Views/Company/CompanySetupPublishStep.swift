import AppKit
import SwiftUI
import WatchtowerCore

private typealias Model = CompanySetupWizardModel

/// **Publish** (company screens spec §2.10): the company name and the
/// summary, the token when Slack's is gone, the run's marks, and the done
/// state with the link, the code, the profile for IT and the IT guide.
struct CompanySetupPublishStep: View {
    @Bindable var model: CompanySetupWizardModel
    @Environment(\.openURL) private var openURL
    @State private var profileProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            switch model.publishState {
            case .running:
                WizardStepLines(lines: model.publishSteps.map { ($0.label, WizardMark($0.mark).kind) })
            case let .done(published):
                done(published)
            case .tokenExpired:
                WizardProblem(text: Model.publishTokenExpiredLine)
                tokenField
            case let .failed(line):
                summary
                WizardProblem(text: line)
                if model.publishShowsToken { tokenField }
            case .ready:
                ready
            }
        }
    }

    @ViewBuilder
    private var ready: some View {
        WizardField(label: Model.companyNameLabel, text: $model.publishName)
        WizardCaption(model.companyNameHelp)
        summary
        if let reason = model.publishBlockedReason {
            WizardProblem(text: reason)
        } else {
            WizardCaption(model.isActive(.slack) ? Model.publishCaption : Model.publishCaptionNoSlack)
        }
        if let refusal = model.publishRefusal { WizardProblem(text: refusal) }
        if model.publishShowsToken {
            WizardCaption(Model.publishNeedsTokenLine)
            tokenField
        }
    }

    private var summary: some View {
        let vendors = CompanyVendor.allCases
        let lines = model.publishSummary.enumerated().map { index, line in
            let mark: WizardMark.Kind = index < vendors.count && !model.isActive(vendors[index]) ? .skipped : .done
            return (title: line, mark: mark)
        }
        return WizardStepLines(lines: lines)
    }

    @ViewBuilder
    private var tokenField: some View {
        if let page = CompanyVendorGuide.guideLines(.slack).first?.link {
            Button(Model.openTokenPage) { openURL(page) }.buttonStyle(.kitSecondary)
        }
        WizardField(label: Model.tokenPlaceholder, text: $model.slackToken, secure: true)
    }

    @ViewBuilder
    private func done(_ published: Model.Published) -> some View {
        let company = model.publishName
        WizardNotice(icon: "checkmark.circle.fill", tone: Tone.success, title: Model.publishedTitle(company),
                     text: published.onSlackPage ? Model.publishedBody : Model.publishedNoSlack)
        VStack(alignment: .leading, spacing: Spacing.medium) {
            WizardValueRow(label: Model.linkLabel, value: published.link, button: Model.copyTitle) {
                WizardPasteboard.copy(published.link)
            }
            WizardValueRow(label: Model.codeLabel, value: published.code, button: Model.copyTitle) {
                WizardPasteboard.copy(published.code)
            }
            WizardValueRow(label: Model.profileLabel, value: Model.profileFileName(company), button: Model.saveProfile) {
                Task { await saveProfile(fileName: Model.profileFileName(company)) }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        if let left = model.publishDraftLeft { WizardProblem(text: left) }
        if let profileProblem { WizardProblem(text: profileProblem) }
        Button(ManagedPolicyHelp.label) { openURL(ManagedPolicyHelp.itGuideURL) }.buttonStyle(.kitQuiet)
    }

    /// **Save…**: `company profile` makes the file; a save panel places it.
    private func saveProfile(fileName: String) async {
        profileProblem = nil
        guard let data = await model.profile() else {
            profileProblem = Model.profileFailed
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            profileProblem = Model.profileSaveFailed(error.localizedDescription)
        }
    }
}

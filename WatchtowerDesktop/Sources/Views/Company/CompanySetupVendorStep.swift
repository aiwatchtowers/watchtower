import DesignKit
import SwiftUI
import WatchtowerCore

private typealias Model = CompanySetupWizardModel

/// One vendor step (company screens spec §2.4–§2.8): the existing-app fork
/// (looking, found, nothing found, We already have one), the guide and
/// fields of **Create new**, the Slack token form and its runs, the check's
/// line, Microsoft's admin consent and Atlassian's confirm checklist.
struct CompanySetupVendorStep: View {
    @Bindable var model: CompanySetupWizardModel
    let vendor: CompanyVendor
    /// The found row the primary button uses.
    @Binding var selection: Int
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if vendor == .slack {
                slack
            } else if showsOnlyTheCheck {
                checkContent
                // The values stay editable: an edit un-checks the step and brings the guide back (A28).
                fields
            } else {
                phaseContent
                checkContent
            }
            if model.needsCompanyName(vendor) {
                WizardField(label: Model.companyNameLabel, text: $model.publishName)
            }
        }
    }

    /// What is left once the check answered: Atlassian's settings checklist
    /// after the sign-in (§2.7), Microsoft's admin consent (§2.8).
    private var showsOnlyTheCheck: Bool {
        switch model.checks[vendor] {
        case .adminConsent?: true
        case .running?: false
        default: vendor == .atlassian && model.isChecked(.atlassian)
        }
    }

    // MARK: The existing-app fork (§2.4)

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase(vendor) {
        case .looking:
            WizardBusy(text: CompanyVendorGuide.looking(vendor))
        case .found:
            found
        case .nothingFound:
            nothingFound
        case .create:
            create
        case .existing:
            existing
        case .reuseSecret:
            reuseSecret
        case .noOrgAccess:
            noOrgAccess
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            WizardCaption(Model.foundTitle)
            VStack(alignment: .leading, spacing: Spacing.small) {
                ForEach(Array(model.candidates(for: vendor).enumerated()), id: \.offset) { index, candidate in
                    WizardChoice(title: candidate.label, detail: candidate.sourceLabel, selected: index == selection) {
                        selection = index
                    }
                }
            }
            WizardCaption(CompanyVendorGuide.reuseCaption(vendor))
        }
    }

    private var nothingFound: some View {
        let already = model.alreadyHaveSelected[vendor] ?? false
        return VStack(alignment: .leading, spacing: Spacing.medium) {
            if model.discoveryFailed {
                WizardProblem(text: Model.discoveryFailed)
            } else if let line = CompanyVendorGuide.notFound(vendor) {
                WizardCaption(line)
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                WizardChoice(title: Model.createNew, detail: Model.createNewDetail, selected: !already) {
                    model.alreadyHaveSelected[vendor] = false
                }
                WizardChoice(title: Model.alreadyHaveOne, detail: Model.alreadyHaveDetail, selected: already) {
                    model.alreadyHaveSelected[vendor] = true
                }
            }
            WizardCaption(CompanyVendorGuide.notSure(vendor))
        }
    }

    // MARK: Create new, We already have one

    @ViewBuilder
    private var create: some View {
        WizardGuide(vendor: vendor)
        if vendor == .google {
            Button(Model.noOrgLink) { model.showNoOrgAccess() }.buttonStyle(.kitQuiet)
            WizardDropZone(model: model)
        } else {
            fields
            if let note = CompanyVendorGuide.fieldsNote(vendor) { WizardCaption(note) }
        }
        WizardCaption(CompanyVendorGuide.adminNeeds(vendor))
    }

    @ViewBuilder
    private var existing: some View {
        if vendor == .google { WizardDropZone(model: model) }
        fields
        if let note = CompanyVendorGuide.fieldsNote(vendor) { WizardCaption(note) }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(CompanyVendorGuide.alreadyHaveFields(vendor)) { spec in
                WizardField(label: spec.label, text: binding(spec.key), secure: spec.secure)
            }
            if vendor == .atlassian {
                WizardField(label: Model.siteLabel, text: Binding(
                    get: { model.draft.atlassian?.site ?? "" },
                    set: { model.setAtlassianSite($0) }
                ), prompt: Model.sitePlaceholder)
            }
        }
    }

    private var reuseSecret: some View {
        let clientID = model.draft.google?.clientID ?? ""
        let chosen = model.candidates(for: vendor).first { $0.clientID == clientID }
        return VStack(alignment: .leading, spacing: Spacing.medium) {
            if let chosen {
                WizardChoice(title: chosen.label, detail: chosen.sourceLabel, selected: true) {}
            }
            WizardCaption(Model.reuseSecretBody)
            if let url = Model.clientURL(clientID) {
                Button(Model.openClient) { openURL(url) }.buttonStyle(.kitSecondary)
            }
            WizardField(label: CompanyVendorGuide.alreadyHaveFields(.google)[1].label, text: binding(.clientSecret), secure: true)
        }
    }

    private var noOrgAccess: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            WizardNotice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: Model.noOrgTitle,
                         text: Model.noOrgBody(domain: model.draft.google?.domain ?? ""))
            Button(Model.copyStepsForAdmin) { WizardPasteboard.copy(Model.adminSteps(.google)) }.buttonStyle(.kitSecondary)
            WizardDropZone(model: model)
        }
    }

    private func binding(_ key: CompanyFieldSpec.Key) -> Binding<String> {
        Binding(get: { value(key) }, set: { model.setField(vendor, key, $0) })
    }

    private func value(_ key: CompanyFieldSpec.Key) -> String {
        let draft = model.draft
        return switch (vendor, key) {
        case (.slack, .slackSettingsLink): model.slackSettingsLink
        case (.slack, .clientID): model.slackClientID
        case (.google, .clientID): draft.google?.clientID ?? ""
        case (.google, .clientSecret): draft.google?.clientSecret ?? ""
        case (.atlassian, .clientID): draft.atlassian?.clientID ?? ""
        case (.atlassian, .clientSecret): draft.atlassian?.clientSecret ?? ""
        case (.linear, .clientID): draft.linear?.clientID ?? ""
        case (.microsoft, .clientID): draft.microsoft?.clientID ?? ""
        case (.microsoft, .tenantID): draft.microsoft?.tenantID ?? ""
        default: ""
        }
    }

    // MARK: The check (§2.6–§2.8)

    @ViewBuilder
    private var checkContent: some View {
        switch model.checks[vendor] {
        case .running?:
            if let wait = model.checkWait(vendor) {
                SignInWaitLine(line: wait.line, hint: wait.hint, cancelTitle: wait.cancelTitle) {
                    model.cancelCheck(vendor)
                }
            } else {
                WizardBusy(text: Model.checkingLine(vendor))
            }
        case let .adminConsent(url)?:
            WizardNotice(icon: "hourglass", tone: Tone.warning, title: Model.consentTitle, text: Model.consentBody)
            WizardValueRow(label: Model.consentLinkLabel, value: url, button: Model.copyTitle) { WizardPasteboard.copy(url) }
                .padding(Spacing.medium)
                .card()
        case .failed?, .replaceNeeded?:
            if let line = model.checkLine(vendor) { WizardProblem(text: line) }
        case .passed?, .idle?, nil:
            if let line = model.checkLine(vendor) {
                Label(line, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        if vendor == .atlassian, model.isChecked(.atlassian) { atlassianConfirm }
    }

    private var atlassianConfirm: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(Model.confirmTitle).font(.callout)
            WizardCaption(Model.confirmBody)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ForEach(Array(Model.confirmChecks.enumerated()), id: \.offset) { index, title in
                    WizardCheckRow(title: title, checked: model.atlassianConfirmed[index],
                                   toggle: { model.atlassianConfirmed[index].toggle() },
                                   trailing: Model.confirmLink.map { link in (Model.openTitle, { openURL(link) }) })
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    // MARK: Slack (§2.5)

    @ViewBuilder
    private var slack: some View {
        if model.slack.isRunning, !model.slackProgress.isEmpty {
            WizardStepLines(lines: model.slackProgress.map { ($0.label, WizardMark($0.mark).kind) },
                            caption: Model.slackProgressCaption)
        } else if let diff = model.slackDiff {
            let same = diff.lines.isEmpty
            WizardNotice(icon: "arrow.triangle.2.circlepath", tone: Tone.status("blue"),
                         title: same ? Model.manifestSameTitle(diff.appID) : Model.manifestDiffTitle(diff.appID),
                         text: same ? Model.manifestSameBody : Model.manifestDiffBody)
            if !same { WizardStepLines(lines: diff.lines.map { ($0, .waiting) }) }
        } else if model.slackProblemNamesTheApp, let problem = model.slackProblem {
            WizardProblem(text: problem)
        } else {
            switch model.phase(.slack) {
            case .create, .reuseSecret, .noOrgAccess:
                tokenForm
            case .existing:
                slackExisting
            default:
                phaseContent
            }
            if let problem = model.slackProblem { WizardProblem(text: problem) }
        }
    }

    @ViewBuilder
    private var tokenForm: some View {
        Text(Model.slackTokenStep1).font(.callout)
        WizardCaption(Model.slackTokenHelp)
        if let page = CompanyVendorGuide.guideLines(.slack).first?.link {
            Button(Model.openTokenPage) { openURL(page) }.buttonStyle(.kitSecondary)
        }
        Text(Model.slackTokenStep2).font(.callout)
        WizardField(label: Model.tokenPlaceholder, text: $model.slackToken, secure: true)
        WizardCaption(Model.tokenNote)
    }

    @ViewBuilder
    private var slackExisting: some View {
        let specs = CompanyVendorGuide.alreadyHaveFields(.slack)
        WizardChoice(title: Model.alreadyHaveOne, detail: Model.alreadyHaveDetail, selected: true) {}
        ForEach(specs) { spec in
            VStack(alignment: .leading, spacing: Spacing.tight) {
                WizardField(label: spec.label, text: binding(spec.key))
                if spec.key == .slackSettingsLink, model.slackSettingsLinkInvalid {
                    Text(Model.slackSettingsInvalid)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let help = spec.help { WizardCaption(help) }
            }
        }
    }
}

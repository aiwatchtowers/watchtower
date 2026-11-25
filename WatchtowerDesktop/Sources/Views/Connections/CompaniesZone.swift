import DesignKit
import SwiftUI
import WatchtowerCore

/// What the Companies zone's buttons do; AppState wires them to the wizard
/// page and the company connect flow.
struct CompaniesZoneActions {
    var setUpForCompany: () -> Void = {}
    var continueSetup: () -> Void = {}
    var tryAgain: () -> Void = {}
    var connectAll: (String) -> Void = { _ in }
    var connectRest: (String) -> Void = { _ in }
    var relogin: (String, [CompanyVendor]) -> Void = { _, _ in }
    /// Cancel on a card's waiting sign-in: **Stop** of the hidden chain.
    var stopChain: () -> Void = {}
    var submitCode: () -> Void = {}
}

/// The Companies zone above Sources (company screens spec §4.1): the setup
/// line while a draft exists, a card per stored company, the read states,
/// the port-busy line and the company-code field. Every string is
/// `CompanyConnectionsPresentation`'s; a card is never an attention item.
struct CompaniesZone: View {
    let state: CompaniesZoneState
    @Bindable var model: CompaniesZoneModel
    /// The card whose chain waits on a vendor's browser sign-in, its sheet
    /// closed: the waiting line with Cancel.
    var connecting: (slug: String, vendor: CompanyVendor)?
    /// A connect flow or another sign-in runs: no card starts a second one.
    var flowBusy = false
    let actions: CompaniesZoneActions
    /// The connect assistant's **Connect with <harness>** (agent connect
    /// §5.4, §7), before **Set up for my company**; nil: no button.
    var agent: (harness: ConnectHarness, open: () -> Void)?

    @Environment(\.openURL) private var openURL

    private typealias Pres = CompanyConnectionsPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HomeZoneTitle(title: Pres.companiesTitle)
            if let setup = state.setup { setupRow(setup) }
            content
            if let problem = state.problem { problemRow(problem) }
            if model.codeFieldOpen || state.codeFieldOpen {
                codeField
                // The field replaces Connect with a company code only: the setup stays reachable (a busy port keeps the field open).
                if state.actions.contains(.setUpForCompany) { zoneButtons(only: [.setUpForCompany]) }
            } else if !state.actions.isEmpty {
                zoneButtons(only: state.actions)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state.body {
        case .loading(let text):
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        case .readFailed(let text):
            problemRow(text)
        case .empty(let text):
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .cards(let cards):
            ForEach(cards) { card in companyCard(card) }
        }
    }

    private func setupRow(_ setup: SetupLine) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(Tone.warning)
            Text(setup.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            Button(setup.action.title) {
                switch setup.action {
                case .continueSetup: actions.continueSetup()
                case .setUpForCompany: actions.setUpForCompany()
                }
            }
            .buttonStyle(.kitPrimary)
        }
        .padding(Spacing.medium)
        .card()
    }

    private func companyCard(_ card: CompanyCard) -> some View {
        let running = connecting?.slug == card.slug ? connecting?.vendor : nil
        return HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "building.2").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(card.name).font(.headline)
                if card.managed { ManagedByOrganizationBadge() }
                Text(card.line).font(.caption).foregroundStyle(.secondary)
                if let vendor = running {
                    let copy = SignInWaitCopy(vendor: vendor)
                    SignInWaitLine(line: copy.line, hint: copy.hint, cancelTitle: copy.cancelTitle,
                                   onCancel: actions.stopChain)
                }
                if let missing = card.missingLine {
                    Text(missing).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem = card.problemLine {
                    Text(problem).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.regular)
            ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                cardButton(action, slug: card.slug)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func cardButton(_ action: CompanyCard.Action, slug: String) -> some View {
        let button = Button(action.title) {
            switch action {
            case .connectAll: actions.connectAll(slug)
            case .connectRest: actions.connectRest(slug)
            case .relogin(let vendors): actions.relogin(slug, vendors)
            }
        }
        .disabled(flowBusy)
        if action.isProminent {
            button.buttonStyle(.kitPrimary)
        } else {
            button.buttonStyle(.kitSecondary)
        }
    }

    private func problemRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            Button(Pres.tryAgain, action: actions.tryAgain).buttonStyle(.kitSecondary)
        }
    }

    /// In a row, stacked when the pane is narrower than the row (the inspector
    /// open), so the row never widens the overview past its pane.
    private func zoneButtons(only shown: [CompaniesZoneState.Action]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.regular) { zoneButtonList(shown) }
            VStack(alignment: .leading, spacing: Spacing.regular) { zoneButtonList(shown) }
        }
    }

    @ViewBuilder
    private func zoneButtonList(_ shown: [CompaniesZoneState.Action]) -> some View {
        if let agent, shown.contains(.setUpForCompany) {
            ConnectAgentButton(title: ConnectAssistantPresentation.connectWith(agent.harness), action: agent.open)
        }
        ForEach(Array(shown.enumerated()), id: \.offset) { _, action in
            Button(action.title) {
                switch action {
                case .setUpForCompany: actions.setUpForCompany()
                case .connectWithCode: model.openCodeField()
                }
            }
            .buttonStyle(.kitQuiet)
        }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if let busy = state.portBusy {
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                    Text(busy).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Spacing.regular) {
                TextField(Pres.codePlaceholder, text: $model.code)
                    .textFieldStyle(.kit)
                    .onSubmit(actions.submitCode)
                Button(Pres.connect, action: actions.submitCode)
                    .buttonStyle(.kitSecondary)
                    .disabled(model.pasting || flowBusy
                        || model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.codeError {
                Text(error).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
            }
            slackHint.padding(.top, Spacing.regular)
        }
    }

    /// "No code?" (always shown under the code field, spec D4): the Slack
    /// address opens the workspace's app list in the browser; Watchtower
    /// fetches nothing.
    private var slackHint: some View {
        let address = SlackAddress.parse(model.slackAddress)
        return VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(Pres.slackHintTitle)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.regular) { slackAddressRow(address) }
                VStack(alignment: .leading, spacing: Spacing.regular) { slackAddressRow(address) }
            }
            if let caption = Pres.slackAddressCaption(address) {
                Text(caption).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(Pres.slackHintSteps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)").font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text(Pres.slackHintFallback)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func slackAddressRow(_ address: SlackAddress) -> some View {
        TextField(Pres.slackAddressPlaceholder, text: $model.slackAddress)
            .textFieldStyle(.kit)
            .onSubmit { openSlackApps(address) }
        Button(Pres.openSlackApps) { openSlackApps(address) }
            .buttonStyle(.kitSecondary)
            .disabled(!address.isWorkspace)
    }

    /// Opens the workspace's app list; anything but a workspace opens nothing.
    private func openSlackApps(_ address: SlackAddress) {
        guard case .workspace(let workspace) = address else { return }
        openURL(SlackAddress.appsURL(workspace: workspace))
    }
}

private extension SlackAddress {
    var isWorkspace: Bool {
        if case .workspace = self { return true }
        return false
    }
}

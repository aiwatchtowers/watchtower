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
    var submitCode: () -> Void = {}
}

/// The Companies zone above Sources (company screens spec §4.1): the setup
/// line while a draft exists, a card per stored company, the read states,
/// the port-busy line and the company-code field. Every string is
/// `CompanyConnectionsPresentation`'s; a card is never an attention item.
struct CompaniesZone: View {
    let state: CompaniesZoneState
    @Bindable var model: CompaniesZoneModel
    /// The card whose chain waits on a vendor: "Connecting… Google" with the spinner.
    var connecting: (slug: String, vendor: CompanyVendor)?
    /// A connect flow or another sign-in runs: no card starts a second one.
    var flowBusy = false
    let actions: CompaniesZoneActions

    private typealias Pres = CompanyConnectionsPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HomeZoneTitle(title: Pres.companiesTitle)
            if let setup = state.setup { setupRow(setup) }
            content
            if let problem = state.problem { problemRow(problem) }
            if model.codeFieldOpen || state.codeFieldOpen {
                codeField
            } else if !state.actions.isEmpty {
                zoneButtons
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
                    HStack(spacing: Spacing.small) {
                        ProgressView().controlSize(.mini)
                        Text(Pres.connecting(vendor)).font(.caption).foregroundStyle(.secondary)
                    }
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

    private var zoneButtons: some View {
        HStack(spacing: Spacing.regular) {
            ForEach(Array(state.actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) {
                    switch action {
                    case .setUpForCompany: actions.setUpForCompany()
                    case .connectWithCode: model.openCodeField()
                    }
                }
                .buttonStyle(.kitQuiet)
            }
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
        }
    }
}

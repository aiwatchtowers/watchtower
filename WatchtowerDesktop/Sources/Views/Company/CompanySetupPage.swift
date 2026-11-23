import SwiftUI
import WatchtowerCore

private typealias Model = CompanySetupWizardModel

/// What the page asks of its host (Connections, the shots, the tests).
struct CompanySetupActions {
    /// **‹ Connections** (and **Done** after Publish).
    var back: () -> Void = {}
    var openQuickConnections: () -> Void = {}
    /// **Show file in Finder** for the set-aside draft (a file name next to the company setups).
    var showFile: (String) -> Void = { _ in }
    /// **Connect this Mac** after Publish (the company connect flow); nil hides it.
    var connectThisMac: (() -> Void)?
    /// **Set up with <harness>** in the header (#1149): the connect assistant
    /// on this wizard's draft (`AppState.companySetupAgent`); nil hides it.
    var agent: (harness: ConnectHarness, open: () -> Void)?
}

/// **Set up for my company** (company screens spec §2.2, C1): a page in the
/// Connections detail area. **‹ Connections** on top, the title and intro,
/// the resume line, then the step rail beside the step's content and its
/// buttons; under 520 pt the rail folds into "Step 3 of 8 · Google".
/// The model lives on `AppState.companySetup`, so leaving the page saves
/// the draft and a running check or Slack run keeps going.
struct CompanySetupPage: View {
    @Bindable var model: CompanySetupWizardModel
    let actions: CompanySetupActions
    /// The width class: measured in the app, forced by the shots and tests.
    var layout = Layout.measured
    @State private var width: CGFloat = 0
    @State private var selection: [CompanyVendor: Int] = [:]
    @State private var confirmDiscard = false

    /// The rail folds below this width (A8).
    static let foldWidth: CGFloat = 520

    static func foldsRail(width: CGFloat) -> Bool { width > 0 && width < foldWidth }

    enum Layout { case measured, wide, narrow }

    private var isNarrow: Bool {
        switch layout {
        case .measured: Self.foldsRail(width: width)
        case .wide: false
        case .narrow: true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Button(action: actions.back) { Label(Model.backToConnections, systemImage: "chevron.left") }
                .buttonStyle(.kitQuiet)
            HStack(alignment: .top, spacing: Spacing.medium) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(Model.wizardTitle).font(.title3.weight(.semibold))
                    WizardCaption(Model.wizardIntro)
                }
                Spacer(minLength: Spacing.regular)
                // In the header, so every step offers it.
                if let agent = actions.agent {
                    ConnectAgentButton(title: ConnectAssistantPresentation.setUpWith(agent.harness), action: agent.open)
                }
            }
            if let line = model.resumeLine { resume(line) }
            if let problem = model.storageProblem {
                HStack(alignment: .top, spacing: Spacing.regular) {
                    WizardProblem(text: problem)
                    if model.load == .notOpened {
                        Button(Model.tryAgainTitle) { Task { await model.open() } }.buttonStyle(.kitSecondary)
                    }
                }
            }
            if model.load == .ready || model.discovering {
                steps
            } else if model.load == .loading {
                WizardBusy(text: Model.loadingLine)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Not `.task`: leaving the page must not cancel the session's open
        // (a cancelled discovery would read as "the look failed").
        .onAppear { Task { await model.open() } }
        .onDisappear { Task { await model.leave() } }
        .confirmationDialog(Model.discardSetup, isPresented: $confirmDiscard) {
            Button(Model.discardButton, role: .destructive) { Task { await model.discard() } }
            Button(Model.keepButton, role: .cancel) {}
        } message: {
            Text(Model.discardConfirm)
        }
    }

    private func resume(_ line: String) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
            Text(line).font(.caption)
            Spacer(minLength: Spacing.regular)
            Button(Model.discardSetup) { confirmDiscard = true }
                .buttonStyle(.kitQuiet)
                .disabled(model.publishState == .running)
        }
        .padding(Spacing.regular)
        .card()
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            if isNarrow {
                HStack(spacing: Spacing.regular) {
                    Text(model.railNarrowLine).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.regular)
                    // The folded rail keeps its way back to the services.
                    if model.current != .services, !model.isPublished, model.publishState != .running {
                        Button(Model.changeServices) { model.goTo(.services) }.buttonStyle(.kitQuiet)
                    }
                }
            }
            HStack(alignment: .top, spacing: Spacing.large) {
                if !isNarrow {
                    CompanySetupRail(model: model)
                        .frame(width: PaneWidth.sideListIdeal)
                        .disabled(model.load != .ready || model.discarding)
                }
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    // Narrow, the folded rail's line already names a vendor step.
                    if !isNarrow || model.current == .services { Text(stepTitle).font(.headline) }
                    // Nothing acts before the draft and discovery are read (writeDraft refuses until then).
                    Group {
                        content
                        // The drop warning carries its own Keep / Drop on Services.
                        if model.dropWarning == nil || model.current != .services { footer }
                    }
                    .disabled(model.load != .ready || model.discarding)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var stepTitle: String {
        model.current == .services ? CompanyVendorGuide.servicesTitle : Model.railName(model.current)
    }

    @ViewBuilder
    private var content: some View {
        switch model.current {
        case .services:
            CompanySetupServicesStep(model: model, actions: actions) { confirmDiscard = true }
        case let .vendor(vendor):
            CompanySetupVendorStep(model: model, vendor: vendor, selection: Binding(
                get: { selection[vendor] ?? 0 },
                set: { selection[vendor] = $0 }
            ))
        case .denyList:
            CompanySetupDenyListStep(model: model)
        case .publish:
            CompanySetupPublishStep(model: model)
        }
    }

    // MARK: Buttons

    private var footer: some View {
        HStack(spacing: Spacing.regular) {
            Spacer(minLength: Spacing.regular)
            if model.isPublished {
                Button(Model.doneTitle) {
                    model.finish()
                    actions.back()
                }
                .buttonStyle(.kitSecondary)
                if let connect = actions.connectThisMac, model.primary.enabled {
                    Button(model.primary.title, action: connect).buttonStyle(.kitPrimary)
                }
            } else {
                if showsSkip { Button(Model.skipStep) { Task { await model.skip() } }.buttonStyle(.kitQuiet) }
                secondary
                Button(primaryTitle, action: primary)
                    .buttonStyle(.kitPrimary)
                    .disabled(!model.primary.enabled)
            }
        }
    }

    /// The vendor shown, when the current step is one.
    private var vendor: CompanyVendor? {
        if case let .vendor(v) = model.current { return v }
        return nil
    }

    private var foundPhase: Bool {
        guard let vendor else { return false }
        return model.phase(vendor) == .found && !(vendor == .slack && (model.slackDiff != nil || model.slackProblem != nil))
    }

    private var showsSkip: Bool {
        guard let vendor else { return false }
        return !model.isRunning(vendor) && !(vendor == .slack && model.slackDiff != nil)
    }

    private var waitingForConsent: Bool {
        if case .adminConsent? = model.checks[.microsoft], model.current == .vendor(.microsoft) { return true }
        return false
    }

    @ViewBuilder
    private var secondary: some View {
        if foundPhase {
            Button(Model.createNew) { model.createNew() }.buttonStyle(.kitSecondary)
        } else if vendor == .slack, model.slackOffersNewApp {
            Button(Model.backTitle) { model.back() }.buttonStyle(.kitSecondary)
            Button(Model.createNewAppInstead) { model.createNewSlackApp() }.buttonStyle(.kitSecondary)
        } else if waitingForConsent {
            Button(Model.checkAgain) { Task { await model.check(.microsoft) } }.buttonStyle(.kitSecondary)
        } else if model.current != .services {
            // A running check or Slack run goes on when the step is left (§2.2).
            Button(Model.backTitle) { model.back() }
                .buttonStyle(.kitSecondary)
                .disabled(model.publishState == .running)
        }
    }

    /// The model's title; on Slack's found apps it names the row chosen in the list.
    private var primaryTitle: String {
        guard foundPhase, vendor == .slack, let chosen = chosenCandidate else { return model.primary.title }
        return Model.useApp(chosen.label)
    }

    private var chosenCandidate: CompanyCandidate? {
        guard let vendor else { return nil }
        let list = model.candidates(for: vendor)
        let index = selection[vendor] ?? 0
        return list.indices.contains(index) ? list[index] : list.first
    }

    /// The prominent button: the found row chosen in the list, else the model's `next()`.
    private func primary() {
        if foundPhase {
            if let chosen = chosenCandidate { model.choose(chosen) }
            return
        }
        Task { await model.next() }
    }
}

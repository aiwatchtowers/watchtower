import Foundation
import Observation
import WatchtowerCore

/// The connect assistant's state on `AppState` (agent connect #2133): the
/// open panel, the ready harness CLIs, the sessions and their drivers.
@MainActor
@Observable
final class ConnectAssistantWiring {
    /// The panel's service, nil while closed.
    var service: String?
    /// The providers whose CLI Go finds (`ai which`), read on the
    /// Connections tab's appear: the assistant runs only on one of them.
    var readyProviders: Set<String> = []
    /// The Add sheet a service's detail opens once it shows (the panel's
    /// **Set up by hand**); the detail clears it.
    var addRequest: ConnectionService?
    /// Bumped whenever a session is dropped and made again: the center's
    /// cache is not observed, so the panel reads its session through this.
    var generation = 0
    /// The catalog's providers; tests pass their own.
    @ObservationIgnored var providers: @MainActor () -> [AIModelCatalog.Provider] = { AIModelCatalog.shared.providers }
    /// One session per service; their drivers live as long as the app state.
    @ObservationIgnored lazy var center = ConnectAssistantCenter { [weak self] in self?.app?.makeConnectSession($0) }
    @ObservationIgnored var drivers: [String: any ConnectServiceDriving] = [:]
    @ObservationIgnored private weak var app: AppState?

    init(app: AppState) {
        self.app = app
    }

    /// App quit: every run ends (held calls answer `closed`, the sockets go, the turns stop).
    func closeAll() {
        center.closeAll()
    }
}

/// The connect assistant (agent connect #2133, spec §5.2, §7): which
/// harness the entry points offer, the panel on the right of the
/// Connections tab, and the per-service drivers its runs answer through.
extension AppState {
    var connectAssistantService: String? {
        get { connectAssistant.service }
        set { connectAssistant.service = newValue }
    }
    var connectReadyProviders: Set<String> {
        get { connectAssistant.readyProviders }
        set { connectAssistant.readyProviders = newValue }
    }
    var connectionAddRequest: ConnectionService? {
        get { connectAssistant.addRequest }
        set { connectAssistant.addRequest = newValue }
    }
    var connectProviders: @MainActor () -> [AIModelCatalog.Provider] {
        get { connectAssistant.providers }
        set { connectAssistant.providers = newValue }
    }
    var connectAssistants: ConnectAssistantCenter { connectAssistant.center }

    /// The session the panel shows: observed through the panel's service and
    /// the generation, so a session made anew (Retry on a harness taken
    /// away) replaces the old one on screen.
    var connectAssistantPanelSession: ConnectAssistantSession? {
        _ = connectAssistant.generation
        return connectAssistantService.flatMap(connectAssistants.loaded)
    }

    /// Drops a service's session (closing it) and tells the panel.
    private func dropConnectSession(_ service: String) {
        connectAssistants.drop(service)
        connectAssistant.generation += 1
    }

    /// The connect service ids that are not a Connections service: the
    /// company setup wizard and a bring-your-own Google client (preflight F5).
    static let companyConnectService = "company"
    static let ownGoogleProjectConnectService = "google_own_project"

    /// The harnesses the assistant may run on (spec §5.2): a catalog
    /// provider that can connect, that the policy allows and whose CLI Go
    /// finds; `initial` is the base provider when it is among them.
    var connectHarnesses: (harnesses: [ConnectHarness], initial: ConnectHarness?) {
        ConnectHarnessCatalog.offered(providers: connectProviders(), allowed: managedPolicy.policy.allowedAIProviders,
                                      ready: connectReadyProviders, base: sharedConfig.aiProvider ?? "")
    }

    /// The harness a service's agent button names; nil = no button: the
    /// service is unknown or blocked by the policy, no harness is offered
    /// (spec §6: a blocked source or provider never opens the panel), or its
    /// driver cannot be made yet (the view model is not loaded), so no
    /// button silently does nothing.
    func connectAssistantButton(for service: String) -> ConnectHarness? {
        guard connectServiceAllowed(service), connectDriver(for: service) != nil else { return nil }
        return connectHarnesses.initial
    }

    /// The entry points' agent buttons over this state: which harness a
    /// service's button names, and opening the panel on it.
    var connectAgentEntry: ConnectAgentEntry {
        ConnectAgentEntry(harness: { [weak self] in self?.connectAssistantButton(for: $0) },
                          open: { [weak self] in self?.openConnectAssistant(service: $0) })
    }

    /// The company setup wizard's **Set up with <harness>** (#1149): the
    /// company assistant, whose driver reads and writes the wizard's own
    /// draft; nil under the same rules as every other agent button.
    var companySetupAgent: (harness: ConnectHarness, open: () -> Void)? {
        connectAssistantButton(for: Self.companyConnectService).map { harness in
            (harness, { [weak self] in self?.openConnectAssistant(service: Self.companyConnectService) })
        }
    }

    /// Whether the organization lets the service be connected at all.
    func connectServiceAllowed(_ service: String) -> Bool {
        let policy = managedPolicy.policy
        switch service {
        case Self.companyConnectService:
            return true  // no managed key gates company setup (Task 12)
        case Self.ownGoogleProjectConnectService:
            return PolicySourceMap.allowed("google", policy: policy) && policy.ownGoogleProjectAllowed
        case ConnectionService.quickConnections.rawValue:
            // The manual Add is locked when the policy allows no connection (#608).
            return policy.allowedQuickConnections?.isEmpty != true
        default:
            guard let known = ConnectionService(rawValue: service), known != .companySetup else { return false }
            return PolicySourceMap.allowed(known.rawValue, policy: policy)
        }
    }

    /// Opens the panel on `service` in the Connections tab. A session made
    /// earlier is reused, so a running chat shows again; one made over
    /// another harness list (a CLI found since, the policy) is made anew
    /// unless its run is under way on a harness still offered. Another
    /// service's run keeps going: only Close ends a run. During onboarding
    /// the panel shows beside the Connect step, so no tab is chosen.
    func openConnectAssistant(service: String) {
        guard connectServiceAllowed(service), connectHarnesses.initial != nil,
              currentConnectSession(service) != nil else { return }
        connectAssistantService = service
        if !needsOnboarding { selectedDestination = .connections }
    }

    /// The service's session, checked against the current offer: a session
    /// whose harness list is stale is dropped and made again, except while
    /// it is live on a harness that is still offered: its run under way, or
    /// its chat still answering (a follow-up after done, spec §5.2: reopening
    /// shows the live chat). nil when nothing is offered or the driver
    /// cannot be made.
    func currentConnectSession(_ service: String) -> ConnectAssistantSession? {
        let offered = connectHarnesses
        guard offered.initial != nil else { return nil }
        if let existing = connectAssistants.loaded(service), existing.harnesses != offered.harnesses {
            let live = Self.runUnderWay(existing.state) || existing.engine?.isBusy == true
                || existing.engine?.isFinishing == true
            if !(live && offered.harnesses.contains(existing.harness)) { dropConnectSession(service) }
        }
        return connectAssistants.session(for: service)
    }

    /// The panel's Start, Guide me in words, Retry, Check again and Continue
    /// without the browser: a run (or its probe) starts only on
    /// a harness the current offer still holds. A session whose harness was
    /// taken away (the policy, the CLI gone) is made again and shows its
    /// empty state on the current initial harness; with none offered the
    /// panel closes.
    func connectAssistantRun(_ action: ConnectAssistantPresentation.Action, service: String) {
        guard let cached = connectAssistants.loaded(service) else { return }
        let offered = connectHarnesses
        guard offered.harnesses.contains(cached.harness) else {
            dropConnectSession(service)
            if currentConnectSession(service) == nil, connectAssistantService == service { connectAssistantService = nil }
            return
        }
        switch action {
        case .start: cached.start()
        case .guideInWords: cached.guideInWords()
        case .retry: cached.retry()
        case .checkBrowser: cached.checkBrowser()
        case .continueWithoutBrowser: cached.continueWithoutBrowser()
        case .setUpByHand, .openIt, .cancel: break
        }
    }

    /// The header's picker: the session's harnesses the current offer still holds.
    func connectPickerHarnesses(_ session: ConnectAssistantSession) -> [ConnectHarness] {
        let offered = connectHarnesses.harnesses
        return session.harnesses.filter(offered.contains)
    }

    /// The panel's Close: the run ends and its chat goes (spec §8: a driver
    /// flow keeps today's behaviour).
    func closeConnectAssistant() {
        guard let service = connectAssistantService else { return }
        connectAssistants.loaded(service)?.close()
        connectAssistantService = nil
        // A Slack sign-in the run started goes on as today's and is handed to
        // its sheet (`SlackConnectDriver.runEnded`); only the Slack detail and
        // onboarding's Connect step mount that sheet, so its Cancel is shown
        // there. App quit closes runs through `closeAll`, never here.
        if service == ConnectionService.slack.rawValue, slackConnectFlow?.showsSheet == true, !needsOnboarding {
            openConnections(.slack)
        }
    }

    /// **Set up by hand**: the panel closes and today's screen opens — the
    /// service's Add sheet where it has one, else its detail, the company
    /// wizard or the own-Google-project page. During onboarding the Connect
    /// step opens its own sheet for the source instead.
    func connectAssistantSetUpByHand(service: String) {
        closeConnectAssistant()
        if needsOnboarding {
            connectionAddRequest = ConnectionService(rawValue: service)
            return
        }
        switch service {
        case Self.companyConnectService:
            openCompanySetup()
        case Self.ownGoogleProjectConnectService:
            openConnections(.google)
            ownGoogleProject.open()
        default:
            guard let known = ConnectionService(rawValue: service) else { return }
            openConnections(known)
            if known.hasAddSheet { connectionAddRequest = known }
        }
    }

    /// A run that is working or waiting on the customer: not before Start,
    /// not after it failed, ended in another window's favour or finished.
    static func runUnderWay(_ state: ConnectAssistantState) -> Bool {
        switch state {
        case .thinking, .listening, .waiting, .secret, .confirm, .browserMissing: true
        case .empty, .failed, .busy, .done: false
        }
    }

    /// The busy state's **Open it**: the related assistant whose run holds
    /// the running sign-in (its controller's flow), else the screen where
    /// today's flow runs.
    func connectAssistantOpenOther(service: String) {
        if let other = Self.relatedConnectServices[service],
           let session = connectAssistants.loaded(other), session.controller?.activeFlow != nil {
            connectAssistantService = other
            return
        }
        if needsOnboarding {  // the Connect step's sheet shows the running sign-in
            connectionAddRequest = ConnectionService(rawValue: service)
            return
        }
        switch service {
        case Self.companyConnectService: openCompanySetup()
        case Self.ownGoogleProjectConnectService: openConnections(.google)
        default: openConnections(ConnectionService(rawValue: service))
        }
    }

    /// Services whose sign-ins share one flow: the personal Google and an own
    /// project; the Slack app and the company setup's Slack step.
    private static let relatedConnectServices = [
        "google": ownGoogleProjectConnectService, ownGoogleProjectConnectService: "google",
        "slack": companyConnectService, companyConnectService: "slack"
    ]

    /// Reads which harness CLIs Go finds (`ai which`): the Connections tab's
    /// appear and each catalog read. A provider that cannot connect is not
    /// asked; under XCTest nothing runs (tests set the set).
    func refreshConnectReadyProviders() async {
        guard !Self.runsUnderXCTest else { return }
        let candidates = connectProviders()
            .filter { ($0.capabilities?.connectMode ?? ConnectCapability.none) != .none }.map(\.id)
        var ready: Set<String> = []
        for id in candidates {
            if case .found = await WatchtowerAIService.which(provider: id) { ready.insert(id) }
        }
        connectReadyProviders = ready
    }

    /// The panel's name for a connect service ("Slack", "your company").
    static func connectServiceName(_ service: String) -> String {
        switch service {
        case companyConnectService: ConnectAssistantPresentation.companyName
        case ownGoogleProjectConnectService: ConnectAssistantPresentation.ownGoogleProjectName
        default: ConnectionService(rawValue: service)?.label ?? service
        }
    }

    // MARK: - Sessions and drivers

    /// The center's factory: nil while no harness is offered or the
    /// service's view model is not loaded yet (nothing is cached then).
    func makeConnectSession(_ service: String) -> ConnectAssistantSession? {
        let offered = connectHarnesses
        guard let initial = offered.initial, let driver = connectDriver(for: service) else { return nil }
        return ConnectAssistantSession(
            service: service, displayName: Self.connectServiceName(service), harnesses: offered.harnesses,
            initial: initial, driver: driver, aiService: WatchtowerAIService(),
            probe: ConnectBrowserProbe(aiService: WatchtowerAIService()), gate: embeddedChatCenter.gate)
    }

    /// One driver per service for the life of this state: a flow a run
    /// started is still the driver's when a later run (Retry, a reopen)
    /// asks about it.
    func connectDriver(for service: String) -> (any ConnectServiceDriving)? {
        if let driver = connectAssistant.drivers[service] { return driver }
        guard let driver = makeConnectDriver(service) else { return nil }
        connectAssistant.drivers[service] = driver
        return driver
    }

    private func makeConnectDriver(_ service: String) -> (any ConnectServiceDriving)? {
        let policy: @MainActor () -> ManagedPolicy = { [weak self] in self?.managedPolicy.policy ?? .none }
        let daemonPolicy: @MainActor () -> DaemonRestartPolicy = { [weak self] in self?.accountDaemonPolicy ?? .deferred }
        switch service {
        case Self.companyConnectService:
            return CompanyConnectDriver(wizard: companySetup)
        case Self.ownGoogleProjectConnectService:
            return OwnGoogleProjectConnectDriver(model: ownGoogleProject, policy: policy) { [weak self] in
                self?.googleAccountsViewModel?.connectRows.map(\.account) ?? []
            }
        default:
            break
        }
        switch ConnectionService(rawValue: service) {
        case .slack:
            guard let accounts = slackAccountsViewModel else { return nil }
            return SlackConnectDriver(
                accounts: accounts, connectFlow: slackConnectFlow, setup: slackAppSetup, policy: policy,
                daemonPolicy: daemonPolicy, runner: ProcessCLIRunner.makeDefault()
            ) { [weak self] in await self?.slackLiveStatusCenter?.reload() }
        case .google:
            return googleAccountsViewModel.map { GoogleConnectDriver(model: $0, policy: policy, daemonPolicy: daemonPolicy) }
        case .email:
            return emailAccountsViewModel.map { EmailConnectDriver(model: $0, policy: policy) }
        case .calendar:
            return calendarAccountsViewModel.map { CalendarConnectDriver(model: $0, policy: policy) }
        case .jira:
            guard let model = jiraAccountsViewModel, let pool = databaseManager?.dbPool else { return nil }
            let steps = LiveJiraConnectSteps(dbPool: pool) { [weak self] in
                self.map { ConfluenceSpacesSection.isFeatureOff($0.featureManager) } ?? true
            }
            return JiraConnectDriver(
                model: model, steps: steps, policy: policy,
                companySlug: { [weak self] in self.flatMap { JiraConnectDriver.companySlug($0.companiesZone.companies) } },
                daemonPolicy: daemonPolicy)
        case .linear:
            return linearAccountsViewModel.map { LinearConnectDriver(model: $0, policy: policy, daemonPolicy: daemonPolicy) }
        case .quickConnections:
            return externalConnectionsViewModel.map { QuickConnectionConnectDriver(model: $0, policy: policy) }
        case .companySetup, nil:
            return nil
        }
    }
}

extension AppState {
    /// Quick Connections' **Add Connection** may open its sheet: the view
    /// model is loaded and idle, and the policy allows a connection (#608).
    var canAddQuickConnection: Bool {
        guard let vm = externalConnectionsViewModel, !vm.isBusy else { return false }
        return managedPolicy.policy.allowedQuickConnections?.isEmpty != true
    }
}

extension ConnectionService {
    /// Its detail opens an Add sheet (`AppState.connectionAddRequest`);
    /// Google and Jira add from the detail itself.
    var hasAddSheet: Bool {
        switch self {
        case .slack, .email, .calendar, .linear, .quickConnections: true
        case .google, .jira, .companySetup: false
        }
    }
}

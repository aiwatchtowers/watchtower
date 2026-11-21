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
    /// service is unknown or blocked by the policy, or no harness is offered
    /// (spec §6: a blocked source or provider never opens the panel).
    func connectAssistantButton(for service: String) -> ConnectHarness? {
        guard connectServiceAllowed(service) else { return nil }
        return connectHarnesses.initial
    }

    /// Whether the organization lets the service be connected at all.
    func connectServiceAllowed(_ service: String) -> Bool {
        let policy = managedPolicy.policy
        switch service {
        case Self.companyConnectService:
            return true  // no managed key gates company setup (Task 12)
        case Self.ownGoogleProjectConnectService:
            return PolicySourceMap.allowed("google", policy: policy) && policy.ownGoogleProjectAllowed
        default:
            guard let known = ConnectionService(rawValue: service), known != .companySetup else { return false }
            return PolicySourceMap.allowed(known.rawValue, policy: policy)
        }
    }

    /// Opens the panel on `service` in the Connections tab. A session made
    /// earlier is reused, so a running chat shows again; an idle one whose
    /// harnesses changed since (a CLI installed, the policy) is made anew.
    /// Another service's run keeps going: only Close ends a run.
    func openConnectAssistant(service: String) {
        let offered = connectHarnesses
        guard connectServiceAllowed(service), offered.initial != nil else { return }
        if let existing = connectAssistants.loaded(service), existing.harnesses != offered.harnesses,
           existing.state == .empty {
            connectAssistants.drop(service)
        }
        guard connectAssistants.session(for: service) != nil else { return }
        connectAssistantService = service
        selectedDestination = .connections
    }

    /// The panel's Close: the run ends and its chat goes (spec §8: a driver
    /// flow keeps today's behaviour).
    func closeConnectAssistant() {
        guard let service = connectAssistantService else { return }
        connectAssistants.loaded(service)?.close()
        connectAssistantService = nil
    }

    /// **Set up by hand**: the panel closes and today's screen opens — the
    /// service's Add sheet where it has one, else its detail, the company
    /// wizard or the own-Google-project page.
    func connectAssistantSetUpByHand(service: String) {
        closeConnectAssistant()
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

    /// The busy state's **Open it**: the related assistant whose run holds
    /// the sign-in, else the screen where today's flow runs.
    func connectAssistantOpenOther(service: String) {
        if let other = Self.relatedConnectServices[service],
           let session = connectAssistants.loaded(other), session.state != .empty {
            connectAssistantService = other
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

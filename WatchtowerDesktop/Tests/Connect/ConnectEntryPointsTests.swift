import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The connect assistant's entry points and panel wiring (agent connect
/// #2133, Task 14): which button shows where, which harnesses the picker
/// offers, and where **Set up by hand** lands. No CLI runs: the catalog is
/// the Go-written fixture and readiness is set by the test.
@MainActor
final class ConnectEntryPointsTests: XCTestCase {
    private typealias Pres = ConnectAssistantPresentation

    /// An isolated app state over the fixture catalog, every provider ready
    /// unless `ready` says otherwise; its config is a scratch file.
    private func appState(policy: [String: Any] = [:], ready: Set<String>? = nil) -> AppState {
        let state = AppState.isolated(managedPolicy: policy)
        state.managedPolicy.refresh()
        state.sharedConfig = ConfigService(configPath: NSTemporaryDirectory() + "watchtower-tests-\(UUID().uuidString).yaml")
        let providers = ProviderCatalogFixture.providers()
        state.connectProviders = { providers }
        state.connectReadyProviders = ready ?? Set(providers.map(\.id))
        return state
    }

    private func account(_ name: String, ok: Bool, error: String = "") -> ConnectionAccountState {
        ConnectionAccountState(name: name, isOK: ok, status: ok ? "ok" : "error", error: error)
    }

    // MARK: - Gating

    func testNoButtonWhenSourceBlocked() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let state = appState(policy: ["AllowedSources": ["slack"], "AllowOwnGoogleProject": false,
                                      "AllowedQuickConnections": [String]()])
        XCTAssertNil(state.connectAssistantButton(for: "slack"), "no button whose driver cannot be made yet")
        state.initSlackAccounts(dbPool: pool)
        state.initExternalConnections(dbPool: pool)
        XCTAssertEqual(state.connectAssistantButton(for: "slack")?.name, "Claude")
        for blocked in ["google", "jira", "email", "linear", "google_own_project", "quickConnections"] {
            XCTAssertNil(state.connectAssistantButton(for: blocked), blocked)
        }
        XCTAssertNotNil(state.connectAssistantButton(for: "company"), "no managed key gates company setup")
        XCTAssertNil(state.connectAssistantButton(for: "companySetup"), "the wizard page is not a connect service")
        XCTAssertNil(state.connectAssistantButton(for: "unknown"))
        state.openConnectAssistant(service: "google")
        XCTAssertNil(state.connectAssistantService, "a blocked source never opens the panel")

        // The overview: a blocked card shows no pair even with a harness offered.
        let view = ConnectionsOverviewContent(
            summaries: [ConnectionSummary(service: .google, accounts: [], blocked: true),
                        ConnectionSummary(service: .linear, accounts: [], blocked: false)],
            agent: ConnectAgentEntry(harness: { state.connectAssistantButton(for: $0) }, open: { _ in })
        ) { _ in }
        XCTAssertThrowsError(try view.inspect().find(button: "Connect with Claude"))
        let unblocked = ConnectionsOverviewContent(
            summaries: [ConnectionSummary(service: .linear, accounts: [], blocked: false)],
            agent: ConnectAgentEntry(harness: { _ in .fixture("claude") }, open: { _ in })
        ) { _ in }
        XCTAssertNoThrow(try unblocked.inspect().find(button: "Connect with Claude"))
    }

    func testNoButtonWhenNoHarness() throws {
        // No CLI found: nothing is offered.
        let none = appState(ready: [])
        XCTAssertNil(none.connectHarnesses.initial)
        for service in ["slack", "google", "company", "google_own_project"] {
            XCTAssertNil(none.connectAssistantButton(for: service), service)
        }
        none.openConnectAssistant(service: "company")
        XCTAssertNil(none.connectAssistantService)
        XCTAssertNil(none.connectAssistants.loaded("company"), "no session is made without a harness")

        // Only a provider that cannot connect is allowed.
        let ollamaOnly = appState(policy: ["AllowedAIProviders": ["ollama"]])
        XCTAssertNil(ollamaOnly.connectAssistantButton(for: "slack"))

        // The overview without a harness: today's screen, unchanged.
        let view = ConnectionsOverviewContent(
            summaries: [ConnectionSummary(service: .linear, accounts: [], blocked: false),
                        ConnectionSummary(service: .jira, accounts: [account("acme.atlassian.net", ok: false,
                                                                             error: "token expired")], blocked: false)],
            agent: ConnectAgentEntry(harness: { none.connectAssistantButton(for: $0) }, open: { _ in })
        ) { _ in }
        XCTAssertThrowsError(try view.inspect().find(button: "Connect with Claude"))
        XCTAssertThrowsError(try view.inspect().find(button: "Reconnect with Claude"))
        XCTAssertNoThrow(try view.inspect().find(button: "Reconnect"))
    }

    func testBlockedProviderNotInPicker() throws {
        let state = appState(policy: ["AllowedAIProviders": ["codex"]])
        XCTAssertEqual(state.connectHarnesses.harnesses.map(\.id), ["codex"])
        XCTAssertEqual(state.connectAssistantButton(for: "company")?.id, "codex")
        state.openConnectAssistant(service: "company")
        XCTAssertEqual(state.connectAssistantService, "company")
        let session = try XCTUnwrap(state.connectAssistants.loaded("company"))
        XCTAssertEqual(session.harnesses.map(\.id), ["codex"], "a blocked provider is never offered")
        XCTAssertEqual(session.harness.id, "codex")
        XCTAssertEqual(session.displayName, "your company")

        // The harnesses change while the panel is idle (a CLI found since):
        // the next open reads them again.
        let later = appState(ready: ["codex"])
        later.openConnectAssistant(service: "company")
        XCTAssertEqual(later.connectAssistants.loaded("company")?.harnesses.map(\.id), ["codex"])
        later.closeConnectAssistant()
        later.connectReadyProviders = ["claude", "codex"]
        later.openConnectAssistant(service: "company")
        XCTAssertEqual(later.connectAssistants.loaded("company")?.harnesses.map(\.id), ["claude", "codex"])
    }

    // MARK: - Overview

    /// The banner keeps today's Reconnect only: no driver signs an existing
    /// account in again, so an agent "Reconnect" would add a new one.
    func testAttentionBannerKeepsTodaysReconnect() throws {
        var opened: [String] = []
        var detail: [ConnectionService] = []
        let claude = ConnectHarness.fixture("claude")
        let summaries = [
            ConnectionSummary(service: .jira, accounts: [account("acme.atlassian.net", ok: false, error: "token expired")],
                              blocked: false),
            ConnectionSummary(service: .google, accounts: [], blocked: false)
        ]
        let agent = ConnectAgentEntry(harness: { _ in claude }, open: { opened.append($0) })
        let openDetail: (ConnectionService) -> Void = { detail.append($0) }
        let view = ConnectionsOverviewContent(
            summaries: summaries, companies: EmptyView(), onCompanyAction: { _ in }, agent: agent, onOpen: openDetail)

        let banner = try view.inspect().find(ConnectionAttentionBanner.self)
        XCTAssertThrowsError(try banner.find(button: "Reconnect with Claude"))
        try banner.find(button: "Reconnect").tap()
        XCTAssertEqual(opened, [])
        XCTAssertEqual(detail, [.jira])

        // An empty card offers the pair; a connected or broken one does not.
        let cards = try view.inspect().findAll(ConnectionCard.self)
        XCTAssertEqual(cards.count, 2)
        try view.inspect().find(button: "Connect with Claude").tap()
        try view.inspect().find(button: "Connect").tap()
        XCTAssertEqual(opened, ["google"])
        XCTAssertEqual(detail, [.jira, .google])
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self) { button in
            (try? button.labelView().find(text: "Connect with Claude")) != nil
        }.count, 1, "only the card with no account")

        // The Connect… menu (preflight F22): a submenu per service and the company entry.
        let menu = try view.inspect().find(ViewType.Menu.self)
        try menu.find(button: "Set up for my company with Claude").tap()
        XCTAssertEqual(opened.last, "company")
        XCTAssertNoThrow(try menu.find(ViewType.Menu.self) { try $0.labelView().text().string() == "Connect with Claude" })
    }

    func testCompaniesZoneOffersConnectWithBeforeSetUp() throws {
        var pressed = 0
        let zone = CompanyConnectionsPresentation.zone(
            companies: [], errors: [], draft: nil, accounts: [], portBusy: false, loading: false)
        let view = CompaniesZone(state: zone, model: CompaniesZoneModel { nil }, actions: CompaniesZoneActions(),
                                 agent: (.fixture("claude"), { pressed += 1 }))
        let titles = try view.inspect().findAll(ViewType.Button.self).compactMap { button -> String? in
            if let text = try? button.labelView().find(ViewType.Text.self).string() { return text }
            return nil
        }
        XCTAssertEqual(titles.first, "Connect with Claude")
        XCTAssertEqual(titles.dropFirst().first, CompaniesZoneState.Action.setUpForCompany.title)
        try view.inspect().find(button: "Connect with Claude").tap()
        XCTAssertEqual(pressed, 1)
    }

    // MARK: - Panel

    func testSetUpByHandOpensService() throws {
        let state = appState()
        state.openConnectAssistant(service: "company")
        XCTAssertEqual(state.connectAssistantService, "company")
        XCTAssertEqual(state.selectedDestination, .connections)
        state.connectAssistantSetUpByHand(service: "company")
        XCTAssertNil(state.connectAssistantService, "the panel closes")
        XCTAssertEqual(state.selectedConnection, .companySetup)

        state.connectAssistantSetUpByHand(service: "email")
        XCTAssertEqual(state.selectedConnection, .email)
        XCTAssertEqual(state.connectionAddRequest, .email, "the detail opens today's Add sheet")

        state.connectionAddRequest = nil
        state.connectAssistantSetUpByHand(service: "jira")
        XCTAssertEqual(state.selectedConnection, .jira)
        XCTAssertNil(state.connectionAddRequest, "Jira adds from its detail")

        state.connectAssistantSetUpByHand(service: "google_own_project")
        XCTAssertEqual(state.selectedConnection, .google)
    }

    func testCloseEndsTheRunAndOpenItFindsTheOtherWindow() throws {
        let state = appState()
        state.openConnectAssistant(service: "company")
        let session = try XCTUnwrap(state.connectAssistants.loaded("company"))
        state.closeConnectAssistant()
        XCTAssertNil(state.connectAssistantService)
        XCTAssertEqual(session.state, .empty)
        XCTAssertNil(session.engine, "Close drops the chat")

        // Busy with no other assistant running: today's screen of the service.
        state.connectAssistantOpenOther(service: "slack")
        XCTAssertEqual(state.selectedConnection, .slack)
        state.connectAssistantOpenOther(service: "company")
        XCTAssertEqual(state.selectedConnection, .companySetup)
    }

    func testComposerTakesQuestionsOnlyDuringARun() {
        XCTAssertFalse(ConnectAssistantHost.acceptsQuestions(.empty))
        XCTAssertFalse(ConnectAssistantHost.acceptsQuestions(.failed(.quota)))
        XCTAssertFalse(ConnectAssistantHost.acceptsQuestions(.busy))
        XCTAssertTrue(ConnectAssistantHost.acceptsQuestions(.listening))
        XCTAssertTrue(ConnectAssistantHost.acceptsQuestions(.secret(label: "Token")))
        XCTAssertTrue(ConnectAssistantHost.acceptsQuestions(.done(accounts: 1, noun: .account)))
    }

    func testPanelSecretCardSendsAndDismisses() throws {
        var sent: [String] = []
        var dismissed = 0
        let panel = ConnectAssistantPanel(
            presentation: Pres(service: "Acme", harness: .fixture("claude"), mode: .browser,
                               state: .secret(label: "Client secret"), secretKind: "google_client_secret"),
            harnesses: [.fixture("claude")],
            onSecret: { sent.append($0) },
            onSecretDismiss: { dismissed += 1 }
        )
        XCTAssertNoThrow(try panel.inspect().find(text: "Close Google's dialog, then Send."))
        try panel.inspect().find(ViewType.Button.self) { (try? $0.accessibilityLabel().string()) == "Don't send" }.tap()
        XCTAssertEqual(dismissed, 1)
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Review round 1

    /// Set up by hand on Quick Connections follows the manual Add button's
    /// gates: no sheet while the view model is busy or the policy allows none.
    func testQuickConnectionAddFollowsTheManualGates() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let open = appState()
        XCTAssertFalse(open.canAddQuickConnection, "not before the view model loads")
        open.initExternalConnections(dbPool: pool)
        XCTAssertTrue(open.canAddQuickConnection)
        open.externalConnectionsViewModel?.isBusy = true
        XCTAssertFalse(open.canAddQuickConnection)

        let none = appState(policy: ["AllowedQuickConnections": [String]()])
        none.initExternalConnections(dbPool: pool)
        XCTAssertFalse(none.canAddQuickConnection)
        XCTAssertNil(none.connectAssistantButton(for: "quickConnections"))
    }

    /// A cached session whose harness the current offer no longer holds:
    /// the picker drops it, and Retry starts over on the current harness
    /// instead of running on the blocked one.
    func testRetryOnAHarnessNoLongerOfferedStartsOver() async throws {
        let state = appState(ready: ["codex"])
        let ai = ScriptedAIService()
        install(ai: ai, in: state)
        state.openConnectAssistant(service: "company")
        let session = try XCTUnwrap(state.connectAssistants.loaded("company"))
        XCTAssertEqual(session.harness.id, "codex")
        let turn = await startRun(session, ai: ai)
        ai.emit(.failure(ChatSessionError(turnID: "t", code: .rateLimit, message: "You've hit your usage limit",
                                          retryable: false, reason: "quota_exhausted")), call: turn)
        ai.finish(call: turn)
        await untilObserved { session.state == .failed(.quota) }

        // Codex is taken away (the policy, its CLI gone); Claude is offered.
        state.connectReadyProviders = ["claude"]
        XCTAssertEqual(state.connectPickerHarnesses(session), [], "the picker offers no blocked harness")
        XCTAssertTrue(state.connectAssistantPanelSession === session)
        let panelChanged = ChangeFlag()
        withObservationTracking { _ = state.connectAssistantPanelSession } onChange: { panelChanged.set() }
        state.connectAssistantRun(.retry, service: "company")
        let fresh = try XCTUnwrap(state.connectAssistants.loaded("company"))
        XCTAssertFalse(fresh === session, "a new session over the current offer")
        XCTAssertTrue(panelChanged.value, "the panel hears of the replacement")
        XCTAssertTrue(state.connectAssistantPanelSession === fresh, "the panel reads the new session")
        XCTAssertEqual(fresh.harness.id, "claude")
        XCTAssertEqual(fresh.state, .empty, "nothing runs on its own")
        XCTAssertEqual(ai.calls.count, turn + 1, "no run on the blocked harness")
        XCTAssertEqual(state.connectAssistantService, "company")

        // Nothing offered at all: the panel closes.
        state.connectReadyProviders = []
        state.connectAssistantRun(.start, service: "company")
        XCTAssertNil(state.connectAssistantService)
    }

    /// Open it focuses the related assistant only while its run holds the
    /// sign-in; a related run that is just talking goes to today's screen.
    func testOpenItFocusesOnlyTheRunHoldingTheSignIn() async throws {
        let state = appState(ready: ["codex"])
        let ai = ScriptedAIService()
        install(ai: ai, in: state)
        state.openConnectAssistant(service: "google_own_project")
        let own = try XCTUnwrap(state.connectAssistants.loaded("google_own_project"))
        _ = await startRun(own, ai: ai)
        XCTAssertNotEqual(own.state, .empty)

        state.connectAssistantService = "google"
        state.connectAssistantOpenOther(service: "google")
        XCTAssertEqual(state.connectAssistantService, "google", "a run with no sign-in is not focused")
        XCTAssertEqual(state.selectedConnection, .google)

        _ = await own.handle(ConnectWireRequest(id: 1, tool: "connect_start", args: Data("{}".utf8)))
        XCTAssertNotNil(own.controller?.activeFlow)
        state.connectAssistantOpenOther(service: "google")
        XCTAssertEqual(state.connectAssistantService, "google_own_project")
        own.close()
    }

    /// A session that is done but still answering a follow-up keeps its live
    /// chat when the offer changes and its harness is still offered; once
    /// the answer ends, a reopen makes it anew.
    func testReopenKeepsAChatStillAnsweringAfterDone() async throws {
        let state = appState(ready: ["codex"])
        let ai = ScriptedAIService()
        install(ai: ai, in: state, connects: true)
        state.openConnectAssistant(service: "company")
        let session = try XCTUnwrap(state.connectAssistants.loaded("company"))
        let turn = await startRun(session, ai: ai)
        _ = await session.handle(ConnectWireRequest(id: 1, tool: "connect_start", args: Data("{}".utf8)))
        _ = await session.handle(ConnectWireRequest(id: 2, tool: "connect_wait", args: Data("{}".utf8)))
        await untilObserved { if case .done = session.state { true } else { false } }
        XCTAssertEqual(session.engine?.isBusy, true, "the turn is still answering")

        state.connectReadyProviders = ["claude", "codex"]  // the offer changes; codex stays
        state.openConnectAssistant(service: "company")
        XCTAssertTrue(state.connectAssistants.loaded("company") === session, "the live chat is kept")
        XCTAssertEqual(session.engine?.isBusy, true, "the answer goes on")

        // Away and back (review rules: a run survives leaving the tab): the
        // answer keeps streaming and the panel shows the same session.
        state.selectedDestination = .targets
        XCTAssertEqual(session.engine?.isBusy, true, "leaving Connections stops nothing")
        state.selectedDestination = .connections
        state.openConnectAssistant(service: "company")
        XCTAssertTrue(state.connectAssistantPanelSession === session)
        XCTAssertEqual(session.engine?.isBusy, true, "the same answer still streams")

        ai.finish(call: turn)
        await untilObserved { session.engine?.isBusy == false && session.engine?.isFinishing == false }
        state.openConnectAssistant(service: "company")
        XCTAssertFalse(state.connectAssistants.loaded("company") === session, "an idle done session is made anew")
        XCTAssertTrue(state.connectAssistantPanelSession === state.connectAssistants.loaded("company"))
    }

    // MARK: - Helpers

    /// The app state's sessions over a scripted AI and a one-flow driver:
    /// the real session, no CLI.
    private func install(ai: ScriptedAIService, in state: AppState, connects: Bool = false) {
        state.connectAssistant.center = ConnectAssistantCenter { [weak state] service in
            guard let state, let initial = state.connectHarnesses.initial else { return nil }
            return ConnectAssistantSession(
                service: service, displayName: AppState.connectServiceName(service),
                harnesses: state.connectHarnesses.harnesses, initial: initial,
                driver: OneFlowDriver(service: service, connects: connects),
                aiService: ai, probe: ConnectBrowserProbe(aiService: ai), gate: EmbeddedStreamGate())
        }
        addTeardownBlock { @MainActor in state.connectAssistant.closeAll() }
    }

    private func startRun(_ session: ConnectAssistantSession, ai: ScriptedAIService) async -> Int {
        session.start()
        await session.prepared()
        await session.engine?.started()
        return ai.calls.count - 1
    }
}

/// Set from an observation's onChange (a Sendable closure).
private final class ChangeFlag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}

/// A driver whose `connect_start` starts one flow; it never ends, or with
/// `connects` it is connected at the first wait.
@MainActor
private final class OneFlowDriver: ConnectServiceDriving {
    let service: String
    let secretKinds: Set<String> = []
    private let connects: Bool

    init(service: String, connects: Bool) {
        self.service = service
        self.connects = connects
    }

    func status() async -> ConnectStatus { ConnectStatus(service: service) }
    func start(options: [String: String]) async -> Result<String, ConnectDriverError> { .success("flow-1") }
    func wait(flowID: String) async -> ConnectWaitOutcome { connects ? .connected(account: "acme") : .waiting }
    func cancel(flowID: String) async {}
    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        .failure(.badArgs("no secret"))
    }
    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> { .success(()) }
    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> { .success([]) }
    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? { nil }
    func policyAllows() -> Bool { true }
}

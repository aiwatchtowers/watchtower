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
        let state = appState(policy: ["AllowedSources": ["slack"], "AllowOwnGoogleProject": false])
        XCTAssertEqual(state.connectAssistantButton(for: "slack")?.name, "Claude")
        for blocked in ["google", "jira", "email", "linear", "google_own_project"] {
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

    func testAttentionBannerOffersReconnectWith() throws {
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
        try banner.find(button: "Reconnect with Claude").tap()
        try banner.find(button: "Reconnect").tap()
        XCTAssertEqual(opened, ["jira"])
        XCTAssertEqual(detail, [.jira])

        // An empty card offers the pair; a connected or broken one does not.
        let cards = try view.inspect().findAll(ConnectionCard.self)
        XCTAssertEqual(cards.count, 2)
        try view.inspect().find(button: "Connect with Claude").tap()
        try view.inspect().find(button: "Connect").tap()
        XCTAssertEqual(opened, ["jira", "google"])
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
}

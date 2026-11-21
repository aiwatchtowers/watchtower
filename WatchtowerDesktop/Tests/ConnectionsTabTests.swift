import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Connections tab (#899): one status rule for the cards, the banners
/// and the sidebar badge, and navigation that lands on a service.
@MainActor
final class ConnectionsTabTests: XCTestCase {
    private func account(
        _ name: String, ok: Bool, enabled: Bool = true, status: String? = nil, error: String = ""
    ) -> ConnectionAccountState {
        ConnectionAccountState(name: name, isOK: ok, enabled: enabled, status: status ?? (ok ? "ok" : "error"), error: error)
    }

    /// An isolated app state whose shared config reads a scratch file, never ~/.config.
    private func isolatedWithConfig(policy: [String: Any] = [:]) -> AppState {
        let appState = AppState.isolated(managedPolicy: policy)
        appState.managedPolicy.refresh()
        appState.sharedConfig = ConfigService(configPath: NSTemporaryDirectory() + "watchtower-tests-\(UUID().uuidString).yaml")
        return appState
    }

    /// Waits for view models' detached reads, up to 2 s.
    private func settle(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: - Summary

    func testNothingConnectedPitchesTheService() {
        do {
            let summary = ConnectionSummary(service: .linear, accounts: [], blocked: false)
            XCTAssertEqual(summary.status, .notConfigured)
            XCTAssertEqual(summary.countLine, "Not connected")
            XCTAssertEqual(summary.statusLine, ConnectionService.linear.pitch)
            XCTAssertFalse(summary.needsAttention)
        }
    }

    func testABrokenAccountNeedsTheOwner() {
        let summary = ConnectionSummary(service: .slack, accounts: [
            account("acme", ok: false, status: "revoked"),
            account("acme-labs", ok: true),
            account("acme-old", ok: false, error: "token expired")
        ], blocked: false)
        XCTAssertEqual(summary.status, .error)
        XCTAssertTrue(summary.needsAttention)
        XCTAssertEqual(summary.countLine, "3 workspaces")
        XCTAssertEqual(summary.problems.map(\.name), ["acme", "acme-old"])
        XCTAssertEqual(summary.statusLine, "acme: access revoked (and 1 more)")
    }

    /// The same rule as the old Settings list (`enabledFilteredStatus`): a
    /// switched-off account paints nothing.
    func testADisabledAccountCountsForNothing() {
        let mixed = ConnectionSummary(service: .jira, accounts: [
            account("acme.atlassian.net", ok: true),
            account("old.atlassian.net", ok: false, enabled: false)
        ], blocked: false)
        XCTAssertEqual(mixed.status, .connected)
        XCTAssertEqual(mixed.statusLine, "Connected")
        XCTAssertEqual(mixed.countLine, "2 sites")

        let off = ConnectionSummary(service: .jira, accounts: [account("old.atlassian.net", ok: false, enabled: false)], blocked: false)
        XCTAssertEqual(off.status, .notConfigured)
        XCTAssertEqual(off.statusLine, "Turned off")
        XCTAssertFalse(off.needsAttention)
    }

    func testErrorTextWinsOverStatus() {
        XCTAssertEqual(account("a", ok: false, status: "revoked", error: "invalid_auth").problem, "invalid_auth")
        XCTAssertEqual(account("a", ok: false, status: "purged").problem, "data deleted, sign in again to resync")
    }

    /// A policy-blocked source cannot be reconnected: no banner, no badge.
    func testBlockedSourceAsksNothing() {
        let summary = ConnectionSummary(service: .jira, accounts: [account("acme.atlassian.net", ok: false)], blocked: true)
        XCTAssertEqual(summary.status, .error)
        XCTAssertFalse(summary.needsAttention)
        XCTAssertEqual(summary.statusLine, SourceBlockedNotice.title)
    }

    func testAttentionCountIsServicesNotAccounts() {
        let summaries = [
            ConnectionSummary(service: .slack, accounts: [account("a", ok: false), account("b", ok: false)], blocked: false),
            ConnectionSummary(service: .google, accounts: [account("owner@example.com", ok: true)], blocked: false),
            ConnectionSummary(service: .jira, accounts: [account("acme", ok: false)], blocked: true),
            ConnectionSummary(service: .email, accounts: [account("owner@example.com", ok: false)], blocked: false)
        ]
        XCTAssertEqual(ConnectionSummary.attentionCount(summaries), 2)
    }

    func testEveryServiceIsInOneGroup() {
        XCTAssertEqual(Set(ConnectionService.services + ConnectionService.pages), Set(ConnectionService.allCases))
        XCTAssertEqual(ConnectionService.services, ConnectionService.sources + ConnectionService.aiTools)
        XCTAssertTrue(Set(ConnectionService.sources).isDisjoint(with: ConnectionService.aiTools))
        XCTAssertTrue(Set(ConnectionService.services).isDisjoint(with: ConnectionService.pages), "a page is no service card")
    }

    // MARK: - Badge from the live view models

    func testBadgeCountsAServiceWithAnExpiredToken() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO slack_accounts (id, team_name, status, error, enabled)
                VALUES (1, 'acme', 'revoked', 'token expired', 1), (2, 'acme-labs', 'ok', '', 1)
                """)
        }
        let appState = AppState.isolated()
        XCTAssertEqual(appState.connectionsAttentionCount, 0, "nothing loaded: nothing to ask")
        appState.initSlackAccounts(dbPool: pool)
        await appState.slackAccountsViewModel?.refreshAsync()
        XCTAssertEqual(appState.connectionsAttentionCount, 1)
        XCTAssertEqual(appState.connectionSummary(.slack).statusLine, "acme: token expired")

        try await pool.write { db in try db.execute(sql: "UPDATE slack_accounts SET status = 'ok', error = '' WHERE id = 1") }
        await appState.slackAccountsViewModel?.refreshAsync()
        XCTAssertEqual(appState.connectionsAttentionCount, 0)
    }

    /// Screens spec §5: an account on the retired shared app reads "Shared
    /// app retiring" on the card; it is not a problem, so no badge, and a
    /// real problem still wins the line.
    func testSharedAppCardIsNotAttention() {
        let ok = ConnectionAccountState(name: "acme", isOK: true, status: "ok", error: "")
        let notice = "Shared app retiring"
        let card = ConnectionSummary(service: .slack, accounts: [ok], blocked: false, notice: notice)
        XCTAssertEqual(card.statusLine, notice)
        XCTAssertFalse(card.needsAttention)
        XCTAssertEqual(ConnectionSummary.attentionCount([card]), 0)

        let broken = ConnectionAccountState(name: "beta", isOK: false, status: "revoked", error: "token expired")
        let both = ConnectionSummary(service: .slack, accounts: [ok, broken], blocked: false, notice: notice)
        XCTAssertEqual(both.statusLine, "beta: token expired", "a problem wins")
        XCTAssertTrue(both.needsAttention)
    }

    // MARK: - Navigation

    func testOpenConnectionsLandsOnTheService() {
        let appState = AppState.isolated()
        appState.selectedDestination = .home
        appState.openConnections(.google)
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .google)
        appState.openConnections()
        XCTAssertNil(appState.selectedConnection, "nil opens the overview")
    }

    func testPurgeNoticeOpensItsSourceOrTheOverview() {
        let appState = AppState.isolated()
        appState.openAccountConnection(source: "jira")
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .jira)
        appState.openAccountConnection(source: "unknown")
        XCTAssertNil(appState.selectedConnection)
    }

    /// The Slack detail runs its connect on AppState's flow, not a view's
    /// own, so a connect survives leaving the service or the tab.
    func testSlackDetailUsesTheAppStateFlow() throws {
        let appState = isolatedWithConfig()
        let split = ConnectionsDetailSplit(service: .slack).environment(appState)
        let detail = try split.inspect().find(SlackConnectionDetail.self).actualView()
        XCTAssertTrue(detail.flow === appState.slackAuthFlow)
    }

    /// The split: All Connections goes back to the overview, the open
    /// service's own detail shows, and a blocked source gets its notice.
    func testDetailSplitBackButtonDetailAndBlockedNotice() throws {
        let appState = isolatedWithConfig(policy: ["AllowedSources": ["slack"]])
        appState.openConnections(.jira)
        let jira = ConnectionsDetailSplit(service: .jira).environment(appState)
        XCTAssertNoThrow(try jira.inspect().find(JiraConnectionDetail.self))
        XCTAssertNoThrow(try jira.inspect().find(SourceBlockedNotice.self))
        try jira.inspect().find(button: "All Connections").tap()
        XCTAssertNil(appState.selectedConnection)

        let slack = ConnectionsDetailSplit(service: .slack).environment(appState)
        XCTAssertThrowsError(try slack.inspect().find(SourceBlockedNotice.self))
    }

    /// **Set up for my company** opens the wizard's page in the detail area
    /// (company screens spec §2.2); ‹ Connections returns to the overview and
    /// the wizard, held on AppState, keeps what was entered.
    func testCompanySetupDestination() throws {
        let appState = isolatedWithConfig()
        appState.selectedDestination = .home
        appState.openCompanySetup()
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .companySetup)
        let model = appState.companySetup
        model.toggle(.google)

        let split = ConnectionsDetailSplit(service: .companySetup).environment(appState)
        let page = try split.inspect().find(CompanySetupPage.self).actualView()
        XCTAssertTrue(page.model === model)
        XCTAssertThrowsError(try split.inspect().find(button: "All Connections"), "the page brings its own way back")
        try split.inspect().find(button: CompanySetupWizardModel.backToConnections).tap()
        XCTAssertNil(appState.selectedConnection)
        XCTAssertTrue(appState.companySetup === model)
        XCTAssertEqual(appState.companySetup.ticked, [.google], "the draft in progress is kept")
        XCTAssertFalse(appState.connectionSummaries.contains { $0.service == .companySetup }, "no card, no badge")
    }

    /// The setup-record rows of Connections → Slack open the wizard (A19).
    func testSlackRecordRowsRoute() {
        func record(_ stage: String) -> SlackSetupRecord {
            SlackSetupRecord(teamID: "T0ACME", teamName: "acme", appID: "A0ACME", clientID: "1111.2222", connected: true,
                             linkWritten: false, installRequested: false, stage: stage)
        }
        let appState = AppState.isolated()
        for stage in ["pending_create", "install", "approval"] {
            XCTAssertFalse(appState.routeSlackSetupRecord(record(stage)), stage)
            XCTAssertNil(appState.selectedConnection, "\(stage) stays on plan B's sheet")
        }
        XCTAssertTrue(appState.routeSlackSetupRecord(record("link_missing")))
        XCTAssertEqual(appState.selectedConnection, .companySetup)
    }

    /// A day plan's Jira item opens Connections → Jira (the Boards tab before #899).
    func testDayPlanJiraItemOpensConnectionsOnJira() {
        let appState = AppState.isolated()
        appState.selectedDestination = .inbox
        let item = DayPlanItem(row: ["id": 1, "day_plan_id": 1, "kind": "backlog", "source_type": "jira",
                                     "source_id": "PROJ-1", "title": "Ship it"])
        appState.openDayPlanItemSource(item)
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertEqual(appState.selectedConnection, .jira)
    }

    // MARK: - Account reads

    /// Every service's view model is re-read (Linear reads through the CLI
    /// and has no seam here; its case is in the same exhaustive switch).
    func testRefreshReReadsEveryServicesAccounts() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        func addOneEach(_ n: Int) async throws {
            try await pool.write { db in
                try TestDatabase.insertSlackAccount(db, teamName: "acme-\(n)")
                try TestDatabase.insertJiraAccount(db, siteURL: "https://acme-\(n).atlassian.net")
                try TestDatabase.insertEmailAccount(db, emailAddress: "owner\(n)@example.com")
                try TestDatabase.insertCalendarAccount(db, username: "owner\(n)@example.com")
                try TestDatabase.insertGoogleAccount(db, email: "owner\(n)@example.com")
                try db.execute(sql: "INSERT INTO external_connections (name, kind, enabled) VALUES (?, 'http', 1)",
                               arguments: ["mcp-\(n)"])
            }
        }
        let services: [ConnectionService] = [.slack, .jira, .email, .calendar, .google, .quickConnections]
        func counts(_ appState: AppState) -> [Int] { services.map { appState.connectionSummary($0).accountCount } }

        try await addOneEach(1)
        let appState = AppState.isolated()
        appState.initSlackAccounts(dbPool: pool)
        appState.initJiraAccounts(dbPool: pool)
        appState.initEmailAccounts(dbPool: pool)
        appState.initCalendarAccounts(dbPool: pool)
        appState.initGoogleAccounts(dbPool: pool)
        appState.initExternalConnections(dbPool: pool)
        // Each view model's own first read is done before the second row lands.
        try await settle { counts(appState).allSatisfy { $0 == 1 } }
        XCTAssertEqual(counts(appState), Array(repeating: 1, count: services.count))

        try await addOneEach(2)
        appState.refreshConnectionAccounts()
        try await settle { counts(appState).allSatisfy { $0 == 2 } }
        XCTAssertEqual(counts(appState), Array(repeating: 2, count: services.count), "\(services)")
    }

    /// A sidebar click re-reads the accounts for the badge at most once a minute.
    func testSidebarRefreshIsThrottled() {
        let appState = AppState.isolated()
        let start = Date(timeIntervalSince1970: 1_000_000)
        appState.refreshConnectionAccountsIfStale(now: start)
        XCTAssertEqual(appState.connectionAccountsReadAt, start, "the first click reads")
        appState.refreshConnectionAccountsIfStale(now: start.addingTimeInterval(59))
        XCTAssertEqual(appState.connectionAccountsReadAt, start, "within a minute: no read")
        appState.refreshConnectionAccountsIfStale(now: start.addingTimeInterval(60))
        XCTAssertEqual(appState.connectionAccountsReadAt, start.addingTimeInterval(60))
        // The tab's own read on appear counts too.
        appState.refreshConnectionAccounts(now: start.addingTimeInterval(100))
        appState.refreshConnectionAccountsIfStale(now: start.addingTimeInterval(130))
        XCTAssertEqual(appState.connectionAccountsReadAt, start.addingTimeInterval(100))
    }

    /// Slack, Jira, Linear and Quick Connections carry their Enabled switch
    /// into the summary; Google, Email and Calendar have none.
    func testEachServicesAccountsMapWithTheirSwitch() {
        let off = ConnectionAccountState(SlackAccount(row: ["id": 1, "team_name": "acme", "status": "error", "enabled": false]))
        XCTAssertEqual(off.name, "acme")
        XCTAssertFalse(off.enabled)
        XCTAssertFalse(ConnectionAccountState(JiraAccount(row: ["id": 1, "site_url": "x", "status": "ok", "enabled": false])).enabled)
        XCTAssertFalse(ConnectionAccountState(LinearAccount(id: 1, orgName: "acme", status: "revoked", enabled: false)).enabled)
        let mcp = ConnectionAccountState(ExternalConnection(row: ["id": 1, "name": "notion", "enabled": false, "status": "error"]))
        XCTAssertEqual(mcp.name, "notion")
        XCTAssertFalse(mcp.enabled)
        XCTAssertTrue(ConnectionAccountState(GoogleAccount(row: ["id": 1, "email": "owner@example.com", "status": "revoked"])).enabled)
        XCTAssertTrue(ConnectionAccountState(EmailAccount(row: ["id": 1, "email_address": "owner@example.com"])).enabled)
        XCTAssertTrue(ConnectionAccountState(CalendarAccount(row: ["id": 1, "username": "owner"])).enabled)
        // A switched-off broken Linear workspace asks nothing of the owner.
        let linear = ConnectionSummary(service: .linear, accounts: [
            ConnectionAccountState(LinearAccount(id: 1, orgName: "acme", status: "revoked", enabled: false))
        ], blocked: false)
        XCTAssertFalse(linear.needsAttention)
    }

    /// Through AppState: a source the policy blocks shows its lock and
    /// never lights the badge, however broken its accounts.
    func testPolicyBlockedSourceThroughAppState() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try TestDatabase.insertJiraAccount(db, siteURL: "https://acme.atlassian.net", status: "revoked", error: "token expired")
        }
        let appState = AppState.isolated(managedPolicy: ["AllowedSources": ["slack"]])
        appState.managedPolicy.refresh()
        appState.initJiraAccounts(dbPool: pool)
        await appState.jiraAccountsViewModel?.refreshAsync()
        let jira = appState.connectionSummary(.jira)
        XCTAssertTrue(jira.blocked)
        XCTAssertEqual(jira.status, .error)
        XCTAssertEqual(jira.statusLine, SourceBlockedNotice.title)
        XCTAssertEqual(appState.connectionsAttentionCount, 0)
    }

    // MARK: - Unknown accounts

    /// Accounts that could not be read are neither "not connected" nor a
    /// problem: no pitch, no badge.
    func testUnreadableAccountsAreUnknown() {
        for summary in [
            ConnectionSummary(service: .linear, accounts: nil, blocked: false),
            ConnectionSummary(service: .linear, accounts: [], readError: "Watchtower CLI not found", blocked: false)
        ] {
            XCTAssertTrue(summary.unknown)
            XCTAssertEqual(summary.statusLine, "Couldn't read accounts")
            XCTAssertNotEqual(summary.countLine, "Not connected")
            XCTAssertFalse(summary.needsAttention)
        }
        // An error beside a listed account is an action's, not the read's.
        let listed = ConnectionSummary(service: .slack, accounts: [account("acme", ok: true)], readError: "Reconnect failed", blocked: false)
        XCTAssertFalse(listed.unknown)
        XCTAssertEqual(listed.statusLine, "Connected")
    }

    /// Only a failed account read makes a service unknown, and the next good
    /// read clears it; an action's failure (a wrong password, a failed
    /// connect) beside no account is still "Not connected". Neither lights
    /// the badge.
    func testOnlyAFailedReadMakesAccountsUnknown() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let appState = AppState.isolated()
        appState.initEmailAccounts(dbPool: pool)
        let vm = try XCTUnwrap(appState.emailAccountsViewModel)
        await vm.refreshAsync()

        vm.error = "Add failed: authentication failed"
        XCTAssertFalse(appState.connectionSummary(.email).unknown)
        XCTAssertEqual(appState.connectionSummary(.email).countLine, "Not connected")

        try await pool.write { db in try db.execute(sql: "ALTER TABLE email_accounts RENAME TO email_accounts_away") }
        await vm.refreshAsync()
        XCTAssertNotNil(vm.readError)
        XCTAssertTrue(appState.connectionSummary(.email).unknown)
        XCTAssertEqual(appState.connectionSummary(.email).statusLine, "Couldn't read accounts")
        XCTAssertEqual(appState.connectionsAttentionCount, 0)

        try await pool.write { db in try db.execute(sql: "ALTER TABLE email_accounts_away RENAME TO email_accounts") }
        await vm.refreshAsync()
        XCTAssertNil(vm.readError)
        XCTAssertFalse(appState.connectionSummary(.email).unknown)
        XCTAssertEqual(appState.connectionSummary(.email).countLine, "Not connected")
    }

    func testProblemWithNoStatusOrErrorStillSaysSo() {
        XCTAssertEqual(account("acme", ok: false, status: "").problem, "needs attention")
    }

    // MARK: - Removed tabs (#899)

    /// `search` and `boards` may sit in `sidebar.hiddenItems` from an older
    /// build: they decode to nothing, hide nothing that shows now, and a
    /// `watchtower-nav://` link naming one opens nothing.
    func testRemovedTabsInStoredValuesAreIgnored() throws {
        XCTAssertNil(SidebarDestination(rawValue: "search"))
        XCTAssertNil(SidebarDestination(rawValue: "boards"))
        let stale: Set<String> = ["search", "boards"]
        for section in SidebarSection.ordered {
            XCTAssertEqual(section.partition(hidden: stale).visible, section.items, section.title)
        }

        let appState = AppState.isolated()
        appState.selectedDestination = .inbox
        XCTAssertFalse(appState.visibleHelpScreenIDs.contains("search"))
        XCTAssertFalse(appState.visibleHelpScreenIDs.contains("boards"))
        XCTAssertTrue(appState.visibleHelpScreenIDs.contains("connections"))
        for screen in ["search", "boards"] {
            appState.openNavLink(try XCTUnwrap(URL(string: "watchtower-nav://\(screen)")))
            XCTAssertEqual(appState.selectedDestination, .inbox, screen)
        }
        appState.selectedConnection = .jira
        appState.openNavLink(try XCTUnwrap(URL(string: "watchtower-nav://connections")))
        XCTAssertEqual(appState.selectedDestination, .connections)
        XCTAssertNil(appState.selectedConnection, "a link opens the overview")
    }

    // MARK: - Jira detail

    /// The Boards tab's sections live in the Jira detail once a site is
    /// connected (#899); with no site there is nothing to choose.
    func testJiraDetailHoldsTheBoardsOnceASiteIsConnected() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let appState = AppState.isolated()
        appState.initJiraAccounts(dbPool: pool)
        await appState.jiraAccountsViewModel?.refreshAsync()
        let empty = JiraConnectionDetail().environment(appState)
        XCTAssertThrowsError(try empty.inspect().find(JiraBoardsSettingsView.self))

        try await pool.write { db in
            try db.execute(sql: "INSERT INTO jira_accounts (id, site_url, status) VALUES (1, 'https://acme.atlassian.net', 'ok')")
        }
        await appState.jiraAccountsViewModel?.refreshAsync()
        let connected = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try connected.inspect().find(JiraBoardsSettingsView.self))
        XCTAssertNoThrow(try connected.inspect().find(JiraFeaturesSettingsView.self))
        XCTAssertNoThrow(try connected.inspect().find(JiraUserMappingSettingsView.self))
        XCTAssertNoThrow(try connected.inspect().find(JiraSyncInfoView.self))
    }

    // MARK: - Overview

    func testOverviewShowsABannerOnlyForServicesThatNeedTheOwner() throws {
        var opened: [ConnectionService] = []
        let summaries = [
            ConnectionSummary(service: .slack, accounts: [account("acme", ok: false, error: "token expired")], blocked: false),
            ConnectionSummary(service: .google, accounts: [account("owner@example.com", ok: true)], blocked: false),
            ConnectionSummary(service: .quickConnections, accounts: [], blocked: false)
        ]
        let view = ConnectionsOverviewContent(summaries: summaries) { opened.append($0) }
        let banners = try view.inspect().findAll(ConnectionAttentionBanner.self)
        XCTAssertEqual(banners.count, 1)
        XCTAssertNoThrow(try view.inspect().find(text: "Slack · acme: token expired"))
        try view.inspect().find(button: "Reconnect").tap()
        XCTAssertEqual(opened, [.slack])

        XCTAssertEqual(try view.inspect().findAll(ConnectionCard.self).count, 3)
        XCTAssertNoThrow(try view.inspect().find(ViewType.Menu.self).find(button: "Google"))
        XCTAssertNoThrow(try view.inspect().find(text: ConnectionService.quickConnections.pitch))
    }

    // MARK: - Companies zone (#1887 Task 25a)

    /// Company screens spec §4.1: the zone sits between the banners and
    /// Sources, its card's button reaches the connect flow with the slug.
    func testCompaniesZoneAboveSources() throws {
        let acme = CompanyRef(slug: "acme", name: "Acme", vendors: [.slack: "", .linear: ""])
        let state = CompanyConnectionsPresentation.zone(
            companies: [acme], errors: [], draft: nil,
            accounts: [AccountRef(vendor: .slack, accountID: 1, label: "acme", companySlug: "acme", status: "ok", error: "")],
            portBusy: false, loading: false)
        var rest: [String] = []
        var actions = CompaniesZoneActions()
        actions.connectRest = { rest.append($0) }
        let model = CompaniesZoneModel { nil }
        let view = ConnectionsOverviewContent(
            summaries: [ConnectionSummary(service: .slack, accounts: [account("acme", ok: true)], blocked: false)],
            companies: CompaniesZone(state: state, model: model, actions: actions)
        ) { _ in }
        let titles = try view.inspect().findAll(HomeZoneTitle.self).map { try $0.actualView().title }
        XCTAssertEqual(titles, [CompanyConnectionsPresentation.companiesTitle, "Sources", "Tools for AI"])
        XCTAssertNoThrow(try view.inspect().find(text: "1 of 2 services connected"))
        XCTAssertNoThrow(try view.inspect().find(text: "Not connected: Linear"))
        try view.inspect().find(button: "Connect the rest").tap()
        XCTAssertEqual(rest, ["acme"])

        // Connect with a company code opens the field in place of the quiet buttons.
        try view.inspect().find(button: CompaniesZoneState.Action.connectWithCode.title).tap()
        XCTAssertTrue(model.codeFieldOpen)
    }

    /// The zone's states through the view: loading, read failed with Try
    /// again, the empty invitation, the port-busy line with the code field,
    /// the setup line, and a card's waiting sign-in (with Cancel) while its chain runs.
    func testCompaniesZoneStates() throws {
        typealias Pres = CompanyConnectionsPresentation
        let model = CompaniesZoneModel { nil }
        var actions = CompaniesZoneActions()
        var pressed: [String] = []
        actions.tryAgain = { pressed.append("tryAgain") }
        actions.setUpForCompany = { pressed.append("setUp") }
        actions.continueSetup = { pressed.append("continue") }
        actions.connectAll = { pressed.append("all:\($0)") }
        actions.stopChain = { pressed.append("stop") }
        func zone(_ state: CompaniesZoneState, connecting: (slug: String, vendor: CompanyVendor)? = nil) -> CompaniesZone {
            CompaniesZone(state: state, model: model, connecting: connecting, actions: actions)
        }
        func state(
            _ companies: [CompanyRef] = [],
            draft: CompanySetupDraftRef? = nil,
            portBusy: Bool = false,
            loading: Bool = false,
            listError: String? = nil
        ) -> CompaniesZoneState {
            Pres.zone(companies: companies, errors: [], draft: draft, accounts: [], portBusy: portBusy, loading: loading,
                      listError: listError)
        }

        XCTAssertNoThrow(try zone(state(loading: true)).inspect().find(text: Pres.companiesLoading))

        let failed = state(listError: "database is locked")
        try zone(failed).inspect().find(button: Pres.tryAgain).tap()
        XCTAssertThrowsError(try zone(failed).inspect().find(text: Pres.companiesEmpty), "a failed read is not no company")

        XCTAssertNoThrow(try zone(state()).inspect().find(text: Pres.companiesEmpty))
        try zone(state()).inspect().find(button: CompaniesZoneState.Action.setUpForCompany.title).tap()

        let busy = state(portBusy: true)
        XCTAssertNoThrow(try zone(busy).inspect().find(text: Pres.portBusyLine))
        XCTAssertNoThrow(try zone(busy).inspect().find(button: Pres.connect), "the code field opens with the line")
        XCTAssertNoThrow(try zone(busy).inspect().find(button: CompaniesZoneState.Action.setUpForCompany.title),
                         "a busy port never hides the way into the setup")

        let draft = state(draft: .inProgress(company: "Acme", step: "Atlassian", index: 3, count: 8))
        try zone(draft).inspect().find(button: "Continue setup").tap()

        let mdm = state([CompanyRef(slug: "acme", name: "Acme", forced: true, vendors: [.google: "example.com"])])
        let running = zone(mdm, connecting: (slug: "acme", vendor: .google))
        // C1: the card's waiting sign-in, its Cancel stops the hidden chain.
        let wait = SignInWaitCopy.google
        XCTAssertNoThrow(try running.inspect().find(text: wait.line))
        XCTAssertNoThrow(try running.inspect().find(text: wait.hint))
        try running.inspect().find(button: wait.cancelTitle).tap()
        XCTAssertThrowsError(try zone(mdm).inspect().find(text: wait.line))
        try zone(mdm).inspect().find(button: "Connect all").tap()
        XCTAssertEqual(pressed, ["tryAgain", "setUp", "continue", "stop", "all:acme"])
    }

    /// A5 unchanged: a company's Re-login row needs the owner (banner and
    /// badge), a vendor it has not connected yet does not, and a company's
    /// card is never an attention item of its own.
    func testAttentionRuleUnchanged() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO slack_accounts (id, team_name, status, error, enabled, company_slug)
                VALUES (1, 'acme', 'ok', '', 1, 'acme')
                """)
        }
        let (appState, fake) = LinearConnectionDetailTests.wired()
        appState.initSlackAccounts(dbPool: pool)
        await appState.slackAccountsViewModel?.refreshAsync()
        fake.enqueue(.init(lines: [#"{"companies":[{"slug":"acme","company":"Acme","forced":false,"personal":false,"#
                + #""vendors":{"slack":{"client_id":"1.2"},"linear":{"client_id":"l"}}}],"errors":[],"draft":{"state":"none"}}"#]))
        await appState.companiesZone.reload()

        XCTAssertEqual(appState.companiesZoneState.body.cards.first?.missingLine, "Not connected: Linear")
        XCTAssertEqual(appState.connectionsAttentionCount, 0, "Not connected is no problem")

        try await pool.write { db in
            try db.execute(sql: "UPDATE slack_accounts SET status = 'error', error = 'company_changed_app' WHERE id = 1")
        }
        await appState.slackAccountsViewModel?.refreshAsync()
        XCTAssertEqual(appState.connectionsAttentionCount, 1, "a Re-login row is")
        XCTAssertEqual(appState.companiesZoneState.body.cards.first?.problemLine, "Slack: Re-login needed — Acme changed its app")
        let ref = try XCTUnwrap(appState.companyAccountRefs.first { $0.vendor == .slack })
        XCTAssertEqual(appState.companyRowStatus(ref)?.needsAttention, true)
    }

    /// Connect… offers only what the policy allows.
    func testConnectMenuHidesBlockedServices() throws {
        let summaries = [
            ConnectionSummary(service: .slack, accounts: [], blocked: false),
            ConnectionSummary(service: .jira, accounts: [], blocked: true)
        ]
        let view = ConnectionsOverviewContent(summaries: summaries) { _ in }
        let menu = try view.inspect().find(ViewType.Menu.self)
        XCTAssertNoThrow(try menu.find(button: "Slack"))
        XCTAssertThrowsError(try menu.find(button: "Jira"))
    }
}

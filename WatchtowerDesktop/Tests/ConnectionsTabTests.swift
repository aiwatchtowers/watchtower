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

    // MARK: - Summary

    func testNothingConnectedPitchesTheService() {
        for accounts in [nil, [ConnectionAccountState]()] {
            let summary = ConnectionSummary(service: .linear, accounts: accounts, blocked: false)
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
        XCTAssertEqual(Set(ConnectionService.sources + ConnectionService.aiTools), Set(ConnectionService.allCases))
        XCTAssertTrue(Set(ConnectionService.sources).isDisjoint(with: ConnectionService.aiTools))
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

    /// A Slack reconnect started in the tab is still there after a trip to
    /// another tab: its state is AppState's, not the detail view's.
    func testSlackFlowSurvivesLeavingTheTab() {
        let appState = AppState.isolated()
        appState.openConnections(.slack)
        let flow = appState.slackAuthFlow
        flow.reconnecting = true
        appState.selectedDestination = .home
        appState.openConnections(.slack)
        XCTAssertTrue(appState.slackAuthFlow === flow)
        XCTAssertTrue(appState.slackAuthFlow.reconnecting)
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
        appState.openNavLink(try XCTUnwrap(URL(string: "watchtower-nav://connections")))
        XCTAssertEqual(appState.selectedDestination, .connections)
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
        XCTAssertNoThrow(try view.inspect().find(text: ConnectionService.quickConnections.pitch))
    }
}

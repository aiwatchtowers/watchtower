import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// With Slack Live only, Catch-Up and Statistics stay in the sidebar and
/// show `needsFullSlack`; no other messages tab appears (screens spec §2.2,
/// owner ask #1315).
@MainActor
final class SidebarSlackLiveTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        dbManager = nil
        TestDatabase.cleanup(path: dbPath)
        try await super.tearDown()
    }

    func testLiveOnlyShowsCatchUpAndStatistics() {
        let live = ConnectedSources(slackLive: true)
        XCTAssertTrue(SidebarDestination.catchUp.isVisible(disabledFeatures: [], connected: live))
        XCTAssertTrue(SidebarDestination.statistics.isVisible(disabledFeatures: [], connected: live))
        XCTAssertFalse(SidebarDestination.catchUp.isVisible(disabledFeatures: [], connected: .none))
        XCTAssertFalse(SidebarDestination.statistics.isVisible(disabledFeatures: [], connected: .none))
    }

    /// Live is not a messages source: every other tab gated on messages
    /// (and nothing else Live provides) stays as it was.
    func testLiveDoesNotCountAsMessages() {
        let live = ConnectedSources(slackLive: true)
        for destination in SidebarDestination.allCases where destination != .catchUp && destination != .statistics {
            XCTAssertEqual(
                destination.isVisible(disabledFeatures: [], connected: live),
                destination.isVisible(disabledFeatures: [], connected: .none),
                destination.rawValue)
        }
    }

    /// A probe (another process) writes `slack_live_status`; the Live
    /// center's next read changes its statuses, and the sidebar's sources
    /// follow: the tabs come with Live and go with Off.
    func testRefreshOnLiveStatusChange() async throws {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        appState.initSlackLive(dbPool: dbManager.dbPool, cliRunner: nil)
        let center = try XCTUnwrap(appState.slackLiveStatusCenter)
        await center.reload()
        await appState.refreshConnectedSources()
        XCTAssertFalse(appState.featureVisibility.connectedSources.slackLive)

        try await insertStatus("ok", team: "T1", at: "2026-11-18T09:00:00.000000000Z")
        await center.reload()
        XCTAssertTrue(appState.featureVisibility.connectedSources.slackLive)
        XCTAssertTrue(SidebarDestination.catchUp.isVisible(
            disabledFeatures: [], connected: appState.featureVisibility.connectedSources))

        try await insertStatus("not_connected", team: "", at: "2026-11-18T10:00:00.000000000Z")
        await center.reload()
        XCTAssertFalse(appState.featureVisibility.connectedSources.slackLive)
        XCTAssertFalse(SidebarDestination.statistics.isVisible(
            disabledFeatures: [], connected: appState.featureVisibility.connectedSources))
    }

    /// A Live write the center did not make (a chat) reaches the readiness
    /// first; the sidebar's sources follow it without opening the pane.
    func testReadinessLiveChangeRefreshesConnectedSources() async throws {
        let appState = AppState.isolated()
        appState.databaseManager = dbManager
        appState.initSlackLive(dbPool: dbManager.dbPool, cliRunner: nil)
        appState.readinessCenter.start(pool: dbManager.dbPool)
        defer { appState.readinessCenter.stop() }
        await untilObserved { !appState.readinessCenter.readiness.isEmpty }
        await appState.refreshConnectedSources()
        XCTAssertFalse(appState.featureVisibility.connectedSources.slackLive)

        try await insertStatus("ok", team: "T1", at: "2026-11-18T09:00:00.000000000Z")
        await appState.readinessCenter.rereadDatabase()
        await untilObserved { appState.featureVisibility.connectedSources.slackLive }
        XCTAssertTrue(SidebarDestination.catchUp.isVisible(
            disabledFeatures: [], connected: appState.featureVisibility.connectedSources))
    }

    private func insertStatus(_ status: String, team: String, at: String) async throws {
        try await dbManager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO slack_live_status (team_id, provider, status, error_class, connector_id, checked_at)
                VALUES (?, 'claude', ?, '', '', ?)
                """, arguments: [team, status, at])
        }
    }
}

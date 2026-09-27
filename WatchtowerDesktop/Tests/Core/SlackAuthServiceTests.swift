import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Settings → Slack "Workspace" status used to read `config.yaml`'s
/// `workspaces.<active>.slack_token`, which the multi-account CLI no longer
/// writes (it moves the token into `slack_token_<id>.json`), so every
/// post-migration install showed "Slack not connected" next to healthy
/// accounts. The status now comes from `slack_accounts` alone — no config
/// file is involved at all, which is exactly the post-migration shape.
@MainActor
final class SlackAuthServiceTests: XCTestCase {
    private func makePool() throws -> DatabasePool {
        let (pool, _) = try TestDatabase.createPool()
        return pool
    }

    func testConnectedWhenAnEnabledAccountRowExists() async throws {
        let pool = try makePool()
        try await pool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamName: "Acme") }

        let service = SlackAuthService()
        service.configure(dbPool: pool)
        await service.refreshStatus()

        XCTAssertTrue(service.isConnected)
        XCTAssertNil(service.error)
    }

    func testNotConnectedWhenOnlyDisabledOrRemovedAccountsExist() async throws {
        let pool = try makePool()
        try await pool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, enabled: false)
            _ = try TestDatabase.insertSlackAccount(db, status: "removed", enabled: false)
        }

        let service = SlackAuthService()
        service.configure(dbPool: pool)
        await service.refreshStatus()

        XCTAssertFalse(service.isConnected)
    }

    /// The Settings pane refreshes on every change to the Workspaces list;
    /// a refresh after the last account is removed must report disconnected.
    func testRefreshAfterRemovingTheLastAccountReportsNotConnected() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertSlackAccount(db, teamName: "Acme") }
        let service = SlackAuthService()
        service.configure(dbPool: pool)
        await service.refreshStatus()
        XCTAssertTrue(service.isConnected)

        try await pool.write { db in
            try db.execute(sql: "UPDATE slack_accounts SET status = 'removed', enabled = 0 WHERE id = ?", arguments: [id])
        }
        await service.refreshStatus()

        XCTAssertFalse(service.isConnected)
    }

    /// `auth logout` removes the lowest-id row. With #1 removed and #2 still
    /// enabled, Slack is connected but a Workspace-level Disconnect would only
    /// re-remove #1 — so it is not offered.
    func testDisconnectOfferedOnlyWhileAccountOneIsConnected() async throws {
        let pool = try makePool()
        let (first, _) = try await pool.write { db -> (Int64, Int64) in
            (try TestDatabase.insertSlackAccount(db, teamName: "First"),
             try TestDatabase.insertSlackAccount(db, teamName: "Second"))
        }
        let service = SlackAuthService()
        service.configure(dbPool: pool)
        await service.refreshStatus()
        XCTAssertEqual(service.disconnectTarget?.displayName, "First")

        try await pool.write { db in
            try db.execute(sql: "UPDATE slack_accounts SET status = 'removed', enabled = 0 WHERE id = ?", arguments: [first])
        }
        await service.refreshStatus()

        XCTAssertTrue(service.isConnected)
        XCTAssertNil(service.disconnectTarget)
    }

    func testLogoutTargetIgnoresADisabledAccountOne() throws {
        let pool = try makePool()
        let rows = try pool.write { db -> [SlackAccount] in
            _ = try TestDatabase.insertSlackAccount(db, enabled: false)
            _ = try TestDatabase.insertSlackAccount(db)
            return try SlackAccountQueries.fetchAll(db)
        }
        XCTAssertNil(SlackAuthService.logoutTarget(in: rows))
        XCTAssertNil(SlackAuthService.logoutTarget(in: []))
    }

    /// A failed read shows its error; the next successful read must clear it
    /// rather than leave a stale "Couldn't read Slack accounts" on screen.
    func testSuccessfulRefreshClearsAnEarlierReadError() async throws {
        let pool = try makePool()
        try await pool.write { db in _ = try TestDatabase.insertSlackAccount(db) }
        let service = SlackAuthService()
        service.configure(dbPool: pool)

        try await pool.write { db in try db.execute(sql: "ALTER TABLE slack_accounts RENAME TO slack_accounts_away") }
        await service.refreshStatus()
        XCTAssertNotNil(service.error)

        try await pool.write { db in try db.execute(sql: "ALTER TABLE slack_accounts_away RENAME TO slack_accounts") }
        await service.refreshStatus()
        XCTAssertNil(service.error)
        XCTAssertTrue(service.isConnected)
    }

    func testNotConnectedWithoutADatabase() async {
        let service = SlackAuthService()
        await service.refreshStatus()
        XCTAssertFalse(service.isConnected)
    }

    func testHasConnectedAccountIgnoresDisabledAndRemovedRows() throws {
        let pool = try makePool()
        XCTAssertFalse(try pool.read { db in try SlackAccountQueries.hasConnectedAccount(db) })

        try pool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, enabled: false)
            // An enabled row whose status is "removed" still does not count.
            _ = try TestDatabase.insertSlackAccount(db, status: "removed", enabled: true)
        }
        XCTAssertFalse(try pool.read { db in try SlackAccountQueries.hasConnectedAccount(db) })

        // A revoked-but-enabled account is still a connected account (it shows
        // its own status row in the list below the Workspace section).
        try pool.write { db in _ = try TestDatabase.insertSlackAccount(db, status: "revoked") }
        XCTAssertTrue(try pool.read { db in try SlackAccountQueries.hasConnectedAccount(db) })
    }
}

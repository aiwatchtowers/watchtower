import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AccountPurgeQueriesTests: XCTestCase {
    private func seed(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO slack_accounts (id, team_name, team_domain, label, status, access_ok_at)
            VALUES (1, 'Acme', 'acme', '', 'revoked', '2026-10-01T09:00:00Z')
            """)
        try db.execute(sql: """
            INSERT INTO jira_accounts (id, site_url, site_name, label, status, access_ok_at)
            VALUES (1, 'https://acme.example.com', '', '', 'removed', '2026-09-01T09:00:00Z')
            """)
        try db.execute(sql: """
            INSERT INTO account_purges (id, source, account_id, reason, due_at, state, finished_at, rows_deleted) VALUES
            (1, 'slack', 1, 'revoked', '2026-10-24T09:00:00Z', 'scheduled', '', 0),
            (2, 'jira', 1, 'lease', '2026-10-24T09:00:00Z', 'running', '', 0),
            (3, 'google', 7, 'lease', '2026-10-10T09:00:00Z', 'done', '2026-10-15T09:00:00Z', 120),
            (4, 'linear', 2, 'revoked', '2026-10-01T09:00:00Z', 'done', '2026-10-01T09:00:00Z', 5),
            (5, 'linear', 3, 'revoked', '2026-10-01T09:00:00Z', 'cancelled', '2026-10-02T09:00:00Z', 0)
            """)
    }

    func testOpenJoinsTheAccountAndSkipsClosedRows() throws {
        let db = try TestDatabase.create()
        try db.write(seed)
        let rows = try db.read { try AccountPurgeQueries.open($0) }
        XCTAssertEqual(rows.map(\.id), [2, 1], "newest first, open only")
        XCTAssertEqual(rows[1].accountLabel, "Acme", "team name when the label is empty")
        XCTAssertEqual(rows[1].accountStatus, "revoked")
        XCTAssertEqual(rows[1].accessOkAt, PlanUsageDates.parse("2026-10-01T09:00:00Z"))
        XCTAssertEqual(rows[1].dueAt, PlanUsageDates.parse("2026-10-24T09:00:00Z"))
        XCTAssertEqual(rows[0].accountLabel, "https://acme.example.com", "site url after the site name")
        XCTAssertTrue(rows[0].isRemovedAccount)
    }

    func testRecentKeepsDoneRowsSinceTheCutoff() throws {
        let db = try TestDatabase.create()
        try db.write(seed)
        let since = try XCTUnwrap(PlanUsageDates.parse("2026-10-14T09:00:00Z"))
        let rows = try db.read { try AccountPurgeQueries.recent($0, since: since) }
        XCTAssertEqual(rows.map(\.id), [3])
        XCTAssertEqual(rows[0].rowsDeleted, 120)
        XCTAssertEqual(rows[0].accountLabel, "", "the account row is gone")
        XCTAssertEqual(rows[0].displayLabel, "Google account #7")
        XCTAssertTrue(rows[0].isRemovedAccount)
    }

    func testEmptyLedger() throws {
        let db = try TestDatabase.create()
        XCTAssertEqual(try db.read { try AccountPurgeQueries.open($0) }, [])
        XCTAssertEqual(try db.read { try AccountPurgeQueries.recent($0, since: .distantPast) }, [])
    }
}

final class AccountPurgeStatusDecodingTests: XCTestCase {
    /// The pinned `watchtower accounts purges --json` shape (TestAccountsPurgesJSONKeys).
    func testDecodesThePinnedSample() throws {
        let json = """
        {
          "enabled": true,
          "enabled_by": "build",
          "grace_hours": 72,
          "lease_days": 30,
          "purges": [
            {"id": 3, "source": "slack", "account_id": 1, "account_label": "acme", "reason": "revoked",
             "state": "scheduled", "scheduled_at": "2026-10-21T09:00:00Z", "due_at": "2026-10-24T09:00:00Z",
             "started_at": "", "finished_at": "", "rows_deleted": 0, "error": ""}
          ]
        }
        """
        let status = try AccountPurgeStatus.decode(Data(json.utf8))
        XCTAssertEqual(status, AccountPurgeStatus(enabled: true, enabledBy: "build", graceHours: 72, leaseDays: 30))
        XCTAssertFalse(status.isSetByPolicy)
    }

    func testEmptyLedgerAndPolicy() throws {
        let json = #"{"enabled": false, "enabled_by": "policy", "grace_hours": 72, "lease_days": 30, "purges": []}"#
        let status = try AccountPurgeStatus.decode(Data(json.utf8))
        XCTAssertFalse(status.enabled)
        XCTAssertTrue(status.isSetByPolicy)
    }

    func testMissingKeyThrows() {
        XCTAssertThrowsError(try AccountPurgeStatus.decode(Data(#"{"enabled": true}"#.utf8)))
    }
}

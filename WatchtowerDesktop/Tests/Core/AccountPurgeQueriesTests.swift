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

    /// A failed purge is finished: recent lists it with the done rows (review #601).
    func testRecentListsFailedRows() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO account_purges (id, source, account_id, reason, due_at, state, finished_at, error) VALUES
                (8, 'slack', 1, 'revoked', '2026-10-15T09:00:00Z', 'failed', '2026-10-16T09:00:00Z', 'disk full')
                """)
        }
        let since = try XCTUnwrap(PlanUsageDates.parse("2026-10-14T09:00:00Z"))
        let rows = try db.read { try AccountPurgeQueries.recent($0, since: since) }
        XCTAssertEqual(rows.map(\.id), [8])
        XCTAssertTrue(rows[0].isFailed)
        XCTAssertFalse(rows[0].isDone)
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

    func testRemoveDialogMessageAddsTheLeaseOnlyWhenOn() {
        let kept = "Already-synced issues stay in Watchtower."
        func message(_ status: AccountPurgeStatus?) -> String {
            AccountPurgeStatus.removeDialogMessage(kept, status: status, policy: .none, setting: nil)
        }
        XCTAssertEqual(message(AccountPurgeStatus(enabled: false, enabledBy: "default")), kept)
        XCTAssertEqual(
            message(AccountPurgeStatus(enabled: true, enabledBy: "build", leaseDays: 14)),
            kept + " Because deleting data on revoked access is on, it is deleted about 14 days after the account "
                + "was last reached, plus 72 hours' notice."
        )
    }

    /// Fix round 1: with the CLI status unknown, the dialogs follow a forced
    /// policy or the owner's saved setting, never the "off" default.
    func testRemoveDialogUnknownStatusFollowsPolicyAndSetting() {
        var forced = ManagedPolicy()
        forced.purgeRevokedData = true
        let slackOn = "Its synced data stays for now and is deleted in 72 hours unless you add the workspace again."
        let slackOff = "deleting data when access ends is off."
        XCTAssertTrue(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: nil, policy: forced, setting: nil)
            .contains(slackOn))
        XCTAssertTrue(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: nil, policy: .none, setting: true)
            .contains(slackOn))
        XCTAssertTrue(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: nil, policy: .none, setting: false)
            .hasSuffix(slackOff))

        let kept = "Kept."
        let jiraOn = kept + " Because deleting data on revoked access is on, it is deleted about 30 days after the "
            + "account was last reached, plus 72 hours' notice."
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(kept, status: nil, policy: forced, setting: nil), jiraOn)
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(kept, status: nil, policy: .none, setting: true), jiraOn)
        XCTAssertEqual(AccountPurgeStatus.removeDialogMessage(kept, status: nil, policy: .none, setting: false), kept)
    }

    /// Fix round 1: nothing known (the CLI has not answered or failed, and a
    /// build may turn the purge on): the dialogs assert neither way.
    func testRemoveDialogAllUnknownIsNeutral() {
        let slack = AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: nil, policy: .none, setting: nil)
        XCTAssertEqual(slack, "Watchtower stops syncing acme and signs out of it at Slack, so this sign-in stops "
            + "working on every Mac that uses it. If deleting data when access ends is on, its synced data is deleted "
            + "in 72 hours unless you add the workspace again; otherwise it stays on this Mac until you delete it. "
            + "Check Settings → System → Privacy.")
        XCTAssertEqual(
            AccountPurgeStatus.removeDialogMessage("Kept.", status: nil, policy: .none, setting: nil),
            "Kept. If deleting data on revoked access is on, it is deleted about 30 days after the account was last "
                + "reached, plus 72 hours' notice; check Settings → System → Privacy."
        )
    }

    /// The notice outside the footnote: the policy's, else the CLI's, else 72.
    func testGraceHoursPrefersThePolicy() {
        var policy = ManagedPolicy()
        let status = AccountPurgeStatus(enabled: true, enabledBy: "setting", graceHours: 48)
        XCTAssertEqual(AccountPurgeStatus.graceHours(nil, policy: policy), 72)
        XCTAssertEqual(AccountPurgeStatus.graceHours(status, policy: policy), 48)
        policy.purgeGraceHours = 0
        XCTAssertEqual(AccountPurgeStatus.graceHours(status, policy: policy), 0)
    }

    /// Fix round 1: an organization's PurgeGraceHours sets the dialogs'
    /// notice even before (or against a stale) CLI status.
    func testRemoveDialogGraceFromPolicy() {
        var policy = ManagedPolicy()
        policy.purgeRevokedData = true
        policy.purgeGraceHours = 24
        let stale = AccountPurgeStatus(enabled: true, enabledBy: "policy", graceHours: 72)
        for status in [nil, stale] {
            XCTAssertTrue(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: status, policy: policy,
                                                                 setting: nil).contains("deleted in 24 hours"))
            XCTAssertTrue(AccountPurgeStatus.removeDialogMessage("Kept.", status: status, policy: policy, setting: nil)
                .hasSuffix(", plus 24 hours' notice."))
        }
        policy.purgeGraceHours = 0
        XCTAssertTrue(AccountPurgeStatus.removeDialogMessage(slackAccount: "acme", status: nil, policy: policy,
                                                             setting: nil).contains("deleted at the next sync unless"))
        XCTAssertTrue(AccountPurgeStatus.removeDialogMessage("Kept.", status: nil, policy: policy, setting: nil)
            .hasSuffix("days after the account was last reached."))
    }
}

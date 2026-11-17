import XCTest
@testable import WatchtowerCore

final class AccountPurgeNoticePolicyTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0) ?? .current
    private let due = PlanUsageDates.parse("2026-10-24T09:00:00Z")
    private let access = PlanUsageDates.parse("2026-09-21T15:30:00Z")
    private let finished = PlanUsageDates.parse("2026-10-24T09:05:00Z")

    func testRevokedLine() {
        let row = AccountPurge(id: 1, source: "slack", accountID: 1, accountLabel: "Acme", dueAt: due)
        XCTAssertEqual(
            AccountPurgeNoticePolicy.line(row, zone: utc),
            "Access to Acme was revoked. Its data will be deleted on October 24 at 09:00 unless you reconnect.")
    }

    func testLeaseLineOfALiveAccount() {
        let row = AccountPurge(id: 1, source: "jira", accountID: 2, accountLabel: "acme.example.com",
                               accountStatus: "ok", accessOkAt: access, reason: "lease", dueAt: due)
        XCTAssertEqual(
            AccountPurgeNoticePolicy.line(row, zone: utc),
            "Watchtower has not reached acme.example.com since September 21 at 15:30. "
                + "Its data will be deleted on October 24 at 09:00 unless you reconnect.")
    }

    func testLeaseLineOfARemovedAccount() {
        // A removed Slack workspace has a zero lease (testZeroLeaseRemovedLine).
        let removed = AccountPurge(id: 1, source: "jira", accountID: 2, accountLabel: "Acme",
                                   accountStatus: "removed", accessOkAt: access, reason: "lease", dueAt: due)
        XCTAssertEqual(
            AccountPurgeNoticePolicy.line(removed, zone: utc),
            "Acme was removed and has not been reached since September 21 at 15:30. "
                + "Its data will be deleted on October 24 at 09:00 unless you add it again.")
        let gone = AccountPurge(id: 2, source: "linear", accountID: 4, accountStatus: "", reason: "lease", dueAt: due)
        XCTAssertEqual(
            AccountPurgeNoticePolicy.line(gone, zone: utc),
            "Linear account #4 was removed. Its data will be deleted on October 24 at 09:00 unless you add it again.")
    }

    func testRunningAndDoneLines() {
        let running = AccountPurge(id: 1, source: "google", accountID: 1, accountLabel: "a@example.com", state: "running")
        XCTAssertEqual(AccountPurgeNoticePolicy.line(running, zone: utc), "Watchtower is deleting a@example.com's data.")
        let done = AccountPurge(id: 1, source: "google", accountID: 1, accountLabel: "a@example.com",
                                state: "done", finishedAt: finished)
        XCTAssertEqual(AccountPurgeNoticePolicy.doneLine(done, zone: utc),
                       "a@example.com's data was deleted on October 24 at 09:05.")
        XCTAssertEqual(AccountPurgeNoticePolicy.purgedLine(done, zone: utc),
                       "a@example.com's data was deleted on October 24 at 09:05. Re-login to sync it again.")
        XCTAssertEqual(AccountPurgeNoticePolicy.purgedLine(nil, zone: utc),
                       "This account's synced data was deleted. Re-login to sync it again.")
    }

    func testDateUsesTheGivenZone() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(AccountPurgeNoticePolicy.date(try XCTUnwrap(due), zone: tokyo), "October 24 at 18:00")
    }

    func testNoticesOncePerRowPerState() {
        let scheduled = AccountPurge(id: 5, source: "slack", accountID: 1, accountLabel: "Acme", dueAt: due)
        var result = AccountPurgeNoticePolicy.notices(rows: [scheduled], sent: [], zone: utc)
        XCTAssertEqual(result.notices.map(\.identifier), ["accountPurge.5:scheduled"])
        XCTAssertEqual(result.notices.first?.title, "Slack account data will be deleted")
        XCTAssertEqual(result.sent, ["5:scheduled"])

        result = AccountPurgeNoticePolicy.notices(rows: [scheduled], sent: result.sent, zone: utc)
        XCTAssertTrue(result.notices.isEmpty, "deduped")

        let running = AccountPurge(id: 5, source: "slack", accountID: 1, accountLabel: "Acme", state: "running")
        result = AccountPurgeNoticePolicy.notices(rows: [running], sent: result.sent, zone: utc)
        XCTAssertTrue(result.notices.isEmpty, "running has no notice")
        XCTAssertEqual(result.sent, ["5:scheduled"], "the row is still listed: its key stays")

        let done = AccountPurge(id: 5, source: "slack", accountID: 1, accountLabel: "Acme", accountStatus: "purged",
                                state: "done", finishedAt: finished)
        result = AccountPurgeNoticePolicy.notices(rows: [done], sent: result.sent, zone: utc)
        XCTAssertEqual(result.notices.map(\.identifier), ["accountPurge.5:done"])
        XCTAssertEqual(result.notices.first?.body, "Acme's data was deleted on October 24 at 09:05.")
        XCTAssertEqual(result.sent, ["5:scheduled", "5:done"])
    }

    /// Review #601: a revoked row whose account reports an error waits; its
    /// line says so instead of a date that may already be past.
    func testRevokedLineOnHoldWhileError() {
        let row = AccountPurge(id: 1, source: "jira", accountID: 1, accountLabel: "Acme", accountStatus: "error",
                               dueAt: PlanUsageDates.parse("2026-10-01T09:00:00Z"))
        XCTAssertEqual(
            AccountPurgeNoticePolicy.line(row, zone: utc),
            "Access to Acme was revoked. Deleting its data is on hold while the account reports an error; reconnect to cancel it.")
    }

    /// Review #601: a failed purge gets its own line and one notice.
    func testFailedLineAndNotice() {
        let failed = AccountPurge(id: 7, source: "slack", accountID: 1, accountLabel: "Acme", state: "failed",
                                  finishedAt: finished, error: "disk full")
        XCTAssertEqual(
            AccountPurgeNoticePolicy.failedLine(failed, zone: utc),
            "Watchtower could not finish deleting Acme's data (disk full). Any new attempt comes with a new notice.")
        var result = AccountPurgeNoticePolicy.notices(rows: [failed], sent: [], zone: utc)
        XCTAssertEqual(result.notices.map(\.identifier), ["accountPurge.7:failed"])
        XCTAssertEqual(result.notices.first?.title, "Slack account data deletion failed")
        XCTAssertEqual(result.notices.first?.body, AccountPurgeNoticePolicy.failedLine(failed, zone: utc))
        result = AccountPurgeNoticePolicy.notices(rows: [failed], sent: result.sent, zone: utc)
        XCTAssertTrue(result.notices.isEmpty, "deduped")
    }

    /// Review #601: a purge whose account came back during the run is done
    /// with a note; its line says the account was kept.
    func testDoneLineWhenAccessCameBack() {
        let done = AccountPurge(id: 1, source: "jira", accountID: 1, accountLabel: "Acme", accountStatus: "ok",
                                state: "done", finishedAt: finished, error: "access came back during the purge")
        XCTAssertEqual(
            AccountPurgeNoticePolicy.doneLine(done, zone: utc),
            "Acme came back while its data was being deleted: the account was kept and syncs again from the start.")
    }

    func testKeysOfUnlistedRowsAreDropped() {
        let result = AccountPurgeNoticePolicy.notices(rows: [], sent: ["5:scheduled", "6:done"], zone: utc)
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertEqual(result.sent, [])
    }

    /// #1769, A2: a removed Slack workspace has a zero lease, so its line has
    /// no "has not been reached since" (SlackPolicyMockCopy.removedLine).
    func testZeroLeaseRemovedLine() {
        let row = AccountPurge(id: 1, source: "slack", accountID: 2, accountLabel: "acme", accountStatus: "removed",
                               accessOkAt: access, reason: "lease",
                               dueAt: PlanUsageDates.parse("2026-11-20T14:00:00Z"))
        XCTAssertEqual(
            AccountPurgeNoticePolicy.line(row, zone: utc),
            "acme was removed. Its data will be deleted on Nov 20, 14:00 unless you add it again.")
    }

    /// #1769, spec §9: a verify failure (`left: …`) holds a revoked or removed
    /// account — no new attempt until a Re-login or adding it back. A live
    /// account and a chunk failure keep the "new notice" line.
    func testFailedLineOfAHeldAccount() {
        let revoked = AccountPurge(id: 7, source: "slack", accountID: 1, accountLabel: "Acme", accountStatus: "revoked",
                                   state: "failed", error: "left: messages=3")
        XCTAssertEqual(
            AccountPurgeNoticePolicy.failedLine(revoked, zone: utc),
            "Watchtower could not finish deleting Acme's data (left: messages=3). "
                + "No new attempt is made until you Re-login.")
        let removed = AccountPurge(id: 8, source: "jira", accountID: 2, accountLabel: "acme.example.com",
                                   accountStatus: "removed", reason: "lease", state: "failed", error: "left: issues=1")
        XCTAssertEqual(
            AccountPurgeNoticePolicy.failedLine(removed, zone: utc),
            "Watchtower could not finish deleting acme.example.com's data (left: issues=1). "
                + "No new attempt is made until you add it again.")
        let notice = AccountPurgeNoticePolicy.notices(rows: [revoked], sent: [], zone: utc).notices.first
        XCTAssertEqual(notice?.body, AccountPurgeNoticePolicy.failedLine(revoked, zone: utc))

        let live = AccountPurge(id: 9, source: "jira", accountID: 3, accountLabel: "Acme", accountStatus: "ok",
                                reason: "lease", state: "failed", error: "left: issues=1")
        XCTAssertEqual(
            AccountPurgeNoticePolicy.failedLine(live, zone: utc),
            "Watchtower could not finish deleting Acme's data (left: issues=1). Any new attempt comes with a new notice.")
        let chunk = AccountPurge(id: 10, source: "slack", accountID: 1, accountLabel: "Acme", accountStatus: "revoked",
                                 state: "failed", error: "disk full")
        XCTAssertTrue(AccountPurgeNoticePolicy.failedLine(chunk, zone: utc).hasSuffix("Any new attempt comes with a new notice."))
    }
}

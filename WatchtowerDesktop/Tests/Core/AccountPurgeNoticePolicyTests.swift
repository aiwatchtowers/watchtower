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
        let removed = AccountPurge(id: 1, source: "slack", accountID: 2, accountLabel: "Acme",
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

    func testKeysOfUnlistedRowsAreDropped() {
        let result = AccountPurgeNoticePolicy.notices(rows: [], sent: ["5:scheduled", "6:done"], zone: utc)
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertEqual(result.sent, [])
    }
}

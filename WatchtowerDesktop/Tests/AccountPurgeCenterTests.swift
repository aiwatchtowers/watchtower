import XCTest
import GRDB
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

@MainActor
final class AccountPurgeCenterTests: XCTestCase {
    final class StubRunner: CLIRunnerProtocol {
        var calls: [[String]] = []
        var output = Data()
        var error: Error?
        func run(args: [String]) async throws -> Data {
            calls.append(args)
            if let error { throw error }
            return output
        }
    }

    final class FakeNotifier: AccountPurgeNotifying {
        var sent: [AccountPurgeNotice] = []
        func sendAccountPurgeNotice(_ notice: AccountPurgeNotice) { sent.append(notice) }
    }

    struct Boom: Error {}

    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private let suiteName = "AccountPurgeCenterTests.\(UUID().uuidString)"
    private let now = PlanUsageDates.parse("2026-10-21T09:00:00Z") ?? Date()

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func insert(_ sql: String) async throws {
        try await pool.write { try $0.execute(sql: sql) }
    }

    private func makeCenter(runner: StubRunner? = nil, notifier: FakeNotifier? = nil) -> AccountPurgeCenter {
        let at = now
        return AccountPurgeCenter(dbPool: pool, runner: runner, notifier: notifier, defaults: defaults) { at }
    }

    func testReloadListsRowsAndNotifiesOncePerState() async throws {
        try await insert("""
            INSERT INTO slack_accounts (id, team_name, status) VALUES (1, 'Acme', 'revoked');
            INSERT INTO account_purges (id, source, account_id, reason, due_at)
            VALUES (1, 'slack', 1, 'revoked', '2026-10-24T09:00:00Z');
            INSERT INTO account_purges (id, source, account_id, reason, due_at, state, finished_at)
            VALUES (2, 'jira', 3, 'lease', '2026-10-01T09:00:00Z', 'done', '2026-09-01T09:00:00Z');
            """)
        let notifier = FakeNotifier()
        let center = makeCenter(notifier: notifier)
        await center.reload()
        XCTAssertEqual(center.openRows.map(\.id), [1])
        XCTAssertEqual(center.recentRows, [], "a done row older than the window is not listed")
        XCTAssertEqual(center.openRow(source: "slack", accountID: 1)?.accountLabel, "Acme")
        XCTAssertNil(center.openRow(source: "slack", accountID: 2))
        XCTAssertEqual(notifier.sent.map(\.identifier), ["accountPurge.1:scheduled"])
        XCTAssertEqual(notifier.sent.first?.source, "slack")

        await center.reload()
        XCTAssertEqual(notifier.sent.count, 1, "deduped across reloads")

        try await insert("""
            UPDATE account_purges SET state = 'done', finished_at = '2026-10-21T08:00:00Z' WHERE id = 1;
            UPDATE slack_accounts SET status = 'purged', enabled = 0 WHERE id = 1;
            """)
        await center.reload()
        XCTAssertEqual(center.openRows, [])
        XCTAssertEqual(center.doneRow(source: "slack", accountID: 1)?.id, 1)
        XCTAssertEqual(notifier.sent.map(\.identifier), ["accountPurge.1:scheduled", "accountPurge.1:done"])

        // A new center (an app relaunch) reads the same sent set.
        let again = FakeNotifier()
        await makeCenter(notifier: again).reload()
        XCTAssertEqual(again.sent, [])
    }

    func testPausedNotificationsHoldTheNoticeBack() async throws {
        try await insert("""
            INSERT INTO account_purges (id, source, account_id, reason, due_at)
            VALUES (1, 'google', 1, 'revoked', '2026-10-24T09:00:00Z');
            """)
        defaults.set(true, forKey: NotificationPreferences.pausedKey)
        let notifier = FakeNotifier()
        let center = makeCenter(notifier: notifier)
        await center.reload()
        XCTAssertEqual(notifier.sent, [])
        defaults.removeObject(forKey: NotificationPreferences.pausedKey)
        await center.reload()
        XCTAssertEqual(notifier.sent.count, 1, "still due after the pause")
    }

    func testReloadStatusReadsTheCLIAndRecordsAFailure() async throws {
        let runner = StubRunner()
        runner.output = Data(#"{"enabled": true, "enabled_by": "setting", "grace_hours": 72, "lease_days": 30, "purges": []}"#.utf8)
        let center = makeCenter(runner: runner)
        await center.reloadStatus()
        XCTAssertEqual(runner.calls, [["accounts", "purges", "--json"]])
        XCTAssertEqual(center.status?.enabled, true)
        XCTAssertNil(center.statusError)

        runner.error = Boom()
        await center.reloadStatus()
        XCTAssertNil(center.status, "a failed read is not shown as off")
        XCTAssertNotNil(center.statusError)
    }
}

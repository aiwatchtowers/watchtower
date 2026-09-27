import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Boards → "Sync Now" ran a bare `watchtower jira sync`, which the CLI
/// rejects ("multiple Jira sites connected — pass --account <id>") as soon as
/// two sites are enabled. Account-scoped actions now fan out per enabled site.
final class JiraAccountFanOutTests: XCTestCase {
    func testOneAccountScopedInvocationPerEnabledSite() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (first, second) = try pool.write { db -> (Int64, Int64) in
            let first = try TestDatabase.insertJiraAccount(db, siteName: "Site A")
            _ = try TestDatabase.insertJiraAccount(db, siteName: "Paused", enabled: false)
            _ = try TestDatabase.insertJiraAccount(db, siteName: "Gone", status: "removed", enabled: false)
            let second = try TestDatabase.insertJiraAccount(db, siteName: "Site B")
            return (first, second)
        }
        let accounts = try pool.read { db in try JiraAccountQueries.fetchAll(db) }

        let calls = JiraAccountFanOut.invocations(for: accounts, subcommand: ["sync"])

        XCTAssertEqual(calls.map(\.arguments), [
            ["jira", "--account", String(first), "sync"],
            ["jira", "--account", String(second), "sync"]
        ])
        XCTAssertEqual(calls.map(\.account.displayName), ["Site A", "Site B"])
    }

    func testNoEnabledSitesMeansNoInvocations() {
        XCTAssertTrue(JiraAccountFanOut.invocations(for: [], subcommand: ["sync"]).isEmpty)
    }

    func testFailureMessageJoinsAndCaps() {
        XCTAssertNil(JiraAccountFanOut.failureMessage([]))
        XCTAssertEqual(JiraAccountFanOut.failureMessage(["A: boom", "B: bust"]), "A: boom; B: bust")
        let long = JiraAccountFanOut.failureMessage([String(repeating: "x", count: 500)])
        XCTAssertEqual(long?.count, 200)
    }
}

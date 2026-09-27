import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The Swift release dashboard counted issues by fix-version NAME across all
/// connected Jira sites, while Go's `GetJiraIssuesByFixVersion` /
/// `GetJiraIssueCountAddedSince` scope by `account_id` — two sites that both
/// ship a "1.0" each showed the other's issues. Mirrors the Go two-account test.
final class JiraReleaseQueriesTests: XCTestCase {
    private static let iso = ISO8601DateFormatter()

    private func insertIssue(_ db: Database, account: Int64, key: String, version: String, syncedAt: Date) throws {
        let now = Self.iso.string(from: Date())
        try db.execute(
            sql: """
                INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
                    fix_versions, created_at, updated_at, synced_at)
                VALUES (?, ?, 'PROJ', ?, 'Open', 'todo', ?, ?, ?, ?)
                """,
            arguments: [account, key, key, "[\"\(version)\"]", now, now, Self.iso.string(from: syncedAt)]
        )
    }

    /// Two sites, each with its own release "1.0" under the SAME Jira release
    /// id: site A has 3 issues on it, site B has 2.
    private func makeTwoSiteFixture() throws -> (DatabasePool, String, Int64, Int64) {
        let (pool, path) = try TestDatabase.createPool()
        let recent = Date()
        let ids = try pool.write { db -> (Int64, Int64) in
            let siteA = try TestDatabase.insertJiraAccount(db, siteName: "Site A")
            let siteB = try TestDatabase.insertJiraAccount(db, siteName: "Site B")
            for account in [siteA, siteB] {
                try db.execute(
                    sql: "INSERT INTO jira_releases (account_id, id, project_key, name) VALUES (?, 100, 'PROJ', '1.0')",
                    arguments: [account]
                )
            }
            for n in 1...3 { try insertIssue(db, account: siteA, key: "PROJ-\(n)", version: "1.0", syncedAt: recent) }
            for n in 1...2 { try insertIssue(db, account: siteB, key: "PROJ-\(n)", version: "1.0", syncedAt: recent) }
            return (siteA, siteB)
        }
        return (pool, path, ids.0, ids.1)
    }

    func testIssuesByFixVersionAreScopedToTheReleaseSite() throws {
        let (pool, path, siteA, siteB) = try makeTwoSiteFixture()
        defer { TestDatabase.cleanup(path: path) }

        let (a, b) = try pool.read { db in
            (try JiraQueries.fetchIssuesByFixVersion(db, accountID: Int(siteA), versionName: "1.0"),
             try JiraQueries.fetchIssuesByFixVersion(db, accountID: Int(siteB), versionName: "1.0"))
        }
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(b.count, 2)
    }

    func testScopeChangesAreScopedToTheReleaseSite() throws {
        let (pool, path, siteA, siteB) = try makeTwoSiteFixture()
        defer { TestDatabase.cleanup(path: path) }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)

        let (a, b) = try pool.read { db in
            (try JiraQueries.fetchScopeChanges(db, accountID: Int(siteA), versionName: "1.0", since: weekAgo),
             try JiraQueries.fetchScopeChanges(db, accountID: Int(siteB), versionName: "1.0", since: weekAgo))
        }
        XCTAssertEqual(a.added, 3)
        XCTAssertEqual(b.added, 2)
    }

    func testReleasesDecodeTheirSiteAndStayDistinctUnderEqualReleaseIDs() throws {
        let (pool, path, siteA, siteB) = try makeTwoSiteFixture()
        defer { TestDatabase.cleanup(path: path) }

        let releases = try pool.read { db in try JiraQueries.fetchUnreleasedReleases(db) }

        XCTAssertEqual(Set(releases.map(\.accountID)), [Int(siteA), Int(siteB)])
        XCTAssertEqual(releases.map(\.releaseID), [100, 100])
        XCTAssertEqual(Set(releases.map(\.id)).count, 2, "equal release ids from two sites collided")
    }
}

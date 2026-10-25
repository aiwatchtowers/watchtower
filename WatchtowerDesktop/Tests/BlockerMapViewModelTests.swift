import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Blockers tab over Jira and Linear: chains, links, downstream counts
/// and ping targets stay inside each issue's own tracker account, even when
/// the same key exists on both trackers.
@MainActor
final class BlockerMapViewModelTests: XCTestCase {
    /// Calendar days, as `daysSince` counts them: 3 × 86 400 s is only two
    /// calendar days across a 25-hour DST day.
    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }

    private struct Fixture {
        let jira: Int64
        let linear: Int64
    }

    /// PROJ-0 blocks PROJ-1 (Jira); Linear ENG-1 blocks Linear ENG-2; a Jira
    /// ENG-1 is blocked by its status and has no links.
    private func seed(_ db: Database) throws -> Fixture {
        let jira = try TestDatabase.insertJiraAccount(db, siteURL: "https://acme.atlassian.net")
        let linear = try TestDatabase.insertLinearAccount(db)
        try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-0") { $0.assignee = "U9"; $0.assigneeName = "Colleague B" }
        try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-1") {
            $0.status = "Blocked"; $0.category = "in_progress"; $0.assignee = "U1"; $0.assigneeName = "Colleague A"
            $0.categoryChanged = self.daysAgo(3)
        }
        try db.execute(sql: """
            INSERT INTO jira_issue_links (account_id, id, source_key, target_key, link_type)
            VALUES (?, '1', 'PROJ-0', 'PROJ-1', 'Blocks')
            """, arguments: [jira])
        try TestDatabase.insertJiraIssue(db, account: jira, key: "ENG-1") { $0.status = "Blocked"; $0.category = "todo" }
        try TestDatabase.insertLinearIssue(db, account: linear, id: "l1", key: "ENG-1") {
            $0.assigneeSlackID = "U8"; $0.assigneeName = "Colleague C"; $0.url = "https://linear.app/acme/issue/ENG-1"
        }
        try TestDatabase.insertLinearIssue(db, account: linear, id: "l2", key: "ENG-2") {
            $0.category = "in_progress"; $0.creatorSlackID = "U7"; $0.creatorName = "Colleague D"
            $0.url = "https://linear.app/acme/issue/ENG-2"
        }
        try TestDatabase.insertLinearBlocks(db, account: linear, id: "r1", blocker: "l1", blocked: "l2")
        return Fixture(jira: jira, linear: linear)
    }

    func testMixedTrackersKeepChainsLinksAndPingsApart() throws {
        let queue = try TestDatabase.create()
        let fixture = try queue.write(seed)
        let entries = try queue.read { db in try BlockerMapViewModel.entries(db) }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        XCTAssertEqual(Set(byID.keys), [
            "jira:\(fixture.jira):PROJ-1", "jira:\(fixture.jira):ENG-1", "linear:\(fixture.linear):ENG-2"
        ], "the colliding ENG-1 is listed once, as the Jira issue blocked by status")

        let linear = try XCTUnwrap(byID["linear:\(fixture.linear):ENG-2"])
        XCTAssertEqual(linear.tracker, .linear)
        XCTAssertEqual(linear.blockingChain, ["ENG-1"])
        XCTAssertEqual(linear.chainURLs["ENG-1"]?.absoluteString, "https://linear.app/acme/issue/ENG-1",
                       "the chain links to the Linear ENG-1, not the Jira one")
        XCTAssertEqual(linear.issueURL?.absoluteString, "https://linear.app/acme/issue/ENG-2")
        XCTAssertEqual(linear.whoToPing.map(\.slackUserID), ["U8", "U7"], "root cause assignee, then the creator")
        XCTAssertEqual(linear.whoToPing.first?.reason, "root cause assignee (ENG-1)")
        XCTAssertEqual(linear.slackContext, "", "a Linear issue never reads Jira's links")

        let jiraENG = try XCTUnwrap(byID["jira:\(fixture.jira):ENG-1"])
        XCTAssertEqual(jiraENG.downstreamCount, 0, "the Linear ENG-1's edge is not the Jira ENG-1's")
        XCTAssertTrue(jiraENG.blockingChain.isEmpty)

        let proj = try XCTUnwrap(byID["jira:\(fixture.jira):PROJ-1"])
        XCTAssertEqual(proj.blockingChain, ["PROJ-0"], "adjacency runs from blocker to blocked")
        XCTAssertEqual(proj.chainURLs["PROJ-0"]?.absoluteString, "https://acme.atlassian.net/browse/PROJ-0")
        XCTAssertEqual(proj.whoToPing.map(\.slackUserID), ["U9", "U1"])
        XCTAssertEqual(proj.blockedDays, 3)
    }

    func testLoadFillsTheTabFromTheDatabase() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        _ = try manager.dbPool.write(seed)
        let vm = BlockerMapViewModel(dbManager: manager)
        vm.load()
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.blockers.count, 3)
    }
}

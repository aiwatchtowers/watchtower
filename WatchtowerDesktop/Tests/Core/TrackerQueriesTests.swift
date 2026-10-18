import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The Desktop's tracker-neutral reads: Jira and Linear rows side by side
/// through `tracker_issues` / `tracker_iterations` (spec §6, Desktop row).
final class TrackerQueriesTests: XCTestCase {
    private func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86400) }

    // MARK: - Blocker map

    func testBlockedIssuesComeFromBothTrackers() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let jira = try TestDatabase.insertJiraAccount(db)
            let linear = try TestDatabase.insertLinearAccount(db)
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-1") { $0.status = "Blocked"; $0.category = "in_progress" }
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-2") { $0.status = "Blocked"; $0.category = "done" }
            // ENG-2 is blocked by the open ENG-1; ENG-4 by the finished ENG-3.
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l1", key: "ENG-1")
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l2", key: "ENG-2") { $0.category = "in_progress" }
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l3", key: "ENG-3") { $0.category = "done" }
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l4", key: "ENG-4")
            try TestDatabase.insertLinearBlocks(db, account: linear, id: "r1", blocker: "l1", blocked: "l2")
            try TestDatabase.insertLinearBlocks(db, account: linear, id: "r2", blocker: "l3", blocked: "l4")
        }
        let blocked = try queue.read { db in try TrackerQueries.fetchBlockedIssues(db) }
        XCTAssertEqual(Set(blocked.map(\.key)), ["PROJ-1", "ENG-2"])
        XCTAssertEqual(blocked.first { $0.key == "ENG-2" }?.tracker, .linear)
    }

    func testStaleIssuesUseTheStatusChangeOfEitherTracker() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let jira = try TestDatabase.insertJiraAccount(db)
            let linear = try TestDatabase.insertLinearAccount(db)
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-1") {
                $0.category = "in_progress"; $0.categoryChanged = self.daysAgo(10)
            }
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l1", key: "ENG-1") {
                $0.category = "in_progress"; $0.stateChanged = self.daysAgo(9)
            }
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l2", key: "ENG-2") {
                $0.category = "in_progress"; $0.stateChanged = self.daysAgo(2)
            }
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l3", key: "ENG-3") {
                $0.category = "in_progress"; $0.stateChanged = self.daysAgo(20); $0.deleted = true
            }
        }
        let stale = try queue.read { db in try TrackerQueries.fetchStaleIssues(db, staleDays: 7) }
        XCTAssertEqual(stale.map(\.key), ["PROJ-1", "ENG-1"], "oldest change first")
    }

    func testBlockLinksJoinJiraLinksAndLinearRelationsByKey() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let jira = try TestDatabase.insertJiraAccount(db)
            let linear = try TestDatabase.insertLinearAccount(db)
            try db.execute(sql: """
                INSERT INTO jira_issue_links (account_id, id, source_key, target_key, link_type) VALUES
                (?, '1', 'PROJ-1', 'PROJ-2', 'Blocks'), (?, '2', 'PROJ-1', 'PROJ-3', 'Relates')
                """, arguments: [jira, jira])
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l1", key: "ENG-1")
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l2", key: "ENG-2")
            try TestDatabase.insertLinearBlocks(db, account: linear, id: "r1", blocker: "l1", blocked: "l2")
            try db.execute(sql: """
                INSERT INTO linear_relations (account_id, id, issue_id, related_issue_id, type)
                VALUES (?, 'r2', 'l1', 'l2', 'related')
                """, arguments: [linear])
        }
        let links = try queue.read { db in try TrackerQueries.fetchBlockLinks(db, keys: ["PROJ-2", "ENG-2"]) }
        XCTAssertEqual(links, [
            TrackerBlockLink(blocker: "PROJ-1", blocked: "PROJ-2"),
            TrackerBlockLink(blocker: "ENG-1", blocked: "ENG-2")
        ])
        XCTAssertTrue(try queue.read { db in try TrackerQueries.fetchBlockLinks(db, keys: []) }.isEmpty)
    }

    func testIssueByKeyCarriesTheTrackerLink() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let linear = try TestDatabase.insertLinearAccount(db)
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l1", key: "ENG-1") {
                $0.url = "https://linear.app/acme/issue/ENG-1"; $0.assigneeSlackID = "U1"; $0.assigneeName = "Colleague A"
            }
        }
        let issue = try XCTUnwrap(try queue.read { db in try TrackerQueries.fetchIssueByKey(db, key: "ENG-1") })
        XCTAssertEqual(issue.tracker, .linear)
        XCTAssertEqual(issue.browseURL?.absoluteString, "https://linear.app/acme/issue/ENG-1")
        XCTAssertEqual(issue.assigneeSlackID, "U1")
        XCTAssertEqual(issue.trackerName, "Linear")
    }

    /// A Jira site with no recorded URL leaves `/browse/KEY` in the view:
    /// no link rather than a broken one.
    func testJiraIssueWithoutSiteURLHasNoBrowseURL() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let jira = try TestDatabase.insertJiraAccount(db)
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-1")
        }
        let issue = try XCTUnwrap(try queue.read { db in try TrackerQueries.fetchIssueByKey(db, key: "PROJ-1") })
        XCTAssertEqual(issue.tracker, .jira)
        XCTAssertNil(issue.browseURL)
    }

    // MARK: - Epic / project progress

    func testContainerProgressCountsEpicsAndProjects() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let jira = try TestDatabase.insertJiraAccount(db)
            let linear = try TestDatabase.insertLinearAccount(db)
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-100") { $0.summary = "Checkout epic"; $0.typeCategory = "epic" }
            for n in 1...3 {
                try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-\(n)") {
                    $0.epicKey = "PROJ-100"
                    if n == 1 { $0.category = "done"; $0.resolved = self.daysAgo(2) }
                }
            }
            try db.execute(sql: "INSERT INTO linear_projects (account_id, id, name) VALUES (?, 'p1', 'Onboarding revamp')",
                           arguments: [linear])
            for n in 1...4 {
                try TestDatabase.insertLinearIssue(db, account: linear, id: "l\(n)", key: "ENG-\(n)") {
                    $0.projectID = "p1"
                    if n <= 2 { $0.category = "done"; $0.completed = self.daysAgo(20) }
                    if n == 3 { $0.category = "in_progress" }
                }
            }
            // Two issues are not enough for a row.
            for n in 5...6 {
                try TestDatabase.insertLinearIssue(db, account: linear, id: "l\(n)", key: "ENG-\(n)") { $0.projectID = "p2" }
            }
        }
        let rows = try queue.read { db in try TrackerQueries.fetchContainerProgress(db) }
        XCTAssertEqual(rows.map(\.name), ["Onboarding revamp", "Checkout epic"])
        let project = try XCTUnwrap(rows.first)
        XCTAssertEqual(project.tracker, .linear)
        XCTAssertEqual(project.kind, "project")
        XCTAssertEqual(project.totalIssues, 4)
        XCTAssertEqual(project.doneIssues, 2)
        XCTAssertEqual(project.inProgressIssues, 1)
        XCTAssertEqual(project.weeklyResolvedCount, 0)
        XCTAssertEqual(project.monthlyResolvedCount, 2)
        let epic = try XCTUnwrap(rows.last)
        XCTAssertEqual(epic.kind, "epic")
        XCTAssertEqual(epic.weeklyResolvedCount, 1)
    }

    // MARK: - Iteration progress

    func testActiveIterationsCountSprintAndCycleIssues() throws {
        let queue = try TestDatabase.create()
        let iso = ISO8601DateFormatter()
        try queue.write { db in
            let jira = try TestDatabase.insertJiraAccount(db)
            let linear = try TestDatabase.insertLinearAccount(db)
            try db.execute(sql: """
                INSERT INTO jira_sprints (account_id, id, board_id, name, state, end_date) VALUES
                (?, 7, 1, 'Sprint 7', 'active', ?), (?, 6, 1, 'Sprint 6', 'closed', '')
                """, arguments: [jira, iso.string(from: Date().addingTimeInterval(3 * 86400)), jira])
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-1") { $0.sprintID = 7; $0.category = "done" }
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-2") { $0.sprintID = 7 }
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-3") { $0.sprintID = 6 }
            try db.execute(sql: """
                INSERT INTO linear_cycles (account_id, id, number, starts_at, ends_at) VALUES (?, 'c1', 12, ?, ?)
                """, arguments: [linear, iso.string(from: Date().addingTimeInterval(-86400)),
                                 iso.string(from: Date().addingTimeInterval(6 * 86400))])
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l1", key: "ENG-1") { $0.cycleID = "c1"; $0.category = "in_progress" }
            try TestDatabase.insertLinearIssue(db, account: linear, id: "l2", key: "ENG-2") { $0.cycleID = "c1"; $0.deleted = true }
        }
        let rows = try queue.read { db in try TrackerQueries.fetchActiveIterations(db) }
        XCTAssertEqual(rows.map(\.name), ["Sprint 7", "Cycle 12"], "soonest end first; closed sprints left out")
        XCTAssertEqual(rows[0].total, 2)
        XCTAssertEqual(rows[0].done, 1)
        XCTAssertEqual(rows[0].todo, 1)
        XCTAssertEqual(rows[1].tracker, .linear)
        XCTAssertEqual(rows[1].total, 1, "deleted issues do not count")
        XCTAssertEqual(rows[1].inProgress, 1)
        XCTAssertEqual(rows[1].daysLeft(), 5)
    }
}

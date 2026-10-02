import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The dashboard SQL in `JiraQueries`: account-scoped board lookup, and the
/// date-bounded aggregates. Jira timestamp columns hold fixed-width UTC
/// ("2006-01-02T15:04:05.000Z", Go `db.FormatJiraTime`, migration 00092), and
/// these queries compare them as strings — the fixtures store that exact form.
final class JiraQueriesTests: XCTestCase {

    // MARK: - Fixtures

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86400) }

    private func day(_ date: Date) -> String { Self.dayFormatter.string(from: date) }

    private func issue(
        _ db: Database,
        _ account: Int64,
        _ key: String,
        _ configure: (inout JiraIssueFixture) -> Void = { _ in }
    ) throws {
        try TestDatabase.insertJiraIssue(db, account: account, key: key, configure)
    }

    // MARK: - Boards

    /// Raw board ids collide across connected sites; the composite key keeps
    /// each site's board addressable on its own.
    func testFetchBoardIsAccountScopedUnderACollidingBoardID() throws {
        let queue = try TestDatabase.create()
        let (siteA, siteB) = try queue.write { db -> (Int64, Int64) in
            let siteA = try TestDatabase.insertJiraAccount(db, siteName: "Site A")
            let siteB = try TestDatabase.insertJiraAccount(db, siteName: "Site B")
            try db.execute(sql: "INSERT INTO jira_boards (account_id, id, name) VALUES (?, 7, 'Alpha board')", arguments: [siteA])
            try db.execute(sql: "INSERT INTO jira_boards (account_id, id, name) VALUES (?, 7, 'Beta board')", arguments: [siteB])
            return (siteA, siteB)
        }

        try queue.read { db in
            XCTAssertEqual(try JiraQueries.fetchBoard(db, accountID: siteA, id: 7)?.name, "Alpha board")
            XCTAssertEqual(try JiraQueries.fetchBoard(db, accountID: siteB, id: 7)?.name, "Beta board")
            XCTAssertNil(try JiraQueries.fetchBoard(db, accountID: siteB + 1, id: 7))
            XCTAssertNil(try JiraQueries.fetchBoard(db, accountID: siteA, id: 8))
        }
    }

    // MARK: - Delivery stats

    func testDeliveryStatsCountOnlyIssuesResolvedInsideTheWindow() throws {
        let queue = try TestDatabase.create()
        let from = daysAgo(7)
        let to = Date().addingTimeInterval(60)
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            // Inside: resolved one second after the lower bound, 4 days after creation.
            let inside = from.addingTimeInterval(1)
            try issue(db, acct, "PROJ-1") {
                $0.category = "done"; $0.assignee = "U1"; $0.storyPoints = 3
                $0.created = inside.addingTimeInterval(-4 * 86400); $0.resolved = inside
                $0.labels = #"["api","ux"]"#; $0.components = #"["core"]"#
            }
            // Inside: resolved now, 2 days after creation.
            try issue(db, acct, "PROJ-2") {
                $0.category = "done"; $0.assignee = "U1"; $0.storyPoints = 5
                $0.created = self.daysAgo(2); $0.resolved = Date(); $0.labels = #"["api"]"#
            }
            // Outside: resolved one second before the lower bound.
            try issue(db, acct, "PROJ-3") {
                $0.category = "done"; $0.assignee = "U1"; $0.storyPoints = 8
                $0.resolved = from.addingTimeInterval(-1); $0.labels = #"["old"]"#
            }
            // Deleted, and another assignee's: never counted.
            try issue(db, acct, "PROJ-4") {
                $0.category = "done"; $0.assignee = "U1"; $0.storyPoints = 13; $0.resolved = Date(); $0.deleted = true
            }
            try issue(db, acct, "PROJ-5") {
                $0.category = "done"; $0.assignee = "U2"; $0.storyPoints = 21; $0.resolved = Date()
            }
            // Open: one overdue, one due in the future.
            try issue(db, acct, "PROJ-6") { $0.assignee = "U1"; $0.dueDate = self.day(self.daysAgo(3)) }
            try issue(db, acct, "PROJ-7") {
                $0.category = "in_progress"; $0.assignee = "U1"; $0.dueDate = self.day(self.daysAgo(-5))
            }
        }

        let stats = try queue.read { db in
            try JiraQueries.fetchDeliveryStats(db, slackID: "U1", from: from, to: to)
        }
        XCTAssertEqual(stats.issuesClosed, 2)
        XCTAssertEqual(stats.storyPointsCompleted, 8)
        XCTAssertEqual(stats.avgCycleTimeDays, 3, accuracy: 0.01)
        XCTAssertEqual(stats.openIssues, 2)
        XCTAssertEqual(stats.overdueIssues, 1)
        XCTAssertEqual(stats.labels, ["api", "ux"], "distinct, sorted, window-bounded")
        XCTAssertEqual(stats.components, ["core"])
    }

    func testDeliveryStatsForAnAssigneeWithNoIssuesAreZero() throws {
        let queue = try TestDatabase.create()
        let stats = try queue.read { db in
            try JiraQueries.fetchDeliveryStats(db, slackID: "U9", from: daysAgo(7), to: Date())
        }
        XCTAssertEqual(stats.issuesClosed, 0)
        XCTAssertEqual(stats.avgCycleTimeDays, 0)
        XCTAssertEqual(stats.storyPointsCompleted, 0)
        XCTAssertEqual(stats.openIssues, 0)
        XCTAssertTrue(stats.labels.isEmpty)
    }

    // MARK: - Stale / blocked

    func testStaleIssuesAreInProgressPastTheThresholdOldestFirst() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            try issue(db, acct, "PROJ-1") { $0.category = "in_progress"; $0.categoryChanged = self.daysAgo(10) }
            try issue(db, acct, "PROJ-2") { $0.category = "in_progress"; $0.categoryChanged = self.daysAgo(20) }
            try issue(db, acct, "PROJ-3") { $0.category = "in_progress"; $0.categoryChanged = self.daysAgo(3) }
            try issue(db, acct, "PROJ-4") { $0.category = "in_progress" }
            try issue(db, acct, "PROJ-5") { $0.category = "done"; $0.categoryChanged = self.daysAgo(30) }
            try issue(db, acct, "PROJ-6") {
                $0.category = "in_progress"; $0.categoryChanged = self.daysAgo(30); $0.deleted = true
            }
        }

        let stale = try queue.read { db in try JiraQueries.fetchStaleIssues(db, staleDays: 7) }
        XCTAssertEqual(stale.map(\.key), ["PROJ-2", "PROJ-1"])
    }

    func testBlockedIssuesMatchTheStatusNameAndSkipDone() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            try issue(db, acct, "PROJ-1") { $0.status = "Blocked"; $0.category = "in_progress" }
            try issue(db, acct, "PROJ-2") { $0.status = "Waiting (blocker)" }
            try issue(db, acct, "PROJ-3") { $0.status = "Blocked"; $0.category = "done" }
            try issue(db, acct, "PROJ-4") { $0.status = "In Progress"; $0.category = "in_progress" }
        }

        let blocked = try queue.read { db in try JiraQueries.fetchBlockedIssues(db) }
        XCTAssertEqual(Set(blocked.map(\.key)), ["PROJ-1", "PROJ-2"])
    }

    // MARK: - Team workload

    func testTeamWorkloadAggregatesPerAssignee() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            let ann: (inout JiraIssueFixture) -> Void = { $0.assignee = "U1"; $0.assigneeName = "Ann" }
            try issue(db, acct, "PROJ-1") {
                ann(&$0); $0.status = "Blocked"; $0.category = "in_progress"
                $0.dueDate = self.day(self.daysAgo(2)); $0.storyPoints = 3
            }
            try issue(db, acct, "PROJ-2") { ann(&$0); $0.storyPoints = 2 }
            // Resolved 10 days ago after 4 days: inside the 30-day cycle window.
            try issue(db, acct, "PROJ-3") {
                ann(&$0); $0.category = "done"; $0.created = self.daysAgo(14); $0.resolved = self.daysAgo(10)
            }
            // Resolved 40 days ago: outside the window, so not in the average.
            try issue(db, acct, "PROJ-4") {
                ann(&$0); $0.category = "done"; $0.created = self.daysAgo(60); $0.resolved = self.daysAgo(40)
            }
            try issue(db, acct, "PROJ-5") { $0.assignee = "U2"; $0.assigneeName = "Bo" }
            try issue(db, acct, "PROJ-6")
        }

        let rows = try queue.read { db in try JiraQueries.fetchTeamWorkload(db) }
        XCTAssertEqual(rows.map(\.slackUserID), ["U1", "U2"], "unassigned dropped, busiest first")
        let ann = try XCTUnwrap(rows.first)
        XCTAssertEqual(ann.openIssues, 2)
        XCTAssertEqual(ann.storyPoints, 5)
        XCTAssertEqual(ann.overdueCount, 1)
        XCTAssertEqual(ann.blockedCount, 1)
        XCTAssertEqual(ann.avgCycleTimeDays, 4, accuracy: 0.01)
    }

    // MARK: - Epic progress

    func testEpicProgressNeedsThreeChildrenAndCountsRecentResolutions() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            try issue(db, acct, "PROJ-100") { $0.typeCategory = "epic"; $0.summary = "Payments" }
            for (key, ago) in [("PROJ-1", 2.0), ("PROJ-2", 20), ("PROJ-3", 40)] {
                try issue(db, acct, key) { $0.category = "done"; $0.resolved = self.daysAgo(ago); $0.epicKey = "PROJ-100" }
            }
            try issue(db, acct, "PROJ-4") { $0.category = "in_progress"; $0.epicKey = "PROJ-100" }
            // Two children are below the floor of three.
            try issue(db, acct, "PROJ-5") { $0.epicKey = "PROJ-200" }
            try issue(db, acct, "PROJ-6") { $0.epicKey = "PROJ-200" }
        }

        let rows = try queue.read { db in try JiraQueries.fetchEpicProgress(db) }
        XCTAssertEqual(rows.map(\.epicKey), ["PROJ-100"])
        let epic = try XCTUnwrap(rows.first)
        XCTAssertEqual(epic.epicName, "Payments")
        XCTAssertEqual(epic.totalIssues, 4)
        XCTAssertEqual(epic.doneIssues, 3)
        XCTAssertEqual(epic.inProgressIssues, 1)
        XCTAssertEqual(epic.progressPct, 0.75, accuracy: 0.001)
        XCTAssertEqual(epic.weeklyResolvedCount, 1)
        XCTAssertEqual(epic.monthlyResolvedCount, 2)
    }

    func testEpicProgressNamesAnEpicWithoutItsOwnRowByKey() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            for n in 1...3 { try issue(db, acct, "PROJ-\(n)") { $0.epicKey = "PROJ-300" } }
        }
        let rows = try queue.read { db in try JiraQueries.fetchEpicProgress(db) }
        XCTAssertEqual(rows.first?.epicName, "PROJ-300")
        XCTAssertEqual(rows.first?.progressPct, 0)
    }

    // MARK: - Links

    func testIssuesForTracksGroupByTrackAndSkipDeleted() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            try issue(db, acct, "PROJ-1")
            try issue(db, acct, "PROJ-2")
            try issue(db, acct, "PROJ-3") { $0.deleted = true }
            try db.execute(sql: """
                INSERT INTO jira_slack_links (issue_key, track_id, link_type) VALUES
                    ('PROJ-1', 1, 'track'), ('PROJ-2', 1, 'track'), ('PROJ-1', 2, 'track'),
                    ('PROJ-3', 2, 'track'), ('PROJ-2', 3, 'track')
                """)
        }

        let grouped = try queue.read { db in try JiraQueries.fetchIssuesForTracks(db, trackIDs: [1, 2]) }
        XCTAssertEqual(Set(grouped[1]?.map(\.key) ?? []), ["PROJ-1", "PROJ-2"])
        XCTAssertEqual(grouped[2]?.map(\.key), ["PROJ-1"])
        XCTAssertNil(grouped[3], "only the asked-for tracks")
        XCTAssertTrue(try queue.read { db in try JiraQueries.fetchIssuesForTracks(db, trackIDs: []) }.isEmpty)
    }

    func testLinkedIssuesGroupByDirectionAndType() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let acct = try TestDatabase.insertJiraAccount(db)
            for key in ["PROJ-1", "PROJ-2", "PROJ-3", "PROJ-4"] { try issue(db, acct, key) }
            try issue(db, acct, "PROJ-5") { $0.deleted = true }
            try db.execute(sql: """
                INSERT INTO jira_issue_links (account_id, id, source_key, target_key, link_type) VALUES
                    (?, 'l1', 'PROJ-1', 'PROJ-2', 'Blocks'),
                    (?, 'l2', 'PROJ-3', 'PROJ-1', 'blocks'),
                    (?, 'l3', 'PROJ-1', 'PROJ-4', 'Relates'),
                    (?, 'l4', 'PROJ-1', 'PROJ-5', 'Blocks')
                """, arguments: [acct, acct, acct, acct])
        }

        let links = try queue.read { db in try JiraQueries.fetchLinkedIssuesGrouped(db, issueKey: "PROJ-1") }
        XCTAssertEqual(links.blocks.map(\.key), ["PROJ-2"], "a deleted target is skipped")
        XCTAssertEqual(links.blockedBy.map(\.key), ["PROJ-3"])
        XCTAssertEqual(links.relatesTo.map(\.key), ["PROJ-4"])
    }

    func testChannelsWithoutJiraExcludeChannelsWithALink() throws {
        let queue = try TestDatabase.create()
        let since = daysAgo(14)
        try queue.write { db in
            try TestDatabase.insertChannel(db, id: "C1", name: "linked")
            try TestDatabase.insertChannel(db, id: "C2", name: "unlinked")
            let recent = Date().timeIntervalSince1970 - 86400
            try TestDatabase.insertDigest(db, channelID: "C1", periodFrom: recent, periodTo: recent + 3600)
            try TestDatabase.insertDigest(db, channelID: "C2", periodFrom: recent, periodTo: recent + 3600)
            // Older than the window: not counted.
            let old = since.timeIntervalSince1970 - 86400
            try TestDatabase.insertDigest(db, channelID: "C2", periodFrom: old, periodTo: old + 3600)
            try db.execute(sql: "INSERT INTO jira_slack_links (issue_key, channel_id) VALUES ('PROJ-1', 'C1')")
        }

        let rows = try queue.read { db in try JiraQueries.fetchChannelsWithoutJira(db, since: since) }
        XCTAssertEqual(rows.map(\.channelID), ["C2"])
        XCTAssertEqual(rows.first?.channelName, "unlinked")
        XCTAssertEqual(rows.first?.digestCount, 1)
    }
}

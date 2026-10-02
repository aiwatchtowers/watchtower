import XCTest
import GRDB
@testable import WatchtowerDesktop
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Jira dashboard math: the Project Map epic badge and roll-up, the
/// Release Dashboard's per-site release items, and the Epic Progress badge.
@MainActor
final class JiraDashboardViewModelTests: XCTestCase {

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    /// A due/release date `days` from today (negative: in the past).
    private func dayFromNow(_ days: Int) -> String {
        Self.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date())
    }

    private func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86400) }

    private func badge(
        total: Int = 10,
        done: Int = 6,
        resolvedLastWeek: Int = 0,
        velocity: Double = 0,
        blocked: Int = 0,
        stale: Int = 0,
        forecastWeeks: Double? = nil,
        dueDate: String? = nil
    ) -> (ProjectMapViewModel.EpicStatusBadge, String) {
        ProjectMapViewModel.computeStatusBadge(
            total: total, done: done, resolvedLastWeek: resolvedLastWeek, velocityPerWeek: velocity,
            blocked: blocked, stale: stale, forecastWeeks: forecastWeeks, dueDate: dueDate
        )
    }

    // MARK: - Project Map: status badge

    func testBadgeAllDoneIsOnTrack() {
        let (status, reason) = badge(total: 4, done: 4)
        XCTAssertEqual(status, .onTrack)
        XCTAssertEqual(reason, "All issues done")
    }

    func testBadgeWithoutVelocityIsBehind() {
        let (status, reason) = badge()
        XCTAssertEqual(status, .behind)
        XCTAssertEqual(reason, "No issues resolved in the last 4 weeks")
    }

    func testBadgeWithoutVelocityPastDueSaysHowLate() {
        let (status, reason) = badge(dueDate: dayFromNow(-10))
        XCTAssertEqual(status, .behind)
        XCTAssertTrue(reason.hasPrefix("No velocity, 10d past due"), reason)
    }

    func testBadgeQuietWeekIsBehindAndNamesBlockedAndStale() {
        let (status, reason) = badge(velocity: 1, blocked: 2, stale: 1)
        XCTAssertEqual(status, .behind)
        XCTAssertEqual(reason, "No issues resolved this week, 2 blocked, 1 stale")
    }

    func testBadgeVelocityDropIsAtRisk() {
        let (status, reason) = badge(resolvedLastWeek: 1, velocity: 2)
        XCTAssertEqual(status, .atRisk)
        XCTAssertEqual(reason, "Velocity dropped 50% vs avg (1 vs 2.0/wk)")
    }

    func testBadgeOnPaceWithoutDueDateReportsRate() {
        let (status, reason) = badge(resolvedLastWeek: 3, velocity: 2, forecastWeeks: 2)
        XCTAssertEqual(status, .onTrack)
        XCTAssertEqual(reason, "2.0 issues/wk, 4 remaining")
    }

    func testBadgeForecastWeeksPastDueIsBehind() {
        let (status, reason) = badge(resolvedLastWeek: 3, velocity: 2, forecastWeeks: 4, dueDate: dayFromNow(7))
        XCTAssertEqual(status, .behind)
        XCTAssertTrue(reason.hasSuffix("~3 wk late"), reason)
    }

    func testBadgeForecastDaysPastDueIsTight() {
        let (status, reason) = badge(resolvedLastWeek: 3, velocity: 2, forecastWeeks: 1, dueDate: dayFromNow(4))
        XCTAssertEqual(status, .atRisk)
        XCTAssertTrue(reason.hasPrefix("Tight — forecast"), reason)
    }

    func testBadgeForecastBeforeDueIsOnPace() {
        let (status, reason) = badge(resolvedLastWeek: 3, velocity: 2, forecastWeeks: 1, dueDate: dayFromNow(30))
        XCTAssertEqual(status, .onTrack)
        XCTAssertTrue(reason.hasPrefix("On pace — forecast"), reason)
    }

    // MARK: - Project Map: epic roll-up

    func testBuildEpicItemRollsUpChildren() throws {
        let queue = try TestDatabase.create()
        let issues = try queue.write { db -> [JiraIssue] in
            let acct = try TestDatabase.insertJiraAccount(db)
            try TestDatabase.insertJiraIssue(db, account: acct, key: "PROJ-100") {
                $0.typeCategory = "epic"; $0.summary = "Payments"
                $0.assignee = "U1"; $0.assigneeName = "Ann"; $0.reporter = "U2"; $0.reporterName = "Bo"
            }
            try TestDatabase.insertJiraIssue(db, account: acct, key: "PROJ-1") {
                $0.epicKey = "PROJ-100"; $0.category = "done"; $0.resolved = self.daysAgo(3); $0.storyPoints = 3
            }
            try TestDatabase.insertJiraIssue(db, account: acct, key: "PROJ-2") {
                $0.epicKey = "PROJ-100"; $0.category = "done"; $0.resolved = self.daysAgo(20); $0.storyPoints = 2
            }
            try TestDatabase.insertJiraIssue(db, account: acct, key: "PROJ-3") {
                $0.epicKey = "PROJ-100"; $0.category = "in_progress"; $0.status = "Blocked"
                $0.categoryChanged = self.daysAgo(10); $0.assignee = "U3"; $0.assigneeName = "Cy"
            }
            try TestDatabase.insertJiraIssue(db, account: acct, key: "PROJ-4") {
                $0.epicKey = "PROJ-100"; $0.assignee = "U1"; $0.assigneeName = "Ann"; $0.storyPoints = 5
            }
            return try JiraIssue.fetchAll(db, sql: "SELECT * FROM jira_issues ORDER BY key")
        }
        let epic = try XCTUnwrap(issues.first { $0.key == "PROJ-100" })
        let children = issues.filter { $0.epicKey == "PROJ-100" }

        let item = ProjectMapViewModel.buildEpicItem(epic: epic, childIssues: children, now: Date())

        XCTAssertEqual(item.name, "Payments")
        XCTAssertEqual(item.ownerSlackID, "U1")
        XCTAssertEqual(item.totalIssues, 4)
        XCTAssertEqual(item.doneIssues, 2)
        XCTAssertEqual(item.inProgressIssues, 1)
        XCTAssertEqual(item.staleCount, 1)
        XCTAssertEqual(item.blockedCount, 1)
        XCTAssertEqual(item.progressPct, 0.5, accuracy: 0.001)
        XCTAssertEqual(item.velocityPerWeek, 0.5, accuracy: 0.001, "two resolved in 28 days")
        XCTAssertEqual(try XCTUnwrap(item.forecastWeeks), 4, accuracy: 0.001)
        XCTAssertEqual(item.totalStoryPoints, 10)
        XCTAssertEqual(item.doneStoryPoints, 5)
        XCTAssertEqual(item.participants.map(\.name), ["Ann", "Cy"], "distinct assignees, by name")
        XCTAssertEqual(item.pingTargets.map(\.reason), ["assignee", "reporter", "assignee_blocker"])
        XCTAssertEqual(item.statusBadge, .onTrack, "one resolved this week keeps pace with 0.5/wk")
        XCTAssertEqual(item.statusReason, "0.5 issues/wk, 2 remaining")
    }

    // MARK: - Release Dashboard

    /// Two sites ship a release "1.0" under the same Jira release id. Site A's
    /// is overdue with half its issues blocked; site B's is due soon and half done.
    func testReleaseItemsAreBuiltPerSite() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let (pastDate, soonDate) = (dayFromNow(-3), dayFromNow(5))
        let (siteA, siteB) = try await manager.dbPool.write { db -> (Int64, Int64) in
            let siteA = try TestDatabase.insertJiraAccount(db, siteName: "Site A")
            let siteB = try TestDatabase.insertJiraAccount(db, siteName: "Site B")
            try db.execute(sql: """
                INSERT INTO jira_releases (account_id, id, project_key, name, release_date, released) VALUES
                    (?, 100, 'PROJ', '1.0', ?, 0), (?, 100, 'PROJ', '1.0', ?, 0), (?, 101, 'PROJ', '0.9', '', 1)
                """, arguments: [siteA, pastDate, siteB, soonDate, siteA])
            let inRelease: (inout JiraIssueFixture) -> Void = { $0.fixVersions = #"["1.0"]"# }
            try TestDatabase.insertJiraIssue(db, account: siteA, key: "PROJ-100") { $0.typeCategory = "epic"; $0.summary = "Payments" }
            for key in ["PROJ-1", "PROJ-2"] {
                try TestDatabase.insertJiraIssue(db, account: siteA, key: key) {
                    inRelease(&$0); $0.status = "Blocked"; $0.assignee = "U1"; $0.assigneeName = "Ann"
                }
            }
            try TestDatabase.insertJiraIssue(db, account: siteA, key: "PROJ-3") {
                inRelease(&$0); $0.category = "done"; $0.epicKey = "PROJ-100"
            }
            try TestDatabase.insertJiraIssue(db, account: siteA, key: "PROJ-4") { inRelease(&$0); $0.epicKey = "PROJ-100" }
            try TestDatabase.insertJiraIssue(db, account: siteB, key: "PROJ-1") { inRelease(&$0); $0.category = "done" }
            try TestDatabase.insertJiraIssue(db, account: siteB, key: "PROJ-2") { inRelease(&$0) }
            return (siteA, siteB)
        }

        let vm = ReleaseDashboardViewModel(dbManager: manager)
        await vm.load()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.releases.map(\.id), ["\(siteA):100", "\(siteB):100"], "released hidden, overdue first")
        let overdue = vm.releases[0]
        XCTAssertTrue(overdue.isOverdue)
        XCTAssertEqual(overdue.totalIssues, 4)
        XCTAssertEqual(overdue.doneIssues, 1)
        XCTAssertEqual(overdue.blockedCount, 2)
        XCTAssertTrue(overdue.atRisk)
        XCTAssertEqual(overdue.atRiskReason, "50% blocked")
        XCTAssertEqual(overdue.pingTargets.map(\.slackUserID), ["U1"], "one ping per blocked assignee")
        XCTAssertEqual(overdue.epicProgress.map(\.name), ["Payments"])
        XCTAssertEqual(overdue.epicProgress.first?.statusBadge, "at_risk")
        XCTAssertEqual(overdue.scopeChanges.added, 4)

        let soon = vm.releases[1]
        XCTAssertFalse(soon.isOverdue)
        XCTAssertEqual(soon.totalIssues, 2)
        XCTAssertEqual(soon.progressPct, 0.5, accuracy: 0.001)
        XCTAssertTrue(soon.atRisk)
        XCTAssertTrue(soon.atRiskReason.hasSuffix("d left, 50% done"), soon.atRiskReason)
        XCTAssertEqual(vm.atRiskCount, 2)
        XCTAssertEqual(vm.overdueCount, 1)
    }

    // MARK: - Epic Progress badge

    private func progressItem(total: Int, done: Int, weekly: Int, monthly: Int) -> EpicProgressItem {
        EpicProgressItem(row: EpicProgressRow(
            epicKey: "PROJ-1", epicName: "Epic", totalIssues: total, doneIssues: done, inProgressIssues: 0,
            progressPct: total > 0 ? Double(done) / Double(total) : 0,
            weeklyResolvedCount: weekly, monthlyResolvedCount: monthly
        ))
    }

    func testEpicProgressBadge() {
        XCTAssertEqual(progressItem(total: 4, done: 4, weekly: 0, monthly: 0).statusBadge, .onTrack, "done")
        XCTAssertEqual(progressItem(total: 4, done: 1, weekly: 0, monthly: 0).statusBadge, .behind, "no velocity")
        XCTAssertEqual(progressItem(total: 4, done: 2, weekly: 0, monthly: 2).statusBadge, .atRisk, "quiet week")
        XCTAssertEqual(progressItem(total: 40, done: 2, weekly: 1, monthly: 4).statusBadge, .atRisk, "38 left at 1/wk")
        XCTAssertEqual(progressItem(total: 10, done: 6, weekly: 1, monthly: 4).statusBadge, .onTrack)
    }

    func testEpicProgressDerivedMetrics() throws {
        let item = progressItem(total: 10, done: 6, weekly: 2, monthly: 8)
        XCTAssertEqual(item.velocity, 2)
        XCTAssertEqual(try XCTUnwrap(item.forecastWeeks), 2)
        XCTAssertEqual(item.weeklyDeltaPct, 20)
        XCTAssertEqual(item.previousProgressPct, 0.4, accuracy: 0.001)
        XCTAssertNil(progressItem(total: 4, done: 1, weekly: 0, monthly: 0).forecastWeeks)
    }
}

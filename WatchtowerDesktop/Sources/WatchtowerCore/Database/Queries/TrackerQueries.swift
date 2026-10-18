import Foundation
import GRDB

/// A "blocks" edge between two issue keys: `blocker` blocks `blocked`.
package struct TrackerBlockLink: Equatable, Sendable {
    package let blocker: String
    package let blocked: String

    package init(blocker: String, blocked: String) {
        self.blocker = blocker
        self.blocked = blocked
    }
}

/// Progress of one epic (Jira) or project (Linear) over its child issues.
package struct ContainerProgressRow: FetchableRecord, Identifiable, Equatable, Sendable {
    package var tracker: TrackerIssue.Tracker
    package var accountID: Int64
    /// "epic" | "project"
    package var kind: String
    package var containerID: String
    package var name: String
    package var totalIssues: Int
    package var doneIssues: Int
    package var inProgressIssues: Int
    package var progressPct: Double
    package var weeklyResolvedCount: Int
    package var monthlyResolvedCount: Int

    package var id: String { "\(tracker.rawValue):\(accountID):\(containerID)" }

    package init(
        tracker: TrackerIssue.Tracker,
        accountID: Int64,
        kind: String,
        containerID: String,
        name: String,
        totalIssues: Int,
        doneIssues: Int,
        inProgressIssues: Int,
        progressPct: Double,
        weeklyResolvedCount: Int,
        monthlyResolvedCount: Int
    ) {
        self.tracker = tracker
        self.accountID = accountID
        self.kind = kind
        self.containerID = containerID
        self.name = name
        self.totalIssues = totalIssues
        self.doneIssues = doneIssues
        self.inProgressIssues = inProgressIssues
        self.progressPct = progressPct
        self.weeklyResolvedCount = weeklyResolvedCount
        self.monthlyResolvedCount = monthlyResolvedCount
    }

    package init(row: Row) {
        tracker = TrackerIssue.Tracker(rawValue: row["tracker"] ?? "") ?? .jira
        accountID = row["account_id"] ?? 0
        kind = row["container_kind"] ?? ""
        containerID = row["container_id"] ?? ""
        name = row["name"] ?? ""
        totalIssues = row["total_issues"] ?? 0
        doneIssues = row["done_issues"] ?? 0
        inProgressIssues = row["in_progress_issues"] ?? 0
        progressPct = row["progress_pct"] ?? 0
        weeklyResolvedCount = row["weekly_resolved_count"] ?? 0
        monthlyResolvedCount = row["monthly_resolved_count"] ?? 0
    }
}

/// The issue counts of one active iteration: a Jira sprint or a Linear cycle.
package struct IterationProgressRow: FetchableRecord, Identifiable, Equatable, Sendable {
    package var tracker: TrackerIssue.Tracker
    package var accountID: Int64
    package var iterationID: String
    package var name: String
    /// The Jira board's project key, or the Linear team key.
    package var projectKey: String
    package var endsAt: String
    package var total: Int
    package var done: Int
    package var inProgress: Int

    package var id: String { "\(tracker.rawValue):\(accountID):\(iterationID)" }
    package var todo: Int { max(0, total - done - inProgress) }
    package var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }

    package init(row: Row) {
        tracker = TrackerIssue.Tracker(rawValue: row["tracker"] ?? "") ?? .jira
        accountID = row["account_id"] ?? 0
        iterationID = row["id"] ?? ""
        name = row["name"] ?? ""
        projectKey = row["project_key"] ?? ""
        endsAt = row["ends_at"] ?? ""
        total = row["total"] ?? 0
        done = row["done"] ?? 0
        inProgress = row["in_progress"] ?? 0
    }

    /// Whole days until `endsAt` (never negative); nil when it has no end
    /// date or the date does not parse.
    package func daysLeft(now: Date = Date()) -> Int? {
        guard let end = SyncProgress.parseTimestamp(endsAt) else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: now, to: end).day ?? 0)
    }
}

/// The Desktop's reads over the tracker-neutral views (`tracker_issues`,
/// `tracker_iterations`), so Jira and Linear issues show side by side
/// (spec §6, Desktop row). Releases, boards, the project map and workload
/// stay on the Jira tables.
package enum TrackerQueries {
    // MARK: - Blocker map

    /// Open issues the tracker reports as blocked: Jira's status-name rule
    /// or an open Linear `blocks` relation (the view's `is_blocked`).
    package static func fetchBlockedIssues(_ db: Database) throws -> [TrackerIssue] {
        try TrackerIssue.fetchAll(db, sql: """
            SELECT * FROM tracker_issues
            WHERE is_blocked = 1 AND status_category != 'done' AND is_deleted = 0
            ORDER BY updated_at DESC
            """)
    }

    /// In-progress issues whose status category has not moved for more than
    /// `staleDays` days.
    package static func fetchStaleIssues(_ db: Database, staleDays: Int = 7) throws -> [TrackerIssue] {
        try TrackerIssue.fetchAll(
            db,
            sql: """
                SELECT * FROM tracker_issues
                WHERE status_category = 'in_progress'
                  AND status_changed_at != ''
                  AND julianday('now') - julianday(status_changed_at) > ?
                  AND is_deleted = 0
                ORDER BY status_changed_at ASC
                """,
            arguments: [staleDays]
        )
    }

    /// The "blocks" edges touching `keys`: Jira links whose type names a
    /// block (source blocks target), and Linear `blocks` relations (issue
    /// blocks related issue), both by current key.
    package static func fetchBlockLinks(_ db: Database, keys: [String]) throws -> [TrackerBlockLink] {
        guard !keys.isEmpty else { return [] }
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT source_key AS blocker, target_key AS blocked FROM jira_issue_links
                WHERE LOWER(link_type) LIKE '%block%'
                  AND (source_key IN (\(placeholders)) OR target_key IN (\(placeholders)))
                UNION ALL
                SELECT b.key, d.key FROM linear_relations r
                JOIN linear_issues b ON b.account_id = r.account_id AND b.id = r.issue_id
                JOIN linear_issues d ON d.account_id = r.account_id AND d.id = r.related_issue_id
                WHERE r.type = 'blocks'
                  AND (b.key IN (\(placeholders)) OR d.key IN (\(placeholders)))
                """,
            arguments: StatementArguments(keys + keys + keys + keys)
        )
        return rows.map { TrackerBlockLink(blocker: $0["blocker"], blocked: $0["blocked"]) }
    }

    /// One issue by key. A key two trackers share resolves to Jira first,
    /// then the lowest account (the bare-key convention of the Jira reads).
    package static func fetchIssueByKey(_ db: Database, key: String) throws -> TrackerIssue? {
        try TrackerIssue.fetchOne(
            db,
            sql: "SELECT * FROM tracker_issues WHERE key = ? ORDER BY tracker, account_id LIMIT 1",
            arguments: [key]
        )
    }

    // MARK: - Epic / project progress

    /// Epics and projects with at least three issues: counts, done share and
    /// how many were resolved in the last 7 and 28 days. One row per
    /// container per account; a container without a name shows its id.
    package static func fetchContainerProgress(_ db: Database, now: Date = Date()) throws -> [ContainerProgressRow] {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        let sevenDaysAgo = day.string(from: Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now)
        let twentyEightDaysAgo = day.string(from: Calendar.current.date(byAdding: .day, value: -28, to: now) ?? now)
        return try ContainerProgressRow.fetchAll(
            db,
            sql: """
                SELECT tracker, account_id, container_kind, container_id,
                       CASE WHEN MAX(container_name) != '' THEN MAX(container_name) ELSE container_id END AS name,
                       COUNT(*) AS total_issues,
                       COUNT(*) FILTER (WHERE status_category = 'done') AS done_issues,
                       COUNT(*) FILTER (WHERE status_category = 'in_progress') AS in_progress_issues,
                       CAST(COUNT(*) FILTER (WHERE status_category = 'done') AS REAL) / COUNT(*) AS progress_pct,
                       COUNT(*) FILTER (WHERE status_category = 'done' AND resolved_at >= ?) AS weekly_resolved_count,
                       COUNT(*) FILTER (WHERE status_category = 'done' AND resolved_at >= ?) AS monthly_resolved_count
                FROM tracker_issues
                WHERE container_id != '' AND is_deleted = 0
                GROUP BY tracker, account_id, container_kind, container_id
                HAVING COUNT(*) >= 3
                ORDER BY progress_pct DESC, total_issues DESC, name
                """,
            arguments: [sevenDaysAgo, twentyEightDaysAgo]
        )
    }

    // MARK: - Iteration progress

    /// Every active sprint and cycle that has issues, soonest end first.
    package static func fetchActiveIterations(_ db: Database) throws -> [IterationProgressRow] {
        try IterationProgressRow.fetchAll(db, sql: """
            SELECT it.tracker, it.account_id, it.id, it.name, it.project_key, it.ends_at,
                   COUNT(*) AS total,
                   COUNT(*) FILTER (WHERE i.status_category = 'done') AS done,
                   COUNT(*) FILTER (WHERE i.status_category = 'in_progress') AS in_progress
            FROM tracker_iterations it
            JOIN tracker_issues i
              ON i.tracker = it.tracker AND i.account_id = it.account_id AND i.iteration_id = it.id
             AND i.is_deleted = 0
            WHERE it.state = 'active'
            GROUP BY it.tracker, it.account_id, it.id
            ORDER BY it.ends_at = '', it.ends_at, it.name
            """)
    }
}

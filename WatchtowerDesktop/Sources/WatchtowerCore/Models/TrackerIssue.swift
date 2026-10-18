import Foundation
import GRDB

/// One row of the tracker-neutral `tracker_issues` view (migration 00120):
/// a Jira issue or a Linear issue, in one shape. The Swift twin of Go's
/// tracker query API (spec §2.1). Read-only — writes go to the trackers.
package struct TrackerIssue: FetchableRecord, Equatable, Identifiable, Sendable {
    /// `tracker` values the view writes.
    package enum Tracker: String, Sendable {
        case jira, linear
    }

    package var tracker: Tracker
    package var accountID: Int64
    /// The tracker's own id: the Jira issue id, or Linear's UUID.
    package var issueID: String
    package var key: String
    /// The Jira project key, or the Linear team key.
    package var projectKey: String
    package var title: String
    package var status: String
    /// "todo" | "in_progress" | "done"
    package var statusCategory: String
    package var statusChangedAt: String
    package var assigneeDisplayName: String
    package var assigneeSlackID: String
    package var reporterDisplayName: String
    package var reporterSlackID: String
    package var priority: String
    /// 1 highest … 5 lowest, 0 none (Jira names and Linear numbers both map).
    package var priorityRank: Int
    package var points: Double?
    package var dueDate: String
    package var iterationID: String
    package var iterationName: String
    /// "epic" | "project" | ""
    package var containerKind: String
    package var containerID: String
    package var containerName: String
    package var isBlocked: Bool
    /// The view's link; a Jira site without a recorded URL leaves a bare
    /// `/browse/KEY` here, which `browseURL` refuses.
    package var url: String
    package var updatedAt: String
    package var resolvedAt: String
    package var isDeleted: Bool

    /// Unique across trackers and accounts: a key can repeat on two sites.
    package var id: String { "\(tracker.rawValue):\(accountID):\(key)" }

    /// The issue's page in its tracker, or nil when the view has no absolute
    /// link for it.
    package var browseURL: URL? {
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        return URL(string: url)
    }

    /// "Jira" or "Linear", for "Open in …" help text.
    package var trackerName: String {
        switch tracker {
        case .jira: "Jira"
        case .linear: "Linear"
        }
    }

    package init(row: Row) {
        // An unknown tracker value would be a view this build does not know;
        // it reads as Jira so the row still renders.
        tracker = Tracker(rawValue: row["tracker"] ?? "") ?? .jira
        accountID = row["account_id"] ?? 0
        issueID = row["issue_id"] ?? ""
        key = row["key"] ?? ""
        projectKey = row["project_key"] ?? ""
        title = row["title"] ?? ""
        status = row["status"] ?? ""
        statusCategory = row["status_category"] ?? ""
        statusChangedAt = row["status_changed_at"] ?? ""
        assigneeDisplayName = row["assignee_display_name"] ?? ""
        assigneeSlackID = row["assignee_slack_id"] ?? ""
        reporterDisplayName = row["reporter_display_name"] ?? ""
        reporterSlackID = row["reporter_slack_id"] ?? ""
        priority = row["priority"] ?? ""
        priorityRank = row["priority_rank"] ?? 0
        points = row["points"]
        dueDate = row["due_date"] ?? ""
        iterationID = row["iteration_id"] ?? ""
        iterationName = row["iteration_name"] ?? ""
        containerKind = row["container_kind"] ?? ""
        containerID = row["container_id"] ?? ""
        containerName = row["container_name"] ?? ""
        isBlocked = row["is_blocked"] ?? false
        url = row["url"] ?? ""
        updatedAt = row["updated_at"] ?? ""
        resolvedAt = row["resolved_at"] ?? ""
        isDeleted = row["is_deleted"] ?? false
    }
}

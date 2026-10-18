import AppKit
import Foundation
import WatchtowerCore

extension AppState {
    /// The issue's page in its tracker, from `tracker_issues`; nil when the
    /// issue is not synced or has no absolute link. A read failure is logged
    /// and reads as nil (the caller has nothing better to open).
    func trackerIssueURL(tracker: TrackerIssue.Tracker, key: String) -> URL? {
        guard let pool = databaseManager?.dbPool else { return nil }
        do {
            return try pool.read { db in try TrackerQueries.fetchIssue(db, tracker: tracker, key: key)?.browseURL }
        } catch {
            NSLog("AppState: reading %@ issue %@ failed: %@", tracker.rawValue, key, error.localizedDescription)
            return nil
        }
    }

    /// Opens a Linear (or Jira) issue's page in the browser; returns whether
    /// there was a link to open.
    @discardableResult
    func openTrackerIssue(tracker: TrackerIssue.Tracker, key: String) -> Bool {
        guard let url = trackerIssueURL(tracker: tracker, key: key) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

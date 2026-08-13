import GRDB

/// One connected alternative calendar — CalDAV or a secret ICS feed — from the
/// `calendar_accounts` table. Google Calendar keeps its own single-account
/// OAuth token-file model and is NOT represented here.
///
/// The ICS secret feed URL is a credential and is NEVER stored in this table
/// (`url` is empty for ics rows) — only the CalDAV server URL appears here.
package struct CalendarAccount: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let provider: String
    package let username: String
    package let url: String
    package let label: String
    package let status: String
    package let error: String

    package init(row: Row) {
        id = row["id"]
        provider = row["provider"] ?? ""
        username = row["username"] ?? ""
        url = row["url"] ?? ""
        label = row["label"] ?? ""
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
    }

    // MARK: - Status predicates

    package var isOK: Bool { status == "ok" }

    // MARK: - Provider predicates

    package var isICS: Bool { provider == "ics" }

    /// Display text for a row: the user-facing label if set, else the CalDAV
    /// username, else "ICS feed" (ics rows have no username and no stored URL).
    package var displayName: String {
        if !label.isEmpty { return label }
        if !username.isEmpty { return username }
        return "ICS feed"
    }
}

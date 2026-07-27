import GRDB

/// One connected alternative calendar — CalDAV or a secret ICS feed — from the
/// `calendar_accounts` table. Google Calendar keeps its own single-account
/// OAuth token-file model and is NOT represented here.
///
/// The ICS secret feed URL is a credential and is NEVER stored in this table
/// (`url` is empty for ics rows) — only the CalDAV server URL appears here.
struct CalendarAccount: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let provider: String
    let username: String
    let url: String
    let label: String
    let status: String
    let error: String

    init(row: Row) {
        id = row["id"]
        provider = row["provider"] ?? ""
        username = row["username"] ?? ""
        url = row["url"] ?? ""
        label = row["label"] ?? ""
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
    }

    // MARK: - Status predicates

    var isOK: Bool { status == "ok" }

    // MARK: - Provider predicates

    var isICS: Bool { provider == "ics" }

    /// Display text for a row: the user-facing label if set, else the CalDAV
    /// username, else "ICS feed" (ics rows have no username and no stored URL).
    var displayName: String {
        if !label.isEmpty { return label }
        if !username.isEmpty { return username }
        return "ICS feed"
    }
}

import GRDB

/// One connected Google account (Calendar and/or Gmail) from the
/// `google_accounts` table (internal/db/migrations/00043_google_accounts.sql).
/// Multiple accounts can be connected side by side; `calendarEnabled`/
/// `gmailEnabled` record which services this account granted.
package struct GoogleAccount: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let email: String
    package let label: String
    package let clientID: String
    package let calendarEnabled: Bool
    package let gmailEnabled: Bool
    package let status: String
    package let error: String

    package init(row: Row) {
        id = row["id"]
        email = row["email"] ?? ""
        label = row["label"] ?? ""
        clientID = row["client_id"] ?? ""
        calendarEnabled = row["calendar_enabled"] ?? false
        gmailEnabled = row["gmail_enabled"] ?? false
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
    }

    // MARK: - Status predicates

    package var isOK: Bool { status == "ok" }
    package var isRevoked: Bool { status == "revoked" }

    /// Display text for a row: the user-facing label if set, else the Google
    /// account's email, else a positional fallback for a not-yet-consented
    /// row (email is only populated once the OAuth flow completes).
    package var displayName: String {
        if !label.isEmpty { return label }
        if !email.isEmpty { return email }
        return "Google account #\(id)"
    }
}

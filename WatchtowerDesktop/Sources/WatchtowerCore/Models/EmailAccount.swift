import GRDB

/// One connected mailbox — IMAP or Outlook — from the `email_accounts` table
/// (internal/db/migrations/00022_email_accounts.sql). Gmail keeps its own
/// single-account token-file model and is NOT represented here.
package struct EmailAccount: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let provider: String
    package let emailAddress: String
    package let host: String
    package let port: Int
    package let security: String
    package let folder: String
    package let label: String
    package let status: String
    package let error: String

    package init(row: Row) {
        id = row["id"]
        provider = row["provider"] ?? ""
        emailAddress = row["email_address"] ?? ""
        host = row["host"] ?? ""
        port = row["port"] ?? 0
        security = row["security"] ?? ""
        folder = row["folder"] ?? ""
        label = row["label"] ?? ""
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
    }

    // MARK: - Status predicates

    package var isOK: Bool { status == "ok" }
    package var isRevoked: Bool { status == "revoked" }

    // MARK: - Provider predicates

    package var isOutlook: Bool { provider == "outlook" }

    /// Display text for a row: the user-facing label if set, else the email address.
    package var displayName: String { label.isEmpty ? emailAddress : label }
}

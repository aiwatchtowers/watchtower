import GRDB

/// One connected mailbox — IMAP or Outlook — from the `email_accounts` table
/// (internal/db/migrations/00022_email_accounts.sql). Gmail keeps its own
/// single-account token-file model and is NOT represented here.
struct EmailAccount: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let provider: String
    let emailAddress: String
    let host: String
    let port: Int
    let security: String
    let folder: String
    let label: String
    let status: String
    let error: String

    init(row: Row) {
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

    var isOK: Bool { status == "ok" }
    var isRevoked: Bool { status == "revoked" }

    // MARK: - Provider predicates

    var isOutlook: Bool { provider == "outlook" }

    /// Display text for a row: the user-facing label if set, else the email address.
    var displayName: String { label.isEmpty ? emailAddress : label }
}

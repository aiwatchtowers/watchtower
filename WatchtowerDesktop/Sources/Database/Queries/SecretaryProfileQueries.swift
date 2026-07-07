import GRDB

/// Free-text brief the secretary pipeline reads before every inbox scan
/// (`workspace.secretary_profile`, TEXT NOT NULL DEFAULT '').
enum SecretaryProfileQueries {
    /// Empty string if there is no workspace row yet, rather than throwing.
    static func fetch(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT secretary_profile FROM workspace LIMIT 1") ?? ""
    }

    /// UPDATE only — if no workspace row exists yet this is a silent no-op
    /// (0 rows affected), matching the Go side which always has a workspace
    /// row by the time the profile editor is reachable (post first sync).
    static func save(_ db: Database, text: String) throws {
        try db.execute(sql: "UPDATE workspace SET secretary_profile = ?", arguments: [text])
    }

    /// Empty strings when no workspace row exists yet.
    static func fetchStyle(_ db: Database) throws -> (text: String, updatedAt: String) {
        let row = try Row.fetchOne(db, sql: "SELECT style_profile, style_profile_updated_at FROM workspace LIMIT 1")
        return (row?["style_profile"] ?? "", row?["style_profile_updated_at"] ?? "")
    }

    /// UPDATE only — silent no-op without a workspace row (matches save(_:text:)).
    static func saveStyle(_ db: Database, text: String) throws {
        try db.execute(
            sql: "UPDATE workspace SET style_profile = ?, style_profile_updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
            arguments: [text]
        )
    }
}

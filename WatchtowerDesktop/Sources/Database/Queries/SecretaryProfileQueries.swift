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
}

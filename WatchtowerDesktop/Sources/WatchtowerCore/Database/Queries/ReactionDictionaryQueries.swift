import GRDB

/// Direct GRDB reads/writes over `reaction_command_map` (+ a `tool_trust`
/// lookup) — the Settings → Slack "Reaction commands" editor. Swift-owned
/// (the `inbox_feedback` dual-path precedent): the table is small and
/// owner-edited, so there is no daemon contention to arbitrate.
package enum ReactionDictionaryQueries {
    package static func fetchAll(_ db: Database) throws -> [ReactionCommandMapping] {
        try ReactionCommandMapping.fetchAll(
            db,
            sql: "SELECT * FROM reaction_command_map ORDER BY emoji ASC"
        )
    }

    package static func setEnabled(_ db: Database, emoji: String, enabled: Bool) throws {
        try db.execute(sql: """
            UPDATE reaction_command_map
            SET enabled = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE emoji = ?
            """, arguments: [enabled, emoji])
    }

    /// Adds a new mapping or repoints an existing emoji at a different tool
    /// — `kind` stays `builtin_tool` (the only kind the Desktop editor can
    /// author; `agent`/`handler_id` are a later-wave extension).
    package static func upsert(_ db: Database, emoji: String, tool: String) throws {
        try db.execute(sql: """
            INSERT INTO reaction_command_map (emoji, kind, tool, enabled)
            VALUES (?, 'builtin_tool', ?, 1)
            ON CONFLICT(emoji) DO UPDATE SET
                tool = excluded.tool,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            """, arguments: [emoji, tool])
    }

    package static func delete(_ db: Database, emoji: String) throws {
        try db.execute(sql: "DELETE FROM reaction_command_map WHERE emoji = ?", arguments: [emoji])
    }

    /// The owner's standing trust decision for `tool` (`"ask"`/`"execute"`),
    /// or nil when the row doesn't exist yet — Go's default is "ask" until
    /// `watchtower actions trust` writes a row (`internal/tools.SetTrust`).
    package static func trustFor(_ db: Database, tool: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT trust FROM tool_trust WHERE tool = ?", arguments: [tool])
    }
}

import Foundation
import GRDB

/// A built-in whose one-time move from the old pipeline settings failed
/// (`builtin_migrations.status = 'failed'`, written by Go
/// `db.RecordBuiltinMigration`): the Inbox shows it as a notice with a retry
/// (`automations upgrade-builtins`). Lives in the Inbox feed snapshot, hence
/// `Equatable`/`Sendable`.
package struct BuiltinUpgradeNotice: Equatable, Sendable {
    package let builtinID: String
    package let error: String
    package let updatedAt: Date

    package init(builtinID: String, error: String, updatedAt: Date) {
        self.builtinID = builtinID
        self.error = error
        self.updatedAt = updatedAt
    }

    /// The built-ins' names by id, twin of Go `builtin.Entry.Name`
    /// (internal/automations/builtin/registry.go).
    private static let names: [String: String] = [
        "morning-brief": "Morning brief"
    ]

    /// The built-in's name; the id itself for one this table does not know.
    package static func name(for id: String) -> String {
        names[id] ?? id
    }

    package var title: String {
        "Couldn't move \(Self.name(for: builtinID)) to Automations"
    }

    /// Every failed move, newest first. A schema without `builtin_migrations`
    /// (before 00150) has none; any other error is thrown.
    package static func load(_ db: Database) throws -> [Self] {
        do {
            let rows = try Row.fetchAll(db, sql: """
                SELECT builtin_id, error, updated_at FROM builtin_migrations
                WHERE status = 'failed' ORDER BY updated_at DESC, builtin_id
                """)
            // Go always writes RFC 3339 UTC; an unparsable date only orders the
            // notice last, it is still a failed move the owner must see.
            return rows.map { row in
                Self(builtinID: row["builtin_id"], error: row["error"],
                     updatedAt: AutomationDates.parse(row["updated_at"]) ?? .distantPast)
            }
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return []
        }
    }
}

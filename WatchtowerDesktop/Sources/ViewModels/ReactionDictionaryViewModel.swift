import Foundation
import GRDB
import WatchtowerCore

/// Drives the Settings → Slack "Reaction commands" editor. `reaction_command_map`
/// (migration 00063) maps an emoji to a registered agent-actions tool; the
/// owner reacts with that emoji in Slack and Watchtower dispatches the tool as
/// an agent action (`internal/reactioncmd`). This VM writes directly via GRDB
/// (the `inbox_feedback` dual-path precedent — a small owner-edited table, no
/// daemon contention) rather than shelling out to the CLI like the account
/// VMs above it. Owned by AppState so an in-flight edit's `refresh()` isn't
/// lost navigating away from Settings.
@MainActor
@Observable
final class ReactionDictionaryViewModel {
    private(set) var mappings: [ReactionCommandMapping] = []
    private(set) var trustByTool: [String: String] = [:]
    var error: String?

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Cross-process writes (the reaction-command daemon phase dispatching a
    /// tool, or another Settings window) don't fire GRDB's ValueObservation,
    /// so callers reload on appear / after an edit rather than observing live.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// The awaitable body of `refresh()`, split out so tests can call it
    /// directly and observe `mappings` deterministically instead of racing a
    /// detached `Task`.
    func refreshAsync() async {
        do {
            let (rows, trust) = try await dbPool.read { db -> ([ReactionCommandMapping], [String: String]) in
                let rows = try ReactionDictionaryQueries.fetchAll(db)
                var trust: [String: String] = [:]
                for tool in Set(rows.map(\.tool)) where !tool.isEmpty {
                    if let value = try ReactionDictionaryQueries.trustFor(db, tool: tool) {
                        trust[tool] = value
                    }
                }
                return (rows, trust)
            }
            mappings = rows
            trustByTool = trust
            error = nil
        } catch {
            self.error = "Failed to load reaction commands: \(error.localizedDescription)"
        }
    }

    /// The owner's standing trust for `tool` ("ask"/"execute"). A tool with no
    /// `tool_trust` row is "ask" — Go's default (`Registry.Propose`), so the
    /// Wave 1 tools, which no migration seeds, read the same as the seeded ones.
    func trustFor(tool: String) -> String {
        trustByTool[tool] ?? "ask"
    }

    /// The Inbox cheat sheet's rows, derived from exactly what this editor
    /// shows — one source, so a Settings edit is what the Inbox renders.
    var cheatSheetRows: [ReactionCheatSheet.Row] {
        ReactionCheatSheet.rows(mappings: mappings, trustByTool: trustByTool)
    }

    func setEnabled(emoji: String, enabled: Bool) async {
        do {
            try await dbPool.write { db in try ReactionDictionaryQueries.setEnabled(db, emoji: emoji, enabled: enabled) }
            await refreshAsync()
        } catch {
            self.error = "Failed to update mapping: \(error.localizedDescription)"
        }
    }

    /// Adds a new emoji mapping, or repoints an existing emoji at a different
    /// tool.
    func upsert(emoji: String, tool: String) async {
        do {
            try await dbPool.write { db in try ReactionDictionaryQueries.upsert(db, emoji: emoji, tool: tool) }
            await refreshAsync()
        } catch {
            self.error = "Failed to save mapping: \(error.localizedDescription)"
        }
    }

    func delete(emoji: String) async {
        do {
            try await dbPool.write { db in try ReactionDictionaryQueries.delete(db, emoji: emoji) }
            await refreshAsync()
        } catch {
            self.error = "Failed to delete mapping: \(error.localizedDescription)"
        }
    }
}

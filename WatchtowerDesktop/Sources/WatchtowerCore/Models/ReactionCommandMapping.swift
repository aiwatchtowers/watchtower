import GRDB

/// One `reaction_command_map` row — an owner-edited emoji-to-action mapping
/// (migration 00063). `kind = "builtin_tool"` names a tool registered in Go's
/// `internal/tools` registry (`tool`); `kind = "agent"` is the forward-compat
/// custom-handler extension point (`handlerID`), not yet reachable from the
/// Desktop editor. Mirrors the Go-owned schema; Swift owns direct writes here
/// (a small owner-edited table, the `inbox_feedback` dual-path precedent —
/// no daemon contention).
package struct ReactionCommandMapping: FetchableRecord, Identifiable, Equatable, Sendable {
    package var id: String { emoji }
    package let emoji: String
    package let kind: String
    package let tool: String
    package let handlerID: Int64
    package let enabled: Bool
    package let createdAt: String
    package let updatedAt: String

    package init(row: Row) {
        emoji = row["emoji"]
        kind = row["kind"] ?? "builtin_tool"
        tool = row["tool"] ?? ""
        handlerID = row["handler_id"] ?? 0
        enabled = row["enabled"] ?? true
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }
}

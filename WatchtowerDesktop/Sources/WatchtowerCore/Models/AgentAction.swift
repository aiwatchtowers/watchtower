import ChatWire
import Foundation
import GRDB

/// One agent_actions row — a write-tool proposal the assistant made. One model
/// with the iPhone's approval card (`ChatWire.ChatAgentAction`, ask #1409). Go
/// owns every status transition (`watchtower actions …`); the Desktop only
/// reads and observes.
package typealias AgentAction = ChatAgentAction

/// The whole row, mirroring `internal/db/agent_actions.go`. `argsSHA256` stays
/// "" on a Mac row: `AgentActionFeed` hashes `argsJSON` at approve (AGENT-07).
extension ChatAgentAction: @retroactive FetchableRecord {
    public init(row: Row) {
        self.init(
            id: row["id"],
            tool: row["tool"],
            external: row["external"] ?? false,
            argsJSON: row["args_json"] ?? "",
            argsComplete: true,
            reason: row["reason"] ?? "",
            surface: row["surface"] ?? "",
            conversationID: row["conversation_id"] ?? 0,
            contextType: row["context_type"] ?? "",
            contextID: row["context_id"] ?? "",
            turnID: row["turn_id"] ?? "",
            status: row["status"] ?? "pending",
            trustAtCreate: row["trust_at_create"] ?? "ask",
            resultJSON: row["result_json"] ?? "",
            error: row["error"] ?? "",
            createdAt: row["created_at"] ?? "",
            decidedAt: row["decided_at"] ?? "",
            appliedAt: row["applied_at"] ?? "",
            dismissedAt: row["dismissed_at"] ?? ""
        )
    }
}

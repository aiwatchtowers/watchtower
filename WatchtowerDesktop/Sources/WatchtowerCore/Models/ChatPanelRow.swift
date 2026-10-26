import Foundation
import GRDB

/// One row of the Chats panel (spec 2026-10-26 §5): the conversation plus
/// what its second line and state dot read, from `ChatHistoryQueries.panelRows`.
package struct ChatPanelRow: FetchableRecord, Identifiable, Equatable, Sendable {
    package let conversation: ChatConversation
    /// The last complete assistant message on the active branch; nil before
    /// the first answer.
    package let lastAnswerAt: Date?
    /// Its first line, markdown stripped ('' when it has no text).
    package let lastAnswerPreview: String
    /// `pending` `agent_actions` rows with this `conversation_id`.
    package let pendingApprovals: Int
    /// The tool of the oldest pending one; nil when none waits.
    package let pendingTool: String?
    /// The chat's project name; nil outside a project.
    package let projectName: String?

    package var id: Int64 { conversation.id }

    /// A complete answer the owner has not seen: newer than `read_at`, or
    /// any answer when the chat was never marked read.
    package var isUnread: Bool {
        guard let lastAnswerAt else { return false }
        guard let readAt = conversation.readAt else { return true }
        return lastAnswerAt.timeIntervalSince1970 > readAt
    }

    package init(
        conversation: ChatConversation,
        lastAnswerAt: Date?,
        lastAnswerPreview: String,
        pendingApprovals: Int,
        pendingTool: String?,
        projectName: String?
    ) {
        self.conversation = conversation
        self.lastAnswerAt = lastAnswerAt
        self.lastAnswerPreview = lastAnswerPreview
        self.pendingApprovals = pendingApprovals
        self.pendingTool = pendingTool
        self.projectName = projectName
    }

    package init(row: Row) throws {
        conversation = try ChatConversation(row: row)
        let answeredAt: Double? = row["last_answer_at"]
        lastAnswerAt = answeredAt.map { Date(timeIntervalSince1970: $0) }
        lastAnswerPreview = Self.preview(row["last_answer_text"] ?? "")
        pendingApprovals = row["pending_approvals"] ?? 0
        pendingTool = row["pending_tool"]
        projectName = row["project_name"]
    }

    /// The first line of `markdown` that has text once stripped (a fence
    /// line alone has none), as plain text.
    package static func preview(_ markdown: String) -> String {
        for line in markdown.split(whereSeparator: \.isNewline) {
            let plain = InboxCardTexts.preview(String(line))
            if !plain.isEmpty { return plain }
        }
        return ""
    }
}

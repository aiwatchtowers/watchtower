import Foundation
import GRDB

/// The main chat's branch-aware message access (spec §2.3). Discuss chats
/// keep using `ChatMessageQueries` (linear, no leaf) — a conversation whose
/// leaf is NULL reads in id order here too, the same fallback Go's
/// `ActiveChatPath` applies.
package enum ChatTreeQueries {
    package static func activePath(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        let all = try allMessages(db, conversationID: conversationID)
        return try resolvePath(db, conversationID: conversationID, all: all).path
    }

    package static func thread(_ db: Database, conversationID: Int64) throws -> [ChatThreadItem] {
        let all = try allMessages(db, conversationID: conversationID)
        let resolved = try resolvePath(db, conversationID: conversationID, all: all)
        let steps = try ChatStepQueries.fetch(db, messageIDs: resolved.path.map(\.id))
        let attachments = try ChatAttachmentQueries.fetchByMessages(db, messageIDs: resolved.path.map(\.id))
        return resolved.path.map { message in
            // Without a leaf there are no branches (legacy / never-branched chat).
            let sibs = resolved.tree.map { $0.siblings(of: message.id) } ?? [message.id]
            return ChatThreadItem(
                message: message,
                steps: steps[message.id] ?? [],
                siblingIndex: (sibs.firstIndex(of: message.id) ?? 0) + 1,
                siblingCount: max(sibs.count, 1),
                attachments: attachments[message.id] ?? []
            )
        }
    }

    package static func siblings(_ db: Database, messageID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(db, sql: """
            SELECT * FROM chat_messages
            WHERE conversation_id = (SELECT conversation_id FROM chat_messages WHERE id = ?)
              AND parent_id IS (SELECT parent_id FROM chat_messages WHERE id = ?)
            ORDER BY id
            """, arguments: [messageID, messageID])
    }

    /// The most recently written message of any branch — what a resumed
    /// provider session last saw, when that turn ran on the same provider.
    package static func newestMessage(_ db: Database, conversationID: Int64) throws -> ChatMessageRecord? {
        try ChatMessageRecord.fetchOne(
            db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY id DESC LIMIT 1",
            arguments: [conversationID]
        )
    }

    // MARK: - Tree

    package static func allMessages(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(
            db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY id", arguments: [conversationID]
        )
    }

    package static func node(_ m: ChatMessageRecord) -> ChatTree.Node {
        ChatTree.Node(id: m.id, parentID: m.parentID)
    }

    private static func resolvePath(
        _ db: Database, conversationID: Int64, all: [ChatMessageRecord]
    ) throws -> (path: [ChatMessageRecord], tree: ChatTree?) {
        let leaf = try Int64.fetchOne(
            db, sql: "SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?", arguments: [conversationID]
        )
        guard let leaf else { return (all, nil) }
        let tree = ChatTree(nodes: all.map(node))
        let ids = tree.path(toLeaf: leaf)
        guard !ids.isEmpty else { return (all, nil) }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return (ids.compactMap { byID[$0] }, tree)
    }
}

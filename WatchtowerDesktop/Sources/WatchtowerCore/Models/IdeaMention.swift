import Foundation
import GRDB

// MARK: - IdeaMention

/// A single sighting of an idea across sources — an idea accumulates one
/// mention row per occurrence instead of being overwritten. See
/// `internal/db/ideas.go` on the Go side (table `idea_mentions`).
package struct IdeaMention: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let ideaID: Int    // column: idea_id
    package let source: String
    package let ref: String
    package let quote: String
    package let author: String
    package let saidAt: String     // column: said_at
    package let createdAt: String  // column: created_at

    package enum Source: String {
        case slack
        case meeting
        case gmail
        case jira
        case owner
        /// An IMAP/Outlook mailbox (`email_accounts`), mined like Gmail.
        case imap
        /// A Linear issue (`stream_digests` source 'linear'); ref = issue key.
        case linear
        /// An AI chat message; ref = `chat:<conversation_id>:<message_id>`
        /// (migration 00154).
        case chat

        /// The user-facing name of the source ("Email" for an IMAP/Outlook
        /// mailbox, the capitalized raw value otherwise).
        package var label: String {
            self == .imap ? "Email" : rawValue.capitalized
        }
    }

    /// Typed source derived from the `source` column.
    package var sourceKind: Source {
        Source(rawValue: source) ?? .owner
    }

    /// The conversation and message a `chat` mention points at; nil for any
    /// other source or a malformed ref.
    package var chatTarget: (conversationID: Int64, messageID: Int64)? {
        guard sourceKind == .chat else { return nil }
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "chat",
              let conversation = Int64(parts[1]), let message = Int64(parts[2]) else { return nil }
        return (conversation, message)
    }

    package init(row: Row) {
        id = row["id"]
        ideaID = row["idea_id"]
        source = row["source"] ?? "owner"
        ref = row["ref"] ?? ""
        quote = row["quote"] ?? ""
        author = row["author"] ?? ""
        saidAt = row["said_at"] ?? ""
        createdAt = row["created_at"] ?? ""
    }
}

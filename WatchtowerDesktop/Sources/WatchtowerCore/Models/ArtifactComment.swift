import Foundation
import GRDB

/// One `chat_artifact_comments` row (goose migration 00082): the owner's
/// comment on a passage of an AI Chat artifact. It belongs to the
/// (conversation, key), not to one version: `artifactVersion` is the version
/// its anchor was last found on, and every newer version re-anchors it
/// (`ArtifactCommentReanchor`).
package struct ArtifactComment: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package enum Status: String, Decodable, Sendable {
        /// Written, not sent yet — the owner's private draft.
        case open
        /// Went out in an owner chat message.
        case sent
        case resolved
        /// Its quote is gone from the latest version.
        case outdated
    }

    package let id: Int64
    package let conversationID: Int64
    package let artifactKey: String
    package let artifactVersion: Int
    package let body: String
    package let anchorQuote: String
    package let anchorPrefix: String
    package let anchorSuffix: String
    package let anchorHeading: String
    package let status: Status
    package let createdAt: Double
    package let sentAt: Double?

    package enum CodingKeys: String, CodingKey {
        case id, body, status
        case conversationID = "conversation_id"
        case artifactKey = "artifact_key"
        case artifactVersion = "artifact_version"
        case anchorQuote = "anchor_quote"
        case anchorPrefix = "anchor_prefix"
        case anchorSuffix = "anchor_suffix"
        case anchorHeading = "anchor_heading"
        case createdAt = "created_at"
        case sentAt = "sent_at"
    }

    package var anchor: CommentAnchor {
        CommentAnchor(quote: anchorQuote, prefix: anchorPrefix, suffix: anchorSuffix, heading: anchorHeading)
    }

    /// Open and sent comments follow the artifact to its newer versions.
    package var isLive: Bool { status == .open || status == .sent }

    /// What `CommentThreadView` shows: the quote and the owner's one comment.
    package var content: CommentThreadContent {
        CommentThreadContent(
            id: id,
            quote: anchorQuote,
            statusNote: statusNote,
            entries: [CommentThreadContent.Entry(id: id, author: "You", body: body)]
        )
    }

    private var statusNote: String {
        switch status {
        case .open: "Not sent yet"
        case .sent: "Sent to the assistant"
        case .resolved: "Resolved"
        case .outdated: "Outdated — the quoted text changed"
        }
    }
}

import Foundation

/// The owner message "Send N comments" composes — the only way the assistant
/// ever learns about artifact comments. Pure: the chat sends the text as an
/// ordinary owner turn (`ChatViewModel.sendArtifactComments`).
package enum ArtifactCommentMessage {
    /// The composed text and exactly the comment ids it carries.
    package struct Outgoing: Equatable, Sendable {
        package let text: String
        package let ids: [Int64]
    }

    /// nil when there is nothing to send. `comments` are used in the given
    /// order (the model passes them in text order). One batch, via
    /// `CommentBatchComposer` — the same rule the chat quote batch uses.
    package static func compose(title: String, key: String, version: Int, comments: [ArtifactComment]) -> String? {
        guard !comments.isEmpty else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : title
        return CommentBatchComposer.compose(
            header: "Comments on the artifact \"\(name)\" (key=\"\(key)\", version \(version)):",
            items: comments.map {
                CommentBatchComposer.Item(quote: $0.anchorQuote, heading: $0.anchorHeading, comment: $0.body)
            },
            closing: "Please reply with a new version of this artifact under the same key that addresses these comments."
        )
    }
}

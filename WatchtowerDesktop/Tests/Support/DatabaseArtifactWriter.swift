import Foundation
import GRDB
import WatchtowerChatText
import WatchtowerCore

/// `ChatArtifactWriting` for the tests: the engine's artifact writes (`chatengine/artifacts.go`) done on the test
/// database directly — a keep in a Live Slack conversation refused as the engine refuses it (`forbidden`). Records
/// every call.
@MainActor
package final class DatabaseArtifactWriter: ChatArtifactWriting {
    private let db: any DatabaseWriter
    package private(set) var calls: [String] = []

    package init(db: any DatabaseWriter) {
        self.db = db
    }

    package func keep(conversationID: Int64, key: String, version: Int) async throws {
        calls.append("keep \(key) v\(version)")
        do {
            try await db.write { try ChatArtifactQueries.keep($0, conversationID: conversationID, artifactKey: key, version: version) }
        } catch ChatArtifactKeepError.liveSlack {
            throw ChatArtifactWriteRefused(code: "forbidden", message: "the conversation used Live Slack")
        }
    }

    package func unkeep(conversationID: Int64, key: String) async throws {
        calls.append("unkeep \(key)")
        try await db.write { try ChatArtifactQueries.unkeep($0, conversationID: conversationID, artifactKey: key) }
    }

    package func edit(conversationID: Int64, key: String, version: Int, content: String) async throws {
        calls.append("edit \(key) v\(version)")
        try await db.write { db in
            guard let base = try ChatArtifactQueries.versions(db, conversationID: conversationID, key: key)
                .first(where: { $0.version == version }) else { return }
            var draft = base.asDraft
            draft.content = content
            _ = try ChatArtifactQueries.saveVersion(db, conversationID: conversationID, messageID: base.messageID,
                                                    draft: draft, edited: true)
        }
    }

    package func addComment(
        conversationID: Int64, key: String, version: Int, anchor: CommentAnchor, body: String
    ) async throws -> Int64 {
        calls.append("comment_add \(key) v\(version)")
        return try await db.write {
            try ArtifactCommentQueries.add($0, conversationID: conversationID, key: key, version: version,
                                           anchor: anchor, body: body)
        }
    }

    package func deleteComment(conversationID: Int64, id: Int64) async throws {
        calls.append("comment_delete \(id)")
        _ = try await db.write { try ArtifactCommentQueries.deleteUnsent($0, id: id) }
    }

    package func resolveComment(conversationID: Int64, id: Int64) async throws {
        calls.append("comment_resolve \(id)")
        _ = try await db.write { try ArtifactCommentQueries.resolve($0, id: id) }
    }

    package func reanchor(conversationID: Int64, key: String, version: Int, moved: [Int64], lost: [Int64]) async throws {
        calls.append("comment_reanchor \(key) v\(version)")
        try await db.write {
            try ArtifactCommentQueries.apply($0, plan: ArtifactCommentReanchor.Plan(moved: moved, lost: lost), version: version)
        }
    }
}

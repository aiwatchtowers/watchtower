import ChatWire
import Foundation

/// The artifact panel's writes (Knowledge keep/unkeep, an edit's new version, the comments), which the chat engine
/// makes (D3, D19: every write of the main chat goes through the engine; the panel reads its rows itself). The
/// artifact side only ever calls these; it never reaches a turn, a process or the network (CHAT-05).
@MainActor
package protocol ChatArtifactWriting: AnyObject {
    func keep(conversationID: Int64, key: String, version: Int) async throws
    func unkeep(conversationID: Int64, key: String) async throws
    /// The edited text of `version` as a new version.
    func edit(conversationID: Int64, key: String, version: Int, content: String) async throws
    /// A new comment on `version`; its id.
    func addComment(conversationID: Int64, key: String, version: Int, anchor: CommentAnchor, body: String) async throws
        -> Int64
    func deleteComment(conversationID: Int64, id: Int64) async throws
    func resolveComment(conversationID: Int64, id: Int64) async throws
    /// The panel's re-anchoring plan for `version`: comments found on it, and comments whose quote is gone.
    func reanchor(conversationID: Int64, key: String, version: Int, moved: [Int64], lost: [Int64]) async throws
}

/// An `artifact_manage` the engine refused.
package struct ChatArtifactWriteRefused: LocalizedError, Equatable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    package var errorDescription: String? { message.isEmpty ? "The chat refused the change (\(code))." : message }
    /// The conversation used Live Slack, so its artifacts are not kept (LIVE-01).
    package var isLiveSlack: Bool { code == "forbidden" }
}

/// `ChatArtifactWriting` over the engine: each write is one `artifact_manage` operation, nothing else (pinned by
/// `ChatArtifactWriterTests`).
@MainActor
package final class ChatArtifactWriter: ChatArtifactWriting {
    private let client: any ChatClient

    package init(client: any ChatClient) {
        self.client = client
    }

    package func keep(conversationID: Int64, key: String, version: Int) async throws {
        _ = try await apply(ChatArtifactRequest(op: .keep, conversationID: conversationID, key: key, version: version))
    }

    package func unkeep(conversationID: Int64, key: String) async throws {
        _ = try await apply(ChatArtifactRequest(op: .unkeep, conversationID: conversationID, key: key))
    }

    package func edit(conversationID: Int64, key: String, version: Int, content: String) async throws {
        _ = try await apply(ChatArtifactRequest(op: .edit, conversationID: conversationID, key: key, version: version,
                                                content: content))
    }

    package func addComment(
        conversationID: Int64, key: String, version: Int, anchor: CommentAnchor, body: String
    ) async throws -> Int64 {
        let comment = ChatArtifactComment(body: body, anchorQuote: anchor.quote, anchorPrefix: anchor.prefix,
                                          anchorSuffix: anchor.suffix, anchorHeading: anchor.heading)
        return try await apply(ChatArtifactRequest(op: .commentAdd, conversationID: conversationID, key: key,
                                                   version: version, comment: comment))
    }

    package func deleteComment(conversationID: Int64, id: Int64) async throws {
        _ = try await apply(ChatArtifactRequest(op: .commentDelete, conversationID: conversationID, commentID: id))
    }

    package func resolveComment(conversationID: Int64, id: Int64) async throws {
        _ = try await apply(ChatArtifactRequest(op: .commentResolve, conversationID: conversationID, commentID: id))
    }

    package func reanchor(conversationID: Int64, key: String, version: Int, moved: [Int64], lost: [Int64]) async throws {
        _ = try await apply(ChatArtifactRequest(op: .commentReanchor, conversationID: conversationID, key: key,
                                                version: version, moved: moved, lost: lost))
    }

    /// The written row's id (0 when the op writes none).
    private func apply(_ request: ChatArtifactRequest) async throws -> Int64 {
        switch try await client.send(.artifact(request)) {
        case .applied(.id(let id)): return id
        case .applied: return 0
        case let .refused(code, message): throw ChatArtifactWriteRefused(code: code, message: message)
        }
    }
}

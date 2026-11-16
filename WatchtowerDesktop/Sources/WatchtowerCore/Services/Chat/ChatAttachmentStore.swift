import Foundation
import GRDB
import WatchtowerInterface

/// Adds owner-chosen files to a chat or a project through `chat.attach`
/// (mobile Inbox spec §8): Go copies them into `<workspace>/chat_files/
/// <conversations|projects>/<id>/` (0700 dirs, 0600 files) and records them
/// in `chat_attachments`. Go reads the stored path from the `turn`
/// command's stdin (CHAT-04: never argv).
///
/// Every call is `async` and runs off the main actor (board #670): a file
/// is first checked here (the composer's own message for a refused kind),
/// then read and copied by the daemon from its path; a pasted file goes as
/// bytes.
package final class ChatAttachmentStore: Sendable {
    package let db: any DatabaseReader
    package let rootDir: URL
    private let writes: ChatWrites

    package init(db: any DatabaseReader, rootDir: URL, writes: ChatWrites) {
        self.db = db
        self.rootDir = rootDir
        self.writes = writes
    }

    /// `Constants.activeWorkspaceDir()/chat_files` — the Swift side of Go
    /// `Config.WorkspaceDir()/chat_files`. Nil without an active workspace.
    package static func defaultRootDir() -> URL? {
        Constants.activeWorkspaceDir().map {
            URL(fileURLWithPath: $0).appendingPathComponent("chat_files", isDirectory: true)
        }
    }

    package func directory(for owner: ChatAttachmentOwner) -> URL {
        rootDir.appendingPathComponent(owner.directoryName, isDirectory: true)
    }

    package func importFile(url: URL, conversationID: Int64) async throws -> ChatAttachment {
        try await importFile(url: url, owner: .conversation(conversationID))
    }

    package func importFile(url: URL, projectID: Int64) async throws -> ChatAttachment {
        try await importFile(url: url, owner: .project(projectID))
    }

    package func importFile(url: URL, owner: ChatAttachmentOwner) async throws -> ChatAttachment {
        _ = try AttachmentValidator.validate(url: url).get()
        let (name, path) = (url.lastPathComponent, url.path)
        return try await attach(owner: owner) { requestID, conversationID, projectID in
            ChatAttachRequest(requestID: requestID, conversationID: conversationID, projectID: projectID, name: name,
                              path: path)
        }
    }

    package func importData(_ data: Data, name: String, owner: ChatAttachmentOwner) async throws -> ChatAttachment {
        _ = try AttachmentValidator.validate(data: data, fileName: name).get()
        let encoded = data.base64EncodedString()
        return try await attach(owner: owner) { requestID, conversationID, projectID in
            ChatAttachRequest(requestID: requestID, conversationID: conversationID, projectID: projectID, name: name,
                              dataBase64: encoded)
        }
    }

    /// Removes a pending attachment's row, and its file once no row points
    /// at it (`chat.attach_delete`).
    package func discard(_ attachment: ChatAttachment) async throws {
        let id = attachment.id
        let _: ChatChanged = try await writes.perform(.chatAttachDelete) {
            ChatAttachmentRequest(requestID: $0, attachmentID: id)
        }
    }

    private func attach(
        owner: ChatAttachmentOwner,
        _ request: @escaping @Sendable (String, Int64?, Int64?) -> ChatAttachRequest
    ) async throws -> ChatAttachment {
        var conversationID: Int64?
        var projectID: Int64?
        switch owner {
        case .conversation(let id): conversationID = id
        case .project(let id): projectID = id
        }
        let (conversation, project) = (conversationID, projectID)
        let added: ChatAttachResponse = try await writes.perform(.chatAttach) { request($0, conversation, project) }
        let id = added.attachmentID
        guard let row = try await db.read({ db in
            try ChatAttachment.fetchOne(db, sql: "SELECT * FROM chat_attachments WHERE id = ?", arguments: [id])
        }) else { throw ChatWriteError(sentence: "The file was attached, but its row is gone.") }
        return row
    }
}

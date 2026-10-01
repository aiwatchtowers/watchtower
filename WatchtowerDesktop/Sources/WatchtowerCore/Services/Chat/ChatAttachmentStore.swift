import CryptoKit
import Foundation
import GRDB

/// Copies owner-chosen files into `<workspace>/chat_files/<conversations|projects>/<id>/`
/// (0700 dirs, 0600 files) and records them in `chat_attachments`. Go reads
/// the stored path from the `turn` command's stdin (CHAT-04: never argv).
package final class ChatAttachmentStore {
    package let db: any DatabaseWriter
    package let rootDir: URL

    package init(db: any DatabaseWriter, rootDir: URL) {
        self.db = db
        self.rootDir = rootDir
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

    package func importFile(url: URL, conversationID: Int64) throws -> ChatAttachment {
        try importFile(url: url, owner: .conversation(conversationID))
    }

    package func importFile(url: URL, projectID: Int64) throws -> ChatAttachment {
        try importFile(url: url, owner: .project(projectID))
    }

    package func importFile(url: URL, owner: ChatAttachmentOwner) throws -> ChatAttachment {
        let kind = try AttachmentValidator.validate(url: url).get()
        let data = try Data(contentsOf: url)
        return try store(data: data, name: url.lastPathComponent, kind: kind, owner: owner)
    }

    package func importData(_ data: Data, name: String, owner: ChatAttachmentOwner) throws -> ChatAttachment {
        let kind = try AttachmentValidator.validate(data: data, fileName: name).get()
        return try store(data: data, name: name, kind: kind, owner: owner)
    }

    /// Removes a pending attachment's row, and its file once no row points at it.
    package func discard(_ attachment: ChatAttachment) throws {
        let stillReferenced = try db.write { db -> Bool in
            try ChatAttachmentQueries.delete(db, id: attachment.id)
            return try ChatAttachmentQueries.referenceCount(db, path: attachment.path) > 0
        }
        if !stillReferenced {
            // Best effort: a missing file is already the desired end state.
            try? FileManager.default.removeItem(atPath: attachment.path)
        }
    }

    /// Post-commit cleanup after a conversation/project delete (rows are gone
    /// by FK cascade). Best effort; a missing directory is a no-op.
    package static func removeFiles(for owner: ChatAttachmentOwner, rootDir: URL) {
        try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(owner.directoryName, isDirectory: true))
    }

    private func store(data: Data, name: String, kind: AttachmentKind, owner: ChatAttachmentOwner) throws -> ChatAttachment {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let existing = try db.read { try ChatAttachmentQueries.existingPath($0, owner: owner, sha256: sha) }
        let reused = existing.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let path = try reused ?? writeFile(data: data, ext: kind.fileExtension(fallbackName: name), owner: owner)
        do {
            return try db.write { db in
                let row = try ChatAttachmentQueries.insert(db, owner: owner, name: name, mime: kind.mime,
                                                           size: Int64(data.count), path: path, sha256: sha)
                if case let .project(projectID) = owner {
                    try ChatProjectQueries.dropSessions(db, projectID: projectID)
                }
                return row
            }
        } catch {
            if reused == nil { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }
    }

    private func writeFile(data: Data, ext: String, owner: ChatAttachmentOwner) throws -> String {
        let dir = directory(for: owner)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
        guard FileManager.default.createFile(atPath: file.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file.path
    }
}

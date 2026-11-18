import ChatWire
import Foundation
import GRDB
import WatchtowerCore

/// A `ChatClient` for the tests that answers `project_manage` the way the engine does (`chatengine/projects.go`),
/// on the test database: a write that fails there (a trigger) is refused. Every other operation is applied with no
/// result. Records the project requests.
package final class DatabaseProjectClient: ChatClient, @unchecked Sendable {
    private let db: any DatabaseWriter
    private let lock = NSLock()
    private var recorded: [ChatProjectRequest] = []

    package init(db: any DatabaseWriter) {
        self.db = db
    }

    package var requests: [ChatProjectRequest] { lock.withLock { recorded } }

    package func send(_ op: ChatOperation) async throws -> ChatEcho {
        guard case .project(let request) = op else { return .applied(.none) }
        lock.withLock { recorded.append(request) }
        do {
            let id = try await db.write { try Self.apply(request, $0) }
            return .applied(.id(id))
        } catch {
            return .refused(code: "internal", message: error.localizedDescription)
        }
    }

    private static func apply(_ r: ChatProjectRequest, _ d: Database) throws -> Int64 {
        let id = r.projectID ?? 0
        switch r.op {
        case .create:
            return try ChatProjectQueries.create(d, name: r.name ?? "").id
        case .update:
            if let name = r.name { try ChatProjectQueries.rename(d, id: id, name: name) }
            if let text = r.instructions { try ChatProjectQueries.updateInstructions(d, id: id, instructions: text) }
        case .archive:
            try ChatProjectQueries.archive(d, id: id)
        case .delete:
            _ = try ChatProjectQueries.delete(d, id: id)
        case .sourceAdd:
            for s in r.sources ?? [] {
                guard let kind = WatchtowerCore.ChatProjectSource.Kind(rawValue: s.kind) else { continue }
                _ = try ChatProjectQueries.addSource(d, projectID: id, kind: kind, ref: s.ref, label: s.label)
            }
        case .sourceRemove:
            _ = try ChatProjectQueries.removeSource(d, id: r.sourceID ?? 0)
        case .fileAdd:
            let path = r.path ?? ""
            try d.execute(sql: """
                INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
                VALUES (?, ?, 'application/pdf', 1, ?, 'h', 1)
                """, arguments: [id, (path as NSString).lastPathComponent, path])
            return d.lastInsertedRowID
        case .fileRemove:
            _ = try ChatProjectQueries.removeFile(d, id: r.fileID ?? 0)
        }
        return 0
    }

    package func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> { AsyncStream { $0.finish() } }
    package func list() -> AsyncStream<ChatListUpdate> { AsyncStream { $0.finish() } }
    package var reachability: AsyncStream<ChatReachability> {
        AsyncStream { $0.yield(.connected) }
    }
}

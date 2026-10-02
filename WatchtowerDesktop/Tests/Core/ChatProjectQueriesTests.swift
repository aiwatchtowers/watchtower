import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatProjectQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    @discardableResult
    private func insertConversation(_ d: Database, title: String, projectID: Int64?) throws -> Int64 {
        try d.execute(
            sql: """
                INSERT INTO chat_conversations (title, created_at, updated_at, project_id)
                VALUES (?, 1, 1, ?)
                """,
            arguments: [title, projectID]
        )
        return d.lastInsertedRowID
    }

    @discardableResult
    private func insertProjectFile(_ d: Database, projectID: Int64, path: String) throws -> Int64 {
        try d.execute(
            sql: """
                INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
                VALUES (?, 'spec.pdf', 'application/pdf', 10, ?, 'abc', 1)
                """,
            arguments: [projectID, path]
        )
        return d.lastInsertedRowID
    }

    func testCreateTrimsNameAndFallsBackWhenEmpty() throws {
        try db.write { d in
            let named = try ChatProjectQueries.create(d, name: "  Payments  ")
            XCTAssertEqual(named.name, "Payments")
            XCTAssertEqual(named.instructions, "")
            XCTAssertNil(named.archivedAt)
            let unnamed = try ChatProjectQueries.create(d, name: "   ")
            XCTAssertEqual(unnamed.name, "New project")
        }
    }

    func testFetchActiveSkipsArchivedAndSortsByName() throws {
        try db.write { d in
            let beta = try ChatProjectQueries.create(d, name: "beta")
            _ = try ChatProjectQueries.create(d, name: "Alpha")
            let gone = try ChatProjectQueries.create(d, name: "Archived")
            try ChatProjectQueries.archive(d, id: gone.id)
            XCTAssertEqual(try ChatProjectQueries.fetchActive(d).map(\.name), ["Alpha", "beta"])
            XCTAssertNotNil(try ChatProjectQueries.fetchByID(d, id: beta.id))
        }
    }

    func testFetchActiveOnEmptyTableIsEmpty() throws {
        try db.read { d in
            XCTAssertTrue(try ChatProjectQueries.fetchActive(d).isEmpty)
            XCTAssertNil(try ChatProjectQueries.fetchByID(d, id: 1))
        }
    }

    func testRenameIgnoresBlankAndUpdateInstructionsPersists() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            try ChatProjectQueries.rename(d, id: p.id, name: "  ")
            XCTAssertEqual(try ChatProjectQueries.fetchByID(d, id: p.id)?.name, "P", "a blank rename is ignored")
            try ChatProjectQueries.rename(d, id: p.id, name: "Q3 launch")
            try ChatProjectQueries.updateInstructions(d, id: p.id, instructions: "Answer in Russian.")
            let reloaded = try XCTUnwrap(ChatProjectQueries.fetchByID(d, id: p.id))
            XCTAssertEqual(reloaded.name, "Q3 launch")
            XCTAssertEqual(reloaded.instructions, "Answer in Russian.")
        }
    }

    func testAddSourceDedupesAndRemoveSourceDeletes() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            XCTAssertTrue(try ChatProjectQueries.addSource(
                d, projectID: p.id, kind: .jiraProject, ref: "PAY", label: "PAY"))
            XCTAssertFalse(try ChatProjectQueries.addSource(
                d, projectID: p.id, kind: .jiraProject, ref: "PAY", label: "PAY again"),
                "same (kind, ref) twice is a no-op")
            XCTAssertTrue(try ChatProjectQueries.addSource(
                d, projectID: p.id, kind: .person, ref: "1:U1", label: "Anna"))
            let sources = try ChatProjectQueries.sources(d, projectID: p.id)
            XCTAssertEqual(sources.map(\.kind), ["jira_project", "person"])
            XCTAssertEqual(sources.first?.label, "PAY", "the duplicate did not overwrite the label")
            XCTAssertEqual(sources.first?.sourceKind, .jiraProject)
            XCTAssertTrue(try ChatProjectQueries.removeSource(d, id: sources[0].id))
            XCTAssertEqual(try ChatProjectQueries.sources(d, projectID: p.id).map(\.ref), ["1:U1"])
            XCTAssertFalse(try ChatProjectQueries.removeSource(d, id: sources[0].id), "already gone: nothing changed")
        }
    }

    /// Migration 00096: a chat project pins a Confluence space.
    func testAddSourceStoresAConfluenceSpace() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            XCTAssertTrue(try ChatProjectQueries.addSource(
                d, projectID: p.id, kind: .confluenceSpace, ref: "ENG", label: "Engineering"))
            let sources = try ChatProjectQueries.sources(d, projectID: p.id)
            XCTAssertEqual(sources.map(\.kind), ["confluence_space"])
            XCTAssertEqual(sources.first?.sourceKind, .confluenceSpace)
        }
    }

    func testFilesAndRemoveFileReturnsPath() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            let fileID = try insertProjectFile(d, projectID: p.id, path: "/tmp/a.pdf")
            XCTAssertEqual(try ChatProjectQueries.files(d, projectID: p.id).map(\.path), ["/tmp/a.pdf"])
            let removed = try ChatProjectQueries.removeFile(d, id: fileID)
            XCTAssertTrue(removed.removed)
            XCTAssertEqual(removed.orphanPath, "/tmp/a.pdf")
            XCTAssertTrue(try ChatProjectQueries.files(d, projectID: p.id).isEmpty)
            let again = try ChatProjectQueries.removeFile(d, id: fileID)
            XCTAssertFalse(again.removed, "second remove finds nothing")
            XCTAssertNil(again.orphanPath)
        }
    }

    /// The store reuses one disk file for the same content imported twice: the
    /// disk file may go only with its last row.
    func testRemoveFileKeepsADiskFileAnotherRowStillUses() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            let first = try insertProjectFile(d, projectID: p.id, path: "/tmp/shared.pdf")
            let second = try insertProjectFile(d, projectID: p.id, path: "/tmp/shared.pdf")
            let kept = try ChatProjectQueries.removeFile(d, id: first)
            XCTAssertTrue(kept.removed)
            XCTAssertNil(kept.orphanPath, "the other row still uses the file")
            XCTAssertEqual(try ChatProjectQueries.removeFile(d, id: second).orphanPath, "/tmp/shared.pdf")
        }
    }

    func testRemoveFileNeverTouchesAConversationAttachment() throws {
        try db.write { d in
            let chat = try insertConversation(d, title: "c", projectID: nil)
            try d.execute(
                sql: """
                    INSERT INTO chat_attachments (conversation_id, name, mime, size, path, sha256, created_at)
                    VALUES (?, 'x.png', 'image/png', 1, '/tmp/x.png', 'h', 1)
                    """,
                arguments: [chat]
            )
            let id = d.lastInsertedRowID
            XCTAssertFalse(try ChatProjectQueries.removeFile(d, id: id).removed)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chat_attachments"), 1)
        }
    }

    func testConversationsListsOnlyThisProjectsUnarchivedChats() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            try insertConversation(d, title: "in", projectID: p.id)
            try insertConversation(d, title: "outside", projectID: nil)
            let archived = try insertConversation(d, title: "old", projectID: p.id)
            try d.execute(sql: "UPDATE chat_conversations SET archived_at = 5 WHERE id = ?", arguments: [archived])
            XCTAssertEqual(try ChatProjectQueries.conversations(d, projectID: p.id).map(\.title), ["in"])
        }
    }

    /// Spec §6.1: deleting a project keeps its chats (ON DELETE SET NULL) and
    /// deletes its files — the rows by cascade, the disk files by the caller
    /// from the returned paths, post-commit.
    func testDeleteKeepsChatsAndReturnsFilePaths() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            let chat = try insertConversation(d, title: "keep me", projectID: p.id)
            try insertProjectFile(d, projectID: p.id, path: "/tmp/a.pdf")
            try ChatProjectQueries.addSource(d, projectID: p.id, kind: .track, ref: "7", label: "T")

            XCTAssertEqual(try ChatProjectQueries.delete(d, id: p.id), ["/tmp/a.pdf"])

            XCTAssertNil(try ChatProjectQueries.fetchByID(d, id: p.id))
            let projectOfChat = try Int64?.fetchOne(
                d, sql: "SELECT project_id FROM chat_conversations WHERE id = ?", arguments: [chat])
            XCTAssertEqual(projectOfChat, .some(nil), "the chat survives, detached")
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chat_attachments"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chat_project_sources"), 0)
        }
    }

    // MARK: - Stored sessions (a `--resume` keeps the prompt it was started with)

    /// A conversation in `projectID` and one outside it, both with a stored
    /// Claude session.
    private func chatsWithSessions(_ d: Database, projectID: Int64) throws -> (inside: Int64, outside: Int64) {
        let inside = try insertConversation(d, title: "in", projectID: projectID)
        let outside = try insertConversation(d, title: "out", projectID: nil)
        try d.execute(sql: "UPDATE chat_conversations SET session_id = 'sess-' || id")
        return (inside, outside)
    }

    private func sessionID(_ d: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(d, sql: "SELECT session_id FROM chat_conversations WHERE id = ?", arguments: [id])
    }

    /// Every write that changes the project's prompt or files drops the
    /// stored session of the project's chats — and only theirs.
    func testPromptChangingWritesDropTheProjectsStoredSessions() throws {
        let writes: [(String, (Database, Int64) throws -> Void)] = [
            ("instructions", { d, pid in try ChatProjectQueries.updateInstructions(d, id: pid, instructions: "new") }),
            ("add source", { d, pid in
                try ChatProjectQueries.addSource(d, projectID: pid, kind: .jiraProject, ref: "PAY", label: "Payments")
            }),
            ("remove source", { d, pid in
                try ChatProjectQueries.addSource(d, projectID: pid, kind: .jiraProject, ref: "OPS", label: "Ops")
                try d.execute(sql: "UPDATE chat_conversations SET session_id = 'sess-' || id")
                let sourceID = try XCTUnwrap(ChatProjectQueries.sources(d, projectID: pid).first?.id)
                try ChatProjectQueries.removeSource(d, id: sourceID)
            }),
            ("remove file", { d, pid in
                let fileID = try self.insertProjectFile(d, projectID: pid, path: "/tmp/x.pdf")
                _ = try ChatProjectQueries.removeFile(d, id: fileID)
            })
        ]
        for (name, write) in writes {
            try db.write { d in
                let project = try ChatProjectQueries.create(d, name: name)
                let chats = try chatsWithSessions(d, projectID: project.id)
                try write(d, project.id)
                XCTAssertNil(try sessionID(d, chats.inside), name)
                XCTAssertEqual(try sessionID(d, chats.outside), "sess-\(chats.outside)", name)
            }
        }
    }

    func testDuplicateSourceAndRenameKeepTheStoredSessions() throws {
        try db.write { d in
            let project = try ChatProjectQueries.create(d, name: "P")
            try ChatProjectQueries.addSource(d, projectID: project.id, kind: .jiraProject, ref: "PAY", label: "Payments")
            let chats = try chatsWithSessions(d, projectID: project.id)
            XCTAssertFalse(try ChatProjectQueries.addSource(d, projectID: project.id, kind: .jiraProject,
                                                            ref: "PAY", label: "Payments"))
            try ChatProjectQueries.rename(d, id: project.id, name: "Q")
            XCTAssertEqual(try sessionID(d, chats.inside), "sess-\(chats.inside)")
        }
    }

    /// The chats survive the delete detached, and none of them may resume a
    /// session that still carries the deleted project's prompt.
    func testDeleteDropsTheDetachedChatsStoredSessions() throws {
        try db.write { d in
            let project = try ChatProjectQueries.create(d, name: "P")
            let chats = try chatsWithSessions(d, projectID: project.id)
            _ = try ChatProjectQueries.delete(d, id: project.id)
            XCTAssertNil(try sessionID(d, chats.inside))
            XCTAssertEqual(try sessionID(d, chats.outside), "sess-\(chats.outside)")
        }
    }
}

import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Owner edits addressed to a row deleted elsewhere (the daemon, the CLI, the
/// agent, a second window) touch no row. Each checked writer must throw a
/// not-found error naming the row instead of reporting a success that never
/// happened, and must still succeed — twice — on a row that exists.
final class RowNotFoundWritersTests: XCTestCase {

    private struct Writer {
        let name: String
        let kind: String
        let table: String
        let run: (Database, Int64) throws -> Void
        let make: (Database) throws -> Int64
    }

    private static func note(_ db: Database) throws -> Int64 {
        try XCTUnwrap(MeetingNoteQueries.create(db, eventID: "evt", type: .note, text: "n", sortOrder: 0).id)
    }

    private let writers: [Writer] = [
        Writer(name: "meetingNote.update", kind: "meeting note", table: "meeting_notes", run: {
            try MeetingNoteQueries.update($0, id: $1, text: "edited")
        }, make: note),
        Writer(name: "meetingNote.toggleChecked", kind: "meeting note", table: "meeting_notes", run: {
            try MeetingNoteQueries.toggleChecked($0, id: $1)
        }, make: note),
        Writer(name: "meetingNote.setTaskID", kind: "meeting note", table: "meeting_notes", run: {
            try MeetingNoteQueries.setTaskID($0, noteID: $1, taskID: 7)
        }, make: note),
        Writer(name: "chat.rename", kind: "chat", table: "chat_conversations", run: {
            try ChatConversationQueries.rename($0, id: $1, title: "renamed")
        }, make: { try TestDatabase.insertChatConversation($0) }),
        Writer(name: "chat.pin", kind: "chat", table: "chat_conversations", run: {
            try ChatConversationQueries.pin($0, id: $1, pinned: true)
        }, make: { try TestDatabase.insertChatConversation($0) }),
        Writer(name: "chat.archive", kind: "chat", table: "chat_conversations", run: {
            try ChatConversationQueries.archive($0, id: $1)
        }, make: { try TestDatabase.insertChatConversation($0) }),
        Writer(name: "project.rename", kind: "chat project", table: "chat_projects", run: {
            try ChatProjectQueries.rename($0, id: $1, name: "renamed")
        }, make: { try ChatProjectQueries.create($0, name: "p").id }),
        Writer(name: "project.updateInstructions", kind: "chat project", table: "chat_projects", run: {
            try ChatProjectQueries.updateInstructions($0, id: $1, instructions: "be brief")
        }, make: { try ChatProjectQueries.create($0, name: "p").id }),
        Writer(name: "project.archive", kind: "chat project", table: "chat_projects", run: {
            try ChatProjectQueries.archive($0, id: $1)
        }, make: { try ChatProjectQueries.create($0, name: "p").id })
    ]

    func testEveryWriter_ThrowsNotFound_ForARowDeletedAfterLoad() throws {
        for writer in writers {
            let queue = try TestDatabase.create()
            let id = try queue.write { db -> Int64 in
                let id = try writer.make(db)
                try db.execute(sql: "DELETE FROM \(writer.table) WHERE id = ?", arguments: [id])
                return id
            }
            XCTAssertThrowsError(try queue.write { try writer.run($0, id) }, writer.name) { error in
                XCTAssertEqual(error as? RowNotFoundError, RowNotFoundError(kind: writer.kind, id: id), writer.name)
            }
        }
    }

    func testEveryWriter_Succeeds_OnAnExistingRow_EvenWhenNothingChanges() throws {
        for writer in writers {
            let queue = try TestDatabase.create()
            let id = try queue.write { try writer.make($0) }
            // The repeat writes the same values: SQLite still counts the matched
            // row, so an unchanged value never reads as "gone".
            XCTAssertNoThrow(try queue.write { try writer.run($0, id) }, writer.name)
            XCTAssertNoThrow(try queue.write { try writer.run($0, id) }, "\(writer.name) (repeat)")
        }
    }

    func testCalendarSelection_OnACalendarTheSyncDropped_ThrowsNotFound() throws {
        let queue = try TestDatabase.create()
        try queue.write { try $0.execute(sql: "INSERT INTO calendar_calendars (id, name) VALUES ('team', 'Team')") }

        XCTAssertNoThrow(try queue.write { try CalendarQueries.setCalendarSelected($0, id: "team", selected: false) })
        XCTAssertThrowsError(try queue.write { try CalendarQueries.setCalendarSelected($0, id: "gone", selected: false) }) {
            XCTAssertEqual($0 as? RowNotFoundError, RowNotFoundError(kind: "calendar", id: "gone"))
        }
    }

    func testTerminalSessionWriters_OnADeletedSession_ThrowNotFound() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int64 in
            let row = try TerminalSessionQueries.create(
                db, .init(projectID: nil, kind: .claude, title: "s", folderPath: "/tmp/acme", claudeSessionID: "u1")
            )
            try TerminalSessionQueries.delete(db, id: row.id)
            return row.id
        }

        let writers: [(String, (Database) throws -> Void)] = [
            ("rename", { try TerminalSessionQueries.rename($0, id: id, title: "new") }),
            ("replaceClaudeSessionID", { try TerminalSessionQueries.replaceClaudeSessionID($0, id: id, uuid: "u2") }),
            ("resetAgentSession", { try TerminalSessionQueries.resetAgentSession($0, id: id) })
        ]
        for (name, run) in writers {
            XCTAssertThrowsError(try queue.write(run), name) {
                XCTAssertEqual($0 as? TerminalSessionQueryError, .notFound(id), name)
            }
        }
        // Best-effort by design: a gone session is not active.
        XCTAssertNoThrow(try queue.write { try TerminalSessionQueries.touch($0, id: id) })
    }

    func testNotFoundError_NamesTheRow() {
        XCTAssertEqual(
            RowNotFoundError(kind: "track", id: 42).localizedDescription,
            "track #42 no longer exists (it may have been deleted elsewhere)"
        )
    }
}

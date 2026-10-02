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

    private static func track(_ db: Database) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority, origin, instruction)
            VALUES ('U1', 'watch', '', 'task', 'watching', 'medium', 'custom', 'watch for x')
            """)
        return db.lastInsertedRowID
    }

    private static func note(_ db: Database) throws -> Int64 {
        try XCTUnwrap(MeetingNoteQueries.create(db, eventID: "evt", type: .note, text: "n", sortOrder: 0).id)
    }

    private static func trackEvent(_ db: Database) throws -> Int64 {
        let trackID = try track(db)
        try db.execute(sql: "INSERT INTO track_events (track_id, summary) VALUES (?, 'e')", arguments: [trackID])
        return db.lastInsertedRowID
    }

    private static func reminder(_ db: Database) throws -> Int64 {
        try db.execute(sql: "INSERT INTO reminders (remind_at) VALUES ('2026-10-01T09:00:00Z')")
        return db.lastInsertedRowID
    }

    private let writers: [Writer] = [
        Writer(name: "track.updatePriority", kind: "track", table: "tracks", run: {
            try TrackQueries.updatePriority($0, id: Int($1), priority: "high")
        }, make: track),
        Writer(name: "track.updateOwnership", kind: "track", table: "tracks", run: {
            try TrackQueries.updateOwnership($0, id: Int($1), ownership: "mine")
        }, make: track),
        Writer(name: "track.updateSubItems", kind: "track", table: "tracks", run: {
            try TrackQueries.updateSubItems($0, id: Int($1), subItems: [])
        }, make: track),
        Writer(name: "track.dismiss", kind: "track", table: "tracks", run: {
            try TrackQueries.dismiss($0, id: Int($1))
        }, make: track),
        Writer(name: "track.restore", kind: "track", table: "tracks", run: {
            try TrackQueries.restore($0, id: Int($1))
        }, make: track),
        Writer(name: "track.setEnabled", kind: "track", table: "tracks", run: {
            try TrackQueries.setEnabled($0, id: Int($1), enabled: false)
        }, make: track),
        Writer(name: "track.updateInstruction", kind: "track", table: "tracks", run: {
            try TrackQueries.updateInstruction($0, id: Int($1), instruction: "watch for y")
        }, make: track),
        Writer(name: "meetingNote.update", kind: "meeting note", table: "meeting_notes", run: {
            try MeetingNoteQueries.update($0, id: $1, text: "edited")
        }, make: note),
        Writer(name: "meetingNote.toggleChecked", kind: "meeting note", table: "meeting_notes", run: {
            try MeetingNoteQueries.toggleChecked($0, id: $1)
        }, make: note),
        Writer(name: "meetingNote.setTaskID", kind: "meeting note", table: "meeting_notes", run: {
            try MeetingNoteQueries.setTaskID($0, noteID: $1, taskID: 7)
        }, make: note),
        Writer(name: "trackEvent.setActionStatus", kind: "track event", table: "track_events", run: {
            try TrackEventQueries.setActionStatus($0, id: Int($1), status: "dismissed")
        }, make: trackEvent),
        Writer(name: "idea.setStatus", kind: "idea", table: "ideas", run: {
            try IdeaQueries.setStatus($0, id: Int($1), status: "active")
        }, make: { try TestDatabase.insertIdea($0) }),
        Writer(name: "idea.snooze", kind: "idea", table: "ideas", run: {
            try IdeaQueries.snooze($0, id: Int($1), until: nil)
        }, make: { try TestDatabase.insertIdea($0) }),
        Writer(name: "idea.supersede", kind: "idea", table: "ideas", run: {
            try IdeaQueries.supersede($0, id: Int($1), by: nil)
        }, make: { try TestDatabase.insertIdea($0) }),
        Writer(name: "idea.setRating", kind: "idea", table: "ideas", run: {
            try IdeaQueries.setRating($0, id: Int($1), rating: 1, comment: "")
        }, make: { try TestDatabase.insertIdea($0) }),
        Writer(name: "idea.markConverted", kind: "idea", table: "ideas", run: {
            let target = try TargetQueries.create($0, text: "t", periodStart: "2026-10-01", periodEnd: "2026-10-01")
            try IdeaQueries.markConverted($0, id: Int($1), targetID: Int64(target))
        }, make: { try TestDatabase.insertIdea($0) }),
        Writer(name: "reminder.snooze", kind: "reminder", table: "reminders", run: {
            try ReminderQueries.snooze($0, id: $1, until: "2026-10-02T09:00:00Z")
        }, make: reminder),
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

    func testTrackPriority_OnADeletedTrack_LeavesNoFeedbackRow() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int64 in
            let id = try Self.track(db)
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [id])
            return id
        }
        XCTAssertThrowsError(try queue.write { try TrackQueries.updatePriority($0, id: Int(id), priority: "high") })
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feedback") }, 0)
    }

    func testIdeaMerge_IntoADeletedIdea_NamesIt_AndMovesNoMention() throws {
        let queue = try TestDatabase.create()
        let (source, gone) = try queue.write { db -> (Int64, Int64) in
            let source = try TestDatabase.insertIdea(db)
            try TestDatabase.insertIdeaMention(db, ideaID: source)
            let gone = try TestDatabase.insertIdea(db)
            try db.execute(sql: "DELETE FROM ideas WHERE id = ?", arguments: [gone])
            return (source, gone)
        }

        XCTAssertThrowsError(try queue.write { try IdeaQueries.merge($0, id: Int(source), into: Int(gone)) }) {
            XCTAssertEqual($0 as? RowNotFoundError, RowNotFoundError(kind: "idea", id: gone))
        }
        let mentions = try queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM idea_mentions WHERE idea_id = ?", arguments: [source])
        }
        XCTAssertEqual(mentions, 1, "the mention stays on its idea")
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
            ("replaceClaudeSessionID", { try TerminalSessionQueries.replaceClaudeSessionID($0, id: id, uuid: "u2") })
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

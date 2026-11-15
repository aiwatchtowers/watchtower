import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The render-time check of row refs (spec "What 'open' means for a `ref`"),
/// on hand-written samples: shown / waits per kind, a deleted record, the
/// snooze and due instants.
final class InboxRefStateTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private let now = "2026-10-16T12:00:00Z"
    private let utc = TimeZone(secondsFromGMT: 0) ?? .current

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func state(_ refs: [InboxRef]) throws -> InboxRefState {
        try pool.read { try InboxRefState.read($0, refs: refs, nowUTC: self.now, timeZone: self.utc) }
    }

    private func ref(_ kind: InboxRef.Kind, _ id: Int64) -> InboxRef { InboxRef(kind: kind, id: id) }

    func testInboxItemOpenWhileItMatchesTheOpenMessageClause() throws {
        let ids = try pool.write { db -> [Int64] in
            [
                try TestDatabase.insertInboxItem(db, messageTS: "1"),
                try TestDatabase.insertInboxItem(db, messageTS: "2", status: "resolved"),
                try TestDatabase.insertInboxItem(db, messageTS: "3", snoozeUntil: "2026-10-16T12:00:00Z"),
                try TestDatabase.insertInboxItem(db, messageTS: "4", snoozeUntil: "2026-10-16T12:00:01Z"),
                try TestDatabase.insertInboxItem(db, messageTS: "5", archivedAt: "2026-10-15T00:00:00Z")
            ]
        }
        let refs = ids.map { ref(.inboxItem, $0) } + [ref(.inboxItem, 999)]

        let s = try state(refs)

        XCTAssertEqual(refs.map(s.isShown), [true, false, true, false, false, false],
                       "open; resolved; snoozed until exactly now = back; still snoozed; archived; deleted")
        XCTAssertEqual(refs.map(s.waits), refs.map(s.isShown))
    }

    func testTrackOpenWhileUnreadAndNotStopped() throws {
        let ids = try pool.write { db -> [Int64] in
            let open = try TestDatabase.insertTrack(db)
            let read = try TestDatabase.insertTrack(db)
            let stopped = try TestDatabase.insertTrack(db)
            try db.execute(sql: "UPDATE tracks SET read_at = NULL")
            try db.execute(sql: "UPDATE tracks SET read_at = ? WHERE id = ?", arguments: [now, read])
            try db.execute(sql: "UPDATE tracks SET dismissed_at = ? WHERE id = ?", arguments: [now, stopped])
            return [open, read, stopped]
        }
        let refs = ids.map { ref(.track, $0) }

        let s = try state(refs)

        XCTAssertEqual(refs.map(s.isShown), [true, false, false])
        XCTAssertEqual(refs.map(s.waits), [true, false, false])
    }

    func testReminderDueAtRemindAtEqualToNow() throws {
        let ids = try pool.write { db -> [Int64] in
            var out: [Int64] = []
            for (at, status) in [(now, "pending"), ("2026-10-16T12:00:01Z", "pending"), ("2026-10-01T00:00:00Z", "done")] {
                try db.execute(sql: """
                    INSERT INTO reminders (message_ref, note, remind_at, status) VALUES ('C1@1', 'n', ?, ?)
                    """, arguments: [at, status])
                out.append(db.lastInsertedRowID)
            }
            return out
        }
        let refs = ids.map { ref(.reminder, $0) }

        let s = try state(refs)

        XCTAssertEqual(refs.map(s.isShown), [true, false, false], "due at the instant; not yet due; done")
        XCTAssertEqual(refs.map(s.waits), [true, false, false])
    }

    func testActionUsesTheAwaitingOwnerPredicate() throws {
        let ids = try pool.write { db -> [Int64] in
            [
                try TestDatabase.insertAgentAction(db, turnID: "p", status: "pending"),
                try TestDatabase.insertAgentAction(db, turnID: "f", status: "failed"),
                try TestDatabase.insertAgentAction(db, turnID: "a", status: "applied"),
                try TestDatabase.insertAgentAction(db, tool: "apply_track_action", surface: "inbox", turnID: "i",
                                                   status: "pending"),
                try TestDatabase.insertAgentAction(db, surface: "inbox", turnID: "t", status: "pending")
            ]
        }
        let refs = ids.map { ref(.action, $0) }

        let s = try state(refs)

        XCTAssertEqual(refs.map(s.isShown), [true, true, false, false, true],
                       "pending; failed with Retry; applied; the inbox one-press row is not the owner's decision;"
                           + " an inbox target-button row is")
        XCTAssertEqual(refs.map(s.waits), refs.map(s.isShown))
        let count = try pool.read { try AgentActionQueries.awaitingOwnerCount($0) }
        XCTAssertEqual(count, s.waiting.count, "the same predicate as the badge's term")
    }

    func testIdeaShownUnlessMergedSupersededOrSnoozedAndWaitsOnVerdict() throws {
        let ids = try pool.write { db -> [Int64] in
            [
                try TestDatabase.insertIdea(db, status: "proposed"),
                try TestDatabase.insertIdea(db, status: "active"),
                try TestDatabase.insertIdea(db, status: "merged"),
                try TestDatabase.insertIdea(db, status: "superseded"),
                try TestDatabase.insertIdea(db, status: "not_now", snoozeUntil: "2026-10-17"),
                try TestDatabase.insertIdea(db, status: "not_now", snoozeUntil: "2026-10-16"),
                try TestDatabase.insertIdea(db, kind: "decision", status: "proposed"),
                try TestDatabase.insertIdea(db, status: "proposed", snoozeUntil: "2026-10-16T12:00:00Z"),
                try TestDatabase.insertIdea(db, status: "proposed", snoozeUntil: "2026-10-16T13:00:00Z")
            ]
        }
        let refs = ids.map { ref(.idea, $0) } + [ref(.idea, 9999)]

        let s = try state(refs)

        XCTAssertEqual(refs.map(s.isShown), [true, true, false, false, false, true, true, true, false, false],
                       "merged, superseded, snoozed to a later day or instant, and deleted are not shown")
        XCTAssertEqual(refs.map(s.waits), [true, false, false, false, false, false, false, true, false, false],
                       "only a shown idea awaiting a verdict waits; a decision never does")
    }

    func testMissingTableShowsNothingOfThatKind() throws {
        let item = try pool.write { db -> Int64 in
            let id = try TestDatabase.insertInboxItem(db)
            try db.execute(sql: "DROP TABLE reminders")
            return id
        }

        let s = try state([ref(.reminder, 1), ref(.inboxItem, item)])

        XCTAssertFalse(s.isShown(ref(.reminder, 1)))
        XCTAssertTrue(s.isShown(ref(.inboxItem, item)))
    }

    func testEmptyRefsReadNothing() throws {
        XCTAssertEqual(try state([]), InboxRefState())
    }

    // MARK: - Text-id refs

    func testMailSenderShownWhileOpenAndUnmutedNeverWaits() throws {
        try pool.write { db in
            try TestDatabase.insertInboxItem(db, messageTS: "1", senderUserID: " Open@Example.com", triggerType: "email_received")
            try TestDatabase.insertInboxItem(db, messageTS: "2", senderUserID: "done@example.com",
                                             triggerType: "email_received", status: "resolved")
            try TestDatabase.insertInboxItem(db, messageTS: "3", senderUserID: "muted@example.com", triggerType: "email_received")
            try TestDatabase.insertInboxItem(db, messageTS: "4", senderUserID: "person@example.com", triggerType: "dm")
            try TestDatabase.insertLearnedRule(db, scopeKey: InboxPeopleRule.muteScope("Muted@Example.com"), source: "user_rule")
        }
        let refs = ["open@example.com", "done@example.com", "muted@example.com", "person@example.com", "gone@example.com"]
            .map { InboxRef(kind: .mailSender, key: $0) }

        let s = try state(refs)

        XCTAssertEqual(refs.map(s.isShown), [true, false, false, false, false],
                       "open mail; only resolved mail; muted; people, not mail; no mail at all")
        XCTAssertEqual(s.waiting, [], "a sender row never counts")
    }

    func testWaitingOlderShownOnlyWithOlderPeople() throws {
        let older = InboxRef(kind: .waitingOlder, key: "older")
        let id = try pool.write { db -> Int64 in
            try TestDatabase.insertInboxItem(db, messageTS: "1", senderUserID: "a@example.com", triggerType: "email_received")
            let person = try TestDatabase.insertInboxItem(db, messageTS: "2", triggerType: "mention")
            // Old mail never makes the people's Older row.
            try db.execute(sql: "UPDATE inbox_items SET created_at = '2026-10-01T00:00:00Z', mentioned_at = ''")
            try db.execute(sql: "UPDATE inbox_items SET created_at = '2026-10-09T12:00:01Z' WHERE id = ?", arguments: [person])
            return person
        }
        XCTAssertFalse(try state([older]).isShown(older), "one second younger than 7 x 24 h is This week")

        try pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET created_at = '2026-10-09T12:00:00Z' WHERE id = ?", arguments: [id])
        }
        let s = try state([older])
        XCTAssertTrue(s.isShown(older), "exactly 7 x 24 h old is Older")
        XCTAssertFalse(s.waits(older), "the Older row never counts")
    }

    // MARK: - Refs of a stored document

    func testRefsInDocumentOrder() {
        let tail = #"]},{"type":"text","text":"x"},{"type":"list","rows":[{"title":"t"},"#
            + #"{"title":"u","ref":{"kind":"idea","id":2}}]}]}"#
        let json = InboxFolderFixtures.listDocument([("action", 3), ("inbox_item", 1)])
            .replacingOccurrences(of: #"]}]}"#, with: tail)
        XCTAssertEqual(InboxRef.refs(blocksJSON: json),
                       [ref(.action, 3), ref(.inboxItem, 1), ref(.idea, 2)])
    }

    func testRefsOfAnUnreadableDocumentAreNone() {
        XCTAssertEqual(InboxRef.refs(blocksJSON: ""), [])
        XCTAssertEqual(InboxRef.refs(blocksJSON: "not json"), [])
        XCTAssertEqual(InboxRef.refs(blocksJSON: #"{"v":2,"blocks":[]}"#), [], "another version")
        XCTAssertEqual(InboxRef.refs(blocksJSON: #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"user","id":1}}]}]}"#), [],
                       "an unknown kind: the Kit reads the whole document as unreadable")
        XCTAssertEqual(InboxRef.refs(blocksJSON: #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":0}}]}]}"#), [],
                       "an id of 0")
        XCTAssertEqual(InboxRef.refs(blocksJSON: #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":true}}]}]}"#), [],
                       "a bool is not an id")
    }

    func testTextIDRefsCarryTheirKey() {
        let json = #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"mail_sender","id":"a@example.com"}},"#
            + #"{"title":"b","ref":{"kind":"waiting_older","id":"older"}},{"title":"c","ref":{"kind":"track","id":4}}]}]}"#
        XCTAssertEqual(InboxRef.refs(blocksJSON: json), [
            InboxRef(kind: .mailSender, key: "a@example.com"), InboxRef(kind: .waitingOlder, key: "older"), ref(.track, 4)
        ])
        let row = { (ref: String) in #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":"# + ref + "}]}]}" }
        XCTAssertEqual(InboxRef.refs(blocksJSON: row(#"{"kind":"mail_sender","id":3}"#)), [], "a text kind with a number id")
        XCTAssertEqual(InboxRef.refs(blocksJSON: row(#"{"kind":"mail_sender","id":""}"#)), [], "an empty text id")
        XCTAssertEqual(InboxRef.refs(blocksJSON: row(#"{"kind":"track","id":"4"}"#)), [], "an integer kind with a string id")
    }
}

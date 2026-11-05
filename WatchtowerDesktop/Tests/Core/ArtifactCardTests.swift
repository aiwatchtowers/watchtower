import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Inbox builder A in the Core (spec "Living upsert and read state", "The
/// Desktop's read-state writers", "Notifications"): the drawn content hash
/// guards every read-state write, a same-hash rewrite is never news, and
/// the Inbox and Home order cards by `changed_at`.
final class ArtifactCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z
    private let blocks = #"{"v":1,"blocks":[{"type":"heading","text":"Threads","level":1}]}"#

    private struct Seeded {
        let automationID: Int64
        let feed: Int64
        let living: Int64
    }

    /// A feed card at 10:00 and a living card at 09:00 (read), both at `h1`.
    private func seed(_ db: Database) throws -> Seeded {
        let automationID = try TestDatabase.insertAutomation(db, slug: "threads", name: "Threads waiting for me")
        let run = try TestDatabase.insertAutomationRun(db, automationID: automationID)
        let living = try TestDatabase.insertAutomationOutput(
            db, automationID: automationID, runID: run, title: "Threads", body: "Threads",
            createdAt: "2026-10-16T09:00:00Z", readAt: "2026-10-16T09:30:00Z",
            blocksJSON: blocks, outputKey: "threads", contentHash: "h1")
        let feed = try TestDatabase.insertAutomationOutput(
            db, automationID: automationID, runID: run, title: "Daily", createdAt: "2026-10-16T10:00:00Z",
            contentHash: "f1")
        return Seeded(automationID: automationID, feed: feed, living: living)
    }

    private func rewrite(_ db: Database, _ seeded: Seeded, hash: String, at stamp: String) throws {
        let run = try TestDatabase.insertAutomationRun(db, automationID: seeded.automationID)
        try TestDatabase.rewriteLivingOutput(db, id: seeded.living, runID: run, body: "Threads",
                                             blocksJSON: blocks, contentHash: hash, at: stamp)
    }

    // MARK: - Guarded writers

    func testWritersMarkTheDrawnVersionOnce() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let automationID = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            let ids = try (0..<3).map { _ in
                try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: run, contentHash: "h1")
            }
            XCTAssertTrue(try AutomationQueries.markOutputOpened(db, id: ids[0], contentHash: "h1", now: now))
            XCTAssertFalse(try AutomationQueries.markOutputOpened(db, id: ids[0], contentHash: "h1", now: now),
                           "already read")
            XCTAssertTrue(try AutomationQueries.markOutputDone(db, id: ids[1], contentHash: "h1", now: now))
            XCTAssertFalse(try AutomationQueries.markOutputDone(db, id: ids[1], contentHash: "h1", now: now))
            XCTAssertTrue(try AutomationQueries.dismissOutput(db, id: ids[2], contentHash: "h1", now: now))
            XCTAssertFalse(try AutomationQueries.dismissOutput(db, id: ids[2], contentHash: "h1", now: now))
        }
    }

    /// A row rewritten under the view (its hash moved) takes no stamp from
    /// any writer, and keeps every column.
    func testStaleHashChangesNothing() throws {
        let queue = try TestDatabase.create()
        let seeded = try queue.write { db -> Seeded in
            let seeded = try seed(db)
            try rewrite(db, seeded, hash: "h2", at: "2026-10-16T11:00:00Z")
            return seeded
        }
        let before = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM automation_outputs WHERE id = ?", arguments: [seeded.living])
        }
        try queue.write { db in
            XCTAssertFalse(try AutomationQueries.markOutputOpened(db, id: seeded.living, contentHash: "h1", now: now))
            XCTAssertFalse(try AutomationQueries.markOutputDone(db, id: seeded.living, contentHash: "h1", now: now))
            XCTAssertFalse(try AutomationQueries.dismissOutput(db, id: seeded.living, contentHash: "h1", now: now))
        }
        let after = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM automation_outputs WHERE id = ?", arguments: [seeded.living])
        }
        XCTAssertEqual(after, before)
    }

    /// A row from before the blocks migration has `content_hash = ''`, and
    /// the card drew `''`: it still marks.
    func testPreMigrationRowStillMarks() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let automationID = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            let id = try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: run)
            let card = try XCTUnwrap(try AutomationQueries.fetchInboxOutputs(db).first)
            XCTAssertEqual(card.contentHash, "")
            XCTAssertTrue(try AutomationQueries.markOutputDone(db, id: id, contentHash: card.contentHash, now: now))
        }
    }

    // MARK: - Same-hash vs changed rewrites

    /// A same-hash rewrite moves only `written_at`: the unread count, the
    /// order, the read state and Home's feed stay as they were. A changed
    /// one makes the card unread and moves it to the top: one more unread.
    func testSameHashRewriteIsNeverNews() throws {
        let queue = try TestDatabase.create()
        let seeded = try queue.write { db in try seed(db) }
        let calendar = Calendar(identifier: .gregorian)
        func state() throws -> (count: Int, order: [Int64], home: [Int64], living: AutomationOutputCard?) {
            try queue.read { db in
                let cards = try AutomationQueries.fetchInboxOutputs(db, includeRead: true)
                return (try AutomationQueries.inboxOutputCount(db), cards.map(\.id),
                        HomeFeedQueries.read(db, now: now, calendar: calendar).outputs.map(\.id),
                        cards.first { $0.id == seeded.living })
            }
        }
        let before = try state()
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.order, [seeded.feed, seeded.living])
        XCTAssertEqual(before.home, [seeded.feed], "Home lists unread cards only")

        try queue.write { db in try rewrite(db, seeded, hash: "h1", at: "2026-10-16T11:00:00Z") }
        let same = try state()
        XCTAssertEqual(same.count, before.count)
        XCTAssertEqual(same.order, before.order, "a same-hash rewrite does not move the card")
        XCTAssertEqual(same.home, before.home)
        XCTAssertEqual(same.living?.isUnread, false)
        XCTAssertEqual(same.living?.changedAt, before.living?.changedAt)
        XCTAssertEqual(same.living?.writtenAt, AutomationDates.parse("2026-10-16T11:00:00Z"))

        try queue.write { db in try rewrite(db, seeded, hash: "h2", at: "2026-10-16T11:30:00Z") }
        let changed = try state()
        XCTAssertEqual(changed.count, before.count + 1)
        XCTAssertEqual(changed.order, [seeded.living, seeded.feed])
        XCTAssertEqual(changed.home, [seeded.living, seeded.feed])
        XCTAssertEqual(changed.living?.isUnread, true)
        XCTAssertEqual(changed.living?.changedAt, AutomationDates.parse("2026-10-16T11:30:00Z"))
    }

    /// `since` (Home's window) reads `changed_at`: an old living card that
    /// changed today is in it, one only rewritten with the same hash is not.
    func testSinceUsesChangedAt() throws {
        let queue = try TestDatabase.create()
        let seeded = try queue.write { db -> Seeded in
            let seeded = try seed(db)
            try db.execute(sql: "UPDATE automation_outputs SET read_at = NULL")
            return seeded
        }
        let since = try XCTUnwrap(AutomationDates.parse("2026-10-16T09:30:00Z"))
        try queue.write { db in try rewrite(db, seeded, hash: "h1", at: "2026-10-16T11:00:00Z") }
        XCTAssertEqual(try queue.read { db in try AutomationQueries.fetchInboxOutputs(db, since: since).map(\.id) },
                       [seeded.feed])
        try queue.write { db in try rewrite(db, seeded, hash: "h2", at: "2026-10-16T11:30:00Z") }
        XCTAssertEqual(try queue.read { db in try AutomationQueries.fetchInboxOutputs(db, since: since).map(\.id) },
                       [seeded.living, seeded.feed])
    }

    func testCardCarriesItsBlocksAndVersion() throws {
        let queue = try TestDatabase.create()
        let seeded = try queue.write { db in try seed(db) }
        let card = try XCTUnwrap(try queue.read { db in
            try AutomationQueries.fetchInboxOutputs(db, includeRead: true).first { $0.id == seeded.living }
        })
        XCTAssertEqual(card.blocksJSON, blocks)
        XCTAssertEqual(card.outputKey, "threads")
        XCTAssertTrue(card.isLiving)
        XCTAssertEqual(card.contentHash, "h1")
        XCTAssertEqual(card.writtenAt, AutomationDates.parse("2026-10-16T09:00:00Z"))
        XCTAssertEqual(card.changedAt, AutomationDates.parse("2026-10-16T09:00:00Z"))
    }

    // MARK: - People

    /// A person block's `slack_user` resolves to the local user's best name;
    /// an unknown user, a closed card and a damaged document name nobody.
    func testArtifactPeopleFromUsers() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO users (id, name, display_name, real_name) VALUES
                    ('acme:U1', 'colleague.a', 'Colleague A', 'Colleague Alpha'),
                    ('acme:U2', 'colleague.b', '', 'Colleague B'),
                    ('acme:U3', 'colleague.c', '', '')
                """)
            let automationID = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            func person(_ user: String) -> String {
                #"{"type":"person","name":"Someone","avatar":{"slack_user":"\#(user)"},"lines":[]}"#
            }
            let open = #"{"v":1,"blocks":[\#(person("acme:U1")),\#(person("acme:U9")),"#
                + #"{"type":"heading","text":"x","level":1},\#(person("acme:U3"))]}"#
            try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: run, blocksJSON: open)
            try TestDatabase.insertAutomationOutput(
                db, automationID: automationID, runID: run, doneAt: "2026-10-16T10:00:00Z",
                blocksJSON: #"{"v":1,"blocks":[\#(person("acme:U2"))]}"#)
            try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: run, blocksJSON: "{not json")
        }
        let people = try queue.read { db in try AutomationQueries.artifactPeople(db) }
        XCTAssertEqual(people, ["acme:U1": "Colleague A", "acme:U3": "colleague.c"])
    }

    /// A valid document whose `blocks` holds a string and a number (and an
    /// avatar that is not an object) next to a healthy card: the people
    /// read and the whole Inbox feed still read, and the healthy card's
    /// person still resolves.
    func testArtifactPeopleSurvivesNonObjectBlocks() throws {
        let queue = try TestDatabase.create()
        let healthy = try queue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO users (id, name, display_name) VALUES ('acme:U1', 'colleague.a', 'Colleague A')")
            let automationID = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            try TestDatabase.insertAutomationOutput(
                db, automationID: automationID, runID: run, createdAt: "2026-10-16T09:00:00Z",
                blocksJSON: #"{"v":1,"blocks":["broken",42,{"type":"person","name":"X","avatar":"acme:U1"}]}"#)
            return try TestDatabase.insertAutomationOutput(
                db, automationID: automationID, runID: run, createdAt: "2026-10-16T10:00:00Z",
                blocksJSON: #"{"v":1,"blocks":[{"type":"person","name":"Someone","avatar":{"slack_user":"acme:U1"}}]}"#)
        }
        XCTAssertEqual(try queue.read { db in try AutomationQueries.artifactPeople(db) }, ["acme:U1": "Colleague A"])
        let snapshot = try queue.read { db in
            try InboxFeedQueries.read(db, nowUTC: "2026-10-16T12:00:00Z", dayLimit: 1)
        }
        XCTAssertEqual(snapshot.outputs.count, 2)
        XCTAssertEqual(snapshot.outputs.first?.id, healthy)
        XCTAssertEqual(snapshot.artifactPeople, ["acme:U1": "Colleague A"])
    }

    // MARK: - Texts

    func testLivingCardSourceLineSaysUpdated() {
        let living = card(id: 1, outputKey: "threads", writtenAt: now.addingTimeInterval(-600))
        XCTAssertEqual(InboxCardTexts.sourceLine(living, now: now), "Threads waiting for me · Updated 10 min ago")
        XCTAssertEqual(InboxCardTexts.readingSourceLine(living, now: now),
                       "ϟ Threads waiting for me · Updated 10 min ago")
        let fresh = card(id: 1, outputKey: "threads", writtenAt: now.addingTimeInterval(-20))
        XCTAssertEqual(InboxCardTexts.updated(fresh, now: now), "Updated just now")
        let feed = card(id: 2, outputKey: nil, writtenAt: now)
        XCTAssertTrue(InboxCardTexts.readingSourceLine(feed, now: now).contains("run #7"))
    }

    // MARK: - Notices

    private func card(
        id: Int64,
        automationID: Int64 = 3,
        runID: Int64 = 7,
        outputKey: String? = "k",
        hash: String = "h1",
        changedAt: Date? = nil,
        writtenAt: Date? = nil
    ) -> AutomationOutputCard {
        AutomationOutputCard(
            id: id, automationID: automationID, automationName: "Threads waiting for me", runID: runID,
            title: "Card \(id)", body: "", priority: "medium", createdAt: now.addingTimeInterval(-3600),
            outputKey: outputKey, contentHash: hash, writtenAt: writtenAt, changedAt: changedAt)
    }

    func testNoticeSkipsSameHashRewrites() {
        let previous = [card(id: 1), card(id: 2)]
        // Rewritten by run 8 with the same content: `written_at` moved only.
        let rewritten = [card(id: 1, runID: 8, writtenAt: now), card(id: 2, runID: 8, writtenAt: now)]
        XCTAssertEqual(InboxCardNotice.cards(changedIn: rewritten, previous: previous), [])
    }

    func testNoticeOnePerAutomationPerRun() {
        let previous = [card(id: 1), card(id: 2), card(id: 3)]
        let current = [
            card(id: 1, runID: 8, hash: "h2", changedAt: now),
            card(id: 2, runID: 8, hash: "h2", changedAt: now),
            card(id: 3, runID: 8),
            card(id: 4, runID: 8, changedAt: now),
            card(id: 5, automationID: 4, runID: 9, changedAt: now)
        ]
        let notices = InboxCardNotice.cards(changedIn: current, previous: previous)
        XCTAssertEqual(notices.map(\.count), [3, 1])
        XCTAssertEqual(notices.map(\.runID), [8, 9])
        XCTAssertEqual(notices.first?.text, "Threads waiting for me: 3 cards changed")
        XCTAssertEqual(notices.last?.text, "Threads waiting for me: 1 card changed")
    }
}

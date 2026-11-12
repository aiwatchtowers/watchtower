import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

final class TrackNewsRuleTests: XCTestCase {

    // MARK: - The shared Go fixture

    private struct Fixture: Decodable {
        let quietDays: Int
        let cases: [Case]

        enum CodingKeys: String, CodingKey {
            case quietDays = "quiet_days"
            case cases
        }
    }

    private struct Case: Decodable {
        let name: String
        let now: String
        let readAt: String?
        let hasUpdates: Bool
        let updatedAt: String
        let newestEventAt: String?
        let hasNews: Bool
        let quiet: Bool

        enum CodingKeys: String, CodingKey {
            case name, now, quiet
            case readAt = "read_at"
            case hasUpdates = "has_updates"
            case updatedAt = "updated_at"
            case newestEventAt = "newest_event_at"
            case hasNews = "has_news"
        }
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/tracks/testdata/track_news.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testMatchesTheGoFixture() throws {
        let fx = try fixture()
        XCTAssertEqual(fx.quietDays, TrackNewsRule.quietDays)
        XCTAssertFalse(fx.cases.isEmpty)
        for tc in fx.cases {
            let now = try XCTUnwrap(AutomationDates.parse(tc.now), tc.name)
            var columns: [String: (any DatabaseValueConvertible)?] = [
                "id": 1, "has_updates": tc.hasUpdates, "updated_at": tc.updatedAt
            ]
            columns["read_at"] = tc.readAt
            let card = InboxTrackCard(
                track: Track(row: Row(columns)),
                lastEventAt: TrackNewsRule.lastEventAt(updatedAt: tc.updatedAt, newestEventAt: tc.newestEventAt),
                newEventCount: 0
            )
            XCTAssertEqual(TrackNewsRule.hasNews(track: card, now: now), tc.hasNews, "\(tc.name): has_news")
            XCTAssertEqual(TrackNewsRule.isQuiet(track: card, now: now, days: fx.quietDays), tc.quiet, "\(tc.name): quiet")
        }
    }

    func testUnknownLastEventIsTheEpochSentinel() {
        XCTAssertEqual(TrackNewsRule.lastEventAt(updatedAt: "garbage", newestEventAt: nil), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(TrackNewsRule.lastEventAt(updatedAt: "", newestEventAt: ""), Date(timeIntervalSince1970: 0))
    }

    // MARK: - fetchInboxCards

    private func iso(_ date: Date) -> String { AutomationDates.format(date) }

    func testFetchInboxCardsUsesTheSameLastEvent() throws {
        let queue = try TestDatabase.create()
        let now = Date()
        let eventAt = iso(now.addingTimeInterval(-1 * 86400))
        let (fresh, garbage) = try queue.write { db -> (Int64, Int64) in
            let fresh = try TestDatabase.insertTrack(db, text: "Fresh")
            try db.execute(sql: "UPDATE tracks SET updated_at = ? WHERE id = ?",
                           arguments: [iso(now.addingTimeInterval(-40 * 86400)), fresh])
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 's', ?)",
                           arguments: [fresh, eventAt])
            let garbage = try TestDatabase.insertTrack(db, text: "Garbage")
            try db.execute(sql: "UPDATE tracks SET updated_at = 'garbage' WHERE id = ?", arguments: [garbage])
            return (fresh, garbage)
        }
        let cards = try queue.read { try TrackQueries.fetchInboxCards($0) }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { (Int64($0.track.id), $0) })
        XCTAssertEqual(byID[fresh]?.lastEventAt, AutomationDates.parse(eventAt))
        XCTAssertEqual(byID[garbage]?.lastEventAt, Date(timeIntervalSince1970: 0))
    }

    func testFetchInboxCardsReadsLatestEventSummary() throws {
        let queue = try TestDatabase.create()
        let (busy, idle) = try queue.write { db -> (Int64, Int64) in
            let busy = try TestDatabase.insertTrack(db, text: "Busy")
            for (summary, created) in [("older", "2026-10-20T00:00:00Z"), ("newer", "2026-10-21T00:00:00Z")] {
                try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, ?, ?)",
                               arguments: [busy, summary, created])
            }
            let idle = try TestDatabase.insertTrack(db, text: "Idle")
            return (busy, idle)
        }
        let cards = try queue.read { try TrackQueries.fetchInboxCards($0) }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { (Int64($0.track.id), $0) })
        XCTAssertEqual(byID[busy]?.latestEventSummary, "newer")
        XCTAssertEqual(byID[idle]?.latestEventSummary, "")
    }

    private func insertSlackImage(_ db: Database, channelID: String, ts: String, kind: String = "image") throws {
        try TestDatabase.insertMessage(db, channelID: channelID, ts: ts)
        try db.execute(sql: """
            INSERT INTO media_items (kind, parent_kind, parent_key, slack_channel_id, slack_ts, locator, scope, content_at)
            VALUES (?, 'slack', ?, ?, ?, 'F1', 'slack:1', '2026-10-20T00:00:00Z')
            """, arguments: [kind, "slack:\(channelID):\(ts)", channelID, ts])
    }

    private func refs(_ pairs: [(channel: String, ts: String)]) -> String {
        let items = pairs.map { "{\"ts\":\"\($0.ts)\",\"channel_id\":\"\($0.channel)\",\"author\":\"a\",\"text\":\"t\"}" }
        return "[" + items.joined(separator: ",") + "]"
    }

    func testFetchInboxCardsFlagsAttachmentOnNewestRef() throws {
        let queue = try TestDatabase.create()
        let ids = try queue.write { db -> (raw: Int64, namespaced: Int64, older: Int64, link: Int64) in
            let older = "1700000000.000100"
            let newest = "1700000500.000200"
            // Raw channel id on the media row.
            try insertSlackImage(db, channelID: "C100", ts: newest)
            let raw = try TestDatabase.insertTrack(
                db, text: "Raw", sourceRefs: refs([("C100", older), ("C100", newest)]))
            // Namespaced id on the media row, raw id on the ref.
            try insertSlackImage(db, channelID: "1:C200", ts: newest)
            let namespaced = try TestDatabase.insertTrack(
                db, text: "Namespaced", sourceRefs: refs([("C200", newest), ("C200", older)]))
            // The image sits on an older ref only.
            try insertSlackImage(db, channelID: "C300", ts: older)
            try TestDatabase.insertMessage(db, channelID: "C300", ts: newest)
            let olderOnly = try TestDatabase.insertTrack(
                db, text: "Older", sourceRefs: refs([("C300", older), ("C300", newest)]))
            // A link is not an attachment.
            try insertSlackImage(db, channelID: "C400", ts: newest, kind: "link")
            let link = try TestDatabase.insertTrack(db, text: "Link", sourceRefs: refs([("C400", newest)]))
            return (raw, namespaced, olderOnly, link)
        }
        let cards = try queue.read { try TrackQueries.fetchInboxCards($0) }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { (Int64($0.track.id), $0) })
        XCTAssertEqual(byID[ids.raw]?.newestRefHasAttachment, true)
        XCTAssertEqual(byID[ids.namespaced]?.newestRefHasAttachment, true)
        XCTAssertEqual(byID[ids.older]?.newestRefHasAttachment, false)
        XCTAssertEqual(byID[ids.link]?.newestRefHasAttachment, false)
    }

    func testFetchInboxCardsFlagsAttachmentOnNewestMailEvent() throws {
        let queue = try TestDatabase.create()
        let ids = try queue.write { db -> (gmail: Int64, imap: Int64, plain: Int64) in
            let google = try TestDatabase.insertGoogleAccount(db, email: "me@example.com", gmailEnabled: true)
            for id in ["m-image", "m-plain"] {
                try db.execute(sql: "INSERT INTO gmail_messages (account_id, id) VALUES (?, ?)", arguments: [google, id])
            }
            try db.execute(sql: """
                INSERT INTO media_items (kind, parent_kind, parent_key, gmail_account_id, gmail_message_id, locator, scope, content_at)
                VALUES ('image', 'gmail', ?, ?, 'm-image', 'a1', 'gmail:1', '2026-10-20T00:00:00Z')
                """, arguments: ["gmail:\(google):m-image", google])
            let imapAccount = try TestDatabase.insertEmailAccount(db)
            try db.execute(sql: "INSERT INTO imap_messages (account_id, uidvalidity, uid) VALUES (?, 7, 42)",
                           arguments: [imapAccount])
            try db.execute(sql: """
                INSERT INTO media_items (kind, parent_kind, parent_key, imap_account_id, imap_uidvalidity, imap_uid, locator, scope, content_at)
                VALUES ('image', 'imap', ?, ?, 7, 42, 'a1', 'imap:1', '2026-10-20T00:00:00Z')
                """, arguments: ["imap:\(imapAccount):7:42", imapAccount])

            func track(_ text: String, newestMailID: String) throws -> Int64 {
                let id = try TestDatabase.insertTrack(db, text: text)
                // An older mail event with an image never counts: only the newest one does.
                try db.execute(sql: """
                    INSERT INTO track_events (track_id, summary, source_type, source_id, created_at)
                    VALUES (?, 'older', 'email', 'm-image', '2026-10-01T00:00:00Z'),
                           (?, 'newer', 'email', ?, '2026-10-02T00:00:00Z'),
                           (?, 'slack', 'slack', 'm-image', '2026-10-03T00:00:00Z')
                    """, arguments: [id, id, newestMailID, id])
                return id
            }
            return (try track("Gmail", newestMailID: "m-image"),
                    try track("IMAP", newestMailID: "7-42"),
                    try track("Plain", newestMailID: "m-plain"))
        }
        let cards = try queue.read { try TrackQueries.fetchInboxCards($0) }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { (Int64($0.track.id), $0) })
        XCTAssertEqual(byID[ids.gmail]?.newestRefHasAttachment, true)
        XCTAssertEqual(byID[ids.imap]?.newestRefHasAttachment, true)
        XCTAssertEqual(byID[ids.plain]?.newestRefHasAttachment, false)
    }
}

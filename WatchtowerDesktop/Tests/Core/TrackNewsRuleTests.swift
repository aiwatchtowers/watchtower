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
}

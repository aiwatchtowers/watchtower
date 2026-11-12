import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The people / mail split of Waiting for me and Mail waiting against Go's
/// own fixture, `internal/inbox/testdata/waiting_split.json` (Go:
/// `TestWaitingSplit_SharedFixture`): `InboxPeopleRule` and `WaitingQueries`
/// reach the same kinds, counts and senders as `db.WaitingKindOf`,
/// `db.OpenPeopleCounts` and `db.OpenMailSenders`.
final class WaitingSplitParityTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// A fixture cell: a string, an integer, a real or null.
    private enum JSONValue: Decodable {
        case text(String), number(Int64), real(Double), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let number = try? c.decode(Int64.self) {
                self = .number(number)
            } else if let real = try? c.decode(Double.self) {
                self = .real(real)
            } else {
                self = .text(try c.decode(String.self))
            }
        }

        var databaseValue: DatabaseValue {
            switch self {
            case let .text(text): text.databaseValue
            case let .number(number): number.databaseValue
            case let .real(real): real.databaseValue
            case .null: .null
            }
        }

        var text: String? {
            if case let .text(text) = self { return text }
            return nil
        }
    }

    private typealias Row = [String: JSONValue]

    private struct Fixture: Decodable {
        struct Issue: Decodable {
            let key: String
            let isDeleted: Int

            enum CodingKeys: String, CodingKey {
                case key
                case isDeleted = "is_deleted"
            }
        }

        struct People: Decodable { let open, today, week, older: Int }

        struct Mail: Decodable {
            let open, today, senderCount, topTenShare: Int

            enum CodingKeys: String, CodingKey {
                case open, today
                case senderCount = "sender_count", topTenShare = "top_ten_share"
            }
        }

        struct Sender: Decodable {
            let address: String
            let open, today: Int
            let subject: String
        }

        struct Expected: Decodable {
            let kinds: [String: String]
            let people: People
            let mail: Mail
            let senders: [Sender]
        }

        let now: String
        let tz: String
        let users: [Row]
        let channels: [Row]
        let jiraIssues: [Issue]
        let items: [Row]
        let rules: [Row]
        let expected: Expected

        enum CodingKeys: String, CodingKey {
            case now, tz, users, channels, items, rules, expected
            case jiraIssues = "jira_issues"
        }
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/inbox/testdata/waiting_split.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Every key but the fixture's own `note` is a column.
    private func insert(_ db: Database, into table: String, _ row: Row) throws {
        let columns = row.keys.filter { $0 != "note" }.sorted()
        try db.execute(
            sql: """
                INSERT INTO \(table) (\(columns.joined(separator: ", ")))
                VALUES (\(databaseQuestionMarks(count: columns.count)))
                """,
            arguments: StatementArguments(columns.map { row[$0]?.databaseValue ?? .null }))
    }

    /// Seeds the fixture; returns its now and start of today, both UTC.
    private func seed(_ fx: Fixture) throws -> (now: String, startOfToday: String) {
        try pool.write { db in
            for user in fx.users { try insert(db, into: "users", user) }
            for channel in fx.channels { try insert(db, into: "channels", channel) }
            let account = try TestDatabase.insertJiraAccount(db)
            for issue in fx.jiraIssues {
                try TestDatabase.insertJiraIssue(db, account: account, key: issue.key) { $0.deleted = issue.isDeleted != 0 }
            }
            for item in fx.items { try insert(db, into: "inbox_items", item) }
            for rule in fx.rules { try insert(db, into: "inbox_learned_rules", rule) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: fx.tz))
        let now = try XCTUnwrap(AutomationDates.parse(fx.now))
        return (fx.now, InboxToday.sinceUTC(now: now, calendar: calendar))
    }

    func testKindsMatchTheGoFixture() throws {
        let fx = try fixture()
        XCTAssertEqual(fx.expected.kinds.count, fx.items.count)
        for item in fx.items {
            guard case let .number(id)? = item["id"], let trigger = item["trigger_type"]?.text else {
                return XCTFail("item without id or trigger: \(item)")
            }
            let want = try XCTUnwrap(fx.expected.kinds[String(id)], "no kind for item \(id)")
            XCTAssertEqual(InboxPeopleRule.isPeople(trigger: trigger) ? "people" : "mail", want, "item \(id) (\(trigger))")
        }
    }

    func testPeopleCountsMatchTheGoFixture() throws {
        let fx = try fixture()
        let (now, today) = try seed(fx)

        let counts = try pool.read { try WaitingQueries.peopleCounts($0, nowUTC: now, startOfTodayUTC: today) }

        let want = fx.expected.people
        XCTAssertEqual(counts, PeopleWaitingCounts(open: want.open, today: want.today, week: want.week, older: want.older))
    }

    func testMailSendersMatchTheGoFixture() throws {
        let fx = try fixture()
        let (now, today) = try seed(fx)

        let mail = try pool.read { try WaitingQueries.mailSenders($0, nowUTC: now, startOfTodayUTC: today, limit: 200) }

        let want = fx.expected
        XCTAssertEqual(mail, MailWaitingSummary(
            open: want.mail.open, today: want.mail.today, senderCount: want.mail.senderCount,
            topTenShare: want.mail.topTenShare,
            senders: want.senders.map { MailSenderRow(address: $0.address, open: $0.open, today: $0.today, subject: $0.subject) }))

        let capped = try pool.read { try WaitingQueries.mailSenders($0, nowUTC: now, startOfTodayUTC: today, limit: 2) }
        XCTAssertEqual(capped.senders.map(\.address), want.senders.prefix(2).map(\.address), "the cap keeps the busiest")
        XCTAssertEqual(capped.senderCount, want.mail.senderCount, "the totals are not capped")
    }

    func testSenderKeyMatchesSQLite() throws {
        let fx = try fixture()
        let spellings = fx.items.compactMap { $0["sender_user_id"]?.text }
            + ["JOSÉ@Example.com", "  Ünïcode@EXAMPLE.com  ", "\tTab@Example.com ", ""]
        try pool.read { db in
            for raw in spellings {
                let sqlite = try String.fetchOne(db, sql: "SELECT lower(trim(?))", arguments: [raw])
                XCTAssertEqual(InboxPeopleRule.senderKey(raw), sqlite, "spelling \(raw.debugDescription)")
            }
        }
        XCTAssertEqual(InboxPeopleRule.senderKey("JOSÉ@Example.com"), "josÉ@example.com", "only ASCII letters are lowered")
        XCTAssertEqual(InboxPeopleRule.muteScope(" News@Example.com"), "email:news@example.com")
    }

    func testMissingItemsTableReadsAsZero() throws {
        try pool.write { db in try db.execute(sql: "DROP TABLE inbox_items") }
        let now = "2026-11-11T08:00:00Z"
        try pool.read { db in
            XCTAssertEqual(try WaitingQueries.peopleCounts(db, nowUTC: now, startOfTodayUTC: now), .zero)
            XCTAssertEqual(try WaitingQueries.mailSenders(db, nowUTC: now, startOfTodayUTC: now, limit: 10),
                           MailWaitingSummary(open: 0, today: 0, senderCount: 0, topTenShare: 0, senders: []))
            XCTAssertEqual(try WaitingQueries.newestOpenMail(db, keys: ["a@example.com"], nowUTC: now), [:])
        }
    }

    /// Without the rules table nothing is muted: the mail still reads.
    func testMissingRulesTableMeansNoMutes() throws {
        let fx = try fixture()
        let (now, today) = try seed(fx)
        let muted = try pool.read { try WaitingQueries.mailSenders($0, nowUTC: now, startOfTodayUTC: today, limit: 200) }
        try pool.write { db in try db.execute(sql: "DROP TABLE inbox_learned_rules") }

        let unmuted = try pool.read { try WaitingQueries.mailSenders($0, nowUTC: now, startOfTodayUTC: today, limit: 200) }

        XCTAssertGreaterThan(unmuted.open, muted.open, "the fixture's muted sender is back, nothing emptied")
        XCTAssertTrue(unmuted.senders.contains { $0.address == "news@example.com" })
        let newest = try pool.read { try WaitingQueries.newestOpenMail($0, keys: ["news@example.com"], nowUTC: now) }
        XCTAssertNotNil(newest["news@example.com"])
    }

    /// An unparsable now reads as the current time, as `InboxRefState`
    /// reads it: Older still counts, never silently zero.
    func testUnparsableNowReadsAsTheCurrentTime() throws {
        try pool.write { db in
            let id = try TestDatabase.insertInboxItem(db, triggerType: "mention")
            try db.execute(sql: "UPDATE inbox_items SET created_at = '2020-01-01T00:00:00Z', mentioned_at = '' WHERE id = ?",
                           arguments: [id])
        }
        let counts = try pool.read {
            try WaitingQueries.peopleCounts($0, nowUTC: "not a time", startOfTodayUTC: "9999-01-01T00:00:00Z")
        }
        XCTAssertEqual(counts, PeopleWaitingCounts(open: 1, today: 0, week: 0, older: 1))
    }

    func testNewestOpenMailIsEachSendersNewestOpenItem() throws {
        let fx = try fixture()
        let (now, _) = try seed(fx)
        let newest = try pool.read {
            try WaitingQueries.newestOpenMail(
                $0, keys: ["colleague-a@example.com", "colleague-b@example.com", "news@example.com", "x@example.com"],
                nowUTC: now)
        }
        XCTAssertEqual(newest["colleague-a@example.com"], "https://mail.example.com/m/20")
        XCTAssertEqual(newest["colleague-b@example.com"], "", "shown; its newest open item has no link")
        XCTAssertNil(newest["news@example.com"], "muted")
        XCTAssertNil(newest["x@example.com"], "no open mail")
    }
}

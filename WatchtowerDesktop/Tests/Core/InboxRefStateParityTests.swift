import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The render-time check against the Go writers' own fixtures (inbox builder
/// B Task 16): Swift `InboxRefState` gives exactly the open refs Go reads.
/// `internal/inbox/testdata/open_items.json` is what `db.OpenInboxItems`
/// (`attention.waiting`, the Waiting for me built-in) reads; its `action` /
/// `reminder` twin, `internal/automations/builtin/testdata/open_approvals.json`
/// (`approvals.list`, Needs approval), is pinned by
/// `InboxRefStateApprovalsFixtureTests`, run with this class.
final class InboxRefStateParityTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private struct Fixture: Decodable {
        struct Issue: Decodable {
            let key: String
            let isDeleted: Int

            enum CodingKeys: String, CodingKey {
                case key
                case isDeleted = "is_deleted"
            }
        }

        let now: String
        let jiraIssues: [Issue]
        let items: [[String: JSONValue]]
        let expectedOpenIDs: [Int64]

        enum CodingKeys: String, CodingKey {
            case now, items
            case jiraIssues = "jira_issues", expectedOpenIDs = "expected_open_ids"
        }
    }

    /// A fixture cell: a string, a number or null.
    private enum JSONValue: Decodable {
        case text(String), number(Int64), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let number = try? c.decode(Int64.self) {
                self = .number(number)
            } else {
                self = .text(try c.decode(String.self))
            }
        }

        var databaseValue: DatabaseValue {
            switch self {
            case let .text(text): text.databaseValue
            case let .number(number): number.databaseValue
            case .null: .null
            }
        }
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/inbox/testdata/open_items.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testOpenInboxItemsMatchTheGoFixture() throws {
        let fx = try fixture()
        try pool.write { db in
            let account = try TestDatabase.insertJiraAccount(db)
            for issue in fx.jiraIssues {
                try TestDatabase.insertJiraIssue(db, account: account, key: issue.key) { $0.deleted = issue.isDeleted != 0 }
            }
            for item in fx.items {
                // Every key but the fixture's own `note` is a column.
                let columns = item.keys.filter { $0 != "note" }.sorted()
                try db.execute(
                    sql: """
                        INSERT INTO inbox_items (\(columns.joined(separator: ", ")))
                        VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")))
                        """,
                    arguments: StatementArguments(columns.map { item[$0]?.databaseValue ?? .null }))
            }
        }
        let refs = fx.items.compactMap { item -> InboxRef? in
            guard case let .number(id)? = item["id"] else { return nil }
            return InboxRef(kind: .inboxItem, id: id)
        }
        XCTAssertEqual(refs.count, fx.items.count)

        let state = try pool.read { try InboxRefState.read($0, refs: refs, nowUTC: fx.now) }

        XCTAssertEqual(Set(refs.filter(state.isShown).map(\.id)), Set(fx.expectedOpenIDs),
                       "the Desktop's open items differ from Go's db.OpenInboxItems")
        XCTAssertEqual(state.waiting, state.shown, "an open item always waits on the owner")
    }
}

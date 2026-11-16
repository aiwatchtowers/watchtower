import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport
import XCTest

/// One Inbox implementation: the Go feed builder (`internal/inboxfeed`) and
/// today's Swift builders give the same feed over the shared fixture
/// `internal/inboxfeed/testdata/inbox_feed_cases.json` (Go runs it in
/// `TestInboxFeedCases`). Each case seeds a database as a fresh migrated Go
/// file is, runs the Swift builders at the case's `now` in UTC and maps them
/// through `SwiftFeedAdapter`.
final class InboxFeedParityTests: XCTestCase {
    /// …/internal/inboxfeed/testdata, from …/WatchtowerDesktop/Tests/Core/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Core
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/inboxfeed/testdata")

    private struct FeedCase: Decodable {
        let name: String
        let now: String
        let seed: [String]
        let opts: FeedRequest
        let expect: Feed
    }

    private var savedZone: TimeZone?

    override func setUp() {
        super.setUp()
        // InboxRefState reads an idea's date-only snooze in the current zone;
        // the Go side reads the case's `now`, which is UTC.
        savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC") ?? .current
    }

    override func tearDown() {
        if let savedZone { NSTimeZone.default = savedZone }
        super.tearDown()
    }

    func testSwiftBuilderMatchesEveryGoCase() throws {
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("inbox_feed_cases.json"))
        let cases = try JSONDecoder().decode([FeedCase].self, from: data)
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for item in cases {
            let now = try XCTUnwrap(AutomationDates.parse(item.now), item.name)
            XCTAssertNil(item.opts.clip == true ? "clip" : nil, "\(item.name): Clip is Go-only; no parity case uses it")
            let queue = try TestDatabase.create()
            let mapped = try queue.write { db -> SwiftFeedAdapter.Mapped in
                try Self.seedLikeAFreshGoFile(db)
                for statement in item.seed { try db.execute(sql: statement) }
                return try SwiftFeedAdapter.feed(db, now: now, folder: item.opts.folder)
            }
            for id in mapped.unmapped {
                let kind = String(id.split(separator: ":").first ?? "")
                XCTAssertTrue(SwiftFeedAdapter.laterKinds.contains(kind), "\(item.name): entry \(id) was not mapped")
            }
            let swift = SwiftFeedAdapter.blankGoOnly(mapped.feed)
            let go = SwiftFeedAdapter.blankGoOnly(item.expect)
            XCTAssertEqual(swift.folders, go.folders, "\(item.name): folders")
            if (item.opts.limit ?? 0) > 0 {
                assertLimited(swift: swift.cards, go: go.cards, more: go.more ?? [], name: item.name)
            } else {
                XCTAssertEqual(swift.cards, go.cards, "\(item.name): cards")
                XCTAssertNil(go.more, "\(item.name): more without a limit")
            }
        }
    }

    /// A limited case: the Mac never caps, so the Go cards are the Swift
    /// cards in the same order with the cut ones out, and `more` counts the
    /// cut per folder.
    private func assertLimited(swift: [Card], go: [Card], more: [FolderMore], name: String) {
        var cut: [Int64: Int] = [:]
        var next = 0
        for card in swift {
            if next < go.count, go[next] == card {
                next += 1
            } else {
                cut[card.folderID, default: 0] += 1
            }
        }
        XCTAssertEqual(next, go.count, "\(name): the Go cards are not the Swift cards in order")
        XCTAssertEqual(cut, Dictionary(uniqueKeysWithValues: more.map { ($0.folderID, $0.count) }), "\(name): more")
    }

    /// The rows a fresh migrated Go file holds that the generated test schema
    /// does not (migration 00183's seeds): the root, Needs approval and the
    /// folder revision.
    private static func seedLikeAFreshGoFile(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO inbox_folders (id, kind, parent_id, slug, title, icon, position)
            VALUES (1, 'root', NULL, 'inbox', 'Inbox', '', 0);
            INSERT INTO inbox_folders (id, kind, parent_id, slug, title, icon, position)
            VALUES (2, 'approvals', 1, 'needs-approval', 'Needs approval', '', 0);
            INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1);
            """)
    }

    /// The save_automation summary: the Go `SummarizeSaveAutomation` and
    /// `SaveAutomationProposalSummary` agree over the shared fixture
    /// `save_automation_summary_cases.json` (Go runs it in
    /// `TestSaveAutomationSummary_SharedCases`).
    func testSaveAutomationSummaryMatchesGo() throws {
        struct SummaryCase: Decodable {
            struct Expect: Decodable {
                let name: String
                let scope: String
                let when: String
                let may: String
            }

            let name: String
            let args: String
            let workbenchNames: [String: String]
            let expect: Expect

            enum CodingKeys: String, CodingKey {
                case name, args, expect
                case workbenchNames = "workbench_names"
            }
        }
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("save_automation_summary_cases.json"))
        let cases = try JSONDecoder().decode([SummaryCase].self, from: data)
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let action = AgentAction(row: Row(["id": 1, "tool": "save_automation", "args_json": item.args]))
            let summary = SaveAutomationProposalSummary(model: SaveAutomationCardModel(action: action)) {
                item.workbenchNames[String($0)]
            }
            XCTAssertEqual(summary.name, item.expect.name, item.name)
            XCTAssertEqual(summary.scope, item.expect.scope, item.name)
            XCTAssertEqual(summary.when, item.expect.when, item.name)
            XCTAssertEqual(summary.mayLine, item.expect.may, item.name)
        }
    }
}

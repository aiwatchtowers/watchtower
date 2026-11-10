import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The open set of `action` and `reminder` refs, on the fixture Go's
/// `approvals.list` reads too (`internal/automations/builtin/testdata/
/// open_approvals.json`): the Desktop draws exactly the approvals the
/// needs-approval built-in writes cards for (dual path, Inbox builder B).
final class InboxRefStateApprovalsFixtureTests: XCTestCase {
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
        struct Action: Decodable {
            let id: Int64
            let tool: String
            let argsJSON: String
            let status: String
            let error: String?
            let surface: String?
            let contextType: String?
            let contextID: String?
            let createdAt: String
            let decidedAt: String?
            let appliedAt: String?
            let dismissedAt: String?

            enum CodingKeys: String, CodingKey {
                case id, tool, status, error, surface
                case argsJSON = "args_json", contextType = "context_type", contextID = "context_id"
                case createdAt = "created_at", decidedAt = "decided_at", appliedAt = "applied_at"
                case dismissedAt = "dismissed_at"
            }
        }

        struct Reminder: Decodable {
            let id: Int64
            let messageRef: String?
            let note: String
            let remindAt: String
            let status: String
            let createdAt: String

            enum CodingKeys: String, CodingKey {
                case id, note, status
                case messageRef = "message_ref", remindAt = "remind_at", createdAt = "created_at"
            }
        }

        let now: String
        let actions: [Action]
        let reminders: [Reminder]
        let open: [String]
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/builtin/testdata/open_approvals.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testOpenActionsAndRemindersMatchTheGoFixture() throws {
        let fx = try fixture()
        try pool.write { db in
            for a in fx.actions {
                try db.execute(sql: """
                    INSERT INTO agent_actions (id, tool, args_json, status, error, surface, context_type, context_id,
                        created_at, decided_at, applied_at, dismissed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [a.id, a.tool, a.argsJSON, a.status, a.error ?? "", a.surface ?? "",
                                     a.contextType ?? "", a.contextID ?? "", a.createdAt, a.decidedAt ?? "",
                                     a.appliedAt ?? "", a.dismissedAt ?? ""])
            }
            for r in fx.reminders {
                try db.execute(sql: """
                    INSERT INTO reminders (id, message_ref, note, remind_at, status, created_at) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [r.id, r.messageRef ?? "", r.note, r.remindAt, r.status, r.createdAt])
            }
        }
        let refs = fx.actions.map { InboxRef(kind: .action, id: $0.id) }
            + fx.reminders.map { InboxRef(kind: .reminder, id: $0.id) }

        let state = try pool.read { try InboxRefState.read($0, refs: refs, nowUTC: fx.now) }

        let shown = Set(refs.filter(state.isShown).map { "\($0.kind == .action ? "action" : "reminder"):\($0.id)" })
        XCTAssertEqual(shown, Set(fx.open), "the Desktop's open approvals differ from Go's approvals.list")
        XCTAssertEqual(state.waiting, state.shown, "an open approval always waits on the owner")
    }
}

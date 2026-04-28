import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TargetPrefillBuilderTests: XCTestCase {

    // MARK: - fromSubItem

    func testFromSubItem_BasicShape() {
        let parent = Self.makeTarget(
            id: 42,
            text: "Ship the rewrite",
            intent: "Unblock Q2 launch",
            subItems: [
                TargetSubItem(text: "Draft RFC", done: false),
                TargetSubItem(text: "Review with team", done: false),
                TargetSubItem(text: "Implement", done: false)
            ]
        )
        let subItem = parent.decodedSubItems[0]
        let prefill = TargetPrefillBuilder.fromSubItem(parent: parent, subItem: subItem, index: 0)

        XCTAssertEqual(prefill.text, "Draft RFC")
        XCTAssertEqual(prefill.sourceType, "promoted_subitem")
        XCTAssertEqual(prefill.sourceID, "42:0")
        XCTAssertEqual(prefill.parentID, 42)
        XCTAssertTrue(prefill.intent.contains("Sub-target of #42"))
        XCTAssertTrue(prefill.intent.contains("«Ship the rewrite»"))
        XCTAssertTrue(prefill.intent.contains("Unblock Q2 launch"))
        XCTAssertTrue(prefill.intent.contains("Review with team"))
        XCTAssertTrue(prefill.intent.contains("Implement"))
        XCTAssertTrue(prefill.secondaryLinks.isEmpty)
    }

    func testFromSubItem_NoSiblings_NoIntent() {
        let parent = Self.makeTarget(
            id: 7,
            text: "Lone target",
            intent: "",
            subItems: [TargetSubItem(text: "Only one", done: false)]
        )
        let subItem = parent.decodedSubItems[0]
        let prefill = TargetPrefillBuilder.fromSubItem(parent: parent, subItem: subItem, index: 0)

        XCTAssertTrue(prefill.intent.contains("Sub-target of #7 «Lone target»."))
        XCTAssertFalse(prefill.intent.contains("Parent context:"))
        XCTAssertFalse(prefill.intent.contains("Sibling sub-items:"))
    }

    // MARK: - fromTrack

    func testFromTrack_HappyPath() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertChannel(db, id: "C002", name: "engineering")
            try TestDatabase.insertTrack(
                db,
                text: "Migrate auth service",
                context: "We need to swap the legacy IDP for the new one.",
                priority: "high",
                channelIDs: #"["C001","C002"]"#,
                blocking: "Waiting on infra",
                decisionSummary: "Going with provider X"
            )
        }
        let track = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = 1"))
        }
        let prefill = try await TargetPrefillBuilder.fromTrack(track, db: mgr)

        XCTAssertEqual(prefill.text, "Migrate auth service")
        XCTAssertEqual(prefill.sourceType, "track")
        XCTAssertEqual(prefill.sourceID, "1")
        XCTAssertNil(prefill.parentID)
        XCTAssertTrue(prefill.intent.contains("We need to swap the legacy IDP"))
        XCTAssertTrue(prefill.intent.contains("Decision: Going with provider X"))
        XCTAssertTrue(prefill.intent.contains("Blocking: Waiting on infra"))
        XCTAssertTrue(prefill.intent.contains("In channels: #general, #engineering"))
        XCTAssertEqual(prefill.secondaryLinks.count, 2)
        XCTAssertEqual(prefill.secondaryLinks[0].externalRef, "slack:C001")
        XCTAssertEqual(prefill.secondaryLinks[0].relation, "related")
    }

    func testFromTrack_UnknownChannelFallsBackToID() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertTrack(
                db,
                text: "Track with orphan channel",
                channelIDs: #"["C999"]"#
            )
        }
        let track = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = 1"))
        }
        let prefill = try await TargetPrefillBuilder.fromTrack(track, db: mgr)
        XCTAssertTrue(prefill.intent.contains("In channels: #C999"))
        XCTAssertEqual(prefill.secondaryLinks.first?.externalRef, "slack:C999")
    }

    // MARK: - Helpers

    /// Creates a file-backed `DatabaseManager` (DatabasePool requires a path),
    /// applies the schema, runs the seed closure. The OS reaps the temp file.
    static func makeManagerSeededWith(_ seed: (Database) throws -> Void) throws -> DatabaseManager {
        let path = NSTemporaryDirectory() + "twtest_\(UUID().uuidString).db"
        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: TestDatabase.schema)
            try seed(db)
        }
        return DatabaseManager(pool: pool)
    }

    static func makeTarget(
        id: Int,
        text: String,
        intent: String = "",
        level: String = "week",
        priority: String = "medium",
        ownership: String = "mine",
        dueDate: String = "",
        subItems: [TargetSubItem] = []
    ) -> Target {
        let subItemsJSON: String = {
            guard !subItems.isEmpty,
                  let data = try? JSONEncoder().encode(subItems),
                  let json = String(data: data, encoding: .utf8) else { return "[]" }
            return json
        }()
        let row: Row = [
            "id": id,
            "text": text,
            "intent": intent,
            "level": level,
            "priority": priority,
            "ownership": ownership,
            "due_date": dueDate,
            "sub_items": subItemsJSON,
            "period_start": "2026-04-20",
            "period_end": "2026-04-26",
            "status": "todo",
            "ball_on": "",
            "snooze_until": "",
            "blocking": "",
            "tags": "[]",
            "notes": "[]",
            "progress": 0.0,
            "source_type": "manual",
            "source_id": "",
            "custom_label": "",
            "created_at": "2026-04-20T00:00:00Z",
            "updated_at": "2026-04-20T00:00:00Z"
        ]
        return Target(row: row)
    }
}

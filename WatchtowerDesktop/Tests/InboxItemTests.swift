import XCTest
import GRDB
@testable import WatchtowerDesktop

final class InboxItemTests: XCTestCase {

    // MARK: - New field decoding

    func testDecodesNewFields() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','1.0','U1','mention','pending','high','actionable',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertEqual(item.itemClass, .actionable)
        XCTAssertNil(item.archivedAt)
        XCTAssertEqual(item.archiveReason, "")
    }

    func testDecodesAmbientClass() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, item_class, created_at, updated_at)
                VALUES ('C1','2.0','U1','mention','pending','low','ambient',?,?)
            """, arguments: ["2026-04-23T10:00:00Z", "2026-04-23T10:00:00Z"])
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertEqual(item.itemClass, .ambient)
    }

    func testDefaultsToActionableWhenClassMissing() throws {
        let db = try TestDatabase.create()
        // insertInboxItem writes item_class explicitly (default "actionable"), matching
        // the inbox_items column default in schema.sql.
        try db.write { db in
            try TestDatabase.insertInboxItem(db)
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertEqual(item.itemClass, .actionable)
    }

    func testDecodesArchivedAt() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type,
                    status, priority, archived_at, archive_reason, created_at, updated_at)
                VALUES ('C1','3.0','U1','mention','resolved','low',?,?,?,?)
            """, arguments: [
                "2026-04-23T12:00:00Z",
                "resolved",
                "2026-04-23T10:00:00Z",
                "2026-04-23T10:00:00Z"
            ])
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertNotNil(item.archivedAt)
        XCTAssertEqual(item.archiveReason, "resolved")
    }

    // MARK: - Secretary card fields

    func testMapsCardColumns() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertInboxItem(
                db,
                cardStatus: "ready",
                whyMatters: "w",
                threadDigest: "t",
                draftReply: "d"
            )
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertEqual(item.cardStatus, .ready)
        XCTAssertEqual(item.whyMatters, "w")
        XCTAssertEqual(item.threadDigest, "t")
        XCTAssertEqual(item.draftReply, "d")
        XCTAssertTrue(item.hasCard)
    }

    func testCardStatusDefaultsToNone() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertInboxItem(db)
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertEqual(item.cardStatus, .none)
        XCTAssertFalse(item.hasCard)
    }

    func testCardStatusFailedIsNotHasCard() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertInboxItem(db, cardStatus: "failed")
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertEqual(item.cardStatus, .failed)
        XCTAssertFalse(item.hasCard)
    }

    func testReadyCardWithEmptyOptionalFieldsHidesTheirBlocks() throws {
        // Go pipeline contract: only why_matters is guaranteed non-empty on a ready card.
        // hasThreadDigest / hasDraftReply gate the digest paragraph and the copyable
        // draft box in InboxCardView, so empty sections must report false here.
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertInboxItem(
                db,
                cardStatus: "ready",
                whyMatters: "w",
                threadDigest: "",
                draftReply: ""
            )
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertTrue(item.hasCard)
        XCTAssertFalse(item.hasThreadDigest)
        XCTAssertFalse(item.hasDraftReply)
    }

    func testCardPresentationPredicatesTrueWhenFieldsPresent() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertInboxItem(
                db,
                cardStatus: "ready",
                whyMatters: "w",
                threadDigest: "t",
                draftReply: "d"
            )
        }
        let item = try XCTUnwrap(db.read { db in
            try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1")
        })
        XCTAssertTrue(item.hasThreadDigest)
        XCTAssertTrue(item.hasDraftReply)
    }
}

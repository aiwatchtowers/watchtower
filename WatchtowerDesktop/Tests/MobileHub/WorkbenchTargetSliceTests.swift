import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `workbench_target` and `workbench_comment` projections (mobile POC
/// spec §4.3, §4.4): board targets only (PROJ-01), the archive window
/// (PROJ-15, read-only), the per-workbench caps and the comment window.
final class WorkbenchTargetSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func records(_ source: any SliceSource) throws -> [SliceRecord] {
        try dbPool.read { try source.records($0) }
    }

    private func targetPayloads() throws -> [Int64: [String: Any]] {
        var out: [Int64: [String: Any]] = [:]
        for payload in try SliceJSON.objects(try records(WorkbenchTargetSlice())) {
            out[(payload["id"] as? NSNumber)?.int64Value ?? -1] = payload
        }
        return out
    }

    private func commentIDs() throws -> Set<Int64> {
        Set(try SliceJSON.objects(try records(WorkbenchCommentSlice())).compactMap { ($0["id"] as? NSNumber)?.int64Value })
    }

    // MARK: - Wire shape

    func testTargetPayloadMatchesTheKitFixture() throws {
        let (parent, child) = try dbPool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            let parent = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "Group")
            let child = try TestDatabase.insertWorkbenchTarget(
                db, projectID: project, text: "Archive Closed Targets Now", status: "in_progress", parentID: parent,
                priority: "high"
            )
            try db.execute(
                sql: "UPDATE targets SET intent = 'Archive on demand.', branch = 'feature/acme', pr = '175', progress = 0.5 WHERE id = ?",
                arguments: [child]
            )
            try TestDatabase.insertWorkbenchComment(db, projectID: project, author: "owner", targetID: child)
            try TestDatabase.insertWorkbenchComment(db, projectID: project, author: "agent", targetID: child)
            try TestDatabase.insertOwnerAsk(db, projectID: project, targetID: child)
            try TestDatabase.insertOwnerAsk(db, projectID: project, targetID: child, status: "answered", answer: "{}")
            let direct = try SliceSeed.insertSession(db, projectID: project, targetID: child)
            let linked = try SliceSeed.insertSession(db, projectID: project, lastActiveAt: Date().addingTimeInterval(-60))
            try SliceSeed.linkSession(db, sessionID: linked, targetID: child)
            try SliceSeed.linkSession(db, sessionID: direct, targetID: child)
            try SliceSeed.insertSession(db, projectID: project, kind: "shell", targetID: child)
            return (parent, child)
        }
        let payloads = try targetPayloads()
        let payload = try XCTUnwrap(payloads[child])

        assertWireShape(
            payload, matches: try SliceJSON.kitFixture("workbench/workbench_target.json"),
            optionalKeys: ["parent_id", "text_clipped", "intent_clipped", "branch_clipped", "pr_clipped",
                           "session_ids_more", "last_status_at", "last_status_actor", "work_on_prompt_clipped"]
        )
        XCTAssertEqual((payload["parent_id"] as? NSNumber)?.int64Value, parent)
        XCTAssertEqual(payload["status"] as? String, "in_progress")
        XCTAssertEqual(payload["priority"] as? String, "high")
        XCTAssertEqual(payload["progress"] as? Double, 0.5)
        XCTAssertEqual(payload["branch"] as? String, "feature/acme")
        XCTAssertEqual(payload["pr"] as? String, "175")
        XCTAssertEqual(payload["archived"] as? Bool, false)
        XCTAssertEqual(payload["open_comments"] as? Int, 1, "the open owner root")
        XCTAssertEqual(payload["unread_for_owner"] as? Int, 1, "the unread agent comment")
        XCTAssertEqual(payload["open_asks"] as? Int, 1, "only the open ask")
        XCTAssertEqual((payload["session_ids"] as? [Any])?.count, 2, "direct and linked claude sessions, once each; no shell")
        XCTAssertEqual(payload["last_status_actor"] as? String, "owner")
        XCTAssertEqual(
            payload["work_on_prompt"] as? String,
            TerminalLaunch.workOnTargetPrompt(targetID: child, vocabulary: .current)
        )
        let group = try XCTUnwrap(payloads[parent])
        XCTAssertEqual(group["children_count"] as? Int, 1)
        XCTAssertNil(group["parent_id"], "a top-level target carries no parent_id key")
    }

    func testCommentPayloadMatchesTheKitFixture() throws {
        let reply = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            let root = try TestDatabase.insertWorkbenchComment(db, projectID: project, author: "owner", targetID: target)
            let reply = try TestDatabase.insertWorkbenchComment(db, projectID: project, targetID: target, parentID: root)
            try db.execute(sql: "UPDATE project_comments SET agent_label = 'claude' WHERE id = ?", arguments: [reply])
            return reply
        }
        let payloads = try SliceJSON.objects(try records(WorkbenchCommentSlice()))
        let payload = try XCTUnwrap(payloads.first { ($0["id"] as? NSNumber)?.int64Value == reply })

        assertWireShape(
            payload, matches: try SliceJSON.kitFixture("workbench/workbench_comment.json"),
            optionalKeys: ["target_id", "parent_id", "agent_label_clipped", "body_clipped"]
        )
        XCTAssertEqual(payload["agent_label"] as? String, "claude")
        XCTAssertEqual(payload["read"] as? Bool, false)
        let root = try XCTUnwrap(payloads.first { $0["parent_id"] == nil })
        XCTAssertEqual(root["author"] as? String, "owner")
    }

    // MARK: - PROJ-01

    func testProj01APersonalTargetIsNeverPublished() throws {
        let (board, personal) = try dbPool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            let board = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            let personal = try TestDatabase.insertTarget(db, text: "Personal")
            return (board, personal)
        }
        let ids = Set(try targetPayloads().keys)

        XCTAssertEqual(ids, [board])
        XCTAssertFalse(ids.contains(personal))
    }

    // MARK: - Archive window (PROJ-15, read-only)

    func testAnArchivedTargetClosedWithin90DaysIsPublishedAndAnOlderOneIsNot() throws {
        let now = Date()
        let (recent, old, open) = try dbPool.write { db -> (Int64, Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            let recent = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "89 days")
            try SliceSeed.close(db, id: recent, at: now.addingTimeInterval(-89 * day))
            let old = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "91 days")
            try SliceSeed.close(db, id: old, at: now.addingTimeInterval(-91 * day))
            let open = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "open")
            try TestDatabase.insertWorkbenchComment(db, projectID: project, targetID: old)
            return (recent, old, open)
        }
        let payloads = try targetPayloads()

        XCTAssertEqual(payloads[recent]?["archived"] as? Bool, true)
        XCTAssertNil(payloads[old], "an archived target closed 91 days ago leaves the window")
        XCTAssertEqual(payloads[open]?["archived"] as? Bool, false)
        XCTAssertTrue(try commentIDs().isEmpty, "a comment on an unpublished target is not published")
    }

    func testADoneTargetNotYetArchivedIsPublishedAsNotArchived() throws {
        let target = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            try SliceSeed.close(db, id: target, at: Date().addingTimeInterval(-2 * day))
            return target
        }
        XCTAssertEqual(try targetPayloads()[target]?["archived"] as? Bool, false, "closed 2 days ago, archive after 14")
    }

    // MARK: - Caps

    func testWorkbenchCapsKeepThe2000NewestNonArchivedTargets() throws {
        let oldest = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            for index in 0..<2001 {
                try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "t\(index)")
            }
            // The lowest id is the stalest, every later one a second newer.
            try db.execute(sql: """
                UPDATE targets SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (5000 - id) || ' seconds')
                """)
            return try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT MIN(id) FROM targets"))
        }
        let ids = Set(try targetPayloads().keys)

        XCTAssertEqual(ids.count, 2000)
        XCTAssertFalse(ids.contains(oldest), "the oldest by updated_at leaves the window")
        let workbench = try XCTUnwrap(SliceJSON.objects(try records(WorkbenchSlice(home: "/Users/acme"))).first)
        XCTAssertEqual(workbench["targets_more"] as? Int, 1)
    }

    func testArchivedTargetsAreCappedAt500NewestClosed() throws {
        let now = Date()
        let oldest = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            var first: Int64 = 0
            for index in 0..<501 {
                let id = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "a\(index)")
                try SliceSeed.close(db, id: id, at: now.addingTimeInterval(-30 * day + Double(index) * 60))
                if index == 0 { first = id }
            }
            return first
        }
        let payloads = try targetPayloads()

        XCTAssertEqual(payloads.count, 500)
        XCTAssertNil(payloads[oldest], "the earliest close leaves the archived window")
        XCTAssertTrue(payloads.values.allSatisfy { $0["archived"] as? Bool == true })
        let workbench = try XCTUnwrap(SliceJSON.objects(try records(WorkbenchSlice(home: "/Users/acme"))).first)
        XCTAssertEqual(workbench["targets_more"] as? Int, 1)
    }

    func testTextFieldsAndSessionIDsAreCapped() throws {
        let target = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: String(repeating: "t", count: 301))
            try db.execute(
                sql: "UPDATE targets SET intent = ?, branch = ?, pr = ? WHERE id = ?",
                arguments: [String(repeating: "i", count: 4001), String(repeating: "b", count: 121),
                            String(repeating: "p", count: 121), target]
            )
            for index in 0..<21 {
                try SliceSeed.insertSession(db, projectID: project, targetID: target, lastActiveAt: Date().addingTimeInterval(Double(-index)))
            }
            return target
        }
        let payload = try XCTUnwrap(try targetPayloads()[target])

        XCTAssertEqual((payload["text"] as? String)?.count, 300)
        XCTAssertEqual(payload["text_clipped"] as? Bool, true)
        XCTAssertEqual((payload["intent"] as? String)?.count, 4000)
        XCTAssertEqual(payload["intent_clipped"] as? Bool, true)
        XCTAssertEqual((payload["branch"] as? String)?.count, 120)
        XCTAssertEqual(payload["branch_clipped"] as? Bool, true)
        XCTAssertEqual((payload["pr"] as? String)?.count, 120)
        XCTAssertEqual(payload["pr_clipped"] as? Bool, true)
        XCTAssertEqual((payload["session_ids"] as? [Any])?.count, 20)
        XCTAssertEqual(payload["session_ids_more"] as? Int, 1)
        XCTAssertNil(payload["work_on_prompt_clipped"])
    }

    // MARK: - Comments

    func testTheNewest200CommentsPerTargetArePublished() throws {
        let oldest = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            for index in 0..<201 {
                try TestDatabase.insertWorkbenchComment(db, projectID: project, body: "c\(index)", targetID: target)
            }
            try db.execute(sql: """
                UPDATE project_comments SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || (5000 - id) || ' seconds')
                """)
            return try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT MIN(id) FROM project_comments"))
        }
        let ids = try commentIDs()

        XCTAssertEqual(ids.count, 200)
        XCTAssertFalse(ids.contains(oldest))
    }

    func testAReplyNamingOnlyItsParentCountsTowardItsRootsTarget() throws {
        let (root, reply) = try dbPool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            let root = try TestDatabase.insertWorkbenchComment(db, projectID: project, author: "owner", targetID: target)
            let reply = try TestDatabase.insertWorkbenchComment(db, projectID: project, parentID: root)
            return (root, reply)
        }
        let payloads = try SliceJSON.objects(try records(WorkbenchCommentSlice()))

        XCTAssertEqual(Set(payloads.compactMap { ($0["id"] as? NSNumber)?.int64Value }), [root, reply])
        let published = try XCTUnwrap(payloads.first { ($0["id"] as? NSNumber)?.int64Value == reply })
        XCTAssertNil(published["target_id"], "the reply names only its parent")
        XCTAssertEqual((published["parent_id"] as? NSNumber)?.int64Value, root)
    }

    func testCommentTextIsCappedAndReadFollowsReadAt() throws {
        try dbPool.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            let id = try TestDatabase.insertWorkbenchComment(
                db, projectID: project, body: String(repeating: "b", count: 4001), targetID: target,
                readAt: dbStamp(Date())
            )
            try db.execute(sql: "UPDATE project_comments SET agent_label = ? WHERE id = ?", arguments: [String(repeating: "l", count: 61), id])
        }
        let payload = try XCTUnwrap(SliceJSON.objects(try records(WorkbenchCommentSlice())).first)

        XCTAssertEqual((payload["body"] as? String)?.count, 4000)
        XCTAssertEqual(payload["body_clipped"] as? Bool, true)
        XCTAssertEqual((payload["agent_label"] as? String)?.count, 60)
        XCTAssertEqual(payload["agent_label_clipped"] as? Bool, true)
        XCTAssertEqual(payload["read"] as? Bool, true)
    }
}

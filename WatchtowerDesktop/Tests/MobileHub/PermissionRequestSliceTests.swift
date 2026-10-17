import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerE2ETesting
import WatchtowerSync
import WatchtowerTestSupport

/// The `permission_request` projection (#517, spec §5.2): the pending
/// requests of live board Claude sessions in the published workbenches, and
/// the expiry of the requests no hook waits on any more (older than the hook
/// timeout, or of a session that is not live).
final class PermissionRequestSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func slice(live: Set<Int64>) -> PermissionRequestSlice {
        let liveness = SessionLiveness(liveIDs: live)
        let now = fixedNow
        return PermissionRequestSlice(liveness: { liveness }, now: { now })
    }

    private func payloads(_ source: PermissionRequestSlice) throws -> [Int64: [String: Any]] {
        let objects = try SliceJSON.objects(try dbPool.read { try source.records($0) })
        var byID: [Int64: [String: Any]] = [:]
        for object in objects { byID[try XCTUnwrap((object["id"] as? NSNumber)?.int64Value)] = object }
        return byID
    }

    @discardableResult
    private func insertRequest(
        _ db: Database,
        session: Int64,
        workbench: Int64,
        summary: String = "git status",
        status: String = "pending",
        age: TimeInterval = 5
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
                VALUES (?, ?, 'Bash', ?, ?, ?)
                """,
            arguments: [session, workbench, summary, status, SessionAgentStatus.formatStamp(fixedNow.addingTimeInterval(-age))]
        )
        return db.lastInsertedRowID
    }

    private func status(_ id: Int64) throws -> String? {
        try dbPool.read { try String.fetchOne($0, sql: "SELECT status FROM permission_requests WHERE id = ?", arguments: [id]) }
    }

    private struct Published {
        let workbench, live, codex, pending: Int64
    }

    func testOnlyPendingRowsOfLiveBoardSessionsArePublished() throws {
        let ids = try dbPool.write { db -> Published in
            let workbench = try TestDatabase.insertWorkbench(db, name: "Acme")
            let live = try SliceSeed.insertSession(db, projectID: workbench)
            let gone = try SliceSeed.insertSession(db, projectID: workbench)
            let codex = try SliceSeed.insertSession(db, projectID: workbench, kind: "codex")
            let pending = try insertRequest(db, session: live, workbench: workbench, summary: "git push origin main\nPush")
            try insertRequest(db, session: live, workbench: workbench, status: "answered_on_mac", age: 60)
            try insertRequest(db, session: live, workbench: workbench, status: "allowed", age: 90)
            try insertRequest(db, session: gone, workbench: workbench)
            try insertRequest(db, session: codex, workbench: workbench)
            return Published(workbench: workbench, live: live, codex: codex, pending: pending)
        }
        let source = slice(live: [ids.live, ids.codex])

        let published = try payloads(source)

        XCTAssertEqual(Set(published.keys), [ids.pending], "only the live Claude session's pending request")
        let payload = try XCTUnwrap(published[ids.pending])
        assertWireShape(payload, matches: try SliceJSON.kitFixture("workbench/permission_request.json"),
                        optionalKeys: ["summary_clipped"])
        XCTAssertEqual((payload["session_id"] as? NSNumber)?.int64Value, ids.live)
        XCTAssertEqual((payload["workbench_id"] as? NSNumber)?.int64Value, ids.workbench)
        XCTAssertEqual(payload["tool_name"] as? String, "Bash")
        XCTAssertEqual(payload["summary"] as? String, "git push origin main\nPush")
        XCTAssertNil(payload["summary_clipped"])
        XCTAssertNil(payload["status"], "only pending rows are published: no status on the wire")
        XCTAssertNil(payload["decided_by"])
        let records = try dbPool.read { try source.records($0) }
        XCTAssertEqual(records.map(\.recordName), ["permission_request-\(ids.pending)"])
    }

    func testAWorkbenchThatIsNotPublishedPublishesNothing() throws {
        let session = try dbPool.write { db -> Int64 in
            let workbench = try TestDatabase.insertWorkbench(db)
            let session = try SliceSeed.insertSession(db, projectID: workbench)
            try insertRequest(db, session: session, workbench: workbench)
            try db.execute(sql: "DELETE FROM projects")
            return session
        }
        XCTAssertTrue(try payloads(slice(live: [session])).isEmpty)
    }

    func testALongSummaryIsClippedAndSaysSo() throws {
        let (session, id) = try dbPool.write { db -> (Int64, Int64) in
            let workbench = try TestDatabase.insertWorkbench(db)
            let session = try SliceSeed.insertSession(db, projectID: workbench)
            return (session, try insertRequest(db, session: session, workbench: workbench, summary: String(repeating: "a", count: 2001)))
        }
        let payload = try XCTUnwrap(try payloads(slice(live: [session]))[id])
        XCTAssertEqual((payload["summary"] as? String)?.count, PermissionRequestSlice.maxSummary)
        XCTAssertEqual(payload["summary_clipped"] as? Bool, true)
    }

    /// Spec §4.2: a pending row older than the hook timeout, or of a session
    /// that is no longer live, has no reader: the pass marks it `expired`
    /// (its own short write before the read) and never publishes it.
    private struct Expiring {
        let live, other, fresh, old, atLimit, orphan, allowed: Int64
    }

    func testOldOrOrphanPendingRowsExpireOnThePass() throws {
        let ids = try dbPool.write { db -> Expiring in
            let workbench = try TestDatabase.insertWorkbench(db)
            let live = try SliceSeed.insertSession(db, projectID: workbench)
            let other = try SliceSeed.insertSession(db, projectID: workbench)
            let gone = try SliceSeed.insertSession(db, projectID: workbench)
            let maxAge = PermissionRequestSlice.maxAge
            return Expiring(
                live: live, other: other,
                fresh: try insertRequest(db, session: live, workbench: workbench),
                old: try insertRequest(db, session: other, workbench: workbench, age: maxAge + 1),
                atLimit: try insertRequest(db, session: other, workbench: workbench, age: maxAge),
                orphan: try insertRequest(db, session: gone, workbench: workbench),
                allowed: try insertRequest(db, session: gone, workbench: workbench, status: "allowed")
            )
        }
        let source = slice(live: [ids.live, ids.other])
        // Before the write: the read alone never publishes a stale row.
        XCTAssertEqual(Set(try payloads(source).keys), [ids.fresh, ids.atLimit])

        XCTAssertEqual(try source.expire(dbPool), 2)

        XCTAssertEqual(try status(ids.fresh), "pending")
        XCTAssertEqual(try status(ids.atLimit), "pending")
        XCTAssertEqual(try status(ids.old), "expired")
        XCTAssertEqual(try status(ids.orphan), "expired")
        XCTAssertEqual(try status(ids.allowed), "allowed", "a decided row is never touched")
        let decided = try dbPool.read {
            try String.fetchOne($0, sql: "SELECT decided_at FROM permission_requests WHERE id = ?", arguments: [ids.old])
        }
        XCTAssertEqual(decided, SessionAgentStatus.formatStamp(fixedNow), "stamped in the agent-state layout")
        XCTAssertEqual(Set(try payloads(source).keys), [ids.fresh, ids.atLimit])
        XCTAssertEqual(try source.expire(dbPool), 0, "nothing left to expire: no write")
    }

    /// Ruling 1: the expiry age is the hook's own timeout (Go↔Swift dual
    /// path with `internal/devpack/workbench_settings.go permissionWaitSpec`).
    func testTheExpiryAgeIsTheHookTimeout() {
        XCTAssertEqual(PermissionRequestSlice.maxAge, 86_400)
        XCTAssertEqual(PermissionRequestSlice.maxSummary, 2000)
    }

    private func seedOneRequest() throws -> Int64 {
        try dbPool.write { db in
            let workbench = try TestDatabase.insertWorkbench(db)
            let session = try SliceSeed.insertSession(db, projectID: workbench)
            return try insertRequest(db, session: session, workbench: workbench)
        }
    }

    /// The publisher runs the source's expiry before its read.
    func testThePublisherExpiresBeforeItReads() async throws {
        let id = try seedOneRequest()
        let publisher = SlicePublisher(
            dbPool: dbPool, state: try HubSyncState.inMemory(), transport: StubHubTransport().sealing(),
            sources: [slice(live: [])]
        )

        _ = try await publisher.publishOnce(kinds: [.permissionRequest])

        XCTAssertEqual(try status(id), "expired", "the session is not live")
    }
}

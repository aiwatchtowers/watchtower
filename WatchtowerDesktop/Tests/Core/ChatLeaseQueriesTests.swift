import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The Swift lease code over Go's shared case fixture
/// (`internal/db/testdata/chat_lease_cases.json`, spec 2026-11-15 §4.4):
/// claim, stale takeover, cancel, release — the same steps, the same rows.
final class ChatLeaseQueriesTests: XCTestCase {
    private struct Step: Decodable {
        let op: String
        let owner: String?
        let ownerID: String?
        let turnID: String
        let nowMS: Int64?

        enum CodingKeys: String, CodingKey {
            case op, owner
            case ownerID = "owner_id"
            case turnID = "turn_id"
            case nowMS = "now_ms"
        }
    }

    private struct Lease: Decodable {
        let owner: String
        let ownerID: String
        let turnID: String
        let startedAtMS: Int64
        let heartbeatAtMS: Int64
        let cancelRequestedAtMS: Int64?

        enum CodingKeys: String, CodingKey {
            case owner
            case ownerID = "owner_id"
            case turnID = "turn_id"
            case startedAtMS = "started_at_ms"
            case heartbeatAtMS = "heartbeat_at_ms"
            case cancelRequestedAtMS = "cancel_requested_at_ms"
        }
    }

    private struct Expect: Decodable {
        let ok: Bool
        let lease: Lease?
    }

    private struct Case: Decodable {
        let name: String
        let steps: [Step]
        let expect: [Expect]
    }

    private func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/chat_lease_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testSharedLeaseCases() throws {
        let all = try cases()
        XCTAssertFalse(all.isEmpty)
        for leaseCase in all {
            let queue = try TestDatabase.create()
            let conv = try queue.write { try TestDatabase.insertChatConversation($0) }
            XCTAssertEqual(leaseCase.steps.count, leaseCase.expect.count, leaseCase.name)
            for (index, step) in leaseCase.steps.enumerated() {
                let label = "\(leaseCase.name) step \(index) (\(step.op))"
                let ok = try queue.write { db -> Bool in
                    let now = step.nowMS ?? 0
                    switch step.op {
                    case "claim":
                        let owner = try XCTUnwrap(ChatLease.Owner(rawValue: step.owner ?? ""), label)
                        let lease = ChatLease(conversationID: conv, owner: owner, ownerID: step.ownerID ?? "",
                                              turnID: step.turnID, startedAtMS: now, heartbeatAtMS: now)
                        return try ChatLeaseQueries.claim(db, lease, nowMS: now)
                    case "heartbeat":
                        return try ChatLeaseQueries.heartbeat(db, conversationID: conv, turnID: step.turnID, nowMS: now)
                    case "cancel":
                        return try ChatLeaseQueries.requestCancel(db, conversationID: conv, turnID: step.turnID, nowMS: now)
                    case "release":
                        try ChatLeaseQueries.release(db, conversationID: conv, turnID: step.turnID)
                        return true
                    default:
                        XCTFail("unknown op \(step.op)")
                        return false
                    }
                }
                let want = leaseCase.expect[index]
                XCTAssertEqual(ok, want.ok, label)
                let got = try queue.read { try ChatLeaseQueries.fetch($0, conversationID: conv) }
                guard let expected = want.lease else {
                    XCTAssertNil(got, label)
                    continue
                }
                let lease = try XCTUnwrap(got, label)
                XCTAssertEqual(lease.conversationID, conv, label)
                XCTAssertEqual(lease.owner.rawValue, expected.owner, label)
                XCTAssertEqual(lease.ownerID, expected.ownerID, label)
                XCTAssertEqual(lease.turnID, expected.turnID, label)
                XCTAssertEqual(lease.startedAtMS, expected.startedAtMS, label)
                XCTAssertEqual(lease.heartbeatAtMS, expected.heartbeatAtMS, label)
                XCTAssertEqual(lease.cancelRequestedAtMS, expected.cancelRequestedAtMS, label)
            }
        }
    }

    func testLiveUntilStale() {
        let lease = ChatLease(conversationID: 1, owner: .hub, ownerID: "h", turnID: "t", startedAtMS: 1000, heartbeatAtMS: 1000)
        XCTAssertTrue(lease.isLive(nowMS: 61_000), "exactly 60 s old: still held (the claim needs older)")
        XCTAssertFalse(lease.isLive(nowMS: 61_001))
    }

    func testReleaseOwnedAndEarlierLaunches() throws {
        let queue = try TestDatabase.create()
        let (one, two, three) = try queue.write { db in
            (try TestDatabase.insertChatConversation(db), try TestDatabase.insertChatConversation(db),
             try TestDatabase.insertChatConversation(db))
        }
        try queue.write { db in
            for (conv, owner, id) in [(one, ChatLease.Owner.desktop, "old"), (two, .desktop, "now"), (three, .hub, "old")] {
                _ = try ChatLeaseQueries.claim(db, ChatLease(conversationID: conv, owner: owner, ownerID: id, turnID: "t",
                                                             startedAtMS: 1, heartbeatAtMS: 1), nowMS: 1)
            }
        }
        let released = try queue.write { try ChatLeaseQueries.releaseEarlierDesktopLaunches($0, currentLaunchID: "now") }
        XCTAssertEqual(released, 1)
        try queue.read { db in
            XCTAssertNil(try ChatLeaseQueries.fetch(db, conversationID: one), "an earlier launch's lease goes")
            XCTAssertNotNil(try ChatLeaseQueries.fetch(db, conversationID: two), "this launch's stays")
            XCTAssertNotNil(try ChatLeaseQueries.fetch(db, conversationID: three), "the hub's stays")
        }
        XCTAssertEqual(try queue.write { try ChatLeaseQueries.releaseOwned($0, owner: .hub, ownerID: "old") }, 1)
    }
}

import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Now tab (spec §13 B2): Waiting for you across workbenches, newest
/// first and 20 shown, the Mac chip and the session summary chips.
final class NowWiringTests: XCTestCase {
    private let now = Date()

    func testZeroOpenAsksShowNothingIsWaiting() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.asks = snapshot.asks.filter { $0.status != .open }
        let model = NowModel(snapshot: snapshot, now: now)
        XCTAssertTrue(model.waiting.isEmpty)
        XCTAssertEqual(model.emptyText, "Nothing is waiting for you")
    }

    func testWaitingRunsAcrossWorkbenchesNewestFirst() throws {
        let model = NowModel(snapshot: try demoSnapshot(now: now), now: now)
        XCTAssertNil(model.emptyText)
        XCTAssertEqual(model.waiting.map(\.id), [111, 109, 110])
        XCTAssertEqual(model.waiting.first?.subline, "Acme · Archive closed targets · #415 · 5m")
    }

    func testOnlyTheNewestTwentyAreShown() throws {
        var snapshot = WorkbenchReplicaSnapshot()
        for index in 0..<25 {
            snapshot.asks.append(try mirror(OwnerAsk.self, DemoSeed.JSON.ask(Int64(index + 1), workbench: 1, [
                "created_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-Double(index) * 60))
            ])))
        }
        let model = NowModel(snapshot: snapshot, now: now)
        XCTAssertEqual(model.waiting.count, 20)
        XCTAssertEqual(model.waiting.first?.id, 1)
        XCTAssertEqual(model.waitingMore, 5)
    }

    func testSessionChipsSumEveryWorkbench() throws {
        let model = NowModel(snapshot: try demoSnapshot(now: now), now: now)
        XCTAssertEqual(model.sessionChips.map(\.text), [
            "2 working", "1 waiting for you", "1 needs approval", "2 finished", "1 failed", "2 stopped"
        ])
    }

    func testTheMacChipFollowsTheHeartbeat() throws {
        var snapshot = try demoSnapshot(now: now)
        XCTAssertEqual(NowModel(snapshot: snapshot, now: now).macChip, "Mac not connected")
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: now, lastRelayAt: now, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "_user", sharing: .none
        )
        XCTAssertEqual(NowModel(snapshot: snapshot, now: now).macChip, "Mac online")
        XCTAssertEqual(NowModel(snapshot: snapshot, now: now.addingTimeInterval(800)).macChip, "Mac offline")
    }
}

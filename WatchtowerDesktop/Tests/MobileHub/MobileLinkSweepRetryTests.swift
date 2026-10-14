import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// The waits a center's injected sleep was asked for; returns at once.
final class WaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Duration] = []

    var all: [Duration] { lock.withLock { waits } }
    func append(_ wait: Duration) { lock.withLock { waits.append(wait) } }
}

/// Target 153: a link close whose share calls fail is retried in the background with a bounded backoff.
@MainActor
final class MobileLinkSweepRetryTests: XCTestCase {
    private var sidecar: HubSyncState!
    private var shares: FakeShareService!
    private var center: MobileLinkCenter!

    override func setUp() async throws {
        sidecar = try HubSyncState.inMemory()
        shares = FakeShareService()
        center = makeCenter()
    }

    override func tearDown() async throws {
        center?.cancelSweepRetry()
        center = nil
        shares = nil
        sidecar = nil
    }

    /// The default sleep parks until cancelled.
    private func makeCenter(sleep: (@Sendable (Duration) async -> Void)? = nil) -> MobileLinkCenter {
        MobileLinkCenter(
            sidecar: sidecar, shares: shares, macName: "Mac acme", ownerUser: { "_owner-acme" },
            sleep: sleep ?? { _ in try? await Task.sleep(for: .seconds(3600)) })
    }

    /// Target 153: a close whose share calls fail retries in the background after `sweepRetryDelays`, and stops
    /// once the sweep went through.
    func testAFailedCloseIsRetriedUntilTheSweepGoesThrough() async throws {
        let waits = WaitLog()
        center = makeCenter { waits.append($0) }
        try sidecar.setMetaValue("1", forKey: MobileLinkCenter.sweepPendingKey)
        shares.failNext("setPublicLink", times: 2)

        await center.closeLink(reason: .restart)
        await center.sweepRetry?.value

        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "0")
        XCTAssertEqual(waits.all, Array(MobileLinkCenter.sweepRetryDelays.prefix(2)), "two retries: one failed, one swept")
        XCTAssertNil(center.sweepRetry)
    }

    /// The retries are bounded: a sweep that keeps failing stays pending for the next close, with no loop.
    func testAFailingSweepIsRetriedABoundedNumberOfTimes() async throws {
        let waits = WaitLog()
        center = makeCenter { waits.append($0) }
        try sidecar.setMetaValue("1", forKey: MobileLinkCenter.sweepPendingKey)
        shares.setFailing(["setPublicLink"])

        await center.closeLink(reason: .restart)
        await center.sweepRetry?.value

        XCTAssertEqual(waits.all, MobileLinkCenter.sweepRetryDelays)
        XCTAssertEqual(shares.calls.filter { $0.hasPrefix("setPublicLink") }.count, 1 + MobileLinkCenter.sweepRetryDelays.count)
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "1")
        XCTAssertNil(center.sweepRetry)
    }

    /// Stopping the hub cancels a waiting retry: no share call runs after it.
    func testCancellingTheRetryStopsIt() async throws {
        try sidecar.setMetaValue("1", forKey: MobileLinkCenter.sweepPendingKey)
        shares.setFailing(["setPublicLink"])
        await center.closeLink(reason: .restart)
        let retry = try XCTUnwrap(center.sweepRetry, "the default sleep parks the retry")

        center.cancelSweepRetry()
        await retry.value

        XCTAssertEqual(shares.calls.filter { $0.hasPrefix("setPublicLink") }.count, 1)
        XCTAssertNil(center.sweepRetry)
    }

    /// A retry cancelled mid-sweep never clears the handle of the retry that replaced it.
    func testACancelledRetryDoesNotClearItsSuccessor() async throws {
        let waits = WaitLog()
        // The first wait returns at once; later ones park until cancelled.
        center = makeCenter { wait in
            waits.append(wait)
            if waits.all.count > 1 { try? await Task.sleep(for: .seconds(3600)) }
        }
        try sidecar.setMetaValue("1", forKey: MobileLinkCenter.sweepPendingKey)
        shares.failNext("setPublicLink", times: 1)
        await center.closeLink(reason: .restart)
        let first = try XCTUnwrap(center.sweepRetry)
        let gate = SaveGate()
        shares.gate("setPublicLink", on: gate)
        await fulfillment(of: [gate.arrived], timeout: 5)

        center.cancelSweepRetry()
        shares.failNext("setPublicLink", times: 1)
        await center.closeLink(reason: .restart)
        let second = try XCTUnwrap(center.sweepRetry)
        gate.release()
        await first.value

        XCTAssertNotNil(center.sweepRetry, "the successor keeps its handle")
        second.cancel()
    }
}

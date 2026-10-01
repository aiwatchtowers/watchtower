import XCTest
@testable import WatchtowerCore

@MainActor
final class EmbeddedStreamGateTests: XCTestCase {
    func testTheFourthTurnWaitsAndReleasesAreFIFO() {
        let gate = EmbeddedStreamGate(limit: 3)
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertTrue(gate.tryAcquire(ids[0]))
        XCTAssertTrue(gate.tryAcquire(ids[1]))
        XCTAssertTrue(gate.tryAcquire(ids[2]))
        XCTAssertFalse(gate.tryAcquire(ids[3]))
        var granted: [Int] = []
        gate.enqueue(ids[3]) { granted.append(3) }
        gate.enqueue(ids[4]) { granted.append(4) }
        XCTAssertEqual(gate.waiting, 2)

        gate.release(ids[0])
        XCTAssertEqual(granted, [3])
        gate.release(ids[1])
        XCTAssertEqual(granted, [3, 4])
        XCTAssertEqual(gate.active.count, 3)
    }

    func testCancelledWaiterIsNeverGranted() {
        let gate = EmbeddedStreamGate(limit: 1)
        let first = UUID(), second = UUID()
        XCTAssertTrue(gate.tryAcquire(first))
        var granted = false
        gate.enqueue(second) { granted = true }
        gate.cancel(second)
        gate.release(first)
        XCTAssertFalse(granted)
        XCTAssertEqual(gate.active.count, 0)
    }

    func testDoubleReleaseIsANoOp() {
        let gate = EmbeddedStreamGate(limit: 1)
        let first = UUID(), second = UUID()
        XCTAssertTrue(gate.tryAcquire(first))
        gate.release(first)
        XCTAssertTrue(gate.tryAcquire(second))
        gate.release(first)
        XCTAssertEqual(gate.active, [second], "releasing a slot not held frees nothing")
    }
}

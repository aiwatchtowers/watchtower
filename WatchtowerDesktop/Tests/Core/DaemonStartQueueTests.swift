import XCTest
@testable import WatchtowerCore

/// #577: every daemon start or restart the app makes runs on one queue, one
/// at a time, and a hung item cannot stall it.
@MainActor
final class DaemonStartQueueTests: XCTestCase {
    func testItemsRunOneAfterTheOther() async {
        let queue = DaemonStartQueue()
        var log: [String] = []
        queue.enqueue {
            log.append("a-start")
            try? await Task.sleep(for: .milliseconds(30))
            log.append("a-end")
        }
        let second = queue.enqueue { () -> Int in
            log.append("b")
            return 7
        }
        let value = await second.value
        XCTAssertEqual(value, 7)
        XCTAssertEqual(log, ["a-start", "a-end", "b"])
        XCTAssertNil(queue.failure)
    }

    /// A hung item times out visibly and the next one runs.
    func testTimeoutMovesOn() async {
        let queue = DaemonStartQueue(itemTimeout: .milliseconds(50))
        let gate = Gate()
        let hung = queue.enqueue { () -> Bool in
            await gate.wait()
            return true
        }
        let next = queue.enqueue { () -> Bool in true }
        let hungValue = await hung.value
        let nextValue = await next.value
        XCTAssertNil(hungValue)
        XCTAssertEqual(nextValue, true)
        XCTAssertEqual(queue.failure, DaemonStartQueue.timedOutText)
        gate.open()
    }
}

/// A suspension that ends only when opened (stands in for a hung CLI call).
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

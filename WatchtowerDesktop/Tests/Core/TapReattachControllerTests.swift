import XCTest
@testable import WatchtowerCore

final class TapReattachControllerTests: XCTestCase {
    private final class FakeMonitor: AudioDeviceChangeMonitoring {
        var handler: ((AudioDeviceChange) -> Void)?
        var stopCalls = 0
        var startError: Error?

        func startMonitoring(_ handler: @escaping (AudioDeviceChange) -> Void) throws {
            if let startError { throw startError }
            self.handler = handler
        }

        func stopMonitoring() {
            stopCalls += 1
        }

        /// A CoreAudio callback; also fires after `stopMonitoring`, the way
        /// a callback already queued behind the stop would.
        func fire(_ change: AudioDeviceChange) {
            handler?(change)
        }
    }

    /// A manual clock: `advance` runs whatever came due, in order.
    private final class ManualScheduler: ReattachScheduling {
        private final class Item {
            let due: TimeInterval
            let work: () -> Void
            var cancelled = false
            init(due: TimeInterval, work: @escaping () -> Void) {
                self.due = due
                self.work = work
            }
            func cancel() { cancelled = true }
        }

        private var now: TimeInterval = 0
        private var items: [Item] = []

        var pendingCount: Int { items.filter { !$0.cancelled }.count }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
            let item = Item(due: now + delay, work: work)
            items.append(item)
            return item.cancel
        }

        func advance(_ seconds: TimeInterval) {
            let target = now + seconds
            while let next = items.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
                items.removeAll { $0 === next }
                now = next.due
                next.work()
            }
            items.removeAll { $0.cancelled }
            now = target
        }
    }

    private struct RebuildFailed: LocalizedError {
        var errorDescription: String? { "no such device" }
    }

    /// What the controller did: rebuild calls and log lines. Outcomes for
    /// the next rebuilds are consumed front first; success once empty.
    private final class Probe {
        var rebuilds = 0
        var outcomes: [Bool] = []
        var logLines: [String] = []
    }

    private var monitor: FakeMonitor!
    private var scheduler: ManualScheduler!
    private var probe = Probe()
    private var rebuilds: Int { probe.rebuilds }
    private var logLines: [String] { probe.logLines }

    override func setUp() {
        super.setUp()
        monitor = FakeMonitor()
        scheduler = ManualScheduler()
        probe = Probe()
    }

    private func makeController() -> TapReattachController {
        let probe = self.probe
        return TapReattachController(
            monitor: monitor,
            scheduler: scheduler,
            rebuild: {
                probe.rebuilds += 1
                if !probe.outcomes.isEmpty, !probe.outcomes.removeFirst() { throw RebuildFailed() }
            },
            log: { probe.logLines.append($0) }
        )
    }

    func testOutputChangeDuringRecordingReattachesOnceAfterTheDebounce() throws {
        let controller = makeController()
        try controller.start()
        XCTAssertEqual(controller.state, .attached)

        monitor.fire(.defaultOutput)
        XCTAssertEqual(controller.state, .pending)
        scheduler.advance(0.9)
        XCTAssertEqual(rebuilds, 0, "nothing happens inside the debounce")
        scheduler.advance(0.2)

        XCTAssertEqual(rebuilds, 1)
        XCTAssertEqual(controller.state, .attached)
        XCTAssertEqual(controller.reattachCount, 1)
        XCTAssertEqual(logLines, ["re-attached system audio after default output change (re-attach #1)"])
    }

    // Not started: no listener is installed, so no change can reach it.
    func testControllerThatNeverStartedListensToNothing() {
        let controller = makeController()
        XCTAssertNil(monitor.handler)
        controller.stop()
        XCTAssertEqual(monitor.stopCalls, 0, "a controller that never started has no listener to remove")
        XCTAssertEqual(controller.state, .stopped)
    }

    func testChangeAfterStopDoesNothing() throws {
        let controller = makeController()
        try controller.start()
        controller.stop()
        XCTAssertEqual(monitor.stopCalls, 1)

        monitor.fire(.defaultOutput) // a callback queued behind the stop
        scheduler.advance(10)

        XCTAssertEqual(rebuilds, 0)
        XCTAssertEqual(controller.state, .stopped)
    }

    // Plugging in a Bluetooth headset flips output, then input, then output
    // again within a second: one rebuild, after the last change.
    func testRapidFlappingIsDebouncedIntoOneRebuild() throws {
        let controller = makeController()
        try controller.start()

        monitor.fire(.defaultOutput)
        scheduler.advance(0.5)
        monitor.fire(.defaultInput)
        scheduler.advance(0.5)
        monitor.fire(.defaultOutput)
        scheduler.advance(0.9)
        XCTAssertEqual(rebuilds, 0)
        scheduler.advance(0.2)

        XCTAssertEqual(rebuilds, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(logLines, ["re-attached system audio after default output + default input change (re-attach #1)"])
    }

    func testStopDuringPendingReattachCancelsIt() throws {
        let controller = makeController()
        try controller.start()
        monitor.fire(.defaultOutput)

        controller.stop()
        scheduler.advance(10)

        XCTAssertEqual(rebuilds, 0)
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(monitor.stopCalls, 1)
        controller.stop()
        XCTAssertEqual(monitor.stopCalls, 1, "stop is idempotent")
    }

    func testStopDuringRetryWaitCancelsTheRetry() throws {
        probe.outcomes = [false]
        let controller = makeController()
        try controller.start()
        monitor.fire(.defaultOutput)
        scheduler.advance(1)
        XCTAssertEqual(rebuilds, 1)

        controller.stop()
        scheduler.advance(10)

        XCTAssertEqual(rebuilds, 1, "no retry runs once the recording stopped")
        XCTAssertEqual(controller.state, .stopped)
    }

    func testFailureIsRetriedAndThenSucceeds() throws {
        probe.outcomes = [false]
        let controller = makeController()
        try controller.start()
        monitor.fire(.defaultOutput)
        scheduler.advance(1)
        XCTAssertEqual(rebuilds, 1)
        XCTAssertEqual(controller.state, .pending)

        scheduler.advance(2)

        XCTAssertEqual(rebuilds, 2)
        XCTAssertEqual(controller.state, .attached)
        XCTAssertEqual(controller.reattachCount, 1)
        XCTAssertEqual(logLines.count, 2)
        XCTAssertTrue(logLines[0].contains("failed, retrying (1/2): no such device"), logLines[0])
    }

    // Every attempt fails: the controller gives up (the capture keeps what it
    // had and the "No call audio" warning stays up) but keeps listening, and
    // the next device change tries again.
    func testFailureAfterEveryRetryLeavesItDetachedUntilTheNextChange() throws {
        probe.outcomes = [false, false, false]
        let controller = makeController()
        try controller.start()
        monitor.fire(.defaultOutput)
        scheduler.advance(1 + 2 + 2)

        XCTAssertEqual(rebuilds, 3)
        XCTAssertEqual(controller.state, .detached)
        XCTAssertEqual(controller.reattachCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0, "no endless retry loop")
        XCTAssertTrue(logLines.last?.contains("giving up until the next device change") == true)

        monitor.fire(.defaultInput)
        scheduler.advance(1)

        XCTAssertEqual(rebuilds, 4)
        XCTAssertEqual(controller.state, .attached)
        XCTAssertEqual(logLines.last, "re-attached system audio after default input change (re-attach #1)")
    }

    // A change during the retry wait restarts the debounce and the retry
    // budget instead of stacking a second schedule: after it, the controller
    // again gets the first attempt plus both retries.
    func testChangeDuringRetryWaitRestartsTheBudget() throws {
        probe.outcomes = [false, false, false, false, false]
        let controller = makeController()
        try controller.start()
        monitor.fire(.defaultOutput)
        scheduler.advance(1 + 2)
        XCTAssertEqual(rebuilds, 2, "first attempt and first retry spent")

        monitor.fire(.defaultOutput)
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(1 + 2)
        XCTAssertEqual(rebuilds, 4)
        XCTAssertEqual(controller.state, .pending, "the old budget would have given up here")
        scheduler.advance(2)

        XCTAssertEqual(rebuilds, 5)
        XCTAssertEqual(controller.state, .detached)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // The recorder can be torn down while a rebuild runs: the stop wins and
    // no success or retry follows it.
    func testStopDuringRebuildWins() throws {
        var controller: TapReattachController?
        let probe = self.probe
        let monitor = try XCTUnwrap(self.monitor)
        controller = TapReattachController(
            monitor: monitor,
            scheduler: scheduler,
            rebuild: {
                probe.rebuilds += 1
                controller?.stop()
            },
            log: { probe.logLines.append($0) }
        )
        try controller?.start()
        monitor.fire(.defaultOutput)
        scheduler.advance(10)

        XCTAssertEqual(probe.rebuilds, 1)
        XCTAssertEqual(controller?.state, .stopped)
        XCTAssertEqual(controller?.reattachCount, 0)
        XCTAssertEqual(probe.logLines, [])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testListenerInstallFailureThrowsAndLeavesItIdle() {
        monitor.startError = RebuildFailed()
        let controller = makeController()

        XCTAssertThrowsError(try controller.start())
        XCTAssertEqual(controller.state, .idle)
        controller.stop()
        XCTAssertEqual(monitor.stopCalls, 0)
    }
}

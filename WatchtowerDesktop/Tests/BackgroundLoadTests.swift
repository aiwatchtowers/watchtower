import XCTest
@testable import WatchtowerDesktop

/// Board #564: the speech detector's model load never blocks a window for
/// longer than its wait, keeps running past it, and retries after a failure.
final class BackgroundLoadTests: XCTestCase {
    /// A load the test finishes by hand; counts how often it was started.
    private final class ManualLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var pending: [CheckedContinuation<Int, Error>] = []
        var starts: Int { lock.withLock { started } }

        func run() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    started += 1
                    pending.append(continuation)
                }
            }
        }

        /// Finishes the `count`-th load once it has started.
        func finish(_ result: Result<Int, Error>, startedLoads count: Int = 1) async {
            while starts < count { await Task.yield() }
            let waiting = lock.withLock { () -> [CheckedContinuation<Int, Error>] in
                defer { pending.removeAll() }
                return pending
            }
            waiting.forEach { $0.resume(with: result) }
        }
    }

    private struct LoadFailed: Error {}

    func testWaitRunsOutWhileTheLoadGoesOn() async throws {
        let manual = ManualLoad()
        let load = BackgroundLoad { try await manual.run() }

        let first = try await load.value(waitingUpTo: .milliseconds(50))
        XCTAssertNil(first, "past the wait the caller goes on without the value")
        let second = try await load.value(waitingUpTo: .milliseconds(50))
        XCTAssertNil(second)

        await manual.finish(.success(7))
        XCTAssertEqual(manual.starts, 1, "one load, never a second while it runs")
        let ready = try await load.value(waitingUpTo: nil)
        XCTAssertEqual(ready, 7)
        let cached = try await load.value(waitingUpTo: .zero)
        XCTAssertEqual(cached, 7)
        XCTAssertEqual(manual.starts, 1, "a loaded value is kept")
    }

    func testAWaiterGetsTheValueAsSoonAsItLoads() async throws {
        let manual = ManualLoad()
        let load = BackgroundLoad { try await manual.run() }
        async let value = load.value(waitingUpTo: .seconds(60))
        await manual.finish(.success(3))
        let loaded = try await value
        XCTAssertEqual(loaded, 3, "the load finishing ends the wait, not the timeout")
    }

    func testAFailedLoadIsThrownOnceAndRetriedInTheBackground() async throws {
        let manual = ManualLoad()
        let load = BackgroundLoad { try await manual.run() }
        _ = try await load.value(waitingUpTo: .milliseconds(20))
        await manual.finish(.failure(LoadFailed()))

        do {
            _ = try await load.value(waitingUpTo: nil)
            XCTFail("the failure reaches the next caller")
        } catch {
            XCTAssertTrue(error is LoadFailed, "got \(error)")
        }

        let retry = try await load.value(waitingUpTo: .milliseconds(20))
        XCTAssertNil(retry, "throwing the failure started a new load, which the next call waits on")
        await manual.finish(.success(1), startedLoads: 2)
        let loaded = try await load.value(waitingUpTo: nil)
        XCTAssertEqual(loaded, 1)
        XCTAssertEqual(manual.starts, 2)
    }
}

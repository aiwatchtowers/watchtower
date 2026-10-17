import XCTest
@testable import WatchtowerDesktop

/// Board #564: the speech detector's model load never blocks a caller for
/// longer than its wait, keeps running past it, delivers a failure only to
/// the callers waiting on that attempt, honours the caller's cancel, and
/// retries a failed load at most once per interval.
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

    /// Failures nobody waited for, as `onUnobservedFailure` reports them.
    private final class UnobservedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let reported: XCTestExpectation
        init(expecting expected: Int) {
            reported = XCTestExpectation(description: "unobserved failure logged")
            reported.expectedFulfillmentCount = max(expected, 1)
            reported.isInverted = expected == 0
        }
        var failures: Int { lock.withLock { count } }
        func record(_ error: Error) {
            lock.withLock { count += 1 }
            reported.fulfill()
        }
    }

    private func makeLoad(
        _ manual: ManualLoad,
        retryAfterFailure: Duration = .seconds(60),
        unobserved: UnobservedLog = UnobservedLog(expecting: 0)
    ) -> BackgroundLoad<Int> {
        BackgroundLoad(retryAfterFailure: retryAfterFailure, onUnobservedFailure: unobserved.record) {
            try await manual.run()
        }
    }

    private struct TimedOut: Error {}

    /// Runs `body` against a deadline, so a wait that never ends fails the
    /// test instead of hanging the suite.
    private func within<T: Sendable>(
        _ seconds: Double,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw TimedOut() }
            return value
        }
    }

    /// A caller of `load`, started now, whose outcome the test reads later.
    private func caller(_ load: BackgroundLoad<Int>, wait: Duration?) -> Task<Int?, Error> {
        Task { try await load.value(waitingUpTo: wait) }
    }

    private func untilWaiting(_ load: BackgroundLoad<Int>, _ count: Int) async {
        while await load.waitingCallers < count { await Task.yield() }
    }

    func testWaitRunsOutWhileTheLoadGoesOn() async throws {
        let manual = ManualLoad()
        let load = makeLoad(manual)

        let first = try await load.value(waitingUpTo: .milliseconds(50))
        XCTAssertNil(first, "past the wait the caller goes on without the value")
        let polled = try await load.value(waitingUpTo: .zero)
        XCTAssertNil(polled, "a zero wait only looks")

        await manual.finish(.success(7))
        let ready = try await within(10) { try await load.value(waitingUpTo: nil) }
        XCTAssertEqual(ready, 7)
        let cached = try await load.value(waitingUpTo: .zero)
        XCTAssertEqual(cached, 7)
        XCTAssertEqual(manual.starts, 1, "one attempt, never a second while it runs, and the value is kept")
    }

    func testAWaiterGetsTheValueAsSoonAsItLoads() async throws {
        let manual = ManualLoad()
        let load = makeLoad(manual)
        let started = ContinuousClock.now
        async let value = load.value(waitingUpTo: .seconds(60))
        await manual.finish(.success(3))
        let loaded = try await value
        XCTAssertEqual(loaded, 3)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(30), "the load finishing ends the wait, not the timeout")
    }

    func testEveryWaiterOnAFailingAttemptGetsTheFailure() async throws {
        let manual = ManualLoad()
        let load = makeLoad(manual)
        let first = caller(load, wait: nil)
        let second = caller(load, wait: .seconds(60))
        await untilWaiting(load, 2)
        await manual.finish(.failure(LoadFailed()))
        for waiter in [first, second] {
            let result = await waiter.result
            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is LoadFailed, "got \($0)") }
        }
        XCTAssertEqual(manual.starts, 1)
    }

    func testAFailureNobodyWaitedForIsLoggedNotThrownLater() async throws {
        let manual = ManualLoad()
        let unobserved = UnobservedLog(expecting: 1)
        let load = makeLoad(manual, retryAfterFailure: .zero, unobserved: unobserved)
        let timedOut = try await load.value(waitingUpTo: .milliseconds(20))
        XCTAssertNil(timedOut)
        await manual.finish(.failure(LoadFailed()))
        await fulfillment(of: [unobserved.reported], timeout: 10)

        let next = try await load.value(waitingUpTo: .milliseconds(20))
        XCTAssertNil(next, "the old failure is not thrown at a later caller: it starts a new attempt instead")
        await manual.finish(.success(5), startedLoads: 2)
        let loaded = try await within(10) { try await load.value(waitingUpTo: nil) }
        XCTAssertEqual(loaded, 5)
        XCTAssertEqual(unobserved.failures, 1)
    }

    func testRetryAfterAFailureIsThrottled() async throws {
        let manual = ManualLoad()
        let load = makeLoad(manual, retryAfterFailure: .seconds(60))
        let failed = caller(load, wait: nil)
        await untilWaiting(load, 1)
        await manual.finish(.failure(LoadFailed()))
        let result = await failed.result
        XCTAssertThrowsError(try result.get())

        let asked = try await load.value(waitingUpTo: .seconds(60))
        XCTAssertNil(asked, "within the interval nothing is started and nobody waits")
        XCTAssertEqual(manual.starts, 1)
    }

    func testCancelledCallerStopsWaitingButTheLoadGoesOn() async throws {
        let manual = ManualLoad()
        let load = makeLoad(manual)
        let started = ContinuousClock.now
        let waiting = caller(load, wait: .seconds(120))
        await untilWaiting(load, 1)
        waiting.cancel()
        let result = await waiting.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(30), "the cancel ends the wait, not the timeout")

        await manual.finish(.success(9))
        let loaded = try await within(10) { try await load.value(waitingUpTo: nil) }
        XCTAssertEqual(loaded, 9, "the shared attempt was not cancelled")
        XCTAssertEqual(manual.starts, 1)
    }
}

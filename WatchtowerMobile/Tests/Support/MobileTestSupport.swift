import Foundation
import Observation
import WatchtowerSync
import XCTest

/// Counts how often an `@Observable` property is SET (a set notifies its
/// observers even when the value is equal), re-arming the tracking after
/// each notification.
@MainActor
final class ObservedSetCounter {
    private(set) var count = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        arm()
    }

    private func arm() {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                self?.count += 1
                self?.arm()
            }
        }
    }
}

/// Collects every value an async sequence publishes, so a test waits for
/// them with a bounded `poll` instead of an unbounded `next()`.
@MainActor
final class PublishedValues<Value: Sendable> {
    private(set) var values: [Value] = []
    private(set) var failure: (any Error)?
    private var task: Task<Void, Never>?

    init<S: AsyncSequence & Sendable>(_ sequence: S) where S.Element == Value {
        task = Task { [weak self] in
            do {
                for try await value in sequence {
                    self?.values.append(value)
                }
            } catch {
                self?.failure = error
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// A fetch-loop sleeper the test steps by hand: each sleep records its
/// interval and waits for `tick()`; a cancelled sleep throws at once.
@MainActor
final class TickSleeper {
    private(set) var requested: [Duration] = []
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]

    var waitingCount: Int { waiting.count }

    func sleep(_ interval: Duration) async throws {
        requested.append(interval)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                MainActor.assumeIsolated { park(id, continuation) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(id) }
        }
    }

    private func park(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiting[id] = continuation
        }
    }

    /// Ends every sleep waiting now.
    func tick() {
        let all = waiting
        waiting = [:]
        all.values.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

extension XCTestCase {
    /// A pool-backed replica on a throwaway temp path: the production
    /// mechanism (`DatabasePool` + WAL) the app's observations run against.
    func makePoolStore() throws -> ReplicaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-replica-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path)
    }

    /// A throwaway replica path whose directory is removed on teardown.
    func makeReplicaPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("replica.sqlite").path
    }

    /// A private UserDefaults suite, wiped on teardown.
    func makeDefaults() throws -> UserDefaults {
        let name = "mobile-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// Polls the main run loop until `condition` holds or the timeout
    /// elapses: the environment's bootstrap and the observations deliver
    /// asynchronously, so tests must yield to let them land.
    @MainActor
    func poll(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        _ message: @autoclosure () -> String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }
}

import Foundation
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

// MARK: - Gates

/// Suspends `wait()` callers until `release()` is called, then lets every
/// subsequent `wait()` (including ones that arrive after release) return
/// immediately — lets a test control exactly when an async fake (an
/// `engineFactory`, a CLI runner, a mic start) resolves relative to other
/// actions it wants to interleave first (e.g. `cancel()`, `pause()`,
/// `meetingCaptureWillStart()`).
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let toResume = waiters
        waiters = []
        lock.unlock()
        toResume.forEach { $0.resume() }
    }
}

/// A `CLIRunnerProtocol` that suspends `run` on an `AsyncGate` before
/// returning its canned stdout — lets a test hold a dictation in `.cleaning`
/// while it interleaves other actions (the P2 handoff tests).
final class GatedCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let gate: AsyncGate
    private let stdoutData: Data

    init(gate: AsyncGate, stdout: Data) {
        self.gate = gate
        self.stdoutData = stdout
    }

    func run(args: [String]) async throws -> Data {
        await gate.wait()
        return stdoutData
    }
}

// MARK: - Fakes

/// Scriptable `MicRecording`. `start` never touches real hardware; a test
/// drives the stream directly with `emit`/`stop` (the `FakeRecorder`
/// precedent, minus the file: `Tests/Helpers/MeetingRecorderTestSupport.swift:11-49`).
final class FakeMicRecorder: MicRecording, @unchecked Sendable {
    var startError: Error?
    /// Settable: a test simulates "capture silently broke mid-stream" by
    /// setting this before finishing the (empty) stream.
    var lastError: Error?
    /// Awaited inside `start()` before it returns — lets a test suspend the
    /// mic startup (the real recorder's `await requestAccess()`) so it can
    /// interleave a `stop()` while the start is still in flight.
    var onStart: (() async -> Void)?

    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var pausedStates: [Bool] = []
    /// Ordering log for the start/stop race tests: `start()` brackets itself
    /// with "start-begin"/"start-end"; `stop()` records "stop" while a start
    /// is still in flight and "stop-after-start" once one has completed —
    /// the assertable proxy for "the engine that came hot was stopped again".
    private(set) var events: [String] = []
    private var paused = false

    private var continuation: AsyncStream<[Float]>.Continuation!
    let samples: AsyncStream<[Float]>

    init() {
        var c: AsyncStream<[Float]>.Continuation!
        samples = AsyncStream { c = $0 }
        continuation = c
    }

    /// Emit one chunk of samples (test drives the stream with this).
    /// Dropped while paused, mirroring `MicRecorder`'s gate.
    func emit(_ samples: [Float]) {
        guard !paused else { return }
        continuation.yield(samples)
    }

    func setPaused(_ paused: Bool) {
        pausedStates.append(paused)
        self.paused = paused
    }

    func start() async throws {
        startCalls += 1
        events.append("start-begin")
        if let onStart { await onStart() }
        events.append("start-end")
        if let startError { throw startError }
    }

    func stop() {
        stopCalls += 1
        events.append(events.contains("start-end") ? "stop-after-start" : "stop")
        continuation.finish()
    }
}

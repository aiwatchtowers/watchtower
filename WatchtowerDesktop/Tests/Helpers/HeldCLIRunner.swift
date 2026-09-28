import Foundation
import WatchtowerCore

/// A `CLIRunnerProtocol` that holds every `run` open until the test releases
/// it, recording each invocation and signalling when the first one has
/// started — lets a test park a long CLI call "in flight", navigate away and
/// back (re-read the AppState-owned VM), and prove a second click starts no
/// parallel run. Built on `AsyncGate` (DictationTestSupport.swift), so the
/// ordering is deterministic, never timer-based.
final class HeldCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    /// Released once the first `run` has been entered.
    let started = AsyncGate()
    private let finish = AsyncGate()
    private let stdoutData: Data
    private let error: Error?
    private let lock = NSLock()
    private var recorded: [[String]] = []

    init(stdout: Data = Data(), error: Error? = nil) {
        self.stdoutData = stdout
        self.error = error
    }

    var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Lets every held (and future) `run` return.
    func release() {
        finish.release()
    }

    func run(args: [String]) async throws -> Data {
        lock.lock()
        recorded.append(args)
        lock.unlock()
        started.release()
        await finish.wait()
        if let error { throw error }
        return stdoutData
    }
}

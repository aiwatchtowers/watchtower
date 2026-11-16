import Foundation
import XCTest
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

    /// The texts that ride stdin (`--text-file -`, `validate -`, #604 S6)
    /// change nothing here.
    func run(args: [String], stdin _: Data) async throws -> Data {
        try await run(args: args)
    }

    func run(args: [String]) async throws -> Data {
        lock.withLock { recorded.append(args) }
        started.release()
        await finish.wait()
        if let error { throw error }
        return stdoutData
    }
}

extension XCTestCase {
    /// Waits for `cli`'s first `run` to begin — the runner's own signal, no
    /// clock and no deadline (a regression that skips the CLI call is a hang
    /// the lane watchdog reports).
    @MainActor
    func awaitStarted(_ cli: HeldCLIRunner) async {
        await cli.started.wait()
    }
}

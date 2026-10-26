import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// A scripted `SessionCleanupStreaming` double: each call is a `Run` whose
/// stdout lines and exit the test feeds by hand. `stop` is only recorded —
/// the run's lines can still be sent after it, as a late line of a stopped
/// process would arrive.
final class ScriptedCleanupStreamer: SessionCleanupStreaming, @unchecked Sendable {
    final class Run: @unchecked Sendable {
        let args: [String]
        let environment: [String: String]
        let lines: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        private let lock = NSLock()
        private var exit: SessionCleanupStream.Exit?
        private var waiters: [CheckedContinuation<SessionCleanupStream.Exit, Never>] = []
        private var stops = 0

        init(args: [String], environment: [String: String]) {
            self.args = args
            self.environment = environment
            (lines, continuation) = AsyncStream.makeStream(of: String.self)
        }

        var stopCount: Int { lock.withLock { stops } }

        func send(_ line: String) {
            continuation.yield(line)
        }

        /// Ends stdout and exits with `status`; idempotent.
        func finish(status: Int32 = 0, message: String = "") {
            continuation.finish()
            let woken: [CheckedContinuation<SessionCleanupStream.Exit, Never>] = lock.withLock {
                guard exit == nil else { return [] }
                exit = SessionCleanupStream.Exit(status: status, message: message)
                defer { waiters = [] }
                return waiters
            }
            let value = lock.withLock { exit } ?? SessionCleanupStream.Exit(status: status, message: message)
            woken.forEach { $0.resume(returning: value) }
        }

        fileprivate func stream() -> SessionCleanupStream {
            SessionCleanupStream(
                lines: lines,
                exit: { [self] in await waitForExit() },
                stop: { [self] in lock.withLock { stops += 1 } }
            )
        }

        private func waitForExit() async -> SessionCleanupStream.Exit {
            await withCheckedContinuation { waiter in
                let ready: SessionCleanupStream.Exit? = lock.withLock {
                    if let exit { return exit }
                    waiters.append(waiter)
                    return nil
                }
                if let ready { waiter.resume(returning: ready) }
            }
        }
    }

    private let lock = NSLock()
    private var started: [Run] = []

    var runs: [Run] { lock.withLock { started } }

    func streamCleanup(args: [String], environment: [String: String]) throws -> SessionCleanupStream {
        let run = Run(args: args, environment: environment)
        lock.withLock { started.append(run) }
        return run.stream()
    }

    /// Ends every run (tearDown): no task stays parked on an exit.
    func finishAll() {
        runs.forEach { $0.finish(status: 1, message: "torn down") }
    }
}

/// Stream lines as `workbench cleanup --json --stream` prints them
/// (spec 2026-10-26-worktree-cleanup-screen §6), on fixture paths.
enum CleanupStreamFixture {
    static let wtA = "worktree:/tmp/example/acme/.claude/worktrees/a"
    static let wtB = "worktree:/tmp/example/acme/.claude/worktrees/b"
    static let branchA = "branch:feat/a"

    static let listed = """
    {"event":"listed","items":[
     {"key":"\(wtA)","kind":"worktree","name":"a","branch":"feat/a"},
     {"key":"\(wtB)","kind":"worktree","name":"b","branch":"feat/b"},
     {"key":"\(branchA)","kind":"branch","name":"feat/a"}]}
    """.replacingOccurrences(of: "\n", with: "")

    static func checked(_ key: String, kind: String = "worktree", action: String = "remove", reason: String = "") -> String {
        #"{"event":"checked","item":{"key":"\#(key)","kind":"\#(kind)","name":"n","action":"\#(action)","reason":"\#(reason)"}}"#
    }

    static func sized(_ key: String, bytes: Int64) -> String {
        #"{"event":"sized","key":"\#(key)","bytes":\#(bytes),"bytes_known":true}"#
    }

    static func removing(_ key: String) -> String {
        #"{"event":"removing","key":"\#(key)"}"#
    }

    static func removed(_ key: String, kind: String = "worktree", done: Bool, reason: String = "") -> String {
        let action = done ? "remove" : "keep"
        return #"{"event":"removed","item":{"key":"\#(key)","kind":"\#(kind)","action":"\#(action)","done":\#(done),"reason":"\#(reason)"}}"#
    }

    /// `done` with a plan of `wtA` (remove, 2 GB) and `branchA` (keep).
    static let donePlan = """
    {"event":"done","plan":{"mode":"plan","sweep":true,"workbench_id":2,"items":[
     {"key":"\(wtA)","kind":"worktree","name":"a","branch":"feat/a","bytes":2000000000,"bytes_known":true,"action":"remove"},
     {"key":"\(branchA)","kind":"branch","name":"feat/a","action":"keep","reason":"checked_out"}]}}
    """.replacingOccurrences(of: "\n", with: "")

    /// `done` with a plan removing each `(key, kind)`.
    static func donePlanOf(_ items: [(key: String, kind: String)]) -> String {
        let json = items.map { #"{"key":"\#($0.key)","kind":"\#($0.kind)","action":"remove"}"# }.joined(separator: ",")
        return #"{"event":"done","plan":{"mode":"plan","items":[\#(json)]}}"#
    }

    static func doneApply(_ items: String = "") -> String {
        #"{"event":"done","plan":{"mode":"apply","sweep":true,"workbench_id":2,"items":[\#(items)],"summary":"ok"}}"#
    }
}

@MainActor
func waitUntil(
    _ what: String = "condition",
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            return XCTFail("timed out waiting for \(what)", file: file, line: line)
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

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

        /// `ignoresCancellation`: the lines go through a channel whose
        /// reads ignore the reader's cancellation, as a pipe read already
        /// under way would — so a line sent after a stop is really read.
        init(args: [String], environment: [String: String], ignoresCancellation: Bool) {
            self.args = args
            self.environment = environment
            let (source, continuation) = AsyncStream.makeStream(of: String.self)
            self.continuation = continuation
            if ignoresCancellation {
                let channel = UncancellableLines(source)
                lines = AsyncStream { await channel.next() }
            } else {
                lines = source
            }
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
    /// See `Run.init`.
    var ignoresCancellation = false

    var runs: [Run] { lock.withLock { started } }

    func streamCleanup(args: [String], environment: [String: String]) throws -> SessionCleanupStream {
        let run = Run(args: args, environment: environment, ignoresCancellation: ignoresCancellation)
        lock.withLock { started.append(run) }
        return run.stream()
    }

    /// Ends every run (tearDown): no task stays parked on an exit.
    func finishAll() {
        runs.forEach { $0.finish(status: 1, message: "torn down") }
    }
}

/// Reads `source` in a task of its own: a caller cancelled while it waits
/// still gets the next line.
private final class UncancellableLines: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var ended = false
    private var waiter: CheckedContinuation<String?, Never>?

    init(_ source: AsyncStream<String>) {
        Task.detached { [self] in
            for await line in source { deliver(line) }
            deliver(nil)
        }
    }

    private func deliver(_ line: String?) {
        let resume: CheckedContinuation<String?, Never>? = lock.withLock {
            if let waiting = waiter {
                waiter = nil
                if line == nil { ended = true }
                return waiting
            }
            if let line { buffer.append(line) } else { ended = true }
            return nil
        }
        resume?.resume(returning: line)
    }

    func next() async -> String? {
        await withCheckedContinuation { continuation in
            let ready: String?? = lock.withLock {
                if !buffer.isEmpty { return .some(buffer.removeFirst()) }
                if ended { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
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

/// A `SessionCleanupStreaming` double shaped like `FakeSessionCleanupRunner`:
/// each streamed run answers from `replies` in order (the last one repeats)
/// with one `done` line of the reply's plan, or exits 1 with the error's
/// text; it can hold its answer until `release()`. A run the center stopped
/// (a cancelled plan) counts in `cancelledCount` and still answers once
/// released — the center drops what a stopped run says.
final class RepliedCleanupStreamer: SessionCleanupStreaming, @unchecked Sendable {
    /// When true, each run waits for `release()` before it answers.
    var holdsCalls = false

    private let scripted = ScriptedCleanupStreamer()
    private let lock = NSLock()
    private var replies: [Result<Data, Error>]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var tornDown = false

    init(replies: [Result<Data, Error>]) {
        self.replies = replies
    }

    var runs: [ScriptedCleanupStreamer.Run] { scripted.runs }
    /// The runs as `FakeSessionCleanupRunner.calls` reads: `args`, `environment`.
    var calls: [ScriptedCleanupStreamer.Run] { runs }
    var heldCount: Int { lock.withLock { held.count } }
    /// The runs the center stopped.
    var cancelledCount: Int { runs.filter { $0.stopCount > 0 }.count }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func streamCleanup(args: [String], environment: [String: String]) throws -> SessionCleanupStream {
        let stream = try scripted.streamCleanup(args: args, environment: environment)
        guard let run = scripted.runs.last else { return stream }
        let (reply, holds) = lock.withLock { () -> (Result<Data, Error>, Bool) in
            let next = replies.count > 1 ? replies.removeFirst() : replies.first ?? .success(Data("{}".utf8))
            return (next, holdsCalls)
        }
        Task.detached { [self] in
            if holds {
                await withCheckedContinuation { continuation in
                    let resume: Bool = lock.withLock {
                        if tornDown { return true }
                        held.append(continuation)
                        return false
                    }
                    if resume { continuation.resume() }
                }
            }
            switch reply {
            case let .success(data):
                run.send(Self.doneLine(data))
                run.finish()
            case let .failure(error):
                run.finish(status: 1, message: error.localizedDescription)
            }
        }
        return stream
    }

    /// Ends every run and every held answer (tearDown).
    func finishAll() {
        lock.withLock { tornDown = true }
        release()
        scripted.finishAll()
    }

    private static func doneLine(_ plan: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: plan)) ?? [:]
        let compact = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return #"{"event":"done","plan":"# + (String(bytes: compact, encoding: .utf8) ?? "{}") + "}"
    }
}

import Foundation
import WatchtowerCore

/// Test double for `CLILineStreaming`. A one-shot `lines(args:stdin:)` call
/// answers from `replies` (FIFO) when one is queued; otherwise it — like every
/// `session(args:)` — opens a `FakeCLILineSession` the test drives
/// (`emit`, `exit`). Every call's args and stdin are recorded.
package final class FakeCLILineStream: CLILineStreaming, @unchecked Sendable {
    /// A scripted run: these stdout lines, then this exit code.
    package struct Reply: Sendable {
        package let lines: [String]
        package let exitCode: Int32
        package let stderr: String

        package init(lines: [String], exitCode: Int32 = 0, stderr: String = "") {
            self.lines = lines
            self.exitCode = exitCode
            self.stderr = stderr
        }
    }

    package struct Invocation: Sendable {
        package let args: [String]
        /// What the call wrote to stdin (one-shot: the `stdin` argument; a
        /// session: its writes so far are on the session).
        package let stdin: Data?
    }

    private let lock = NSLock()
    private var queued: [Reply] = []
    private var recorded: [Invocation] = []
    private var opened: [FakeCLILineSession] = []
    /// Fires after every recorded call and every session change.
    package let signal = StateSignal()

    /// Strict: an unscripted one-shot call never opens a session (which a
    /// test would have to end, or it waits forever). It ends at once with
    /// `nonZeroExit(127)` and reports itself through `onUnscripted`, which a
    /// test sets to `XCTFail`. Sessions (`session(args:)`) are unaffected.
    private let strict: Bool
    package var onUnscripted: (@Sendable ([String]) -> Void)?

    package init(replies: [Reply] = [], strict: Bool = false) {
        queued = replies
        self.strict = strict
    }

    package func enqueue(_ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        queued.append(reply)
    }

    package var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Every session opened, in order.
    package var sessions: [FakeCLILineSession] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    /// Returns once at least `count` sessions were opened; the last one.
    package func session(number count: Int) async -> FakeCLILineSession {
        await signal.until { [self] in sessions.count >= count }
        return sessions[count - 1]
    }

    package func lines(args: [String], stdin: Data?) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(Invocation(args: args, stdin: stdin))
        let reply = queued.isEmpty ? nil : queued.removeFirst()
        lock.unlock()
        if reply == nil, strict {
            onUnscripted?(args)
            signal.changed()
            let (stream, sink) = AsyncThrowingStream.makeStream(of: String.self)
            sink.finish(throwing: CLIRunnerError.nonZeroExit(code: 127, stderr: "unscripted call: \(args.joined(separator: " "))"))
            return stream
        }
        guard let reply else {
            let session = open(args: args, record: false)
            if let stdin { session.write(stdin) }
            session.closeInput()
            return session.lines
        }
        signal.changed()
        let (stream, sink) = AsyncThrowingStream.makeStream(of: String.self)
        reply.lines.forEach { sink.yield($0) }
        if reply.exitCode == 0 {
            sink.finish()
        } else {
            sink.finish(throwing: CLIRunnerError.nonZeroExit(code: reply.exitCode, stderr: reply.stderr))
        }
        return stream
    }

    package func session(args: [String]) -> any CLILineSession {
        open(args: args, record: true)
    }

    private func open(args: [String], record: Bool) -> FakeCLILineSession {
        let session = FakeCLILineSession(args: args, signal: signal)
        lock.lock()
        if record { recorded.append(Invocation(args: args, stdin: nil)) }
        opened.append(session)
        lock.unlock()
        signal.changed()
        return session
    }
}

/// A fake child: the test writes its stdout (`emit`) and ends it (`exit`);
/// what the code under test writes to stdin is recorded.
package final class FakeCLILineSession: CLILineSession, @unchecked Sendable {
    package let args: [String]
    package let lines: AsyncThrowingStream<String, Error>
    private let sink: AsyncThrowingStream<String, Error>.Continuation
    private let signal: StateSignal
    private let lock = NSLock()
    private var written: [Data] = []
    private var inputClosedFlag = false
    private var terminatedFlag = false
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(args: [String], signal: StateSignal) {
        self.args = args
        self.signal = signal
        (lines, sink) = AsyncThrowingStream.makeStream(of: String.self)
    }

    /// What was written to stdin, in order.
    package var writes: [Data] {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    /// The stdin writes as text lines.
    package var writtenLines: [String] {
        writes.flatMap { (String(bytes: $0, encoding: .utf8) ?? "").split(separator: "\n").map(String.init) }
    }

    package var inputClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return inputClosedFlag
    }

    package var terminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminatedFlag
    }

    /// The child writes one stdout line.
    package func emit(_ line: String) {
        sink.yield(line)
    }

    /// The child exits: 0 finishes the stream, any other code throws.
    package func exit(code: Int32 = 0) {
        if code == 0 {
            sink.finish()
        } else {
            sink.finish(throwing: CLIRunnerError.nonZeroExit(code: code, stderr: ""))
        }
        markExited()
    }

    package func write(_ data: Data) {
        lock.lock()
        if !inputClosedFlag { written.append(data) }
        lock.unlock()
        signal.changed()
    }

    package func closeInput() {
        lock.lock()
        inputClosedFlag = true
        lock.unlock()
        signal.changed()
    }

    package func terminate() {
        lock.lock()
        terminatedFlag = true
        lock.unlock()
        exit(code: 0)
    }

    package func waitForExit() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited {
                lock.unlock()
                waiter.resume()
            } else {
                exitWaiters.append(waiter)
                lock.unlock()
            }
        }
    }

    private func markExited() {
        lock.lock()
        exited = true
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
        signal.changed()
    }
}

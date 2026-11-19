import XCTest
@testable import WatchtowerCore

/// `stopDaemonBounded` is the one daemon stop both the quit path and the
/// launch-time CLI-store sync depend on, so its bound is the contract: it must
/// return, and it must not leave the child it spawned behind.
final class DaemonManagerStopTests: XCTestCase {
    private var scriptPath: String!
    private var pidFile: String!

    override func tearDownWithError() throws {
        if let scriptPath { try? FileManager.default.removeItem(atPath: scriptPath) }
        if let pidFile { try? FileManager.default.removeItem(atPath: pidFile) }
    }

    /// Writes an executable shell script. `exec` matters on the hung script:
    /// `sh` does not forward SIGTERM to a child, so without it `terminate()`
    /// would kill the shell and orphan the sleeper.
    private func makeScript(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-stop-\(UUID().uuidString).sh").path
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        scriptPath = path
        return path
    }

    func testHungSubprocessIsBoundedAndLeavesNoChildBehind() async throws {
        let fifo = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-stop-pid-\(UUID().uuidString)").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        pidFile = fifo
        // `$$` survives the exec, so the recorded pid IS the sleeping process.
        // Writing to the fifo blocks until the test reads it: the pid is in
        // hand before the watchdog runs out, on any machine load.
        let script = try makeScript("echo $$ > \(fifo)\nexec sleep 100")
        // The timeout runs out once the child has reported its pid; the
        // SIGTERM grace never does.
        let clock = WatchdogClock(timeoutAfterReading: fifo)

        await DaemonManager.stopDaemonBounded(timeout: .seconds(2), cliPath: script, sleep: clock.sleep)

        // Returning at all proves the bound: the child would run for 100 s,
        // and only the watchdog's timeout running out could release us.
        XCTAssertEqual(clock.durations, [.seconds(2), .milliseconds(250)], "timeout, then the SIGTERM grace")
        let recorded = clock.read.trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(recorded))
        XCTAssertNotEqual(kill(pid, 0), 0, "the terminated child must be gone, not left running")
    }

    /// The degenerate arm of the same loop: a `sync stop` that finishes
    /// immediately must be awaited for as long as it actually takes, not for
    /// the watchdog's timeout.
    func testFastExitReturnsWellBeforeTheTimeout() async throws {
        let script = try makeScript("exit 0")
        let clock = WatchdogClock() // the timeout never runs out

        await DaemonManager.stopDaemonBounded(timeout: .seconds(12), cliPath: script, sleep: clock.sleep)

        // The timeout never ran out, so only the child's exit released us;
        // no SIGTERM grace was waited.
        XCTAssertTrue(clock.durations.allSatisfy { $0 == .seconds(12) }, "\(clock.durations)")
        XCTAssertLessThanOrEqual(clock.durations.count, 1, "a prompt stop must not wait out the watchdog")
    }

    /// No CLI resolved (dev run without the binary): nothing to spawn, nothing
    /// to wait for.
    func testMissingCLIPathIsANoOp() async {
        let clock = WatchdogClock()
        await DaemonManager.stopDaemonBounded(timeout: .seconds(12), cliPath: nil, sleep: clock.sleep)
        XCTAssertEqual(clock.durations, [], "nothing waited")
    }
}

/// The watchdog's `sleep` seam, no real time involved. With a fifo, the
/// first wait (the timeout) reads it to its end and then runs out; every
/// other wait never runs out and returns only when the race cancels it.
private final class WatchdogClock: @unchecked Sendable {
    private let lock = NSLock()
    private let fifo: String?
    private var recorded: [Duration] = []
    private var fifoText = ""

    init(timeoutAfterReading fifo: String? = nil) {
        self.fifo = fifo
    }

    var durations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// What the child wrote to the fifo.
    var read: String {
        lock.lock()
        defer { lock.unlock() }
        return fifoText
    }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in
            lock.lock()
            recorded.append(duration)
            let first = recorded.count == 1
            lock.unlock()
            if first, let fifo {
                let text = await Self.readToEnd(fifo)
                lock.lock()
                fifoText = text
                lock.unlock()
                return
            }
            await Self.untilCancelled()
        }
    }

    /// Suspends until the task is cancelled.
    private static func untilCancelled() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        for await _ in stream {}
        continuation.finish()
    }

    /// Reads `fifo` to its end on a thread of its own: opening it blocks until
    /// the child opens it for writing, and that must not hold a pool thread.
    private static func readToEnd(_ fifo: String) async -> String {
        await withCheckedContinuation { continuation in
            Thread {
                let data = FileHandle(forReadingAtPath: fifo)?.readDataToEndOfFile() ?? Data()
                continuation.resume(returning: String(bytes: data, encoding: .utf8) ?? "")
            }.start()
        }
    }
}

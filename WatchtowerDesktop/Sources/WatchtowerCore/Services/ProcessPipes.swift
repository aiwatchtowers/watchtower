import Foundation
import os

// MARK: - ProcessOutput

/// A finished child process: its exit status plus both output streams decoded
/// as UTF-8, untrimmed. A launch failure is exit `-1` with the launch error's
/// description as `stderr` — the shape every ad-hoc wrapper already returned.
package struct ProcessOutput: Sendable {
    package let exitCode: Int32
    package let stdout: String
    package let stderr: String

    /// Both streams trimmed of surrounding whitespace, as the tuple the ad-hoc
    /// wrappers hand their callers.
    package var trimmed: (exitCode: Int32, stdout: String, stderr: String) {
        (
            exitCode,
            stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - ProcessPipes

/// The one place the ad-hoc `Process` wrappers drain a child's output.
///
/// SB3 (see `ProcessCLIRunner.run`): stdout and stderr MUST be drained
/// concurrently. A child that writes more than the 64 KiB pipe buffer to
/// stderr before it closes stdout blocks on that write until someone reads
/// stderr; a parent parked on stdout EOF — or on `waitUntilExit` — first
/// never gets there, and both sides wait forever.
///
/// Every blocking call (a read to EOF, the stdin write, `waitUntilExit`) runs
/// on a thread of its own, never on a Swift-concurrency pool thread: the pool
/// is as wide as the CPU count and does not grow when a thread blocks, so a
/// few concurrent children (parallel tests on a 3-core CI runner) parked
/// every pool thread in a read whose other pipe nobody could drain any more —
/// a deadlock that also starves any `Task.sleep` deadline. Not a GCD global
/// queue either: those share the same CPU-wide thread budget.
package enum ProcessPipes {
    /// Starts reading `pipe` to EOF at once, on its own thread. Call it right
    /// after `Process.run()` for any stream the caller does not read itself,
    /// and await the task's value once the stream it does read is done.
    package static func drain(_ pipe: Pipe) -> Task<Data, Never> {
        let handle = pipe.fileHandleForReading
        let read = BlockingCall { handle.readDataToEndOfFile() }
        return Task { await read.value }
    }

    /// Runs blocking `work` on its own thread and awaits its result, leaving
    /// the Swift-concurrency pool free meanwhile.
    package static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await BlockingCall(work).value
    }

    /// Attaches fresh stdout/stderr pipes to a pre-configured `process`,
    /// launches it, drains both streams concurrently and waits for exit. The
    /// wait itself runs on a detached task, so no caller's actor is blocked.
    ///
    /// If `stdin` is given, `process.standardInput` must already be a `Pipe`:
    /// the string is written to it and the pipe closed (how secrets reach a
    /// child without touching argv). The write happens after both drains have
    /// started, so a child that answers before reading all of its input
    /// cannot wedge the write.
    ///
    /// `onLaunch` runs synchronously right after a successful launch: a
    /// caller whose Cancel may land before the child is running (when
    /// `terminate()` is not allowed yet) re-checks its cancel flag there.
    package static func run(
        _ process: Process,
        stdin: String? = nil,
        onLaunch: (@Sendable (Process) -> Void)? = nil
    ) async -> ProcessOutput {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessOutput(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
        onLaunch?(process)

        let stdoutRead = drain(stdoutPipe)
        let stderrRead = drain(stderrPipe)

        if let stdin, let inputPipe = process.standardInput as? Pipe {
            // Not awaited: the child may answer before reading its input. A
            // child that exits unread must not SIGPIPE the app, and a failed
            // write is logged — the child's exit code tells the caller.
            let writer = inputPipe.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            let data = Data(stdin.utf8)
            Thread.detachNewThread {
                do {
                    try writer.write(contentsOf: data)
                } catch {
                    NSLog("[ProcessPipes] writing the child's stdin failed: %@", String(describing: error))
                }
                try? writer.close()
            }
        }

        let stdoutData = await stdoutRead.value
        let stderrData = await stderrRead.value
        await offPool { process.waitUntilExit() }

        return ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// `run` under a watchdog, for a child that may hang (a provider CLI's
    /// version skew): once `timeout` passes it is terminated (SIGTERM) and
    /// `timedOut` says so, so the caller can tell a hang from a failure.
    package static func run(
        _ process: Process,
        timeout: Duration
    ) async -> (output: ProcessOutput, timedOut: Bool) {
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        let output = await run(process)
        watchdog.cancel()
        return (output, timedOut.withLock { $0 })
    }
}

// MARK: - BlockingCall

/// One blocking call started on a thread of its own the moment it is
/// created; its result is awaited without holding a Swift-concurrency pool
/// thread.
private final class BlockingCall<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T?
    private var waiter: CheckedContinuation<T, Never>?

    init(_ work: @escaping @Sendable () -> T) {
        Thread.detachNewThread { self.finish(work()) }
    }

    /// Awaited once (one waiter is kept).
    var value: T {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                precondition(waiter == nil, "BlockingCall awaited twice")
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private func finish(_ value: T) {
        lock.lock()
        result = value
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }
}

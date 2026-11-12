import Foundation
import os
@testable import WatchtowerCore
import XCTest

/// `ProcessCompactionCLI` over a real child: a `/bin/sh` stub stands in for
/// the `watchtower` binary. Stubs that run on write their pid (`$$`) into
/// the `pidFile` FIFO once their traps are set, which the test reads — no
/// clock, the write is the event; tearDown SIGKILLs any stub that is left.
final class ProcessCompactionCLITests: XCTestCase {
    private var directory: URL?
    private var child: (any CompactionChild)?
    /// The pid the stub reported through `pidFile`.
    private var startedPID: pid_t?

    override func tearDown() async throws {
        // A child the test left running is killed and reaped.
        if let child {
            child.kill()
            _ = await child.waitForExit()
        }
        // A stub the test could not reap through a child handle (a `--check`
        // stub after a failed assertion) is killed by pid.
        if let pid = startedPID, Darwin.kill(pid, 0) == 0 {
            Darwin.kill(pid, SIGKILL)
        }
        // A background sleep a stub's trap did not end.
        if let text = try? String(contentsOfFile: sleepPIDFilePath, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), Darwin.kill(pid, 0) == 0 {
            Darwin.kill(pid, SIGKILL)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - startCompact

    /// A preamble line before the JSON and a non-zero exit (2: disk) come
    /// through as the exit status and a decodable last line.
    func testStartCompactReadsResultAfterPreambleAndExitStatus() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        echo "schema format upgraded"
        echo '{"compacted":false,"skipped":"disk"}'
        exit 2
        """)
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact { _ in }
        self.child = child

        let exit = await child.waitForExit()
        XCTAssertEqual(exit.status, 2)
        XCTAssertEqual(exit.reason, .exit)
        let output = try decodeLastJSONLine(CompactionRunOutput.self, from: exit.stdout)
        XCTAssertFalse(output.compacted)
        XCTAssertEqual(output.skipped, "disk")
    }

    /// Phase lines reach `onPhase` while the child still runs, in order; the
    /// result stays the last stdout line. The stub prints the second phase
    /// only once the test writes a line into the `goFilePath` FIFO.
    func testStartCompactReportsPhaseLinesAsTheyArrive() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        echo '{"phase":"fts_rebuild"}'
        read go < "\(goFilePath)"
        echo '{"phase":"compact"}'
        echo '{"compacted":true,"fts_rebuilt":true}'
        """)
        XCTAssertEqual(mkfifo(goFilePath, 0o600), 0)
        let phases = OSAllocatedUnfairLock<[CompactionRunPhase]>(initialState: [])
        let (arrived, arrival) = AsyncStream<Void>.makeStream()
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact { phase in
            phases.withLock { $0.append(phase) }
            arrival.yield()
        }
        self.child = child

        var arrivals = arrived.makeAsyncIterator()
        _ = await arrivals.next()
        XCTAssertEqual(phases.withLock { $0 }, [.ftsRebuild], "the first line arrives while the stub waits")
        let go = goFilePath
        // Opening a FIFO for writing blocks until the stub opens it to read.
        await Task.detached { FileHandle(forWritingAtPath: go)?.write(Data("go\n".utf8)) }.value

        let exit = await child.waitForExit()
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(phases.withLock { $0 }, [.ftsRebuild, .compact])
        let output = try decodeLastJSONLine(CompactionRunOutput.self, from: exit.stdout)
        XCTAssertTrue(output.compacted)
        XCTAssertTrue(output.ftsRebuilt)
    }

    /// SIGTERM reaches the child's handler: the CLI's interrupt path exits 4.
    func testTerminateEndsCompactWithItsTrapStatus() async throws {
        // `wait` returns at once on a trapped signal; the trap ends the sleep
        // too. The sleep holds none of the child's pipes: a sleep the trap
        // missed must not keep `waitForExit` from seeing the stub's end (it
        // did on a loaded machine); tearDown kills it by its recorded pid.
        let stub = try makeStub("""
        #!/bin/sh
        trap 'kill $! 2>/dev/null; exit 4' TERM
        sleep 3600 </dev/null >/dev/null 2>&1 &
        echo $! > "\(sleepPIDFilePath)"
        echo $$ > "\(pidFilePath)"
        wait $!
        """)
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact { _ in }
        self.child = child
        try await waitForStubPID()

        child.terminate()
        let exit = await child.waitForExit()
        XCTAssertEqual(exit.status, 4)
        XCTAssertEqual(exit.reason, .exit)
    }

    /// A child that ignores SIGTERM is ended by `kill()`, and `waitForExit`
    /// returns with the signal.
    func testKillReapsChildThatIgnoresTerminate() async throws {
        // An ignored SIGTERM stays ignored across `exec`: the sleep is the stub.
        let stub = try makeStub("""
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(pidFilePath)"
        exec sleep 3600
        """)
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact { _ in }
        self.child = child
        let pid = try await waitForStubPID()

        // `terminate()` sends SIGTERM synchronously, and an ignored signal is
        // dropped when it is sent: nothing is left to wait for.
        child.terminate()
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "the stub ignores SIGTERM")
        child.kill()
        let exit = await child.waitForExit()
        XCTAssertEqual(exit.reason, .uncaughtSignal)
        XCTAssertEqual(exit.status, SIGKILL)
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "the stub is gone")
    }

    // MARK: - check

    func testCheckDecodesLastLineAfterPreamble() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        echo "schema format upgraded"
        echo '{"due":true,"reason":"freelist","db_bytes":10,"wal_bytes":0,"free_disk_bytes":100,"needs_disk_bytes":20,"disk_ok":true}'
        """)
        let check = try await ProcessCompactionCLI(executablePath: stub).check()
        XCTAssertEqual(check, CompactionCheck(
            due: true, reason: "freelist", dbBytes: 10, walBytes: 0, freeDiskBytes: 100, needsDiskBytes: 20, diskOk: true
        ))
    }

    func testCheckNonZeroExitThrowsWithStderr() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        echo "database is locked" >&2
        exit 1
        """)
        do {
            _ = try await ProcessCompactionCLI(executablePath: stub).check()
            XCTFail("exit 1 must throw")
        } catch let ProcessCompactionCLI.Failure.exited(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("database is locked"), stderr)
        }
    }

    /// Cancelling the calling task (a quit during the check) ends the check
    /// with CancellationError — the stub would otherwise exit 0 with no
    /// result — and the child is gone.
    func testCancellingCheckTerminatesChild() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        echo $$ > "\(pidFilePath)"
        exec sleep 30
        """)
        let cli = ProcessCompactionCLI(executablePath: stub)
        let check = Task { try await cli.check() }
        let pid = try await waitForStubPID()

        check.cancel()
        do {
            _ = try await check.value
            XCTFail("a cancelled check must throw")
        } catch is CancellationError {
            // expected
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "the check's child is gone")
    }

    // MARK: - Helpers

    private var pidFilePath: String {
        directory?.appendingPathComponent("stub.pid").path ?? "/dev/null"
    }

    private var sleepPIDFilePath: String {
        directory?.appendingPathComponent("sleep.pid").path ?? "/dev/null"
    }

    private var goFilePath: String {
        directory?.appendingPathComponent("go").path ?? "/dev/null"
    }

    /// Reads the stub's pid out of the `pidFilePath` FIFO: the read blocks
    /// until the stub wrote it (its traps are set and it is running) — no
    /// deadline (`check()` resolves the login-shell environment first).
    @discardableResult
    private func waitForStubPID() async throws -> pid_t {
        let path = pidFilePath
        let data = await Task.detached { FileHandle(forReadingAtPath: path)?.readDataToEndOfFile() }.value
        let text = String(bytes: data ?? Data(), encoding: .utf8) ?? ""
        let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), "the stub's pid")
        startedPID = pid
        return pid
    }

    /// Creates the temp directory first so `pidFilePath` is valid inside
    /// `script`.
    private func makeStub(_ script: @autoclosure () -> String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessCompactionCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let stub = directory.appendingPathComponent("watchtower")
        let text = script()
        try text.write(to: stub, atomically: true, encoding: .utf8)
        if text.contains(pidFilePath) { XCTAssertEqual(mkfifo(pidFilePath, 0o600), 0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }
}

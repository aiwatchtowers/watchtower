import Foundation
@testable import WatchtowerCore
import XCTest

/// `ProcessCompactionCLI` over a real child: a `/bin/sh` stub stands in for
/// the `watchtower` binary. Stubs that run on write their pid (`$$`) to
/// `pidFile` once their traps are set; tearDown SIGKILLs any that is left.
final class ProcessCompactionCLITests: XCTestCase {
    private var directory: URL?
    private var child: (any CompactionChild)?

    override func tearDown() async throws {
        // A child the test left running is killed and reaped.
        if let child {
            child.kill()
            _ = await child.waitForExit()
        }
        // A stub the test could not reap through a child handle (a `--check`
        // stub after a failed assertion) is killed by pid.
        if let pid = stubPID(), Darwin.kill(pid, 0) == 0 {
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
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact()
        self.child = child

        let exit = await child.waitForExit()
        XCTAssertEqual(exit.status, 2)
        XCTAssertEqual(exit.reason, .exit)
        let output = try decodeLastJSONLine(CompactionRunOutput.self, from: exit.stdout)
        XCTAssertFalse(output.compacted)
        XCTAssertEqual(output.skipped, "disk")
    }

    /// SIGTERM reaches the child's handler: the CLI's interrupt path exits 4.
    func testTerminateEndsCompactWithItsTrapStatus() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        trap 'exit 4' TERM
        echo $$ > "\(pidFilePath)"
        while :; do sleep 0.05; done
        """)
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact()
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
        let stub = try makeStub("""
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(pidFilePath)"
        while :; do :; done
        """)
        let child = try ProcessCompactionCLI(executablePath: stub).startCompact()
        self.child = child
        let pid = try await waitForStubPID()

        child.terminate()
        try await Task.sleep(for: .milliseconds(200))
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
    /// with CancellationError well before the stub's 30 s, and the child is
    /// gone.
    func testCancellingCheckTerminatesChild() async throws {
        let stub = try makeStub("""
        #!/bin/sh
        echo $$ > "\(pidFilePath)"
        exec sleep 30
        """)
        let cli = ProcessCompactionCLI(executablePath: stub)
        let check = Task { try await cli.check() }
        let pid = try await waitForStubPID()

        let start = ContinuousClock.now
        check.cancel()
        do {
            _ = try await check.value
            XCTFail("a cancelled check must throw")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "the check's child is gone")
    }

    // MARK: - Helpers

    private var pidFilePath: String {
        directory?.appendingPathComponent("stub.pid").path ?? "/dev/null"
    }

    private func stubPID() -> pid_t? {
        guard let directory,
              let text = try? String(contentsOf: directory.appendingPathComponent("stub.pid"), encoding: .utf8)
        else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Waits (bounded, 20 s: `check()` resolves the login-shell environment
    /// first) until the stub has written its pid: its traps are set and it
    /// is running.
    @discardableResult
    private func waitForStubPID(file: StaticString = #filePath, line: UInt = #line) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let pid = stubPID() { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the stub never started", file: file, line: line)
        throw CancellationError()
    }

    /// Creates the temp directory first so `pidFilePath` is valid inside
    /// `script`.
    private func makeStub(_ script: @autoclosure () -> String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessCompactionCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let stub = directory.appendingPathComponent("watchtower")
        try script().write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }
}

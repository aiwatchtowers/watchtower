import Darwin
import XCTest
@testable import WatchtowerCore

/// The real `ProcessCLILineStream` over `/bin/sh` children. Every group a test
/// starts is killed in teardown, whatever the test's outcome.
final class CLILineStreamTests: XCTestCase {
    private var groups: [pid_t] = []

    override func tearDown() {
        // Groups a passing test confirmed gone were dropped; what is left is a
        // failing test's, killed here whatever its state.
        groups.forEach { _ = killpg($0, SIGKILL) }
        groups = []
        super.tearDown()
    }

    private let shell = ProcessCLILineStream(binaryPath: "/bin/sh") { ["PATH": "/usr/bin:/bin"] }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async -> (lines: [String], error: Error?) {
        var lines: [String] = []
        do {
            for try await line in stream { lines.append(line) }
            return (lines, nil)
        } catch {
            return (lines, error)
        }
    }

    func testLinesThenCleanExit() async {
        let result = await collect(shell.lines(args: ["-c", "echo one; printf 'two\\nthree'"], stdin: nil))
        XCTAssertEqual(result.lines, ["one", "two", "three"])
        XCTAssertNil(result.error)
    }

    func testStdinFedAndClosed() async {
        // `cat` ends only on EOF: the stream finishing proves stdin was closed.
        let result = await collect(shell.lines(args: ["-c", "cat"], stdin: Data("secret-token\nsecond\n".utf8)))
        XCTAssertEqual(result.lines, ["secret-token", "second"])
        XCTAssertNil(result.error)
    }

    func testStdinEOFWithoutInput() async {
        let result = await collect(shell.lines(args: ["-c", "cat; echo done"], stdin: nil))
        XCTAssertEqual(result.lines, ["done"])
    }

    func testNonZeroExitThrowsAfterLines() async {
        let result = await collect(shell.lines(args: ["-c", "echo partial; echo why >&2; exit 3"], stdin: nil))
        XCTAssertEqual(result.lines, ["partial"])
        guard case let .nonZeroExit(code, stderr)? = result.error as? CLIRunnerError else {
            return XCTFail("expected nonZeroExit, got \(String(describing: result.error))")
        }
        XCTAssertEqual(code, 3)
        XCTAssertEqual(stderr, "why")
    }

    func testLaunchFailureThrows() async {
        let missing = ProcessCLILineStream(binaryPath: "/nonexistent/watchtower") { [:] }
        let result = await collect(missing.lines(args: [], stdin: nil))
        guard case .launchFailed? = result.error as? CLIRunnerError else {
            return XCTFail("expected launchFailed, got \(String(describing: result.error))")
        }
    }

    func testSessionWritesInOrder() async {
        let session = shell.session(args: ["-c", "read a; echo got-$a; read b; echo got-$b"])
        session.write(Data("x\n".utf8))
        session.write(Data("y\n".utf8))
        let result = await collect(session.lines)
        XCTAssertEqual(result.lines, ["got-x", "got-y"])
    }

    func testCancelKillsProcessGroup() async throws {
        let session = shell.session(args: ["-c", "echo $$; sleep 1000 & echo $!; wait"])
        let pids = AsyncStream.makeStream(of: pid_t.self)
        let consumer = Task {
            for try await line in session.lines {
                if let pid = pid_t(line) { pids.continuation.yield(pid) }
            }
        }
        var iterator = pids.stream.makeAsyncIterator()
        let first = await iterator.next(), second = await iterator.next()
        let leader = try XCTUnwrap(first)
        groups.append(leader)
        let sleeper = try XCTUnwrap(second)
        XCTAssertTrue(Self.isRunning(sleeper))

        consumer.cancel()
        await session.waitForExit()

        // The stream ends only after stdout's EOF, which the sleeper (holding
        // the pipe) gives only once it has exited: both are gone, not running.
        XCTAssertFalse(Self.isRunning(leader))
        XCTAssertFalse(Self.isRunning(sleeper))
        forgetIfGone(leader, members: [leader, sleeper])
    }

    func testTerminateKillsProcessGroup() async throws {
        let session = shell.session(args: ["-c", "echo $$; sleep 1000 & wait"])
        var iterator = session.lines.makeAsyncIterator()
        let line = try await iterator.next()
        let leader = try XCTUnwrap(line.flatMap { pid_t($0) })
        groups.append(leader)
        session.terminate()
        await session.waitForExit()
        XCTAssertFalse(Self.isRunning(leader))
        // The stream ended on stdout's EOF: the sleeper holding it is gone too.
        forgetIfGone(leader, members: [leader])
    }

    func testFailedPipeClosesEarlierPipes() throws {
        var made: [Int32] = []
        var calls = 0
        struct NoPipe: Error {}
        XCTAssertThrowsError(try SpawnedChild.start(path: "/bin/sh", args: ["-c", "true"], environment: [:]) {
            calls += 1
            guard calls < 2 else { throw NoPipe() }
            let pair = try SpawnedChild.pipePair()
            made += [pair.read, pair.write]
            return pair
        })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(made.count, 2)
        for fd in made {
            XCTAssertEqual(fcntl(fd, F_GETFD), -1, "fd \(fd) still open")
            XCTAssertEqual(errno, EBADF)
        }
    }

    /// Drops `group` from teardown's kill list once none of its known members
    /// runs: its id may be recycled from here on.
    private func forgetIfGone(_ group: pid_t, members: [pid_t]) {
        guard !members.contains(where: Self.isRunning) else { return }
        groups.removeAll { $0 == group }
    }

    /// Alive and not a zombie (a zombie has exited; only its parent's reap is left).
    private static func isRunning(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) != SZOMB
    }
}

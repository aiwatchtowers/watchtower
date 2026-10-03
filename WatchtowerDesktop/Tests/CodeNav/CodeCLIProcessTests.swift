import Darwin
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// The code-navigation child process: utility QoS, its own process group
/// (a kill takes its children too), stderr kept, always reaped; and
/// `CodeSearchRun` on top of it (cancel = kill, no callback).
@MainActor
final class CodeCLIProcessTests: XCTestCase {
    private var stub: CodeCLIStub!

    override func setUp() async throws {
        stub = try CodeCLIStub()
    }

    override func tearDown() async throws {
        await stub.assertAllGroupsReaped()
        stub.remove()
    }

    private func shell(_ script: String) throws -> CodeCLIProcess {
        try CodeCLIProcess.launch(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"])
    }

    func testStdinStdoutStderrAndExitStatus() async throws {
        let process = try shell("read -r line; echo \"got $line\"; echo oops >&2; exit 3")
        process.sendLine("hello")
        var out = Data()
        for await chunk in process.output { out += chunk }
        let exit = await process.exitStatus
        XCTAssertEqual(String(bytes: out, encoding: .utf8), "got hello\n")
        XCTAssertEqual(exit, CodeCLIProcess.Exit(status: 3, signaled: false, stderr: "oops\n"))
        XCTAssertEqual(exit.failureMessage(command: "code index"), "oops")
    }

    /// A line sent after `closeInput` never reaches the child; the ones
    /// before it do, then EOF.
    func testALineSentAfterCloseIsDropped() async throws {
        let process = try shell("cat")
        process.sendLine("one")
        process.closeInput()
        process.sendLine("two")
        var out = Data()
        for await chunk in process.output { out += chunk }
        let exit = await process.exitStatus
        XCTAssertEqual(String(bytes: out, encoding: .utf8), "one\n")
        XCTAssertTrue(exit.succeeded)
    }

    /// Writes from many threads racing the close (as `--serve` requests do
    /// with a terminate): every write runs before the close or not at all,
    /// and the close runs once.
    func testConcurrentWritesNeverFollowTheClose() async {
        final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [String] = []
            func add(_ event: String) { lock.withLock { list.append(event) } }
            var all: [String] { lock.withLock { list } }
        }
        for round in 0 ..< 50 {
            let events = Events()
            let channel = CodeCLIInputChannel(
                write: { data in events.add(String(bytes: data, encoding: .utf8) ?? "?") },
                close: { events.add("close") }
            )
            DispatchQueue.concurrentPerform(iterations: 40) { i in
                if i == 20 { channel.close() }
                channel.write(Data("w\(i)".utf8))
                if i.isMultiple(of: 13) { channel.close() }
            }
            channel.waitUntilIdle()
            let all = events.all
            XCTAssertEqual(all.filter { $0 == "close" }.count, 1, "round \(round): one close")
            XCTAssertEqual(all.last, "close", "round \(round): a write after the close: \(all)")
        }
    }

    func testTerminateKillsTheWholeGroupAndReaps() async throws {
        let pidFile = stub.directory.appendingPathComponent("child.pid")
        let process = try shell("sleep 30 & echo $! > '\(pidFile.path)'; wait")
        let wrote = await eventually { FileManager.default.fileExists(atPath: pidFile.path) }
        XCTAssertTrue(wrote)
        try await Task.sleep(for: .milliseconds(50))
        let child = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(getpgid(child), process.pid, "the child shares the CLI's own group")
        XCTAssertNotEqual(process.pid, getpgrp(), "never Watchtower's group")
        process.terminateGroup()
        let exit = await process.exitStatus
        XCTAssertTrue(exit.signaled)
        let childGone = await eventually { kill(child, 0) == -1 }
        XCTAssertTrue(childGone, "the grandchild went with the group")
        process.terminateGroup() // idempotent after the reap: signals nobody
    }

    func testRunsAtUtilityQoS() async throws {
        let process = try shell("ps -o pri= -p $$; exit 0")
        var out = Data()
        for await chunk in process.output { out += chunk }
        _ = await process.exitStatus
        let priority = try XCTUnwrap(Int(String(bytes: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        XCTAssertLessThan(priority, 31, "utility QoS lowers the scheduling priority below the default 31")
    }

    func testAMissingExecutableIsNotFound() {
        XCTAssertThrowsError(try CodeCLIProcess.launch(executable: "/nonexistent/watchtower", arguments: [], environment: [:])) {
            XCTAssertEqual($0.localizedDescription, "The watchtower command-line tool was not found.")
        }
    }

    // MARK: CodeSearchRun

    func testCancelledSearchKillsTheChildAndCallsNothing() async throws {
        var matches: [CodeSearchMatch] = []
        var outcomes: [CodeSearchRun.Outcome] = []
        let run = CodeSearchRun.start(
            folder: stub.directory, options: CodeSearchOptions(query: "hit"),
            executable: stub.executable.path, environment: stub.environment()
        ) { matches.append($0) } onDone: { outcomes.append($0) }
        let matched = await eventually { matches.count == 1 }
        XCTAssertTrue(matched)
        XCTAssertEqual(matches.first?.path, "a.swift")
        run.cancel()
        await stub.assertAllGroupsReaped()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(outcomes, [])
    }

    func testSearchWithoutTheCLIFails() async {
        var outcomes: [CodeSearchRun.Outcome] = []
        let run = CodeSearchRun.start(
            folder: stub.directory, options: CodeSearchOptions(query: "x"), executable: nil, environment: [:]
        ) { _ in } onDone: { outcomes.append($0) }
        XCTAssertEqual(outcomes, [], "reported after start returns")
        let done = await eventually { !outcomes.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(outcomes, [.failed("The watchtower command-line tool was not found.")])
        withExtendedLifetime(run) {}
    }
}

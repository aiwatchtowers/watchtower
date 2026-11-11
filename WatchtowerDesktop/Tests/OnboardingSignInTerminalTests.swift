import Darwin
import XCTest
@testable import WatchtowerDesktop

/// #1521: the onboarding sign-in terminal runs one command in its own
/// process group, reports its exit once, and Stop leaves nothing behind.
@MainActor
final class OnboardingSignInTerminalTests: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("signin-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A login shell that reads no profile of the developer's.
    private var environment: [String: String] {
        ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin"]
    }

    /// A session whose exits land in `exits`; stopped (group killed and
    /// gone) in teardown whatever the test did.
    private func makeSession(
        shell: String = "/bin/zsh",
        exited: XCTestExpectation? = nil
    ) -> (OnboardingSignInSession, ExitLog) {
        let log = ExitLog()
        let session = OnboardingSignInSession(environment: environment, onExit: { code in
            log.codes.append(code)
            exited?.fulfill()
        }, shell: shell)
        addTeardownBlock { @MainActor in
            let group = session.isRunning ? session.view.process.shellPid : 0
            session.stop()
            if group > 0 {
                _ = killpg(group, SIGKILL)
                _ = await Self.groupGone(group)
            }
        }
        return (session, log)
    }

    func testExitCodeIsReported() async {
        let exited = expectation(description: "exit")
        let (session, log) = makeSession(exited: exited)
        session.start(command: "exit 3")
        XCTAssertTrue(session.isRunning)
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(log.codes, [3])
        XCTAssertFalse(session.isRunning)
    }

    func testZeroExit() async {
        let exited = expectation(description: "exit")
        let (session, log) = makeSession(exited: exited)
        session.start(command: "true")
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(log.codes, [0])
    }

    func testStopKillsTheProcessGroup() async throws {
        let exited = expectation(description: "no exit after stop")
        exited.isInverted = true
        let (session, log) = makeSession(exited: exited)
        session.start(command: "sleep 60 & sleep 60; wait")
        let group = session.view.process.shellPid
        XCTAssertGreaterThan(group, 0)
        // forkpty returns before the child's login_tty → setsid: until then
        // the child is still in the test runner's group.
        let leads = await Self.poll(timeout: 10) { getpgid(group) == group }
        XCTAssertTrue(leads, "the shell leads its own group")
        // The shell and both sleeps.
        let started = await Self.poll(timeout: 10) { Self.groupMembers(group) >= 3 }
        XCTAssertTrue(started, "the command's children run in the shell's group")

        session.stop()
        XCTAssertFalse(session.isRunning)
        let gone = await Self.groupGone(group, timeout: 2)
        XCTAssertTrue(gone, "kill(-pgid, 0) reports ESRCH within 2 s of Stop")
        await fulfillment(of: [exited], timeout: 0.5)
        XCTAssertEqual(log.codes, [], "Stop never reports an exit")
    }

    func testStartFailureReportsEnded() async {
        let exited = expectation(description: "exit")
        let (session, log) = makeSession(shell: "/nonexistent/zsh", exited: exited)
        session.start(command: "true")
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(log.codes, [127])
    }

    /// One session runs one command: a second start changes nothing.
    func testSecondStartIsIgnored() async {
        let exited = expectation(description: "no exit from the ignored start")
        exited.isInverted = true
        let (session, log) = makeSession(exited: exited)
        session.start(command: "sleep 60")
        let first = session.view.process.shellPid
        XCTAssertGreaterThan(first, 0)
        session.start(command: "exit 4")
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.view.process.shellPid, first)
        await fulfillment(of: [exited], timeout: 1)
        XCTAssertEqual(log.codes, [])
    }

    func testStartAfterExitIsIgnored() async {
        let exited = expectation(description: "exit")
        let (session, log) = makeSession(exited: exited)
        session.start(command: "exit 3")
        let first = session.view.process.shellPid
        await fulfillment(of: [exited], timeout: 10)
        session.start(command: "exit 5")
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.view.process.shellPid, first)
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(log.codes, [3], "no second run, no second exit")
    }

    func testExitCodeDecoding() {
        XCTAssertEqual(OnboardingSignInSession.exitCode(3 << 8), 3)
        XCTAssertEqual(OnboardingSignInSession.exitCode(SIGTERM), 128 + SIGTERM)
    }

    // MARK: Helpers

    @MainActor
    private final class ExitLog {
        var codes: [Int32] = []
    }

    private static func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func groupGone(_ group: pid_t, timeout: TimeInterval = 5) async -> Bool {
        await poll(timeout: timeout) { kill(-group, 0) == -1 && errno == ESRCH }
    }

    /// The live processes in a process group, through `sysctl`.
    private static func groupMembers(_ group: pid_t) -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return 0 }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return 0 }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(count).filter { $0.kp_proc.p_stat != CChar(SZOMB) }.count
    }
}

import ChatUI
import Darwin
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Cancel on a waiting Slack Re-login (#2132 S1, S2): the cancel trio on the
/// built-in route of `SlackAccountsViewModel.relogin`, the row's waiting line,
/// and the card's `.cancelled` outcome. The stub CLI blocks on a FIFO, so every
/// step is driven by the test, never by a clock.
@MainActor
final class SlackSignInCancelTests: XCTestCase {
    private var stub: SlackLoginStub?

    override func tearDown() async throws {
        stub?.reap()
        stub = nil
        try await super.tearDown()
    }

    private func makeVM() throws -> (SlackAccountsViewModel, SlackLoginStub, FakeDaemonRestarter, SlackAccount) {
        let stub = try SlackLoginStub()
        self.stub = stub
        let (manager, _) = try TestDatabase.createDatabaseManager()
        let pool = manager.dbPool
        try pool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamName: "Acme") }
        let account = try XCTUnwrap(try pool.read { db in try SlackAccountQueries.fetchAll(db) }.first)
        let daemon = FakeDaemonRestarter()
        let path = stub.path
        let vm = SlackAccountsViewModel(dbPool: pool, daemon: daemon) { path }
        vm.loginEnvironment = { [:] }
        return (vm, stub, daemon, account)
    }

    // MARK: - The cancel trio (S1)

    func testCancelWhileWaitingReturnsToIdleSilently() async throws {
        let (vm, stub, daemon, account) = try makeVM()
        let run = Task { await vm.relogin(account) }
        let live = await stub.started(1)
        XCTAssertTrue(vm.isConnecting)
        XCTAssertEqual(vm.signInAccountID, account.id)

        vm.cancelConnect()
        XCTAssertFalse(vm.isConnecting, "Cancel resets the busy state at once")
        XCTAssertNil(vm.signInAccountID)
        XCTAssertNil(vm.error)

        await live.exited()
        let route = await run.value
        XCTAssertEqual(route, .builtin)
        XCTAssertTrue(vm.lastRunCancelled)
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error, "a cancel is silent")
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testCancelAfterTheStubExitedStaysIdleWithNoError() async throws {
        let (vm, stub, _, account) = try makeVM()
        let run = Task { await vm.relogin(account) }
        let live = await stub.started(1)
        stub.release(1, exitCode: 0)
        await live.exited()
        // The completion may or may not have run yet: either way Cancel
        // leaves the row idle, and the finished sign-in is not an error.
        vm.cancelConnect()
        _ = await run.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.signInAccountID)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.lastRunCancelled, "the sign-in had finished: the card reports it signed in")
    }

    func testStaleCompletionDoesNotResetANewerRun() async throws {
        let (vm, stub, _, account) = try makeVM()
        stub.ignoreSIGTERM(run: 1)
        let first = Task { await vm.relogin(account) }
        let firstLive = await stub.started(1)
        vm.cancelConnect()

        let second = Task { await vm.relogin(account) }
        let secondLive = await stub.started(2)
        // The first stub outlived the Cancel's SIGTERM; it now fails.
        stub.release(1, exitCode: 1)
        await firstLive.exited()
        _ = await first.value
        XCTAssertTrue(vm.lastRunCancelled)
        XCTAssertTrue(vm.isConnecting, "the first run's exit must not end the second")
        XCTAssertEqual(vm.signInAccountID, account.id)
        XCTAssertNil(vm.error, "the cancelled run's failure is not shown")

        stub.release(2, exitCode: 0)
        await secondLive.exited()
        _ = await second.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertFalse(vm.lastRunCancelled)
        XCTAssertNil(vm.error)
    }

    // MARK: - The row (S1)

    func testOnlyTheWaitingRowShowsTheWaitingLine() async throws {
        let (vm, stub, _, account) = try makeVM()
        XCTAssertNil(vm.signInWait(forAccount: account.id), "idle: the row's own Re-login")
        let run = Task { await vm.relogin(account) }
        let live = await stub.started(1)
        XCTAssertEqual(vm.signInWait(forAccount: account.id), .slack)
        XCTAssertNil(vm.signInWait(forAccount: account.id + 1))
        vm.cancelConnect()
        XCTAssertNil(vm.signInWait(forAccount: account.id), "after Cancel: idle again")
        await live.exited()
        _ = await run.value
    }

    func testAddWaitsWithoutARow() async throws {
        let (vm, stub, _, account) = try makeVM()
        let run = Task { await vm.addAccount() }
        let live = await stub.started(1)
        XCTAssertTrue(vm.isConnecting)
        XCTAssertNil(vm.signInWait(forAccount: account.id), "a new workspace's sign-in shows in its sheet")
        vm.cancelConnect()
        await live.exited()
        await run.value
    }

    // MARK: - The card (S2)

    func testCancelledBuiltinSignInIsCancelledOutcome() {
        let appState = AppState.isolated()
        XCTAssertEqual(appState.reconnectOutcome(route: .builtin, error: nil, cancelled: true), .cancelled)
        XCTAssertEqual(appState.reconnectOutcome(route: .builtin, error: nil, cancelled: false), .signedIn)
    }

    func testCardWaitingLineIsTheMacsSignInLine() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let services = ChatApprovalServices.mac(
            feed: AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner()), reconnectSlack: { _ in .signedIn },
            cancelReconnectSlack: {}, sessionHolds: { _ in false }
        )
        // The card draws it while Reconnect Slack runs (`AgentActionCard.reconnectWaitLine`, ChatUI's tests).
        XCTAssertNotNil(services.reconnectSlackWaiting?(), "the chat's card gets the Mac's waiting line")
    }
}

/// A `watchtower` stand-in for `slack login`/`slack add` that waits until the
/// test releases it. Run n (in launch order) opens `live<n>` for writing when it
/// starts and holds it until it exits, so the test sees both moments; it exits
/// with the code written to `gate<n>`.
final class SlackLoginStub: @unchecked Sendable {
    let dir: URL
    let path: String
    private static let runs = 1...4

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slack-login-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in Self.runs {
            for name in ["gate\(n)", "live\(n)"] {
                guard mkfifo(dir.appendingPathComponent(name).path, 0o600) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
        let script = """
        #!/bin/sh
        d='\(dir.path)'
        n=1
        while ! /bin/mkdir "$d/claim$n" 2>/dev/null; do n=$((n+1)); done
        echo $$ > "$d/pid$n"
        if [ -e "$d/ignoreterm$n" ]; then trap '' TERM; fi
        exec 3>"$d/live$n"
        read code < "$d/gate$n"
        exit "${code:-0}"
        """
        let url = dir.appendingPathComponent("watchtower")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        path = url.path
    }

    /// Run n ignores the SIGTERM a Cancel sends: it exits only when released.
    func ignoreSIGTERM(run n: Int) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent("ignoreterm\(n)").path, contents: nil)
    }

    /// Returns once run n is running (it opened `live<n>`).
    func started(_ n: Int) async -> Live {
        let live = dir.appendingPathComponent("live\(n)").path
        let handle = await Task.detached { FileHandle(forReadingAtPath: live) }.value
        return Live(handle: handle)
    }

    /// Lets run n exit with `exitCode`.
    func release(_ n: Int, exitCode: Int32) {
        let gate = dir.appendingPathComponent("gate\(n)").path
        Task.detached {
            let handle = FileHandle(forWritingAtPath: gate)
            try? handle?.write(contentsOf: Data("\(exitCode)\n".utf8))
            try? handle?.close()
        }
    }

    /// Kills every run that started, with its process group.
    func reap() {
        for n in Self.runs {
            let pidFile = dir.appendingPathComponent("pid\(n)").path
            guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    struct Live: @unchecked Sendable {
        let handle: FileHandle?

        /// Returns once the run exited (its end of `live<n>` closed).
        func exited() async {
            let handle = handle
            await Task.detached {
                _ = try? handle?.readToEnd()
                try? handle?.close()
            }.value
        }
    }
}

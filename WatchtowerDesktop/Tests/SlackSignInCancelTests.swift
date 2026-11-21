import ChatUI
import Darwin
import GRDB
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Cancel on a waiting Slack Re-login (#2132 S1, S2): the cancel trio on the
/// built-in route of `SlackAccountsViewModel.relogin`, a Cancel during the
/// route read, the row's waiting line, and the card's `.cancelled` outcome.
/// The stub CLI blocks on a FIFO and the VM's seams hold on gates, so every
/// step is driven by the test, never by a clock.
@MainActor
final class SlackSignInCancelTests: XCTestCase {
    private var stub: SlackLoginStub?
    /// The connect flow a route-read test hands the VM (held: the VM's is weak).
    private var flow: SlackConnectFlowModel?

    override func tearDown() async throws {
        stub?.reap()
        stub = nil
        flow = nil
        try await super.tearDown()
    }

    private struct Rig {
        let vm: SlackAccountsViewModel
        let stub: SlackLoginStub
        let daemon: FakeDaemonRestarter
        let account: SlackAccount
        let pool: DatabasePool
        /// Account re-reads (`refreshAsync`) since the rig was made.
        let rereads: Counter
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    private func makeRig() throws -> Rig {
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
        let rereads = Counter()
        vm.onAccountsChanged = { rereads.bump() }
        return Rig(vm: vm, stub: stub, daemon: daemon, account: account, pool: pool, rereads: rereads)
    }

    /// Hands `vm` a connect flow and a route read that waits on `held` after
    /// opening `entered`, answering the built-in route for `account`.
    private func holdRouteRead(
        _ vm: SlackAccountsViewModel,
        account: SlackAccount,
        entered: AsyncGate,
        held: AsyncGate
    ) async throws {
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        let flow = SlackConnectFlowModel(host: host)
        self.flow = flow
        vm.connectFlow = flow
        let json = #"{"builtin_app":true,"accounts":[{"id":\#(account.id),"team_id":"T0ACME","client_id":"5.6","#
            + #""shared_app":false,"relogin":"builtin"}]}"#
        let doc = try JSONDecoder().decode(SlackAccountsDocument.self, from: Data(json.utf8))
        vm.routeDocumentRead = {
            entered.release()
            await held.wait()
            return .success(doc)
        }
    }

    // MARK: - The cancel trio (S1)

    func testCancelWhileWaitingReturnsToIdleSilently() async throws {
        let rig = try makeRig()
        let vm = rig.vm
        let run = Task { await vm.relogin(rig.account) }
        let live = try await rig.stub.started(1, unlessEnded: run)
        XCTAssertTrue(vm.isConnecting)
        XCTAssertEqual(vm.signInAccountID, rig.account.id)

        vm.cancelConnect()
        XCTAssertFalse(vm.isConnecting, "Cancel resets the busy state at once")
        XCTAssertNil(vm.signInAccountID)
        XCTAssertNil(vm.error)

        await live.exited()
        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error, "a cancel is silent")
        XCTAssertEqual(rig.rereads.count, 1, "a Cancel ends with one re-read of the accounts")
        XCTAssertNil(vm.daemonRestartTask, "and never a daemon restart")
        XCTAssertEqual(rig.daemon.restartCount, 0)
    }

    /// The child exited 0 (the account was saved) and its completion is held
    /// until the Cancel lands: the finished sign-in is wired in like one that
    /// was never cancelled.
    func testCancelAfterTheStubExitedKeepsTheSignIn() async throws {
        let rig = try makeRig()
        let vm = rig.vm
        let exitedChild = AsyncGate()
        let holdCompletion = AsyncGate()
        vm.afterAuthExit = {
            exitedChild.release()
            await holdCompletion.wait()
        }
        let run = Task { await vm.relogin(rig.account) }
        let live = try await rig.stub.started(1, unlessEnded: run)
        rig.stub.release(1, exitCode: 0)
        await live.exited()
        await exitedChild.wait()

        vm.cancelConnect()
        XCTAssertFalse(vm.isConnecting)
        holdCompletion.release()
        let outcome = await run.value
        XCTAssertEqual(outcome, .signedIn, "the sign-in had finished: the card reports it signed in")
        XCTAssertEqual(rig.rereads.count, 1, "the accounts were re-read")
        await vm.daemonRestartTask?.value
        XCTAssertEqual(rig.daemon.restartCount, 1, "a saved account re-wires the daemon")
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.signInAccountID)
        XCTAssertNil(vm.error)
    }

    func testStaleCompletionDoesNotResetANewerRun() async throws {
        let rig = try makeRig()
        let vm = rig.vm
        rig.stub.ignoreSIGTERM(run: 1)
        let first = Task { await vm.relogin(rig.account) }
        let firstLive = try await rig.stub.started(1, unlessEnded: first)
        vm.cancelConnect()

        let second = Task { await vm.relogin(rig.account) }
        let secondLive = try await rig.stub.started(2, unlessEnded: second)
        // The first stub outlived the Cancel's SIGTERM; it now fails.
        rig.stub.release(1, exitCode: 1)
        await firstLive.exited()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertTrue(vm.isConnecting, "the first run's exit must not end the second")
        XCTAssertEqual(vm.signInAccountID, rig.account.id)
        XCTAssertNil(vm.error, "the cancelled run's failure is not shown")

        rig.stub.release(2, exitCode: 0)
        await secondLive.exited()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .signedIn)
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
    }

    // MARK: - Cancel during the route read

    /// The Re-login's `slack accounts --json` read is part of the attempt: a
    /// Cancel then starts no `slack login`, and the outcome is `.cancelled`.
    func testCancelDuringTheRouteReadStartsNoSignIn() async throws {
        let rig = try makeRig()
        let vm = rig.vm
        let entered = AsyncGate()
        let held = AsyncGate()
        try await holdRouteRead(vm, account: rig.account, entered: entered, held: held)

        let run = Task { await vm.relogin(rig.account) }
        await entered.wait()
        XCTAssertTrue(vm.isConnecting)
        vm.cancelConnect(accountID: rig.account.id + 1)
        XCTAssertTrue(vm.isConnecting, "another account's Cancel leaves this attempt running")
        vm.cancelConnect(accountID: rig.account.id)
        XCTAssertFalse(vm.isConnecting)
        held.release()

        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(rig.stub.launched(1), "no `slack login` after the Cancel")
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
        XCTAssertEqual(rig.rereads.count, 1)
        XCTAssertEqual(rig.daemon.restartCount, 0)
    }

    /// With nothing of its own running, Cancel leaves the busy state alone.
    func testCancelWithNoAttemptChangesNothing() async throws {
        let rig = try makeRig()
        let vm = rig.vm
        let entered = AsyncGate()
        let held = AsyncGate()
        try await holdRouteRead(vm, account: rig.account, entered: entered, held: held)
        // `reloginRoute` alone (the connect section's read) is no sign-in.
        let read = Task { await vm.reloginRoute(accountID: Int64(rig.account.id)) }
        await entered.wait()
        vm.cancelConnect()
        XCTAssertTrue(vm.isConnecting)
        held.release()
        _ = await read.value
        XCTAssertFalse(vm.isConnecting)
    }

    // MARK: - The row (S1)

    func testOnlyTheWaitingRowShowsTheWaitingLine() async throws {
        let rig = try makeRig()
        let vm = rig.vm
        XCTAssertNil(vm.signInWait(forAccount: rig.account.id), "idle: the row's own Re-login")
        let run = Task { await vm.relogin(rig.account) }
        let live = try await rig.stub.started(1, unlessEnded: run)
        XCTAssertEqual(vm.signInWait(forAccount: rig.account.id), .slack)
        XCTAssertNil(vm.signInWait(forAccount: rig.account.id + 1))
        vm.cancelConnect(accountID: rig.account.id)
        XCTAssertNil(vm.signInWait(forAccount: rig.account.id), "after Cancel: idle again")
        await live.exited()
        _ = await run.value
    }

    func testAddWaitsWithoutARow() async throws {
        let rig = try makeRig()
        let vm = rig.vm
        let run = Task { await vm.addAccount() }
        let live = try await rig.stub.started(1, unlessEnded: run)
        XCTAssertTrue(vm.isConnecting)
        XCTAssertNil(vm.signInWait(forAccount: rig.account.id), "a new workspace's sign-in shows in its sheet")
        vm.cancelConnect(accountID: rig.account.id)
        XCTAssertTrue(vm.isConnecting, "a card's Cancel never ends the Add sheet's sign-in")
        vm.cancelConnect()
        await live.exited()
        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
    }

    // MARK: - The card (S2)

    /// End to end: the card's Reconnect Slack, cancelled through
    /// `AppState.cancelCardSlackSignIn` while it reads the route.
    func testCardReconnectCancelledIsCancelledOutcome() async throws {
        let rig = try makeRig()
        let appState = AppState.isolated()
        appState.initSlackAccounts(dbPool: rig.pool)
        let vm = try XCTUnwrap(appState.slackAccountsViewModel)
        await vm.refreshAsync()
        let entered = AsyncGate()
        let held = AsyncGate()
        try await holdRouteRead(vm, account: rig.account, entered: entered, held: held)
        let accountID = Int64(rig.account.id)

        let run = Task { await appState.reconnectSlack(accountID: accountID) }
        await entered.wait()
        appState.cancelCardSlackSignIn(accountID: accountID)
        held.release()
        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(vm.isConnecting)
    }

    func testCardWaitingLineIsSlacksAndCancelsTheCardsAccount() throws {
        let action = try agentAction()
        var cancelled: [Int64] = []
        let card = MacAgentActionCard(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                      onCancelReconnectSlack: { cancelled.append($0) })
        let wait = try XCTUnwrap(card.cardSignInWait?(7))
        XCTAssertEqual(wait.copy, .slack)
        let view = try wait.view.inspect()
        _ = try view.find(text: SignInWaitCopy.slack.line)
        _ = try view.find(text: SignInWaitCopy.slack.hint)
        try view.find(button: SignInWaitCopy.slack.cancelTitle).tap()
        XCTAssertEqual(cancelled, [7], "Cancel ends the card's own account's sign-in")

        let plain = MacAgentActionCard(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNil(plain.cardSignInWait, "no Cancel to offer: no waiting line")
    }

    /// The chat's cards (`ChatApprovalServices.mac`) draw the same line.
    func testChatCardWaitingLineCancelsTheCardsAccount() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        var cancelled: [Int64] = []
        let services = ChatApprovalServices.mac(
            feed: AgentActionFeed(dbPool: pool, cliRunner: FakeCLIRunner()), reconnectSlack: { _ in .signedIn },
            cancelReconnectSlack: { cancelled.append($0) }, sessionHolds: { _ in false }
        )
        let line = try XCTUnwrap(services.reconnectSlackWaiting?(9)).inspect()
        _ = try line.find(text: SignInWaitCopy.slack.line)
        try line.find(button: SignInWaitCopy.slack.cancelTitle).tap()
        XCTAssertEqual(cancelled, [9])
    }

    private func agentAction() throws -> AgentAction {
        let queue = try TestDatabase.create()
        try queue.write { db in _ = try TestDatabase.insertAgentAction(db, tool: "send_slack_message", external: true) }
        return try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
    }
}

/// A `watchtower` stand-in for `slack login`/`slack add` that waits until the
/// test releases it. Run n (in launch order) writes its pid, then opens
/// `live<n>` for writing and holds it until it exits, so the test sees both
/// moments; it exits with the code written to `gate<n>`.
final class SlackLoginStub: @unchecked Sendable {
    let dir: URL
    let path: String
    private static let runs = 1...4

    struct NeverStarted: Error {}

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

    private func file(_ name: String) -> String {
        dir.appendingPathComponent(name).path
    }

    /// Run n ignores the SIGTERM a Cancel sends: it exits only when released.
    func ignoreSIGTERM(run n: Int) {
        FileManager.default.createFile(atPath: file("ignoreterm\(n)"), contents: nil)
    }

    /// Run n was launched at all.
    func launched(_ n: Int) -> Bool {
        FileManager.default.fileExists(atPath: file("claim\(n)"))
    }

    /// Returns once run n is running (it opened `live<n>`). Throws when `run`
    /// (the VM call that should launch it) ends first: its end unblocks the
    /// wait, so a stub that never starts fails the test instead of hanging it.
    func started<T: Sendable>(_ n: Int, unlessEnded run: Task<T, Never>) async throws -> Live {
        let live = file("live\(n)")
        let opener = Task.detached { FileHandle(forReadingAtPath: live) }
        Task.detached {
            _ = await run.value
            // A non-blocking writer releases a reader still waiting in open();
            // with no reader left it fails (ENXIO) and does nothing.
            let fd = open(live, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        let handle = await opener.value
        guard FileManager.default.fileExists(atPath: file("pid\(n)")) else {
            try? handle?.close()
            throw NeverStarted()
        }
        return Live(handle: handle)
    }

    /// Lets run n exit with `exitCode`.
    func release(_ n: Int, exitCode: Int32) {
        let gate = file("gate\(n)")
        Task.detached {
            let handle = FileHandle(forWritingAtPath: gate)
            try? handle?.write(contentsOf: Data("\(exitCode)\n".utf8))
            try? handle?.close()
        }
    }

    /// Kills every run that started (a shell with no children) and removes
    /// the stub's directory.
    func reap() {
        for n in Self.runs {
            guard let text = try? String(contentsOfFile: file("pid\(n)"), encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: dir)
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

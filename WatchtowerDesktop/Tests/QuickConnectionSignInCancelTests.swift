import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Q1 (#2132): a Quick Connection's **Sign in again** waits in the browser
/// with Cancel on its row. Cancel is silent, and a cancelled run's late exit
/// never resets the next attempt.
@MainActor
final class QuickConnectionSignInCancelTests: XCTestCase {
    private var pool: DatabasePool!

    private func makeVM(
        _ stub: GatedLoginStub,
        tools: CountingToolsRunner? = nil,
        beforeLaunch: @escaping @Sendable () async -> Void = {}
    ) throws -> ExternalConnectionsViewModel {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        self.pool = pool
        return ExternalConnectionsViewModel(
            dbPool: pool, makeRunner: { tools }, cliPath: { stub.path }, beforeLaunch: beforeLaunch
        )
    }

    /// Answers every `connections tools` call with an empty list, counting them.
    final class CountingToolsRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }

        func run(args: [String]) async throws -> Data {
            lock.withLock { count += 1 }
            return Data(#"{"id":3,"name":"acme-wiki","listed":true,"listed_at":"2026-01-01T00:00:00Z","explicit":false,"tools":[]}"#.utf8)
        }
    }

    @MainActor
    private final class VMBox {
        var vm: ExternalConnectionsViewModel?
    }

    private func stub(ignoreTerm: Bool = false) throws -> GatedLoginStub {
        let stub = try GatedLoginStub(ignoreTerm: ignoreTerm)
        addTeardownBlock { stub.reap() }
        return stub
    }

    private func connection(_ id: Int, _ name: String) -> ExternalConnection {
        ExternalConnection(row: Row(["id": id, "name": name, "kind": "http", "status": "revoked", "enabled": true]))
    }

    func testCancelWhileWaitingIsSilent() async throws {
        let stub = try stub()
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")

        let run = Task { await vm.signInAgain(wiki) }
        _ = try await stub.nextRun(or: run)
        XCTAssertTrue(vm.isBusy)
        XCTAssertEqual(vm.signInWait(for: wiki), SignInWaitCopy(service: "acme-wiki"))

        vm.cancelSignIn()
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.signInWait(for: wiki))

        await run.value // the stub died of the SIGTERM
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.error)
    }

    /// A Cancel can land while the CLI saves: once the killed run is gone,
    /// the list is read again, so what it saved shows.
    func testCancelRereadsWhatTheKilledRunSaved() async throws {
        let stub = try stub()
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")
        XCTAssertTrue(vm.connections.isEmpty)

        let run = Task { await vm.signInAgain(wiki) }
        _ = try await stub.nextRun(or: run)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO external_connections (name, kind, url, enabled, status, error) "
                + "VALUES ('acme-wiki', 'http', 'https://mcp.example.com', 0, 'revoked', '')")
        }
        vm.cancelSignIn()
        await run.value

        XCTAssertEqual(vm.connections.map(\.name), ["acme-wiki"])
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isBusy)
    }

    func testCancelAfterTheRunExitedStaysIdle() async throws {
        let stub = try stub()
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")

        let run = Task { await vm.signInAgain(wiki) }
        await stub.release(try await stub.nextRun(or: run), exitCode: 0)
        await run.value

        vm.cancelSignIn()
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.signInConnectionID)
    }

    func testCancelledRunsLateExitLeavesTheNextAttemptWaiting() async throws {
        let stub = try stub(ignoreTerm: true)
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")
        let docs = connection(4, "acme-docs")

        let first = Task { await vm.signInAgain(wiki) }
        let firstPID = try await stub.nextRun(or: first)
        vm.cancelSignIn() // SIGTERM is ignored: the first run lives on
        let second = Task { await vm.signInAgain(docs) }
        let secondPID = try await stub.nextRun(or: second)

        await stub.release(firstPID, exitCode: 1)
        await first.value
        XCTAssertTrue(vm.isBusy, "the stale completion must not reset the second run")
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.signInConnectionID, docs.id)
        XCTAssertNotNil(vm.signInWait(for: docs))

        vm.cancelSignIn()
        await stub.release(secondPID, exitCode: 0)
        await second.value
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.error)
    }

    /// The waiting row: the two lines under the name and Cancel in place of
    /// the actions; Cancel ends the wait.
    func testRowShowsTheWaitingLineAndCancels() async throws {
        let stub = try stub()
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")
        let copy = SignInWaitCopy(service: "acme-wiki")
        let row = QuickConnectionRow(connection: wiki, vm: vm, policy: .none) {}

        XCTAssertThrowsError(try row.inspect().find(text: copy.line))
        XCTAssertNoThrow(try row.inspect().find(button: "Sign in again"))
        XCTAssertNoThrow(try row.inspect().find(ViewType.Toggle.self))

        let run = Task { await vm.signInAgain(wiki) }
        _ = try await stub.nextRun(or: run)
        XCTAssertNoThrow(try row.inspect().find(text: copy.line))
        XCTAssertNoThrow(try row.inspect().find(text: copy.hint))
        XCTAssertThrowsError(try row.inspect().find(button: "Sign in again"))
        XCTAssertThrowsError(try row.inspect().find(button: "Remove"))
        XCTAssertThrowsError(try row.inspect().find(ViewType.Toggle.self))

        try row.inspect().find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.signInConnectionID)
        await run.value
        XCTAssertNil(vm.error)
    }

    /// A sign-in the Add sheet or an import runs is cancelled there (an
    /// import's Cancel also stops its next sign-ins), so no row shows it.
    func testASignInTheRowDidNotStartIsNotShownOnTheRow() async throws {
        let stub = try stub()
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")
        let row = QuickConnectionRow(connection: wiki, vm: vm, policy: .none) {}

        let run = Task { await vm.signIn(wiki) }
        _ = try await stub.nextRun(or: run)
        XCTAssertTrue(vm.isBusy)
        XCTAssertNil(vm.signInWait(for: wiki))
        XCTAssertThrowsError(try row.inspect().find(button: SignInWaitCopy(service: "acme-wiki").cancelTitle))

        vm.cancelSignIn()
        await run.value
    }

    /// A Cancel that lands after the identity check but before the child
    /// runs finds nothing to terminate; the child is stopped as soon as it
    /// launches, so it never signs in.
    func testCancelDuringTheLaunchStopsTheChild() async throws {
        let stub = try stub()
        let tools = CountingToolsRunner()
        let box = VMBox()
        let vm = try makeVM(stub, tools: tools) { await MainActor.run { box.vm?.cancelSignIn() } }
        box.vm = vm
        let wiki = connection(3, "acme-wiki")
        await vm.loadTools(wiki) // a finished sign-in would list them again

        let run = Task { await vm.signInAgain(wiki) }
        // If the stub got as far as its gate, let it sign in (exit 0) instead
        // of waiting for ever: a child the post-launch check missed then ends
        // as a finished sign-in, which re-lists the tools.
        if let pid = try? await stub.nextRun(or: run) {
            await stub.release(pid, exitCode: 0, or: run)
        }
        await run.value

        XCTAssertEqual(tools.calls, 1, "the child must be stopped at launch, not left to sign in")
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.signInConnectionID)
    }

    /// A cancelled sign-in does not re-list the tools, so the row's
    /// controls are free at once.
    func testCancelLeavesTheToolsAlone() async throws {
        let stub = try stub()
        let tools = CountingToolsRunner()
        let vm = try makeVM(stub, tools: tools)
        let wiki = connection(3, "acme-wiki")
        await vm.loadTools(wiki)

        let run = Task { await vm.signInAgain(wiki) }
        _ = try await stub.nextRun(or: run)
        vm.cancelSignIn()
        await run.value

        XCTAssertEqual(tools.calls, 1)
        XCTAssertFalse(vm.toolsInFlight.contains(wiki.id))
        XCTAssertFalse(vm.isBusy)
    }

    /// The re-read after a Cancel is quiet: a failed read is `readError`,
    /// not the pane's error.
    func testAFailedRereadAfterCancelIsNotAnError() async throws {
        let stub = try stub()
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")

        let run = Task { await vm.signInAgain(wiki) }
        _ = try await stub.nextRun(or: run)
        try await pool.write { db in try db.execute(sql: "DROP TABLE external_connections") }
        vm.cancelSignIn()
        await run.value

        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.readError)
    }
}

/// O1 (#2132): the Add Outlook sheet's Cancel already existed; a cancelled
/// run's late exit must not reset a connect started right after it.
@MainActor
final class OutlookConnectCancelTests: XCTestCase {
    private func makeVM(_ stub: GatedLoginStub, daemon: FakeDaemonRestarter) throws -> EmailAccountsViewModel {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        self.pool = pool
        return EmailAccountsViewModel(dbPool: pool, daemon: daemon) { stub.path }
    }

    private var pool: DatabasePool!

    private func stub(ignoreTerm: Bool = false) throws -> GatedLoginStub {
        let stub = try GatedLoginStub(ignoreTerm: ignoreTerm)
        addTeardownBlock { stub.reap() }
        return stub
    }

    func testCancelWhileWaitingIsSilent() async throws {
        let stub = try stub()
        let daemon = FakeDaemonRestarter()
        let vm = try makeVM(stub, daemon: daemon)

        let run = try XCTUnwrap(vm.connectOutlook())
        _ = try await stub.nextRun(or: run)
        XCTAssertTrue(vm.isRunning)

        vm.cancelConnect()
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.error)

        await run.value
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    /// A Cancel can land while the CLI saves: once the killed run is gone,
    /// the accounts are read again, once, with no daemon restart.
    func testCancelRereadsTheAccountsOnce() async throws {
        let stub = try stub()
        let daemon = FakeDaemonRestarter()
        let vm = try makeVM(stub, daemon: daemon)
        var rereads = 0
        vm.onAccountsChanged = { rereads += 1 }

        let run = try XCTUnwrap(vm.connectOutlook())
        _ = try await stub.nextRun(or: run)
        _ = try await pool.write { db in
            try TestDatabase.insertEmailAccount(db, provider: "outlook", emailAddress: "owner@example.com")
        }
        vm.cancelConnect()
        await run.value

        XCTAssertEqual(rereads, 1)
        XCTAssertEqual(vm.accounts.map(\.emailAddress), ["owner@example.com"])
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testAFailedRereadAfterCancelIsNotAnError() async throws {
        let stub = try stub()
        let vm = try makeVM(stub, daemon: FakeDaemonRestarter())

        let run = try XCTUnwrap(vm.connectOutlook())
        _ = try await stub.nextRun(or: run)
        try await pool.write { db in try db.execute(sql: "DROP TABLE email_accounts") }
        vm.cancelConnect()
        await run.value

        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.readError)
    }

    func testCancelAfterTheRunExitedStaysIdle() async throws {
        let stub = try stub()
        let vm = try makeVM(stub, daemon: FakeDaemonRestarter())

        let run = try XCTUnwrap(vm.connectOutlook())
        await stub.release(try await stub.nextRun(or: run), exitCode: 0)
        await run.value

        vm.cancelConnect()
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.error)
    }

    func testCancelledRunsLateExitLeavesTheNextConnectRunning() async throws {
        let stub = try stub(ignoreTerm: true)
        let daemon = FakeDaemonRestarter()
        let vm = try makeVM(stub, daemon: daemon)

        let first = try XCTUnwrap(vm.connectOutlook())
        let firstPID = try await stub.nextRun(or: first)
        vm.cancelConnect() // SIGTERM is ignored: the first run lives on
        let second = try XCTUnwrap(vm.connectOutlook())
        let secondPID = try await stub.nextRun(or: second)

        await stub.release(firstPID, exitCode: 1)
        await first.value
        XCTAssertTrue(vm.isRunning, "the stale completion must not reset the second connect")
        XCTAssertNil(vm.error)

        XCTAssertEqual(daemon.restartCount, 0)

        // The second exits 0 though cancelled: a finished connect, so it
        // keeps its daemon restart.
        vm.cancelConnect()
        await stub.release(secondPID, exitCode: 0)
        await second.value
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 1)
    }
}

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
    private func makeVM(_ stub: GatedLoginStub) throws -> ExternalConnectionsViewModel {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return ExternalConnectionsViewModel(dbPool: pool, makeRunner: { nil }, cliPath: { stub.path })
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

        let run = Task { await vm.signIn(wiki) }
        _ = await stub.nextRun()
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

    func testCancelAfterTheRunExitedStaysIdle() async throws {
        let stub = try stub()
        let vm = try makeVM(stub)
        let wiki = connection(3, "acme-wiki")

        let run = Task { await vm.signIn(wiki) }
        await stub.release(await stub.nextRun(), exitCode: 0)
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

        let first = Task { await vm.signIn(wiki) }
        let firstPID = await stub.nextRun()
        vm.cancelSignIn() // SIGTERM is ignored: the first run lives on
        let second = Task { await vm.signIn(docs) }
        let secondPID = await stub.nextRun()

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

        let run = Task { await vm.signIn(wiki) }
        _ = await stub.nextRun()
        XCTAssertNoThrow(try row.inspect().find(text: copy.line))
        XCTAssertNoThrow(try row.inspect().find(text: copy.hint))
        XCTAssertThrowsError(try row.inspect().find(button: "Sign in again"))
        XCTAssertThrowsError(try row.inspect().find(button: "Remove"))

        try row.inspect().find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.signInConnectionID)
        await run.value
        XCTAssertNil(vm.error)
    }
}

/// O1 (#2132): the Add Outlook sheet's Cancel already existed; a cancelled
/// run's late exit must not reset a connect started right after it.
@MainActor
final class OutlookConnectCancelTests: XCTestCase {
    private func makeVM(_ stub: GatedLoginStub, daemon: FakeDaemonRestarter) throws -> EmailAccountsViewModel {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return EmailAccountsViewModel(dbPool: pool, daemon: daemon) { stub.path }
    }

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
        _ = await stub.nextRun()
        XCTAssertTrue(vm.isRunning)

        vm.cancelConnect()
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.error)

        await run.value
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testCancelAfterTheRunExitedStaysIdle() async throws {
        let stub = try stub()
        let vm = try makeVM(stub, daemon: FakeDaemonRestarter())

        let run = try XCTUnwrap(vm.connectOutlook())
        await stub.release(await stub.nextRun(), exitCode: 0)
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
        let firstPID = await stub.nextRun()
        vm.cancelConnect() // SIGTERM is ignored: the first run lives on
        let second = try XCTUnwrap(vm.connectOutlook())
        let secondPID = await stub.nextRun()

        await stub.release(firstPID, exitCode: 1)
        await first.value
        XCTAssertTrue(vm.isRunning, "the stale completion must not reset the second connect")
        XCTAssertNil(vm.error)

        vm.cancelConnect()
        await stub.release(secondPID, exitCode: 0)
        await second.value
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 0)
    }
}

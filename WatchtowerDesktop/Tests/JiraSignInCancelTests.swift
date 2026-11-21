import DesignKit
import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Connections → Jira, a site's **Re-login** waiting in the browser (#2132
/// A1): the row shows the waiting line and Cancel, and a Cancel is silent —
/// idle at once, no error, and the cancelled run's late end writes nothing.
@MainActor
final class JiraSignInCancelTests: XCTestCase {
    private let copy = SignInWaitCopy.atlassian

    /// Account re-reads after the first one (`onAccountsChanged`).
    private var rereads = 0

    private func make(ignoresTerm: Bool = false) async throws
        -> (JiraAccountsViewModel, AtlassianSignInStub, JiraAccount, DatabasePool) {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            _ = try TestDatabase.insertJiraAccount(db, siteURL: "https://acme.atlassian.net", status: "error",
                                                   error: "token expired")
        }
        let stub = try AtlassianSignInStub(ignoresTerm: ignoresTerm, test: self)
        let vm = JiraAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { stub.cli }
        await vm.refreshAsync()
        let account = try XCTUnwrap(vm.accounts.first)
        vm.onAccountsChanged = { [weak self] in self?.rereads += 1 }
        return (vm, stub, account, pool)
    }

    // MARK: - The cancel trio

    /// Start → busy on this account; Cancel → idle at once, with no error.
    func testCancelEndsTheReloginSilently() async throws {
        let (vm, stub, account, _) = try await make()
        let run = Task { await vm.relogin(account) }
        await stub.started(1, of: run)
        XCTAssertTrue(vm.isConnecting)
        XCTAssertEqual(vm.signInAccountID, account.id)

        vm.cancelConnect()
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.signInAccountID)
        XCTAssertNil(vm.error)

        await run.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error, "a Cancel is not an error")
        XCTAssertEqual(rereads, 1, "the Cancel re-read the accounts once")
        XCTAssertEqual(stub.argv, ["jira login --account \(account.id) --app-return"])
    }

    /// The CLI ends as the owner presses Cancel: still idle, no error.
    func testCancelAsTheReloginEndsIsSilent() async throws {
        let (vm, stub, account, _) = try await make()
        let run = Task { await vm.relogin(account) }
        await stub.started(1, of: run)
        await stub.release(1, exitCode: 0)
        vm.cancelConnect()

        await run.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.signInAccountID)
        XCTAssertNil(vm.error)
    }

    /// Cancel, Re-login again, then the first CLI ends (it ignored the
    /// terminate): its late end leaves the new run busy, and shows no error.
    func testStaleReloginEndKeepsTheNewRunBusy() async throws {
        let (vm, stub, account, _) = try await make(ignoresTerm: true)
        let first = Task { await vm.relogin(account) }
        await stub.started(1, of: first)
        vm.cancelConnect()

        let second = Task { await vm.relogin(account) }
        await stub.started(2, of: second)
        await stub.release(1, exitCode: 1)
        await first.value
        XCTAssertTrue(vm.isConnecting, "the first run's end did not reset the second")
        XCTAssertEqual(vm.signInAccountID, account.id)
        XCTAssertNil(vm.error)
        XCTAssertEqual(rereads, 1, "the cancelled run re-read the accounts")

        vm.cancelConnect()
        await stub.release(2, exitCode: 1)
        await second.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
    }

    // MARK: - The row

    /// The waiting row: the two lines under its name and Cancel in place of
    /// its buttons; Cancel ends the sign-in and the row offers Re-login again.
    func testWaitingRowShowsTheLineAndCancel() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let (vm, stub, account, _) = try await make()
        appState.jiraAccountsViewModel = vm

        let idle = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try idle.inspect().find(button: RowStatus.Action.relogin.title))
        XCTAssertThrowsError(try idle.inspect().find(text: copy.line))

        let run = Task { await vm.relogin(account) }
        await stub.started(1, of: run)
        let waiting = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try waiting.inspect().find(text: copy.line))
        XCTAssertNoThrow(try waiting.inspect().find(text: copy.hint))
        XCTAssertThrowsError(try waiting.inspect().find(button: RowStatus.Action.relogin.title))
        XCTAssertThrowsError(try waiting.inspect().find(button: "Rename…"))
        try waiting.inspect().find(SignInWaitCancel.self).find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isConnecting)

        await run.value
        XCTAssertNil(vm.error)
        let after = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try after.inspect().find(button: RowStatus.Action.relogin.title))
        XCTAssertThrowsError(try after.inspect().find(text: copy.line))
    }

    /// A Confluence grant of the site waits in its own section, not on the row.
    func testConfluenceGrantDoesNotMarkTheRow() async throws {
        let (vm, stub, account, _) = try await make()
        let run = Task { await vm.reloginWithConfluence(accountID: account.id) }
        await stub.started(1, of: run)
        XCTAssertTrue(vm.isConnecting)
        XCTAssertNil(vm.signInAccountID)
        vm.cancelConnect()
        await run.value
    }
}

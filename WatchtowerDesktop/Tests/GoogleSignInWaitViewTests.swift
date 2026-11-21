import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Where a waiting Google sign-in shows its line and Cancel (#2132 G1–G4):
/// the Re-login row, the add section, the Calendar banner and its top line.
/// The sign-in is held before its CLI launches (the login environment never
/// resolves), so no process runs.
@MainActor
final class GoogleSignInWaitViewTests: XCTestCase {
    private let copy = SignInWaitCopy.google

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return pool
    }

    /// A model with one account (`status`), whose sign-ins wait on `gate`.
    private func makeVM(status: String, gate: AsyncGate) async throws -> (GoogleAccountsViewModel, GoogleAccount) {
        let pool = try pool()
        _ = try await pool.write { db in
            try TestDatabase.insertGoogleAccount(db, email: "team@acme.example", calendarEnabled: true, status: status)
        }
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { "/usr/bin/false" }
        vm.loginEnvironment = { await gate.wait(); return [:] }
        await vm.refreshAsync()
        addTeardownBlock { @MainActor in
            vm.cancelConnect()
            gate.release()
            await vm.signInTask?.value
        }
        return (vm, try XCTUnwrap(vm.accounts.first))
    }

    private func detail(_ appState: AppState) -> some View {
        GoogleConnectionDetail(config: appState.sharedConfig).environment(appState)
    }

    // MARK: - Connections → Google

    /// G1: the waiting row trades Re-login for Cancel and shows the lines;
    /// Cancel brings Re-login back.
    func testWaitingRowShowsTheLineAndCancel() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let (vm, account) = try await makeVM(status: "error", gate: AsyncGate())
        appState.googleAccountsViewModel = vm
        let view = detail(appState)
        XCTAssertNoThrow(try view.inspect().find(button: RowStatus.Action.relogin.title))
        XCTAssertThrowsError(try view.inspect().find(text: copy.line))

        vm.relogin(account)
        XCTAssertNoThrow(try view.inspect().find(SignInWaitText.self))
        XCTAssertNoThrow(try view.inspect().find(text: copy.hint))
        XCTAssertThrowsError(try view.inspect().find(button: RowStatus.Action.relogin.title))
        XCTAssertThrowsError(try view.inspect().find(SignInWaitLine.self), "the row's line, not the section's")

        try view.inspect().find(SignInWaitCancel.self).find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
        XCTAssertNoThrow(try view.inspect().find(button: RowStatus.Action.relogin.title))
        XCTAssertThrowsError(try view.inspect().find(text: copy.line))
    }

    /// G2: Connect Google Calendar waits under the add section's buttons.
    func testConnectCalendarShowsTheLineInTheAddSection() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let (vm, _) = try await makeVM(status: "ok", gate: AsyncGate())
        appState.googleAccountsViewModel = vm
        let view = detail(appState)

        try view.inspect().find(button: CompanyConnectionsPresentation.connectCalendar).tap()
        XCTAssertEqual(vm.signIn, .section)
        let line = try view.inspect().find(SignInWaitLine.self)
        XCTAssertNoThrow(try line.find(text: copy.line))
        XCTAssertThrowsError(try view.inspect().find(SignInWaitCancel.self), "no row waits")

        try line.find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
        XCTAssertThrowsError(try view.inspect().find(SignInWaitLine.self))
    }

    // MARK: - Calendar

    /// G3/G4: the banner of the account that signs in carries the line;
    /// any other Google sign-in waits at Calendar's top.
    func testCalendarSignInWaitSpot() throws {
        let account = try XCTUnwrap(try pool().write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "team@acme.example", status: "error")
            return try GoogleAccount.fetchOne(db, sql: "SELECT * FROM google_accounts")
        })
        typealias View = CalendarEventsView
        XCTAssertEqual(View.signInWaitSpot(nil, health: .accountError(account)), .none)
        XCTAssertEqual(View.signInWaitSpot(.account(account.id), health: .accountError(account)), .account)
        XCTAssertEqual(View.signInWaitSpot(.account(account.id + 1), health: .accountError(account)), .top)
        XCTAssertEqual(View.signInWaitSpot(.section, health: .accountError(account)), .top)
        XCTAssertEqual(View.signInWaitSpot(.account(account.id), health: .ok), .top)
        XCTAssertEqual(View.signInWaitSpot(.section, health: .syncOff), .top)
    }

    /// G4: the legacy Reconnect waits at Calendar's top, and the empty
    /// state's own Connect waits its turn.
    func testCalendarTopLineAndDisabledConnect() async throws {
        let appState = AppState.isolated()
        let (vm, _) = try await makeVM(status: "ok", gate: AsyncGate())
        appState.googleAccountsViewModel = vm
        let view = CalendarEventsView().environment(appState)
        let connect = Self.connectCalendarTitle
        XCTAssertFalse(try view.inspect().find(button: connect).isDisabled())
        XCTAssertThrowsError(try view.inspect().find(SignInWaitLine.self))

        appState.reconnectGoogleCalendar(accountID: nil)
        XCTAssertEqual(vm.signIn, .section)
        XCTAssertNoThrow(try view.inspect().find(SignInWaitLine.self).find(text: copy.line))
        XCTAssertTrue(try view.inspect().find(button: connect).isDisabled())

        try view.inspect().find(SignInWaitLine.self).find(button: copy.cancelTitle).tap()
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
        XCTAssertThrowsError(try view.inspect().find(SignInWaitLine.self))
        XCTAssertFalse(try view.inspect().find(button: connect).isDisabled())
    }

    private static let connectCalendarTitle = "Connect Google Calendar"

    /// A §4.3 status row (Re-login to finish the setup) gives its status way
    /// to the waiting lines while its Re-login waits.
    func testWaitingRowHidesItsStatus() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        _ = try await pool.write { db in
            try TestDatabase.insertGoogleAccount(db, email: "team@acme.example", calendarEnabled: true,
                                                 status: "ok", error: "pdr_scope_missing")
        }
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { "/usr/bin/false" }
        let gate = AsyncGate()
        vm.loginEnvironment = { await gate.wait(); return [:] }
        await vm.refreshAsync()
        addTeardownBlock { @MainActor in
            vm.cancelConnect()
            gate.release()
            await vm.signInTask?.value
        }
        appState.googleAccountsViewModel = vm
        let view = detail(appState)
        XCTAssertNoThrow(try view.inspect().find(text: CompanyConnectionsPresentation.pdrScopeMissing))

        vm.relogin(try XCTUnwrap(vm.accounts.first))
        XCTAssertThrowsError(try view.inspect().find(text: CompanyConnectionsPresentation.pdrScopeMissing))
        XCTAssertNoThrow(try view.inspect().find(text: copy.line))
    }

    /// The list failed to read: a waiting sign-in still shows its line and
    /// Cancel in the section (a Re-login has no row on screen).
    func testReadFailedListKeepsTheWaitingLine() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        try await pool.write { db in try db.execute(sql: "DROP TABLE google_accounts") }
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { "/usr/bin/false" }
        let gate = AsyncGate()
        vm.loginEnvironment = { await gate.wait(); return [:] }
        await vm.refreshAsync()
        XCTAssertNotNil(vm.readError)
        addTeardownBlock { @MainActor in
            vm.cancelConnect()
            gate.release()
            await vm.signInTask?.value
        }
        appState.googleAccountsViewModel = vm
        let view = detail(appState)

        for start in [{ vm.reloginLegacyCalendar() }, { vm.relogin(accountID: 3) }] {
            start()
            let line = try view.inspect().find(SignInWaitLine.self)
            try line.find(button: copy.cancelTitle).tap()
            XCTAssertFalse(vm.isConnecting)
            XCTAssertThrowsError(try view.inspect().find(SignInWaitLine.self))
        }
    }

    /// The Add sheet waits only for its own sign-in: while another place's
    /// runs, it offers no Cancel and its Connect is disabled.
    func testAddSheetLeavesAnotherPlacesSignInAlone() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let (vm, account) = try await makeVM(status: "error", gate: AsyncGate())
        appState.googleAccountsViewModel = vm
        let view = AddGoogleAccountView(offersGmail: false).environment(appState)

        vm.relogin(account)
        XCTAssertThrowsError(try view.inspect().find(button: "Cancel"))
        XCTAssertTrue(try view.inspect().find(button: "Connect").isDisabled())
        XCTAssertTrue(vm.isConnecting)
    }

    /// A Reconnect from the alert with no account banner that fails: its
    /// error shows at Calendar's top, where its waiting line was.
    func testCalendarTopShowsAFailedSignInsError() async throws {
        let stub = try GatedLoginStub()
        addTeardownBlock { stub.reap() }
        let appState = AppState.isolated()
        let vm = GoogleAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { stub.path }
        vm.loginEnvironment = { [:] }
        await vm.refreshAsync()
        appState.googleAccountsViewModel = vm
        let view = CalendarEventsView().environment(appState)

        appState.reconnectGoogleCalendar(accountID: nil)
        let run = try XCTUnwrap(vm.signInTask)
        await stub.release(try await stub.nextRun(or: run), exitCode: 1)
        await run.value

        let error = try XCTUnwrap(vm.error)
        XCTAssertEqual(vm.failedSignIn, .section)
        XCTAssertNoThrow(try view.inspect().find(text: error))
        XCTAssertThrowsError(try view.inspect().find(SignInWaitLine.self))
        XCTAssertTrue(CalendarEventsView.showsSignInFailureAtTop(.section, health: .ok))
        XCTAssertFalse(CalendarEventsView.showsSignInFailureAtTop(nil, health: .ok))
    }
}

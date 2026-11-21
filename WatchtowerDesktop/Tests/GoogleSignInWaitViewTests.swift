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
}

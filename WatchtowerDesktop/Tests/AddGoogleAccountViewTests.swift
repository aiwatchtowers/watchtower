import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Add Google Account without "Advanced: custom OAuth client" (#1887 C4,
/// S19): an own project is the Google detail's page now.
@MainActor
final class AddGoogleAccountViewTests: XCTestCase {
    func testNoCustomClientDisclosure() throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let (appState, _) = LinearConnectionDetailTests.wired()
        appState.googleAccountsViewModel = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { nil }
        let view = AddGoogleAccountView().environment(appState)

        XCTAssertThrowsError(try view.inspect().find(text: "Advanced: custom OAuth client"))
        XCTAssertThrowsError(try view.inspect().find(ViewType.SecureField.self), "no client secret field")
        XCTAssertThrowsError(try view.inspect().find(ViewType.TextField.self), "no client id field")
        XCTAssertFalse(try view.inspect().find(button: "Connect").isDisabled())
    }

    /// The shared app asks for Calendar only (#1887 D11): Gmail is shown off
    /// and disabled, the note says where it connects, and Connect asks for
    /// Calendar alone.
    func testSharedPathGmailOffWithNote() throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let view = AddGoogleAccountView(offersGmail: false).environment(appState)

        let gmail = try view.inspect().find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Gmail" }
        XCTAssertTrue(gmail.isDisabled())
        XCTAssertFalse(try gmail.isOn())
        XCTAssertNoThrow(try view.inspect().find(text: CompanyConnectionsPresentation.sharedGoogleGmailNote(locks: [])))
        XCTAssertFalse(try view.inspect().find(button: "Connect").isDisabled(), "Calendar alone still connects")
    }

    /// The safety property itself: Connect on the shared path asks the CLI
    /// for Calendar only, never `--gmail` (Go would refuse it, D11).
    func testSharedPathConnectAsksForCalendarOnly() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let (appState, _) = LinearConnectionDetailTests.wired()
        let cli = try GoogleConnectionDetailTests.stubCLI(test: self)
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { cli.path }
        vm.loginEnvironment = { [:] }
        appState.googleAccountsViewModel = vm
        let view = AddGoogleAccountView(offersGmail: false).environment(appState)

        try view.inspect().find(button: "Connect").tap()
        await vm.signInTask?.value
        let args = try String(contentsOf: cli.log, encoding: .utf8)
        XCTAssertEqual(args.trimmingCharacters(in: .whitespacesAndNewlines), "google add --app-return --calendar")
    }

    /// The sheet closes only when its own attempt connected: a Cancel
    /// pressed in another view (Calendar, the Google detail) ends the
    /// attempt silently, and the count of connected sign-ins stays put.
    func testSheetClosesOnlyOnItsOwnConnect() async throws {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        let stub = try GatedLoginStub()
        addTeardownBlock { stub.reap() }
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { stub.path }
        vm.loginEnvironment = { [:] }

        let before = vm.connectedSignIns
        vm.addAccount(calendar: true, gmail: false, clientID: "", clientSecret: "", daemonPolicy: .deferred)
        let cancelled = try XCTUnwrap(vm.signInTask)
        _ = try await stub.nextRun(or: cancelled)
        vm.cancelConnect() // pressed in another view
        await cancelled.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
        XCTAssertFalse(AddGoogleAccountView.ownAttemptConnected(before: before, now: vm.connectedSignIns),
                       "a silent cancel does not close the sheet")

        vm.addAccount(calendar: true, gmail: false, clientID: "", clientSecret: "", daemonPolicy: .deferred)
        let connected = try XCTUnwrap(vm.signInTask)
        await stub.release(try await stub.nextRun(or: connected), exitCode: 0)
        await connected.value
        XCTAssertTrue(AddGoogleAccountView.ownAttemptConnected(before: before, now: vm.connectedSignIns))
        XCTAssertFalse(AddGoogleAccountView.ownAttemptConnected(before: before, now: nil))
    }

    /// Own projects locked (§5.4): the note names the company's project only.
    func testSharedPathNoteUnderOwnProjectLock() throws {
        let (appState, _) = LinearConnectionDetailTests.wired(policy: ["AllowOwnGoogleProject": false])
        let view = AddGoogleAccountView(offersGmail: false).environment(appState)
        XCTAssertNoThrow(try view.inspect().find(
            text: CompanyConnectionsPresentation.sharedGoogleGmailNote(locks: [.ownGoogleProject])))
    }

    /// A flavored build's client asks for Gmail: the switch is live and on, no note.
    func testFlavoredBuildOffersGmail() throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let view = AddGoogleAccountView(offersGmail: true).environment(appState)

        let gmail = try view.inspect().find(ViewType.Toggle.self) { try $0.labelView().text().string() == "Gmail" }
        XCTAssertFalse(gmail.isDisabled())
        XCTAssertTrue(try gmail.isOn())
        XCTAssertThrowsError(try view.inspect().find(text: CompanyConnectionsPresentation.sharedGoogleGmailNote(locks: [])))
    }
}

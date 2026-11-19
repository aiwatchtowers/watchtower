import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Connections → Google off `Form` and grouped by company (#1887 Task 25b,
/// company screens spec §4.2, §5.3, §7): the empty state's buttons, a failed
/// read that is never "nothing connected", and the shared-Gmail banner from
/// Go's `shared_gmail` flag.
@MainActor
final class GoogleConnectionDetailTests: XCTestCase {
    private typealias Pres = CompanyConnectionsPresentation

    /// A stand-in CLI: appends its arguments to `log` and prints `stdout`.
    static func stubCLI(stdout: String = "", test: XCTestCase) throws -> (path: String, log: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("args.log")
        let stub = dir.appendingPathComponent("watchtower")
        let script = "#!/bin/sh\necho \"$@\" >> '\(log.path)'\ncat <<'JSON'\n\(stdout)\nJSON\n"
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return (stub.path, log)
    }

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return pool
    }

    private func detail(_ appState: AppState) -> some View {
        GoogleConnectionDetail(config: appState.sharedConfig).environment(appState)
    }

    func testLoadingBeforeTheFirstRead() throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        appState.googleAccountsViewModel = GoogleAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { nil }
        let view = detail(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.googleLoading))
        XCTAssertThrowsError(try view.inspect().find(text: Pres.googleEmpty))
    }

    /// §5.3: no account and no company → the empty line with Connect Google
    /// Calendar (Calendar only on the shared app, D11), Use my own Google
    /// project and Paste a company code.
    func testEmptyStateActions() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let cli = try Self.stubCLI(test: self)
        let vm = GoogleAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { cli.path }
        vm.loginEnvironment = { [:] }
        appState.googleAccountsViewModel = vm
        await vm.refreshAsync()

        let view = detail(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.googleEmpty))
        XCTAssertNoThrow(try view.inspect().find(button: CompanyBanner.Action.useOwnGoogle.title))
        XCTAssertThrowsError(try view.inspect().find(text: Pres.addAccountTitle), "the empty state holds the buttons")

        try view.inspect().find(button: Pres.connectCalendar).tap()
        await vm.addTask?.value
        let args = try String(contentsOf: cli.log, encoding: .utf8)
        XCTAssertEqual(args.trimmingCharacters(in: .whitespacesAndNewlines), "google add --app-return --calendar",
                       "the shared app is asked for Calendar only")

        appState.openConnections(.google)
        try view.inspect().find(button: RowStatus.Action.pasteCode.title).tap()
        XCTAssertTrue(appState.companiesZone.codeFieldOpen)
        XCTAssertNil(appState.selectedConnection, "the overview, where the code field is")
    }

    /// A failed read with nothing listed is its own state with Try again,
    /// never the empty state's invitation.
    func testReadFailedIsNotEmpty() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        try await pool.write { db in try db.execute(sql: "DROP TABLE google_accounts") }
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { nil }
        appState.googleAccountsViewModel = vm
        await vm.refreshAsync()
        XCTAssertNotNil(vm.readError)

        let view = detail(appState)
        let line = try XCTUnwrap(vm.readError.map { Pres.readFailed(.google, $0) })
        XCTAssertTrue(line.hasPrefix("Could not read Google accounts: "))
        XCTAssertNoThrow(try view.inspect().find(text: line))
        XCTAssertNoThrow(try view.inspect().find(button: Pres.tryAgain))
        XCTAssertThrowsError(try view.inspect().find(text: Pres.googleEmpty))
        XCTAssertThrowsError(try view.inspect().find(button: Pres.connectCalendar))
    }

    /// Go's `shared_gmail` flag gives the §7 banner and the row's tag; the
    /// overview card says it without counting it as a problem.
    func testSharedGmailBanner() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO google_accounts (id, email, gmail_enabled, status) VALUES (1, 'bob@example.org', 1, 'ok')")
        }
        let cli = try Self.stubCLI(stdout: #"[{"id":1,"shared_gmail":true}]"#, test: self)
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter(), cliPath: { cli.path },
                                         readsAccountFlags: true)
        appState.googleAccountsViewModel = vm
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedFlags.accountIDs, [1])

        let view = detail(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.googleBannerTitle))
        XCTAssertNoThrow(try view.inspect().find(text: Pres.sharedTag))
        let summary = appState.connectionSummary(.google)
        XCTAssertEqual(summary.statusLine, Pres.googleBannerCardLine)
        XCTAssertFalse(summary.needsAttention, "a banner is not an attention item")

        // The banner's Paste a company code opens the overview's field.
        try view.inspect().find(CompanyBannerView.self).find(button: RowStatus.Action.pasteCode.title).tap()
        XCTAssertTrue(appState.companiesZone.codeFieldOpen)
    }

    /// Use my own Google project opens the add sheet with the custom client
    /// shown and required: Gmail never goes to the shared app (D11).
    func testOwnProjectSheetNeedsTheClient() throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        appState.googleAccountsViewModel = GoogleAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { nil }
        let own = AddGoogleAccountView(requiresCustomClient: true).environment(appState)
        XCTAssertTrue(try own.inspect().find(button: "Connect").isDisabled())
        let plain = AddGoogleAccountView().environment(appState)
        XCTAssertFalse(try plain.inspect().find(button: "Connect").isDisabled(), "onboarding's sheet is unchanged")
    }

    /// §5.4: under the lock, Use my own Google project is gone from the
    /// add buttons and the banner.
    func testOwnProjectLockHidesTheButton() {
        let appState = AppState.isolated(managedPolicy: ["AllowOwnGoogleProject": false])
        appState.managedPolicy.refresh()
        XCTAssertEqual(appState.companyLocks, [.ownGoogleProject])
        XCTAssertFalse(appState.companyDetailActions(.google, empty: true).contains { $0.kind == .useOwnGoogle })
    }
}

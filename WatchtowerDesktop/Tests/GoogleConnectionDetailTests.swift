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

    /// §5.1: Use my own Google project opens its page in the detail, and
    /// **‹ Google** leaves it.
    func testUseOwnGoogleOpensThePage() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let vm = GoogleAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { nil }
        appState.googleAccountsViewModel = vm
        await vm.refreshAsync()

        let view = detail(appState)
        try view.inspect().find(button: CompanyBanner.Action.useOwnGoogle.title).tap()
        XCTAssertTrue(appState.ownGoogleProject.isOpen)
        XCTAssertNoThrow(try view.inspect().find(OwnGoogleProjectPage.self))
        XCTAssertNoThrow(try view.inspect().find(text: OwnGoogleProjectModel.intro))
        XCTAssertTrue(try view.inspect().find(button: OwnGoogleProjectModel.connectTitle).isDisabled(), "no JSON yet")

        try view.inspect().find(button: OwnGoogleProjectModel.backTitle).tap()
        XCTAssertFalse(appState.ownGoogleProject.isOpen)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.googleEmpty))
    }

    /// AppState's own-project model waits for the other Google sign-ins, and
    /// a connect re-reads the accounts and re-wires the daemon.
    func testOwnProjectWiring() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let vm = GoogleAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { nil }
        appState.googleAccountsViewModel = vm
        let own = appState.ownGoogleProject
        own.drop(Data(#"{"installed":{"client_id":"9876-home","client_secret":"s"}}"#.utf8), fileName: "c.json")
        XCTAssertTrue(own.canConnect)
        vm.isConnecting = true
        XCTAssertFalse(own.canConnect, "a Google sign-in of the detail runs")
        XCTAssertTrue(appState.companyDetailBusy(.google))
        vm.isConnecting = false

        XCTAssertNil(vm.daemonRestartTask)
        own.onConnected?()
        XCTAssertNotNil(vm.daemonRestartTask, "the new account's first sync is wired")
        await vm.daemonRestartTask?.value
    }

    /// §5.4 with Go's `own_project` flag: an untied legacy own-credentials
    /// account sits under "Your own Google project" (not the shared app),
    /// stopped by the organization with no Re-login, then the lock card;
    /// a company account is untouched; the page cannot open.
    func testOwnProjectLockStopsItsRowsAndShowsTheCard() async throws {
        let appState = AppState.isolated(managedPolicy: ["AllowOwnGoogleProject": false])
        appState.managedPolicy.refresh()
        let pool = try pool()
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO google_accounts (id, email, gmail_enabled, status, error) "
                + "VALUES (1, 'alice@example.net', 1, 'error', 'token expired')")
        }
        let cli = try Self.stubCLI(stdout: #"[{"id":1,"shared_gmail":false,"own_project":true}]"#, test: self)
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter(), cliPath: { cli.path },
                                         readsAccountFlags: true)
        appState.googleAccountsViewModel = vm
        await vm.refreshAsync()

        let groups = appState.companyAccountGroups(.google)
        XCTAssertEqual(groups.map(\.kind), [.ownProject])
        let ref = try XCTUnwrap(appState.companyAccountRefs.first)
        XCTAssertTrue(appState.companyRowStoppedByPolicy(ref))
        XCTAssertEqual(appState.companyRowStatus(ref)?.text, Pres.stoppedByPolicyLine)

        let view = detail(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.groupOwnGoogle))
        XCTAssertNoThrow(try view.inspect().find(text: Pres.stoppedByPolicyLine))
        XCTAssertNoThrow(try view.inspect().find(text: Pres.lockCard(.ownGoogleProject).text))
        XCTAssertNoThrow(try view.inspect().find(button: ManagedPolicyHelp.label))
        XCTAssertThrowsError(try view.inspect().find(button: RowStatus.Action.relogin.title), "Go refuses its sign-in")
        XCTAssertThrowsError(try view.inspect().find(button: CompanyBanner.Action.useOwnGoogle.title))

        appState.ownGoogleProject.open()
        XCTAssertThrowsError(try view.inspect().find(OwnGoogleProjectPage.self), "the lock wins over an open page")
    }

    /// D11: a shared-app Gmail row that must sign in again offers the move to
    /// an own project instead of a Re-login the shared app would refuse.
    func testSharedGmailRowOffersTheMove() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO google_accounts (id, email, gmail_enabled, calendar_enabled, status) "
                + "VALUES (1, 'bob@example.org', 1, 1, 'ok'), (2, 'carol@example.org', 1, 1, 'error')")
        }
        let cli = try Self.stubCLI(stdout: #"[{"id":1,"shared_gmail":true},{"id":2,"shared_gmail":true}]"#, test: self)
        let vm = GoogleAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter(), cliPath: { cli.path },
                                         readsAccountFlags: true)
        appState.googleAccountsViewModel = vm
        await vm.refreshAsync()

        let view = detail(appState)
        XCTAssertThrowsError(try view.inspect().find(button: RowStatus.Action.relogin.title))
        let moves = try view.inspect().findAll(ViewType.Button.self) {
            try $0.labelView().text().string() == CompanyBanner.Action.useOwnGoogle.title
        }
        XCTAssertGreaterThanOrEqual(moves.count, 3, "the banner's, the stopped row's and the add section's")
        let before = moves.count
        try await pool.write { db in try db.execute(sql: "UPDATE google_accounts SET status = 'ok' WHERE id = 2") }
        await vm.refreshAsync()
        let after = try view.inspect().findAll(ViewType.Button.self) {
            try $0.labelView().text().string() == CompanyBanner.Action.useOwnGoogle.title
        }.count
        XCTAssertLessThan(after, before, "a syncing shared row has no move button")
        try moves[0].tap()
        XCTAssertTrue(appState.ownGoogleProject.isOpen)
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

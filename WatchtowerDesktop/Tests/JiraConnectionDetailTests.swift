import GRDB
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Connections → Jira off `Form` and grouped by company (#1887 Task 25b,
/// company screens spec §4.2, §6.4, §7): the empty state's buttons, a failed
/// read that is never "nothing connected", the company's Atlassian app as
/// the way to add a site, and the retired-shared-app banner from Go's
/// `shared_atlassian` flag (D15 amended: Re-login, no countdown).
@MainActor
final class JiraConnectionDetailTests: XCTestCase {
    private typealias Pres = CompanyConnectionsPresentation

    static let acmeWithAtlassian = #"{"companies":[{"slug":"acme","company":"Acme","forced":false,"personal":false,"#
        + #""vendors":{"atlassian":{"client_id":"atl-1","site":"https://acme.atlassian.net"}}}],"errors":[],"#
        + #""draft":{"state":"none"}}"#

    private func pool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        addTeardownBlock { TestDatabase.cleanup(path: path) }
        return pool
    }

    /// §6.4: no site and no company → the empty line with **Connect with an
    /// API token** (it opens the token sheet) and Paste a company code; no
    /// Add Jira Site (the shared app is retired).
    func testEmptyStateActions() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let vm = JiraAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { nil }
        appState.jiraAccountsViewModel = vm
        let loading = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try loading.inspect().find(text: Pres.jiraLoading))

        await vm.refreshAsync()
        let view = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.jiraEmpty))
        XCTAssertThrowsError(try view.inspect().find(button: "Add Jira Site"))
        try view.inspect().find(button: CompanyBanner.Action.connectWithToken.title).tap()
        XCTAssertTrue(appState.atlassianToken.isPresented)
        XCTAssertEqual(appState.atlassianToken.mode, .add)
        appState.atlassianToken.close()
        appState.openConnections(.jira)
        try view.inspect().find(button: RowStatus.Action.pasteCode.title).tap()
        XCTAssertTrue(appState.companiesZone.codeFieldOpen)
        XCTAssertNil(appState.selectedConnection)
    }

    func testReadFailedIsNotEmpty() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        try await pool.write { db in try db.execute(sql: "DROP TABLE jira_accounts") }
        let vm = JiraAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { nil }
        appState.jiraAccountsViewModel = vm
        await vm.refreshAsync()

        let view = JiraConnectionDetail().environment(appState)
        let line = try XCTUnwrap(vm.readError.map { Pres.readFailed(.atlassian, $0) })
        XCTAssertTrue(line.hasPrefix("Could not read Jira sites: "))
        XCTAssertNoThrow(try view.inspect().find(text: line))
        XCTAssertNoThrow(try view.inspect().find(button: Pres.tryAgain))
        XCTAssertThrowsError(try view.inspect().find(text: Pres.jiraEmpty))
    }

    /// A stored company with an Atlassian app: its Not connected row and
    /// Connect with Acme's Atlassian app, which signs in through the
    /// company's stored bundle (no confirm over a link).
    func testCompanyAppConnects() async throws {
        let (appState, fake) = LinearConnectionDetailTests.wired()
        let vm = JiraAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { nil }
        appState.jiraAccountsViewModel = vm
        await vm.refreshAsync()
        fake.enqueue(.init(lines: [Self.acmeWithAtlassian]))
        await appState.companiesZone.reload()

        let view = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.rowNotConnected))
        XCTAssertThrowsError(try view.inspect().find(text: Pres.jiraEmpty))
        try view.inspect().find(button: Pres.connectCompanyApp("Acme", .atlassian)).tap()
        await fake.signal.until { fake.invocations.contains { $0.args.starts(with: ["company", "inspect"]) } }
        let inspect = try XCTUnwrap(fake.invocations.last { $0.args.starts(with: ["company", "inspect"]) })
        XCTAssertEqual(inspect.args, ["company", "inspect", "--json", "--slug", "acme"])
        fake.sessions.last?.exit(code: 1)
        await untilObserved { appState.companyConnect?.isRunning == false }
    }

    /// Go's `shared_atlassian` flag: the §7 banner (Set up for my company
    /// opens the wizard), the row's Shared app tag and its Re-login status
    /// once Go marked the retired client unknown.
    func testSharedAtlassianBanner() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO jira_accounts (id, site_url, status, error) "
                + "VALUES (3, 'https://old.atlassian.net', 'error', 'unknown_client')")
        }
        let cli = try GoogleConnectionDetailTests.stubCLI(stdout: #"[{"id":3,"auth_kind":"oauth","shared_atlassian":true}]"#,
                                                          test: self)
        let vm = JiraAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter(), cliPath: { cli.path },
                                       readsAccountFlags: true)
        appState.jiraAccountsViewModel = vm
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedFlags.accountIDs, [3])

        let view = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.atlassianBannerTitle))
        XCTAssertNoThrow(try view.inspect().find(text: Pres.atlassianBannerBody(["old.atlassian.net"])))
        XCTAssertNoThrow(try view.inspect().find(text: Pres.sharedTag))
        XCTAssertNoThrow(try view.inspect().find(text: Pres.reloginUntied))
        XCTAssertEqual(try view.inspect().find(text: Pres.groupShared).string(), Pres.groupShared)
        let banner = try view.inspect().find(CompanyBannerView.self)
        try banner.find(button: CompaniesZoneState.Action.setUpForCompany.title).tap()
        XCTAssertEqual(appState.selectedConnection, .companySetup)
    }

    /// §6.3: a dead API token's row offers **Paste a new token** (the sheet
    /// in replace mode, email and site read-only), never an OAuth Re-login;
    /// its note names Go's `purge_lease_at` while no purge is scheduled.
    func testDeadTokenRowPastesANewToken() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired()
        let pool = try pool()
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO jira_accounts (id, site_url, status, error, auth_kind, owner_email) "
                + "VALUES (2, 'https://beta.atlassian.net', 'error', 'api_token_dead', 'api_token', 'bob@example.com')")
        }
        let cli = try GoogleConnectionDetailTests.stubCLI(
            stdout: #"[{"id":2,"auth_kind":"api_token","shared_atlassian":false,"purge_lease_at":"2026-12-18T09:00:00Z"}]"#,
            test: self)
        let vm = JiraAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter(), cliPath: { cli.path },
                                       readsAccountFlags: true)
        appState.jiraAccountsViewModel = vm
        await vm.refreshAsync()

        let view = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.tokenDead))
        let lease = Pres.tokenLease(Date(timeIntervalSince1970: 1_797_584_400), zone: .current)
        XCTAssertNoThrow(try view.inspect().find(text: lease))
        XCTAssertThrowsError(try view.inspect().find(button: RowStatus.Action.relogin.title))
        try view.inspect().find(button: RowStatus.Action.pasteNewToken.title).tap()
        XCTAssertTrue(appState.atlassianToken.isPresented)
        XCTAssertEqual(appState.atlassianToken.mode,
                       .replace(accountID: 2, email: "bob@example.com", site: "https://beta.atlassian.net"))
    }

    /// §6.5: with API tokens forbidden the token site reads "Stopped by your
    /// organization — data kept" under the lock card (no lease note: POLICY-03
    /// holds the lease), and no token offer or new-token button is left.
    func testTokenLock() async throws {
        let (appState, _) = LinearConnectionDetailTests.wired(policy: ["AllowAtlassianAPIToken": false])
        let pool = try pool()
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO jira_accounts (id, site_url, status, error, auth_kind) "
                + "VALUES (2, 'https://beta.atlassian.net', 'error', 'api_token_dead', 'api_token')")
        }
        // Even a lease day on the row (Go holds it, so it would not send one) shows no note.
        let cli = try GoogleConnectionDetailTests.stubCLI(
            stdout: #"[{"id":2,"auth_kind":"api_token","shared_atlassian":false,"purge_lease_at":"2026-12-18T09:00:00Z"}]"#,
            test: self)
        let vm = JiraAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter(), cliPath: { cli.path },
                                       readsAccountFlags: true)
        appState.jiraAccountsViewModel = vm
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedFlags.leaseDates.count, 1)

        let view = JiraConnectionDetail().environment(appState)
        XCTAssertNoThrow(try view.inspect().find(text: Pres.stoppedByPolicyLine))
        XCTAssertNoThrow(try view.inspect().find(text: Pres.tokenLocked))
        XCTAssertNoThrow(try view.inspect().find(button: ManagedPolicyHelp.label))
        XCTAssertThrowsError(try view.inspect().find(text: Pres.tokenDead))
        XCTAssertThrowsError(try view.inspect().find(button: RowStatus.Action.pasteNewToken.title))
        XCTAssertThrowsError(try view.inspect().find(button: CompanyBanner.Action.connectWithToken.title))
        XCTAssertThrowsError(try view.inspect().find(button: RowStatus.Action.relogin.title))
        XCTAssertNil(appState.companyRowStatus(appState.companyAccountRefs[0])?.note)
    }

    /// A failed flags read is not the account read.
    func testFlagsFailureIsNotAReadError() async throws {
        let vm = JiraAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter(), cliPath: { "/usr/bin/false" },
                                       readsAccountFlags: true)
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedFlags.accountIDs, [])
        XCTAssertNil(vm.readError)
        XCTAssertTrue(vm.hasRead)
    }

    /// Off by default: a test view model never runs the CLI for flags.
    func testFlagsNotReadByDefault() async throws {
        let cli = try GoogleConnectionDetailTests.stubCLI(stdout: "[]", test: self)
        let vm = JiraAccountsViewModel(dbPool: try pool(), daemon: FakeDaemonRestarter()) { cli.path }
        await vm.refreshAsync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cli.log.path))
    }
}

import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class JiraAccountsViewModelTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    // MARK: - refresh

    func testRefreshPopulatesAccountsFromDB() async throws {
        let pool = try makePool()
        try await pool.write { db in
            _ = try TestDatabase.insertJiraAccount(db, siteName: "Acme")
        }
        let vm = JiraAccountsViewModel(dbPool: pool)
        XCTAssertTrue(vm.accounts.isEmpty)

        await vm.refreshAsync()

        XCTAssertEqual(vm.accounts.count, 1)
        XCTAssertEqual(vm.accounts[0].siteName, "Acme")
    }

    /// AppState re-resolves the owner (OWNER-01) through this hook: every
    /// add/remove/enable/re-login ends in a refresh, so the callback must fire
    /// after each successful reload.
    func testRefreshNotifiesAccountsChanged() async throws {
        let pool = try makePool()
        let vm = JiraAccountsViewModel(dbPool: pool)
        var calls = 0
        vm.onAccountsChanged = { calls += 1 }

        await vm.refreshAsync()
        await vm.refreshAsync()

        XCTAssertEqual(calls, 2)
    }

    func testRefreshReplacesStaleAccounts() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertJiraAccount(db, siteName: "Acme") }
        let vm = JiraAccountsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.accounts.count, 1)

        try await pool.write { db in try db.execute(sql: "DELETE FROM jira_accounts WHERE id = ?", arguments: [id]) }
        await vm.refreshAsync()

        XCTAssertTrue(vm.accounts.isEmpty)
    }

    // MARK: - addArgs (pure)

    // The connect never names the site: the CLI labels it after its host.
    func testAddArgsCarryNoLabel() {
        let args = JiraAccountsViewModel.addArgs()
        XCTAssertEqual(args, ["jira", "add", "--app-return", "--app-site-picker"])
    }

    // #574: a grant reaching several Atlassian sites is answered from a list,
    // never a typed site — the connect asks the CLI for its site line and
    // never passes `--site`.
    func testAddArgsAskForTheSiteListNotASite() {
        let args = JiraAccountsViewModel.addArgs()
        XCTAssertTrue(args.contains("--app-site-picker"))
        XCTAssertFalse(args.contains("--site"))
    }

    // #573: "Also connect Confluence" widens the same consent.
    func testAddArgsWithConfluence() {
        XCTAssertEqual(
            JiraAccountsViewModel.addArgs(withConfluence: true),
            ["jira", "add", "--app-return", "--app-site-picker", "--with-confluence"]
        )
    }

    // #574: with several sites the CLI prints them and waits; the owner's
    // pick goes back on its stdin and the connect finishes.
    func testSeveralSitesAreChosenFromTheList() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let answer = dir.appendingPathComponent("answer")
        let cli = dir.appendingPathComponent("watchtower")
        let line = #"[jira-sites] {"sites":[{"url":"https://alpha.example.com","name":"Alpha"},"#
            + #"{"url":"https://beta.example.com","name":"Beta"}]}"#
        try "#!/bin/sh\necho '\(line)'\nread -r site\necho \"$site\" > '\(answer.path)'\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let (vm, _, _) = try makeVM(cli: cli.path)

        let connect = Task { await vm.addAccountHoldingRestart(daemonPolicy: .deferred).connected }
        for _ in 0..<500 where vm.siteChoices == nil { try await Task.sleep(for: .milliseconds(10)) }
        let sites = try XCTUnwrap(vm.siteChoices)
        XCTAssertEqual(sites.map(\.name), ["Alpha", "Beta"])
        vm.chooseSite(sites[1])
        XCTAssertNil(vm.siteChoices, "the list goes away once answered")

        let connected = await connect.value
        XCTAssertTrue(connected)
        XCTAssertEqual(try String(contentsOf: answer, encoding: .utf8), "https://beta.example.com\n")
    }

    /// A stand-in `jira add` that offers two sites and records its stdin
    /// answer (`<eof>` when stdin closes unanswered). Like the CLI, no
    /// answer exits 1 with "no site was chosen"; with `connectsOnRerun` set,
    /// a second run connects at once (exit 0).
    private func sitePickerCLI(connectsOnRerun: Bool = false) throws -> (cli: String, answer: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let answer = dir.appendingPathComponent("answer")
        let cli = dir.appendingPathComponent("watchtower")
        let line = #"[jira-sites] {"sites":[{"url":"https://alpha.example.com","name":"Alpha"},"#
            + #"{"url":"https://beta.example.com","name":"Beta"}]}"#
        let ran = dir.appendingPathComponent("ran").path
        let rerun = connectsOnRerun ? "[ -e '\(ran)' ] && exit 0\ntouch '\(ran)'\n" : ""
        let script = "#!/bin/sh\n\(rerun)echo '\(line)'\n"
            + "if read -r site; then echo \"$site\" > '\(answer.path)'; exit 0; fi\n"
            + "echo '<eof>' > '\(answer.path)'\n"
            + "echo 'this Atlassian grant reaches 2 sites and no site was chosen' >&2\nexit 1\n"
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli.path, answer)
    }

    private func waitForSiteChoices(_ vm: JiraAccountsViewModel) async throws -> [JiraSiteChoice] {
        for _ in 0..<500 where vm.siteChoices == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(vm.siteChoices)
    }

    // F1 (#574 review): Cancel on the list closes the CLI's stdin rather than
    // killing it, so `jira add` takes its no-site path (which runs before any
    // account row exists); the sheet sees a Cancel, not an error, and no
    // account appears.
    func testCancelOnTheSiteListClosesStdinAndEndsAsACancel() async throws {
        let stub = try sitePickerCLI()
        let (vm, daemon, _) = try makeVM(cli: stub.cli)

        let connect = Task { await vm.addAccountHoldingRestart(daemonPolicy: .restart) }
        let sites = try await waitForSiteChoices(vm)
        XCTAssertEqual(sites.count, 2)
        vm.declineSiteChoice()
        XCTAssertNil(vm.siteChoices)

        let result = await connect.value
        XCTAssertFalse(result.connected)
        XCTAssertTrue(result.cancelled)
        XCTAssertNil(vm.error, "a Cancel at the list is not an error")
        XCTAssertFalse(vm.isConnecting)
        XCTAssertEqual(try String(contentsOf: stub.answer, encoding: .utf8), "<eof>\n", "the CLI read end-of-file")
        await vm.refreshAsync()
        XCTAssertTrue(vm.accounts.isEmpty)
        vm.finishBoardStep()
        XCTAssertEqual(daemon.restartCount, 0)
    }

    // F2 (#574 review): the sheet closes while `jira add` waits at the list;
    // the flow ends with the sheet, and a reopened sheet's connect works.
    func testClosingTheSheetEndsTheConnectAndANewOneWorks() async throws {
        let stub = try sitePickerCLI(connectsOnRerun: true)
        let (vm, _, _) = try makeVM(cli: stub.cli)

        let first = Task { await vm.addAccountHoldingRestart(daemonPolicy: .deferred) }
        _ = try await waitForSiteChoices(vm)
        vm.abandonConnect()
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.siteChoices)

        let second = await vm.addAccountHoldingRestart(daemonPolicy: .deferred)
        XCTAssertTrue(second.connected, "error: \(vm.error ?? "nil")")
        let firstResult = await first.value
        XCTAssertFalse(firstResult.connected)
        XCTAssertTrue(firstResult.cancelled)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isConnecting)
    }

    // F7 (#574 review): the sheet goes away after Continue. The owner chose
    // the site, so the CLI is left to finish, and the finished connect
    // applies the restart once by itself.
    func testClosingTheSheetAfterContinueLetsTheConnectFinish() async throws {
        let stub = try sitePickerCLI()
        let (vm, daemon, _) = try makeVM(cli: stub.cli)

        let connect = Task { await vm.addAccountHoldingRestart(daemonPolicy: .restart) }
        let sites = try await waitForSiteChoices(vm)
        vm.chooseSite(sites[0])
        // The sheet's onDisappear.
        vm.abandonConnect()
        vm.finishBoardStep()
        XCTAssertTrue(vm.isConnecting, "an answered connect is not cancelled")

        let result = await connect.value
        XCTAssertTrue(result.connected)
        XCTAssertFalse(result.cancelled)
        XCTAssertNil(vm.error)
        XCTAssertEqual(try String(contentsOf: stub.answer, encoding: .utf8), "https://alpha.example.com\n")
        await vm.daemonRestartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
        vm.finishBoardStep()
        await vm.daemonRestartTask?.value
        XCTAssertEqual(daemon.restartCount, 1, "nothing is left held to fire twice")
    }

    // F2: closing the sheet while the consent is still in the browser
    // cancels the flow too.
    func testClosingTheSheetMidConsentCancels() async throws {
        // `exec`: the terminate reaches sleep itself, nothing is left behind.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("watchtower")
        try "#!/bin/sh\nexec sleep 30\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let (vm, _, _) = try makeVM(cli: cli.path)
        let connect = Task { await vm.addAccountHoldingRestart(daemonPolicy: .deferred) }
        for _ in 0..<500 where !vm.isConnecting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(vm.isConnecting)
        let closed = ContinuousClock.now
        vm.abandonConnect()
        XCTAssertFalse(vm.isConnecting)
        let result = await connect.value
        XCTAssertFalse(result.connected)
        XCTAssertTrue(result.cancelled)
        // Even a Cancel that lands mid-launch stops the child (onLaunch).
        XCTAssertLessThan(closed.duration(to: .now), .seconds(10), "the CLI must not run on")
    }

    // MARK: - removeArgs (pure)

    func testRemoveArgs() {
        let account = JiraAccount(row: Row(["id": 3]))
        XCTAssertEqual(JiraAccountsViewModel.removeArgs(for: account), ["jira", "remove", "3"])
    }

    // MARK: - loginArgs (pure)

    func testLoginArgs() {
        let account = JiraAccount(row: Row(["id": 7]))
        XCTAssertEqual(
            JiraAccountsViewModel.loginArgs(for: account),
            ["jira", "login", "--account", "7", "--app-return"]
        )
    }

    /// "Grant Confluence access" rides the same login flow plus
    /// `--with-confluence`; the default Re-login must never ask for the
    /// Confluence scopes (they are opt-in on the CLI side).
    func testLoginArgsWithConfluence() {
        XCTAssertEqual(
            JiraAccountsViewModel.loginArgs(accountID: 3, withConfluence: true),
            ["jira", "login", "--account", "3", "--app-return", "--with-confluence"]
        )
        XCTAssertFalse(JiraAccountsViewModel.loginArgs(accountID: 3).contains("--with-confluence"))
    }

    /// "Allow editing" asks for the Confluence write scopes via
    /// `--with-confluence-write` (which implies read on the CLI side); no
    /// other re-login ever adds it.
    func testLoginArgsWithConfluenceWrite() {
        XCTAssertEqual(
            JiraAccountsViewModel.loginArgs(accountID: 3, withConfluenceWrite: true),
            ["jira", "login", "--account", "3", "--app-return", "--with-confluence-write"]
        )
        XCTAssertFalse(JiraAccountsViewModel.loginArgs(accountID: 3, withConfluence: true).contains("--with-confluence-write"))
        XCTAssertFalse(JiraAccountsViewModel.loginArgs(accountID: 3).contains("--with-confluence-write"))
    }

    // MARK: - setEnabledArgs (pure)

    func testSetEnabledArgsEnable() {
        let account = JiraAccount(row: Row(["id": 2]))
        XCTAssertEqual(JiraAccountsViewModel.setEnabledArgs(for: account, enabled: true), ["jira", "enable", "2"])
    }

    func testSetEnabledArgsDisable() {
        let account = JiraAccount(row: Row(["id": 2]))
        XCTAssertEqual(JiraAccountsViewModel.setEnabledArgs(for: account, enabled: false), ["jira", "disable", "2"])
    }
}

// MARK: - Daemon restart policy
//
// `/usr/bin/true` / `/usr/bin/false` stand in for the CLI: the VM's own
// success/failure branch runs for real, only the daemon restart is faked.

extension JiraAccountsViewModelTests {
    private func makeVM(cli: String) throws -> (JiraAccountsViewModel, FakeDaemonRestarter, DatabasePool) {
        let pool = try makePool()
        let daemon = FakeDaemonRestarter()
        return (JiraAccountsViewModel(dbPool: pool, daemon: daemon) { cli }, daemon, pool)
    }

    private func insertAccount(_ pool: DatabasePool) async throws -> JiraAccount {
        try await pool.write { db in _ = try TestDatabase.insertJiraAccount(db) }
        let rows = try await pool.read { db in try JiraAccountQueries.fetchAll(db) }
        return try XCTUnwrap(rows.first)
    }

    func testAddRestartsTheDaemonByDefault() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        await vm.addAccount()
        await vm.daemonRestartTask?.value
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testDeferredAddDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        await vm.addAccount(daemonPolicy: .deferred)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testRemoveRestartsTheDaemonByDefault() async throws {
        let (vm, daemon, pool) = try makeVM(cli: "/usr/bin/true")
        let account = try await insertAccount(pool)
        await vm.remove(account)
        await vm.daemonRestartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testDeferredRemoveDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, pool) = try makeVM(cli: "/usr/bin/true")
        let account = try await insertAccount(pool)
        await vm.remove(account, daemonPolicy: .deferred)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testFailedAddDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/false")
        await vm.addAccount()
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    // MARK: - Also connect Confluence (#573)

    // The owner's ask: the box starts checked; unticking it is the opt-out.
    func testAlsoConnectConfluenceIsOnByDefault() {
        XCTAssertTrue(JiraAccountsViewModel.alsoConnectConfluenceByDefault)
    }

    /// A stand-in CLI that writes its argv to a file and exits 0.
    private func argvRecordingCLI() throws -> (cli: String, argv: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let argv = dir.appendingPathComponent("argv")
        let cli = dir.appendingPathComponent("watchtower")
        try "#!/bin/sh\necho \"$@\" > '\(argv.path)'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return (cli.path, argv)
    }

    func testHoldingConnectPassesTheConfluenceFlagThrough() async throws {
        let stub = try argvRecordingCLI()
        let (vm, _, _) = try makeVM(cli: stub.cli)
        _ = await vm.addAccountHoldingRestart(withConfluence: true, daemonPolicy: .deferred)
        XCTAssertEqual(
            try String(contentsOf: stub.argv, encoding: .utf8),
            "jira add --app-return --app-site-picker --with-confluence\n"
        )

        _ = await vm.addAccountHoldingRestart(withConfluence: false, daemonPolicy: .deferred)
        XCTAssertEqual(try String(contentsOf: stub.argv, encoding: .utf8), "jira add --app-return --app-site-picker\n")
    }

    // F11: `jira add`'s stable timeout exit code reaches the sheet as timedOut.
    func testHoldingConnectReportsTheLoginTimeout() async throws {
        let stub = try argvRecordingCLI()
        try "#!/bin/sh\necho 'jira login: login timed out after 5m0s' >&2\nexit 75\n"
            .write(toFile: stub.cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.cli)
        let (vm, _, _) = try makeVM(cli: stub.cli)
        let result = await vm.addAccountHoldingRestart(withConfluence: true, daemonPolicy: .deferred)
        XCTAssertFalse(result.connected)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertNil(vm.connectStatus)
    }

    // MARK: - Board step (#572)

    func testBoardStepRestartsOnceAfterTheStepUnderRestart() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        let connected = await vm.addAccountHoldingRestart(daemonPolicy: .restart).connected
        XCTAssertTrue(connected)
        XCTAssertNil(vm.daemonRestartTask, "no restart while the board step is up")
        XCTAssertEqual(daemon.restartCount, 0)
        vm.finishBoardStep()
        await vm.daemonRestartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
        // Done after Skip, or a second disappear: still one restart.
        vm.finishBoardStep()
        await vm.daemonRestartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testBoardStepNeverRestartsUnderDeferred() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        let connected = await vm.addAccountHoldingRestart(daemonPolicy: .deferred).connected
        XCTAssertTrue(connected)
        vm.finishBoardStep()
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testFailedConnectHoldsNoRestart() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/false")
        let connected = await vm.addAccountHoldingRestart(daemonPolicy: .restart).connected
        XCTAssertFalse(connected)
        vm.finishBoardStep()
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    /// The sheet closes while `jira add` is still in the browser: the
    /// connect that succeeds afterwards restarts once by itself under
    /// `.restart` and never under `.deferred`.
    func testStepClosedBeforeTheConnectFinishesAppliesThePolicyOnce() async throws {
        for (policy, expected) in [(DaemonRestartPolicy.restart, 1), (.deferred, 0)] {
            let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
            let connect = Task { await vm.addAccountHoldingRestart(daemonPolicy: policy).connected }
            for _ in 0..<1000 where !vm.isConnecting { await Task.yield() }
            XCTAssertTrue(vm.isConnecting, "\(policy)")
            vm.finishBoardStep()
            let connected = await connect.value
            XCTAssertTrue(connected)
            await vm.daemonRestartTask?.value
            XCTAssertEqual(daemon.restartCount, expected, "\(policy)")
            // Nothing is left held for a later sheet to fire.
            vm.finishBoardStep()
            await vm.daemonRestartTask?.value
            XCTAssertEqual(daemon.restartCount, expected, "\(policy)")
        }
    }
}

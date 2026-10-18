import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Settings → Linear: the CLI calls the view model makes, run against
/// stand-in CLI scripts (the JiraAccountsViewModelTests pattern) — argv,
/// stdin, exit codes and the daemon restart policy.
@MainActor
final class LinearAccountsViewModelTests: XCTestCase {
    private struct StubCLI {
        let path: String
        let argv: URL
        let stdin: URL
    }

    /// A stand-in CLI: records its argv and stdin, prints `accounts` for
    /// `linear accounts`, `teams` for `linear teams`, and exits `exitCode`
    /// with `stderr` for every other command.
    private func stubCLI(
        accounts: String = "[]", teams: String = "[]", exitCode: Int32 = 0, stderr: String = ""
    ) throws -> StubCLI {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let argv = dir.appendingPathComponent("argv")
        let stdin = dir.appendingPathComponent("stdin")
        let accountsFile = dir.appendingPathComponent("accounts.json")
        let teamsFile = dir.appendingPathComponent("teams.json")
        try accounts.write(to: accountsFile, atomically: true, encoding: .utf8)
        try teams.write(to: teamsFile, atomically: true, encoding: .utf8)
        let cli = dir.appendingPathComponent("watchtower")
        let script = """
            #!/bin/sh
            case "$2" in
              accounts) cat '\(accountsFile.path)'; exit 0 ;;
              teams) if [ "$3" = "--json" ]; then cat '\(teamsFile.path)'; exit 0; fi ;;
            esac
            echo "$@" > '\(argv.path)'
            cat > '\(stdin.path)'
            [ -n '\(stderr)' ] && echo '\(stderr)' >&2
            exit \(exitCode)

            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return StubCLI(path: cli.path, argv: argv, stdin: stdin)
    }

    private func makeVM(_ cli: StubCLI) -> (LinearAccountsViewModel, FakeDaemonRestarter) {
        let daemon = FakeDaemonRestarter()
        return (LinearAccountsViewModel(daemon: daemon) { cli.path }, daemon)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private let oneAccount = """
        [{"id": 4, "label": "", "org_name": "Acme", "url": "https://linear.app/acme",
          "status": "ok", "enabled": true, "error": "", "auth": "oauth"}]
        """

    // MARK: - Refresh

    func testRefreshReadsTheCLIList() async throws {
        let (vm, _) = makeVM(try stubCLI(accounts: oneAccount))
        var changed = 0
        vm.onAccountsChanged = { changed += 1 }
        await vm.refreshAsync()
        XCTAssertEqual(vm.accounts.map(\.displayName), ["Acme"])
        XCTAssertEqual(changed, 1)
        XCTAssertNil(vm.error)
    }

    func testUndecodableListSaysWhy() async throws {
        let (vm, _) = makeVM(try stubCLI(accounts: "not json"))
        await vm.refreshAsync()
        XCTAssertTrue(vm.accounts.isEmpty)
        XCTAssertNotNil(vm.error)
    }

    // MARK: - API key

    /// The key reaches the CLI on stdin, never in argv.
    func testAPIKeyGoesToStdinNotArgv() async throws {
        let cli = try stubCLI()
        let (vm, daemon) = makeVM(cli)
        let ok = await vm.addWithAPIKey("  lin_api_secret  ")
        await vm.daemonRestartTask?.value
        XCTAssertTrue(ok)
        XCTAssertEqual(try read(cli.argv), "linear add --api-key\n")
        XCTAssertEqual(try read(cli.stdin), "lin_api_secret\n")
        XCTAssertFalse(try read(cli.argv).contains("secret"))
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testEmptyAPIKeyIsRefusedBeforeTheCLI() async throws {
        let cli = try stubCLI()
        let (vm, _) = makeVM(cli)
        let ok = await vm.addWithAPIKey("   ")
        XCTAssertFalse(ok)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cli.argv.path))
    }

    func testFailedAPIKeyShowsStderrAndDoesNotRestart() async throws {
        let (vm, daemon) = makeVM(try stubCLI(exitCode: 1, stderr: "Linear rejected the key"))
        let ok = await vm.addWithAPIKey("lin_api_bad")
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.error, "Linear rejected the key")
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    /// Onboarding defers the restart to its finish.
    func testDeferredAddDoesNotRestart() async throws {
        let (vm, daemon) = makeVM(try stubCLI())
        _ = await vm.addWithAPIKey("lin_api_x", daemonPolicy: .deferred)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testReplacingAKeyUsesLoginForThatAccount() async throws {
        let cli = try stubCLI()
        let (vm, _) = makeVM(cli)
        _ = await vm.reloginWithAPIKey(LinearAccount(id: 4, auth: "api_key"), key: "lin_api_new")
        XCTAssertEqual(try read(cli.argv), "linear login --account 4 --api-key\n")
        XCTAssertEqual(try read(cli.stdin), "lin_api_new\n")
    }

    // MARK: - OAuth and management

    func testOAuthArgs() async throws {
        let cli = try stubCLI()
        let (vm, daemon) = makeVM(cli)
        await vm.addWithOAuth()
        await vm.daemonRestartTask?.value
        XCTAssertEqual(try read(cli.argv), "linear add --app-return\n")
        XCTAssertEqual(daemon.restartCount, 1)

        await vm.relogin(LinearAccount(id: 4))
        XCTAssertEqual(try read(cli.argv), "linear login --account 4 --app-return\n")
    }

    func testEnableDisableRemoveArgs() async throws {
        let cli = try stubCLI()
        let (vm, daemon) = makeVM(cli)
        let account = LinearAccount(id: 4)
        await vm.setEnabled(account, enabled: false)
        await vm.daemonRestartTask?.value
        XCTAssertEqual(try read(cli.argv), "linear disable 4\n")
        await vm.setEnabled(account, enabled: true)
        await vm.daemonRestartTask?.value
        XCTAssertEqual(try read(cli.argv), "linear enable 4\n")
        await vm.remove(account, daemonPolicy: .deferred)
        XCTAssertEqual(try read(cli.argv), "linear remove 4\n")
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 2, "enable and disable restart; the deferred remove does not")
    }

    func testBusyGuardRefusesASecondCommand() async throws {
        let cli = try stubCLI()
        let (vm, _) = makeVM(cli)
        vm.isBusy = true
        await vm.remove(LinearAccount(id: 4))
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isBusy, "the guard must not clear a flag it did not set")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cli.argv.path))
    }

    // MARK: - Teams

    func testTeamsLoadAndSelectionScopesToTheAccount() async throws {
        let cli = try stubCLI(teams: #"[{"key": "ENG", "name": "Engineering", "selected": false}]"#)
        let (vm, daemon) = makeVM(cli)
        let account = LinearAccount(id: 4)
        await vm.loadTeams(for: account)
        let team = try XCTUnwrap(vm.teams[4]?.first)
        XCTAssertEqual(team.name, "Engineering")

        await vm.setTeam(team, selected: true, for: account)
        XCTAssertEqual(try read(cli.argv), "linear teams select --account 4 ENG\n")
        await vm.setTeam(team, selected: false, for: account)
        XCTAssertEqual(try read(cli.argv), "linear teams deselect --account 4 ENG\n")
        XCTAssertEqual(daemon.restartCount, 0, "the daemon reads the selection on its next pass")
    }

    func testTeamsLoadFailureIsPerAccount() async throws {
        let (vm, _) = makeVM(try stubCLI(teams: "garbage"))
        await vm.loadTeams(for: LinearAccount(id: 4))
        XCTAssertNotNil(vm.teamErrors[4])
        XCTAssertNil(vm.teams[4])
        XCTAssertNil(vm.error)
    }

    func testArgumentBuilders() {
        XCTAssertEqual(LinearAccountsViewModel.accountsArgs, ["linear", "accounts", "--json"])
        XCTAssertEqual(LinearAccountsViewModel.teamsArgs(accountID: 2), ["linear", "teams", "--json", "--account", "2"])
    }
}

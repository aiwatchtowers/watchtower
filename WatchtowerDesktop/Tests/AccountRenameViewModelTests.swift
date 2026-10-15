import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Each account view model's Rename… runs its own source's `rename` (the CLI
/// keys the table off the source; ids collide across tables) and reloads on
/// success. The Slack VM's daemon/error behaviour is pinned in
/// SlackAccountsViewModelTests.
@MainActor
final class AccountRenameViewModelTests: XCTestCase {
    private var dir: URL!
    private var argsFile: URL { dir.appendingPathComponent("args") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-vm-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A shell-builtins-only stand-in CLI that records its argv.
    private func stub() throws -> String {
        let stub = dir.appendingPathComponent("cli")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argsFile.path)'\nexit 0\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }

    private func recordedArgs() throws -> [String] {
        try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func makePool() throws -> DatabasePool {
        try TestDatabase.createDatabaseManager().0.dbPool
    }

    func testJiraRenamesThroughJira() async throws {
        let cli = try stub()
        let vm = JiraAccountsViewModel(dbPool: try makePool(), daemon: FakeDaemonRestarter()) { cli }
        var reloads = 0
        vm.onAccountsChanged = { reloads += 1 }
        await vm.rename(accountID: 2, to: "Client")
        XCTAssertNil(vm.error)
        XCTAssertEqual(try recordedArgs(), ["jira", "rename", "--", "2", "Client"])
        XCTAssertEqual(reloads, 1)
    }

    func testGoogleRenamesThroughGoogle() async throws {
        let cli = try stub()
        let vm = GoogleAccountsViewModel(dbPool: try makePool(), daemon: FakeDaemonRestarter()) { cli }
        await vm.rename(accountID: 3, to: "Personal")
        XCTAssertNil(vm.error)
        XCTAssertEqual(try recordedArgs(), ["google", "rename", "--", "3", "Personal"])
    }

    func testEmailRenamesThroughImapForAnyMailbox() async throws {
        let cli = try stub()
        let vm = EmailAccountsViewModel(dbPool: try makePool()) { cli }
        var reloads = 0
        vm.onAccountsChanged = { reloads += 1 }
        await vm.rename(accountID: 4, to: "Work mail")
        XCTAssertNil(vm.error)
        XCTAssertEqual(try recordedArgs(), ["imap", "rename", "--", "4", "Work mail"])
        XCTAssertEqual(reloads, 1)
    }

    func testCalendarRenamesThroughCaldav() async throws {
        let cli = try stub()
        let vm = CalendarAccountsViewModel(dbPool: try makePool()) { cli }
        await vm.rename(accountID: 5, to: "Team")
        XCTAssertNil(vm.error)
        XCTAssertEqual(try recordedArgs(), ["caldav", "rename", "--", "5", "Team"])
    }

    func testRenameWaitsForAnInFlightConnect() async throws {
        let cli = try stub()
        let vm = CalendarAccountsViewModel(dbPool: try makePool()) { cli }
        vm.isRunning = true
        await vm.rename(accountID: 5, to: "Team")
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: argsFile.path), "the CLI must not run")
    }
}

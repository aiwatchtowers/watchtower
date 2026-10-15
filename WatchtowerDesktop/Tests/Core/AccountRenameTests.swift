import Foundation
import Testing
@testable import WatchtowerCore

@Suite("AccountRename")
struct AccountRenameTests {
    @Test("args end the flags before the id and trim the name")
    func args() {
        #expect(AccountRename.args(source: "slack", id: 3, name: "  Work ")
            == ["slack", "rename", "--", "3", "Work"])
        // A leading "-" stays the name, not a flag: it comes after "--".
        #expect(AccountRename.args(source: "imap", id: 1, name: "-Ops")
            == ["imap", "rename", "--", "1", "-Ops"])
    }

    @Test("an empty name is refused before the CLI runs")
    func emptyName() async {
        let failure = await AccountRename.run(source: "jira", id: 1, name: " \n ", cliPath: "/nonexistent")
        #expect(failure == "The name must not be empty.")
    }

    @Test("no CLI is reported")
    func noCLI() async {
        let failure = await AccountRename.run(source: "jira", id: 1, name: "Work", cliPath: nil)
        #expect(failure == "Watchtower CLI not found")
    }

    @Test("success is nil and the CLI gets the args")
    func success() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let argsFile = dir.appendingPathComponent("args")
        let stub = try makeStub(in: dir, body: "printf '%s\\n' \"$@\" > '\(argsFile.path)'\nexit 0")

        let failure = await AccountRename.run(source: "caldav", id: 4, name: "Team", cliPath: stub)

        #expect(failure == nil)
        let recorded = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(recorded == "caldav\nrename\n--\n4\nTeam\n")
    }

    @Test("a failure shows the CLI's stderr, or the exit code without one")
    func failure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let loud = try makeStub(in: dir, name: "loud", body: "echo 'renaming account: no account 9' 1>&2\nexit 1")
        #expect(await AccountRename.run(source: "google", id: 9, name: "X", cliPath: loud)
            == "renaming account: no account 9")

        let quiet = try makeStub(in: dir, name: "quiet", body: "exit 3")
        #expect(await AccountRename.run(source: "google", id: 9, name: "X", cliPath: quiet)
            == "Rename failed (exit 3)")
    }

    /// A shell-builtins-only stand-in CLI, so no grandchild can outlive the test.
    private func makeStub(in dir: URL, name: String = "cli", body: String) throws -> String {
        let stub = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }
}

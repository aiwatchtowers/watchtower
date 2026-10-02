import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board target #91: Re-run setup runs `watchtower workbench resync`, shows what
/// it added and its suggestions, and keeps the result across navigation.
@MainActor
final class WorkbenchesViewModelResyncTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelResyncTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// The Go side's empty-state wire shape: no new documents, nothing to
    /// install, no suggestions — every array present and empty.
    private static let upToDate = #"""
        {"id":1,"docs_ok":true,"docs_error":"",
         "docs":{"imported":[],"already_attached":["README.md"],"skipped_over_cap":[],"unreadable":[],"dry_run":false},
         "integration_ok":true,"integration_error":"","skill":"unchanged","hooks_added":false,"excluded":[],
         "mcp_registered":true,"mcp_command":"","suggestions":[],"suggestions_error":""}
        """#

    private static let added = #"""
        {"id":1,"docs_ok":true,"docs_error":"",
         "docs":{"imported":["docs/specs/a.md"],"already_attached":[],"skipped_over_cap":["docs/plans/b.md"],
                 "unreadable":["docs/x: permission denied"],"dry_run":false},
         "integration_ok":true,"integration_error":"","skill":"updated","hooks_added":true,"excluded":[".claude/"],
         "mcp_registered":true,"mcp_command":"","suggestions":["The project has no sources: add them."],
         "suggestions_error":"","index_ok":true,"index_error":"","indexed":2,"index_skipped":false}
        """#

    /// A failed import carries no docs report (Go `omitempty`).
    private static let failed = #"""
        {"id":1,"docs_ok":false,"docs_error":"permission denied","integration_ok":false,
         "integration_error":"claude CLI not found","skill":"drifted","hooks_added":false,"excluded":[],
         "mcp_registered":false,"mcp_command":"cd /tmp/a && claude mcp add","suggestions":[],
         "suggestions_error":"listing sources: database is locked",
         "index_ok":false,"index_error":"database is locked","indexed":0,"index_skipped":false}
        """#

    private static let status = Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8)

    private func decode(_ json: String) throws -> WorkbenchResynced {
        try JSONDecoder().decode(WorkbenchResynced.self, from: Data(json.utf8))
    }

    private func line(_ text: String, problem: Bool = false) -> WorkbenchResynced.Line {
        WorkbenchResynced.Line(text: text, problem: problem)
    }

    func testCLIPassesTheProjectAndDecodesEveryShape() async throws {
        let runner = FakeCLIRunner(stdout: Data(Self.upToDate.utf8))
        let result = try await WorkbenchCLI(runner: runner).resync(projectID: 7)
        XCTAssertEqual(runner.invocations, [["workbench", "resync", "7", "--json"]])
        XCTAssertEqual(result.summaryLines, [line("Everything was already up to date.")],
                       "an envelope without the index keys (an older CLI) reports nothing about it")

        let skipped = try decode(Self.upToDate.replacingOccurrences(
            of: #""suggestions_error":"""#,
            with: #""suggestions_error":"","index_ok":true,"index_error":"","indexed":0,"index_skipped":true"#))
        XCTAssertEqual(skipped.summaryLines, [line("Documents not indexed for search: knowledge search is off")])

        XCTAssertEqual(try decode(Self.added).summaryLines, [
            line("Attached 1 new document(s): docs/specs/a.md"),
            line("1 more document(s) past the import cap — run Re-run Setup again", problem: true),
            line("Could not read docs/x: permission denied", problem: true),
            line("Indexed 2 document(s) for search in this workbench's sessions"),
            line("Updated the watchtower-workbench skill"),
            line("Added the session hooks"),
            line("Excluded 1 more path(s) from git"),
            line("Next: The project has no sources: add them.")
        ])

        let failed = try decode(Self.failed)
        XCTAssertEqual(failed.summaryLines, [
            line("Attaching documents failed: permission denied", problem: true),
            line("Indexing the documents for search failed: database is locked", problem: true),
            line("Your own copy of the watchtower-workbench skill was kept, so its update was not applied "
                 + "— merge it by hand, or delete your copy and run Re-run Setup again", problem: true),
            line("The MCP server is not registered — run: cd /tmp/a && claude mcp add", problem: true),
            line("Installing into the folder failed: claude CLI not found", problem: true),
            line("Suggestions may be incomplete: listing sources: database is locked", problem: true)
        ])
    }

    /// Re-run Setup on a folder set up before the Workbench rename (spec
    /// 2026-10-02 §5.4): the migration's own lines, in Go's wording. The
    /// permission-rule note arrives as a suggestion (Go adds it), so it shows
    /// once; an envelope without the legacy keys reports no migration.
    func testLegacyMigrationLines() throws {
        let legacy = Self.upToDate
            .replacingOccurrences(of: #""skill":"unchanged","hooks_added":false"#,
                                  with: #""skill":"installed","hooks_added":true"#)
            .replacingOccurrences(
                of: #""suggestions":[],"suggestions_error":"""#,
                with: #""suggestions":["2 permission rule(s) still name the old watchtower-project server; "#
                    + #"re-allow the tools under watchtower-workbench when Claude Code asks."],"suggestions_error":"","#
                    + #""legacy_skill":"removed","legacy_mcp_removed":true,"legacy_hooks_replaced":true,"#
                    + #""legacy_permission_rules":2"#)
        let removed = try decode(legacy)
        XCTAssertEqual(removed.legacyPermissionRules, 2)
        XCTAssertEqual(removed.summaryLines, [
            line("Installed the watchtower-workbench skill"),
            line("Replaced the old session hooks"),
            line("Removed the old watchtower-project skill"),
            line("Removed the old watchtower-project MCP server"),
            line("Next: 2 permission rule(s) still name the old watchtower-project server; "
                 + "re-allow the tools under watchtower-workbench when Claude Code asks.")
        ])

        let kept = "Your own copy of the old watchtower-project skill was kept — delete .claude/skills/watchtower-project "
            + "yourself once you no longer need it; until then Claude Code sees both skills."
        for state in ["drifted", "foreign"] {
            let lines = try decode(legacy.replacingOccurrences(of: #""legacy_skill":"removed""#,
                                                               with: #""legacy_skill":"\#(state)""#)).summaryLines
            XCTAssertTrue(lines.contains(line(kept, problem: true)), state)
            XCTAssertFalse(lines.contains(line("Removed the old watchtower-project skill")), state)
        }

        let older = try decode(Self.upToDate)
        XCTAssertEqual(older.legacySkill, "")
        XCTAssertFalse(older.legacyMCPRemoved)
        XCTAssertFalse(older.legacyHooksReplaced)
        XCTAssertEqual(older.legacyPermissionRules, 0)
    }

    /// Repair on a legacy folder is the migration: it runs the resync, so
    /// the owner sees its report (the permission rules, a kept old skill)
    /// instead of an install whose output is dropped. A current folder's
    /// Repair still runs the plain install.
    func testRepairOnALegacyFolderRunsTheResyncAndShowsItsSummary() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let legacyStatus = Data(#"{"skill":"missing","hook":false,"mcp":true,"legacy":true,"legacy_skill":"unchanged"}"#.utf8)
        let migrated = Self.upToDate.replacingOccurrences(
            of: #""suggestions":[],"suggestions_error":"""#,
            with: #""suggestions":["2 permission rule(s) still name the old watchtower-project server; "#
                + #"re-allow the tools under watchtower-workbench when Claude Code asks."],"suggestions_error":"","#
                + #""legacy_skill":"removed","legacy_mcp_removed":true,"legacy_hooks_replaced":true,"legacy_permission_rules":2"#)
        let runner = ScriptedCLIRunner(results: [
            .success(legacyStatus), .success(Data(migrated.utf8)), .success(Self.status)
        ])
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        await vm.refreshInstallStatus(projectID: id)
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, true)

        await vm.repairInstall(projectID: id)

        XCTAssertEqual(runner.invocations, [
            ["integrate", "status", "--workbench", String(id), "--json"],
            ["workbench", "resync", String(id), "--json"],
            ["integrate", "status", "--workbench", String(id), "--json"]
        ])
        let lines = try XCTUnwrap(vm.resyncResults[id]?.summaryLines)
        XCTAssertTrue(lines.contains(line("Next: 2 permission rule(s) still name the old watchtower-project server; "
                                          + "re-allow the tools under watchtower-workbench when Claude Code asks.")))
        XCTAssertEqual(vm.installStatus[id]?.legacy, false)

        let current = ScriptedCLIRunner(results: [.success(Data(#"{"skill":"missing","hook":true,"mcp":true}"#.utf8))])
        let plain = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: current), defaults: defaults)
        await plain.refreshInstallStatus(projectID: id)
        await plain.repairInstall(projectID: id)
        XCTAssertEqual(current.invocations[1], ["integrate", "claude-code", "--workbench", String(id)])
        XCTAssertNil(plain.resyncResults[id])
    }

    func testResyncStoresTheResultAndRefreshesTheInstallStatus() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [.success(Data(Self.added.utf8)), .success(Self.status)])
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)

        await vm.resync(projectID: id)

        XCTAssertEqual(runner.invocations, [
            ["workbench", "resync", String(id), "--json"],
            ["integrate", "status", "--workbench", String(id), "--json"]
        ])
        XCTAssertEqual(vm.resyncResults[id]?.imported, ["docs/specs/a.md"])
        XCTAssertNil(vm.resyncErrors[id])
        XCTAssertFalse(vm.resyncing.contains(id))
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)

        vm.dismissResync(projectID: id)
        XCTAssertNil(vm.resyncResults[id])
    }

    func testAFailedRunSaysWhyKeepsNoStaleResultAndStillRefreshes() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(Data(Self.upToDate.utf8)), .success(Self.status),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "project 1: not found")), .success(Self.status)
        ])
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        await vm.resync(projectID: id)
        XCTAssertNotNil(vm.resyncResults[id])

        await vm.resync(projectID: id)

        XCTAssertNil(vm.resyncResults[id], "the previous run's result is not shown as this one's")
        let error = try XCTUnwrap(vm.resyncErrors[id])
        XCTAssertTrue(error.hasPrefix("Re-run Setup failed"), error)
        XCTAssertFalse(vm.resyncing.contains(id))
        XCTAssertEqual(runner.invocations.last, ["integrate", "status", "--workbench", String(id), "--json"],
                       "the CLI may have changed the folder before failing: the status is re-read")
    }

    /// Version skew: the CLI ran (and may have attached documents) but its
    /// report does not decode — say so, and still refresh the page.
    func testAnUnreadableReportSaysTheRunHappened() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [.success(Data(#"{"id":1}"#.utf8)), .success(Self.status)])
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)

        await vm.resync(projectID: id)

        let error = try XCTUnwrap(vm.resyncErrors[id])
        XCTAssertTrue(error.contains("its report could not be read"), error)
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
    }

    /// The VM is AppState-owned: a run in flight while the owner moves to
    /// another project finishes, and its result is there on return. A second
    /// click, or Repair, starts no parallel folder install meanwhile.
    func testTheResultSurvivesNavigatingAwayAndBlocksAParallelInstall() async throws {
        let (first, second) = try await pool.write { d in
            (try TestDatabase.insertWorkbench(d), try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta"))
        }
        let runner = HeldCLIRunner(stdout: Data(Self.added.utf8))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.selectedWorkbenchID = first
        let run = Task { await vm.resync(projectID: first) }
        await awaitStarted(runner)
        XCTAssertTrue(vm.isInstalling(projectID: first))

        vm.selectedWorkbenchID = second
        await vm.resync(projectID: first)
        await vm.repairInstall(projectID: first)
        XCTAssertEqual(runner.invocations.count, 1, "no second install while one runs")

        runner.release()
        await run.value
        vm.selectedWorkbenchID = first

        XCTAssertEqual(vm.resyncResults[first]?.hooksAdded, true)
        XCTAssertNil(vm.resyncResults[second])
        XCTAssertFalse(vm.isInstalling(projectID: first))
    }

    func testWithoutTheCLIItSaysSo() async throws {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.resync(projectID: 1)
        XCTAssertEqual(vm.resyncErrors[1], "The watchtower CLI was not found.")
    }
}

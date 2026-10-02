import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Board target #91: Re-run setup runs `watchtower project resync`, shows what
/// it added and its suggestions, and keeps the result across navigation.
@MainActor
final class ProjectsViewModelResyncTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsViewModelResyncTests-\(UUID().uuidString)"))
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

    private func decode(_ json: String) throws -> ProjectResynced {
        try JSONDecoder().decode(ProjectResynced.self, from: Data(json.utf8))
    }

    private func line(_ text: String, problem: Bool = false) -> ProjectResynced.Line {
        ProjectResynced.Line(text: text, problem: problem)
    }

    func testCLIPassesTheProjectAndDecodesEveryShape() async throws {
        let runner = FakeCLIRunner(stdout: Data(Self.upToDate.utf8))
        let result = try await ProjectCLI(runner: runner).resync(projectID: 7)
        XCTAssertEqual(runner.invocations, [["project", "resync", "7", "--json"]])
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
            line("Indexed 2 document(s) for search in this project's sessions"),
            line("Updated the watchtower-project skill"),
            line("Added the session hooks"),
            line("Excluded 1 more path(s) from git"),
            line("Next: The project has no sources: add them.")
        ])

        let failed = try decode(Self.failed)
        XCTAssertEqual(failed.summaryLines, [
            line("Attaching documents failed: permission denied", problem: true),
            line("Indexing the documents for search failed: database is locked", problem: true),
            line("Your own copy of the watchtower-project skill was kept, so its update was not applied "
                 + "— merge it by hand, or delete your copy and run Re-run Setup again", problem: true),
            line("The MCP server is not registered — run: cd /tmp/a && claude mcp add", problem: true),
            line("Installing into the folder failed: claude CLI not found", problem: true),
            line("Suggestions may be incomplete: listing sources: database is locked", problem: true)
        ])
    }

    func testResyncStoresTheResultAndRefreshesTheInstallStatus() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [.success(Data(Self.added.utf8)), .success(Self.status)])
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)

        await vm.resync(projectID: id)

        XCTAssertEqual(runner.invocations, [
            ["project", "resync", String(id), "--json"],
            ["integrate", "status", "--project", String(id), "--json"]
        ])
        XCTAssertEqual(vm.resyncResults[id]?.imported, ["docs/specs/a.md"])
        XCTAssertNil(vm.resyncErrors[id])
        XCTAssertFalse(vm.resyncing.contains(id))
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)

        vm.dismissResync(projectID: id)
        XCTAssertNil(vm.resyncResults[id])
    }

    func testAFailedRunSaysWhyKeepsNoStaleResultAndStillRefreshes() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(Data(Self.upToDate.utf8)), .success(Self.status),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "project 1: not found")), .success(Self.status)
        ])
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
        await vm.resync(projectID: id)
        XCTAssertNotNil(vm.resyncResults[id])

        await vm.resync(projectID: id)

        XCTAssertNil(vm.resyncResults[id], "the previous run's result is not shown as this one's")
        let error = try XCTUnwrap(vm.resyncErrors[id])
        XCTAssertTrue(error.hasPrefix("Re-run Setup failed"), error)
        XCTAssertFalse(vm.resyncing.contains(id))
        XCTAssertEqual(runner.invocations.last, ["integrate", "status", "--project", String(id), "--json"],
                       "the CLI may have changed the folder before failing: the status is re-read")
    }

    /// Version skew: the CLI ran (and may have attached documents) but its
    /// report does not decode — say so, and still refresh the page.
    func testAnUnreadableReportSaysTheRunHappened() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [.success(Data(#"{"id":1}"#.utf8)), .success(Self.status)])
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)

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
            (try TestDatabase.insertProject(d), try TestDatabase.insertProject(d, name: "beta", folder: "/tmp/beta"))
        }
        let runner = HeldCLIRunner(stdout: Data(Self.added.utf8))
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
        vm.selectedProjectID = first
        let run = Task { await vm.resync(projectID: first) }
        await awaitStarted(runner)
        XCTAssertTrue(vm.isInstalling(projectID: first))

        vm.selectedProjectID = second
        await vm.resync(projectID: first)
        await vm.repairInstall(projectID: first)
        XCTAssertEqual(runner.invocations.count, 1, "no second install while one runs")

        runner.release()
        await run.value
        vm.selectedProjectID = first

        XCTAssertEqual(vm.resyncResults[first]?.hooksAdded, true)
        XCTAssertNil(vm.resyncResults[second])
        XCTAssertFalse(vm.isInstalling(projectID: first))
    }

    func testWithoutTheCLIItSaysSo() async throws {
        let vm = ProjectsViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.resync(projectID: 1)
        XCTAssertEqual(vm.resyncErrors[1], "The watchtower CLI was not found.")
    }
}

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
        {"project_id":1,"docs_ok":true,"docs_error":"",
         "docs":{"imported":[],"already_attached":["README.md"],"skipped_over_cap":[],"unreadable":[],"dry_run":false},
         "integration_ok":true,"integration_error":"","skill":"unchanged","hooks_added":false,"excluded":[],
         "mcp_registered":true,"mcp_command":"","suggestions":[]}
        """#

    private static let added = #"""
        {"project_id":1,"docs_ok":true,"docs_error":"",
         "docs":{"imported":["docs/specs/a.md"],"already_attached":[],"skipped_over_cap":["docs/plans/b.md"],
                 "unreadable":["docs/x: permission denied"],"dry_run":false},
         "integration_ok":true,"integration_error":"","skill":"updated","hooks_added":true,"excluded":[".claude/"],
         "mcp_registered":true,"mcp_command":"","suggestions":["The project has no sources: add them."]}
        """#

    private static let failed = #"""
        {"project_id":1,"docs_ok":false,"docs_error":"permission denied","integration_ok":false,
         "integration_error":"claude CLI not found","skill":"drifted","hooks_added":false,"excluded":[],
         "mcp_registered":false,"mcp_command":"cd /tmp/a && claude mcp add","suggestions":[]}
        """#

    private static let status = Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8)

    func testCLIPassesTheProjectAndDecodesEveryShape() async throws {
        let runner = FakeCLIRunner(stdout: Data(Self.upToDate.utf8))
        let result = try await ProjectCLI(runner: runner).resync(projectID: 7)
        XCTAssertEqual(runner.invocations, [["project", "resync", "--project", "7", "--json"]])
        XCTAssertEqual(result, ProjectResynced())
        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.summaryLines, ["Everything was already up to date."])

        let added = try JSONDecoder().decode(ProjectResynced.self, from: Data(Self.added.utf8))
        XCTAssertEqual(added.summaryLines, [
            "Attached 1 new document(s): docs/specs/a.md",
            "1 more document(s) past the import cap — run Re-run setup again",
            "Could not read docs/x: permission denied",
            "Updated the watchtower-project skill",
            "Added the session hooks",
            "Next: The project has no sources: add them."
        ])

        let failed = try JSONDecoder().decode(ProjectResynced.self, from: Data(Self.failed.utf8))
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.summaryLines, [
            "Attaching documents failed: permission denied",
            "Your own copy of the watchtower-project skill was left as it is",
            "The MCP server is not registered — run: cd /tmp/a && claude mcp add",
            "Installing into the folder failed: claude CLI not found"
        ])
    }

    func testResyncStoresTheResultAndRefreshesTheInstallStatus() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [.success(Data(Self.added.utf8)), .success(Self.status)])
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)

        await vm.resync(projectID: id)

        XCTAssertEqual(runner.invocations, [
            ["project", "resync", "--project", String(id), "--json"],
            ["integrate", "status", "--project", String(id), "--json"]
        ])
        XCTAssertEqual(vm.resyncResults[id]?.imported, ["docs/specs/a.md"])
        XCTAssertNil(vm.resyncErrors[id])
        XCTAssertFalse(vm.resyncing.contains(id))
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)

        vm.dismissResync(projectID: id)
        XCTAssertNil(vm.resyncResults[id])
    }

    func testAFailedRunSaysWhyAndKeepsNoStaleResult() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(Data(Self.upToDate.utf8)), .success(Self.status),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "project 1: not found"))
        ])
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
        await vm.resync(projectID: id)
        XCTAssertNotNil(vm.resyncResults[id])

        await vm.resync(projectID: id)

        XCTAssertNil(vm.resyncResults[id], "the previous run's result is not shown as this one's")
        let error = try XCTUnwrap(vm.resyncErrors[id])
        XCTAssertTrue(error.hasPrefix("Re-run setup failed"), error)
        XCTAssertFalse(vm.resyncing.contains(id))
    }

    /// The VM is AppState-owned: a run started on one project finishes and
    /// stays shown after the owner moves to another project and back.
    func testTheResultSurvivesNavigatingAway() async throws {
        let (first, second) = try await pool.write { d in
            (try TestDatabase.insertProject(d), try TestDatabase.insertProject(d, name: "beta", folder: "/tmp/beta"))
        }
        let runner = FakeCLIRunner(stdout: Data(Self.added.utf8))
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
        vm.selectedProjectID = first
        let run = Task { await vm.resync(projectID: first) }
        vm.selectedProjectID = second
        await run.value
        vm.selectedProjectID = first

        XCTAssertEqual(vm.resyncResults[first]?.hooksAdded, true)
        XCTAssertNil(vm.resyncResults[second])
    }

    func testWithoutTheCLIItSaysSo() async throws {
        let vm = ProjectsViewModel(dbPool: pool, cli: nil, defaults: defaults)
        await vm.resync(projectID: 1)
        XCTAssertEqual(vm.resyncErrors[1], "The watchtower CLI was not found.")
    }
}

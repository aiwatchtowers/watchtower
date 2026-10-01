import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class ProjectCLITests: XCTestCase {
    func testCreatePassesFolderNameAndJSONAndDecodesTheEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"id":7,"folder":"/tmp/acme","name":"acme"}"#.utf8))
        let created = try await ProjectCLI(runner: runner).create(folder: "/tmp/acme dir", name: "Acme")
        XCTAssertEqual(created, ProjectCreated(id: 7, folder: "/tmp/acme", name: "acme"))
        XCTAssertEqual(runner.invocations, [["project", "create", "--folder", "/tmp/acme dir", "--json", "--name", "Acme"]])
    }

    func testCreateDecodesAFailedDocumentImport() async throws {
        let json = #"{"id":7,"folder":"/tmp/acme","name":"acme","docs_import_ok":false,"docs_import_error":"permission denied"}"#
        let created = try await ProjectCLI(runner: FakeCLIRunner(stdout: Data(json.utf8))).create(folder: "/tmp/acme", name: nil)
        XCTAssertFalse(created.docsImportOK)
        XCTAssertEqual(created.docsImportError, "permission denied")
        XCTAssertEqual(created.importNote,
                       "Importing the folder's documents failed (permission denied) — retry with: watchtower project import-docs 7")
    }

    func testCreateDecodesSkippedPathsAndAnOlderEnvelopeMeansNothingFailed() throws {
        let json = #"""
            {"id":7,"folder":"/tmp/acme","name":"acme","docs_import_ok":true,"docs_import_error":"",
             "docs_import":{"imported":["README.md"],"already_attached":[],"dry_run":false,
             "skipped_over_cap":["docs/specs/a.md","docs/specs/b.md"],
             "unreadable":["docs/private: permission denied","docs/x: no such file or directory"]}}
            """#
        let created = try JSONDecoder().decode(ProjectCreated.self, from: Data(json.utf8))
        XCTAssertEqual(created.unreadable.count, 2)
        XCTAssertEqual(created.skippedOverCap, 2)
        XCTAssertEqual(created.importNote,
                       "Could not read docs/private: permission denied and 1 more — fix it, then run: "
                       + "watchtower project import-docs 7. 2 more document(s) past the import cap — run: "
                       + "watchtower project import-docs 7")

        let older = try JSONDecoder().decode(ProjectCreated.self, from: Data(#"{"id":1,"folder":"/tmp/a","name":"a"}"#.utf8))
        XCTAssertTrue(older.docsImportOK)
        XCTAssertEqual(older.docsImportError, "")
        XCTAssertNil(older.importNote, "a CLI without the keys reports no failure")
    }

    func testCreateWithoutNameOmitsTheFlag() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"id":1,"folder":"/tmp/a","name":"a"}"#.utf8))
        _ = try await ProjectCLI(runner: runner).create(folder: "/tmp/a", name: nil)
        XCTAssertEqual(runner.invocations, [["project", "create", "--folder", "/tmp/a", "--json"]])
    }

    func testInstallStatusAndDeleteArguments() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":false}"#.utf8))
        let cli = ProjectCLI(runner: runner)
        try await cli.install(projectID: 3)
        let status = try await cli.status(projectID: 3)
        XCTAssertEqual(runner.invocations, [
            ["integrate", "claude-code", "--project", "3"],
            ["integrate", "status", "--project", "3", "--json"]
        ])
        XCTAssertEqual(status, ProjectInstallStatus(skill: "unchanged", hook: true, mcp: false))
        XCTAssertTrue(status.needsRepair)
    }

    func testDeletePassesJSONAndDecodesBothEnvelopeShapes() async throws {
        let clean = FakeCLIRunner(stdout: Data(#"{"id":3,"deleted":true,"removal_ok":true,"removal_error":""}"#.utf8))
        let ok = try await ProjectCLI(runner: clean).delete(projectID: 3)
        XCTAssertEqual(clean.invocations, [["project", "delete", "3", "--json"]])
        XCTAssertEqual(ok, ProjectDeleted(id: 3, deleted: true, removalOK: true, removalError: ""))

        let partial = FakeCLIRunner(
            stdout: Data(#"{"id":3,"deleted":true,"removal_ok":false,"removal_error":"hook: permission denied"}"#.utf8)
        )
        let warned = try await ProjectCLI(runner: partial).delete(projectID: 3)
        XCTAssertEqual(warned, ProjectDeleted(id: 3, deleted: true, removalOK: false, removalError: "hook: permission denied"))
    }

    func testAttachDocumentEndsFlagsBeforeThePathAndDecodesTheEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"document_id":9,"rel_path":"docs/-x.md","created":true}"#.utf8))
        let cli = ProjectCLI(runner: runner)
        let attached = try await cli.attachDocument(projectID: 3, path: "/tmp/acme/docs/-x.md", kind: "spec", targetID: 5)
        XCTAssertEqual(attached, ProjectDocumentAttached(documentID: 9, relPath: "docs/-x.md", created: true))
        _ = try await cli.attachDocument(projectID: 3, path: "/tmp/acme/a.md", kind: "doc", targetID: nil)
        XCTAssertEqual(runner.invocations, [
            ["project", "attach-doc", "--kind", "spec", "--json", "--target", "5", "--", "3", "/tmp/acme/docs/-x.md"],
            ["project", "attach-doc", "--kind", "doc", "--json", "--", "3", "/tmp/acme/a.md"]
        ])
    }

    func testNeedsRepairOnlyWhenSomethingIsMissing() {
        XCTAssertFalse(ProjectInstallStatus(skill: "unchanged", hook: true, mcp: true).needsRepair)
        XCTAssertFalse(ProjectInstallStatus(skill: "drifted", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "missing", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "unchanged", hook: false, mcp: true).needsRepair)
    }

    func testSkillUpdatedNeedsRepairAndClaudeFoundDecodes() throws {
        XCTAssertTrue(ProjectInstallStatus(skill: "updated", hook: true, mcp: true).needsRepair)
        let json = Data(#"{"skill":"unchanged","hook":true,"mcp":false,"claude_found":false}"#.utf8)
        let status = try JSONDecoder().decode(ProjectInstallStatus.self, from: json)
        XCTAssertEqual(status, ProjectInstallStatus(skill: "unchanged", hook: true, mcp: false, claudeFound: false))
        let legacy = try JSONDecoder().decode(
            ProjectInstallStatus.self, from: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8)
        )
        XCTAssertTrue(legacy.claudeFound, "an older CLI without the key could check the registration")
    }

    /// Without `claude` the MCP registration is unknown and not repairable:
    /// Repair must not loop on `mcp=false`, but still repairs the rest.
    func testClaudeNotFoundDoesNotAskForRepairOfMCP() {
        XCTAssertFalse(ProjectInstallStatus(skill: "unchanged", hook: true, mcp: false, claudeFound: false).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "unchanged", hook: false, mcp: false, claudeFound: false).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "missing", hook: true, mcp: false, claudeFound: false).needsRepair)
    }

    /// Shared fixture with Go `TestProjectMCPCommand_MatchesTheDesktopFixture`
    /// (`internal/devpack/project_test.go`): same inputs, same text.
    func testManualMCPCommandMatchesTheGoTwin() {
        XCTAssertEqual(
            ProjectInstallStatus.manualMCPCommand(
                projectID: 7, folder: "/tmp/acme project", cliPath: "/tmp/acme bin/it's/watchtower"
            ),
            #"cd '/tmp/acme project' && claude mcp add --scope local watchtower-project -- '/tmp/acme bin/it'\''s/watchtower' mcp --project 7"#
        )
        XCTAssertEqual(
            ProjectInstallStatus.manualMCPCommand(projectID: 3, folder: "/tmp/acme", cliPath: "/usr/local/bin/watchtower"),
            "cd /tmp/acme && claude mcp add --scope local watchtower-project -- /usr/local/bin/watchtower mcp --project 3",
            "shell-safe paths stay bare, as Go leaves them"
        )
    }

    func testMalformedCreateOutputThrows() async {
        let runner = FakeCLIRunner(stdout: Data("created project 7".utf8))
        do {
            _ = try await ProjectCLI(runner: runner).create(folder: "/tmp/a", name: nil)
            XCTFail("expected a decode error")
        } catch {}
    }

    func testRunnerErrorPropagates() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "folder is already bound to a project"))
        do {
            try await ProjectCLI(runner: runner).install(projectID: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already bound"))
        }
    }
}

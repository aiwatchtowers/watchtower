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

    func testNeedsRepairOnlyWhenSomethingIsMissing() {
        XCTAssertFalse(ProjectInstallStatus(skill: "unchanged", hook: true, mcp: true).needsRepair)
        XCTAssertFalse(ProjectInstallStatus(skill: "drifted", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "missing", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(ProjectInstallStatus(skill: "unchanged", hook: false, mcp: true).needsRepair)
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

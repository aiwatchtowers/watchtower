import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AutomationsCLITests: XCTestCase {
    private func cli(_ json: String = "{}") -> (AutomationsCLI, FakeCLIRunner) {
        let runner = FakeCLIRunner(stdout: Data(json.utf8))
        return (AutomationsCLI(runner: runner), runner)
    }

    func testRunArgs() async throws {
        let (cli, runner) = cli(#"{"run_id":12,"coalesced":true,"daemon_running":false}"#)
        let result = try await cli.run(7)
        XCTAssertEqual(runner.invocations, [["automations", "run", "7", "--json"]])
        XCTAssertEqual(result.runID, 12)
        XCTAssertTrue(result.coalesced)
        XCTAssertFalse(result.daemonRunning)
    }

    func testRerunArgs() async throws {
        let (cli, runner) = cli(#"{"run_id":13,"coalesced":false,"daemon_running":true}"#)
        let result = try await cli.run(7, rerunOf: 3)
        XCTAssertEqual(runner.invocations, [["automations", "run", "7", "--rerun-of", "3", "--json"]])
        XCTAssertEqual(AutomationsCLI.args(.run(7, rerunOf: 3)), ["automations", "run", "7", "--rerun-of", "3", "--json"])
        XCTAssertEqual(result.runID, 13)
    }

    func testDryRunArgs() async throws {
        let (cli, runner) = cli(#"{"run_id":3,"status":"succeeded","error":"","input_tokens":10,"output_tokens":4}"#)
        let result = try await cli.dryRun(7)
        XCTAssertEqual(runner.invocations, [["automations", "dry-run", "7", "--json"]])
        XCTAssertEqual(result.runID, 3)
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertEqual(result.inputTokens + result.outputTokens, 14)
    }

    func testSaveArgs() async throws {
        let (cli, runner) = cli(#"{"automation_id":4,"path":"/tmp/acme/digest.md","approval_hash":"abc","confirmed":true}"#)
        let file = URL(fileURLWithPath: "/tmp/acme/draft.md")
        let result = try await cli.save(file: file, path: "/tmp/acme/digest.md", confirmHash: "abc",
                                        expectContentHash: "")
        XCTAssertEqual(runner.invocations, [["automations", "save", "--file", "/tmp/acme/draft.md", "--path",
                                             "/tmp/acme/digest.md", "--confirm-hash", "abc",
                                             "--expect-content-hash", "", "--json"]])
        XCTAssertEqual(result.automationID, 4)
        XCTAssertTrue(result.confirmed)
    }

    func testAutoOnArgs() async throws {
        let (cli, runner) = cli()
        try await cli.setAuto(7, tool: "create_jira_issue", on: true, hash: "abc")
        XCTAssertEqual(runner.invocations, [["automations", "auto", "7", "create_jira_issue", "on", "--hash", "abc",
                                             "--json"]])
    }

    func testAutoOffArgs() async throws {
        let (cli, runner) = cli()
        try await cli.setAuto(7, tool: "create_jira_issue", on: false, hash: "abc")
        XCTAssertEqual(runner.invocations, [["automations", "auto", "7", "create_jira_issue", "off", "--json"]])
    }

    func testValidateAgainstArgs() async throws {
        let payload = #"{"ok":true,"errors":[],"slug":"digest","name":"Digest","scope":"personal","#
            + #""approval_hash":"a","content_hash":"c","permissions":["llm:light"],"outputs":["inbox"],"#
            + #""widening":["llm:light"]}"#
        let (cli, runner) = cli(payload)
        let file = URL(fileURLWithPath: "/tmp/acme/draft.md")
        let result = try await cli.validate(file: file, against: 7)
        _ = try await cli.validate(file: file, against: nil)
        XCTAssertEqual(runner.invocations, [
            ["automations", "validate", "/tmp/acme/draft.md", "--against", "7", "--json"],
            ["automations", "validate", "/tmp/acme/draft.md", "--json"]
        ])
        XCTAssertEqual(result.widening, ["llm:light"])
        XCTAssertEqual(result.approvalHash, "a")
    }

    func testOtherArgs() {
        XCTAssertEqual(AutomationsCLI.args(.show(7)), ["automations", "show", "7", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.confirm(7, hash: "h")), ["automations", "confirm", "7", "--hash", "h"])
        XCTAssertEqual(AutomationsCLI.args(.setEnabled(7, true)), ["automations", "enable", "7"])
        XCTAssertEqual(AutomationsCLI.args(.setEnabled(7, false)), ["automations", "disable", "7"])
        XCTAssertEqual(AutomationsCLI.args(.delete(7)), ["automations", "delete", "7"])
        XCTAssertEqual(AutomationsCLI.args(.cancel(runID: 9)), ["automations", "cancel", "9"])
        XCTAssertEqual(AutomationsCLI.args(.wake), ["automations", "wake"])
        XCTAssertEqual(AutomationsCLI.args(.templates), ["automations", "templates", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.installTemplate(name: "new-mail-summary", workbenchID: nil)),
                       ["automations", "install-template", "new-mail-summary", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.installTemplate(name: "release-buttons", workbenchID: 3)),
                       ["automations", "install-template", "release-buttons", "--workbench", "3", "--json"])
    }

    /// The empty-array payloads of Go's TestAutomationsCLI_JSONEmptyArraysNotNull.
    func testDecodesEmptyStateJSON() async throws {
        let show = #"{"id":2,"slug":"bare","scope":"personal","project_id":0,"path":"/tmp/acme/bare.md","#
            + #""name":"Bare","description":"","script":"return 1","recipe_text":"---","trigger_kind":"manual","#
            + #""trigger_spec":"{\"manual\":true}","permissions":[],"outputs":[],"budget_tokens":50000,"#
            + #""budget_minutes":5,"concurrency":1,"missed_policy":"run_once","pause_timeout_hours":72,"#
            + #""enabled":false,"runnable":false,"needs_confirmation":true,"parse_error":"","content_hash":"c","#
            + #""approval_hash":"a","confirmed_hash":"","widening":[],"grants":[],"changes":[],"#
            + #""changes_known":false,"changed_by":"","changed_at":null,"auto_tools":[]}"#
        let detail = try await cli(show).0.show(2)
        XCTAssertEqual(detail.autoTools, [])
        XCTAssertEqual(detail.permissions, [])
        XCTAssertEqual(detail.outputs, [])
        XCTAssertEqual(detail.widening, [])
        XCTAssertEqual(detail.changes, [])
        XCTAssertNil(detail.changedAt)
        XCTAssertTrue(detail.needsConfirmation)

        let validate = #"{"ok":false,"errors":[],"slug":"","name":"","scope":"","approval_hash":"","#
            + #""content_hash":"","permissions":[],"outputs":[],"widening":[]}"#
        let v = try await cli(validate).0.validate(file: URL(fileURLWithPath: "/tmp/x.md"), against: nil)
        XCTAssertEqual(v.errors, [])
        XCTAssertEqual(v.permissions, [])

        let templates = try await cli("[]").0.templates()
        XCTAssertEqual(templates, [])
    }

    func testDecodesShowChanges() async throws {
        let show = #"{"id":2,"slug":"s","scope":"workbench","project_id":3,"path":"/p","name":"N","#
            + #""enabled":true,"runnable":false,"needs_confirmation":true,"#
            + #""changes":[{"field":"budget_tokens","old":"50000","new":"120000"}],"changes_known":true,"#
            + #""changed_by":"assistant","changed_at":"2026-10-15T08:30:00Z"}"#
        let detail = try await cli(show).0.show(2)
        XCTAssertEqual(detail.changes, [AutomationChange(field: "budget_tokens", old: "50000", new: "120000")])
        XCTAssertTrue(detail.changesKnown)
        XCTAssertEqual(detail.changedBy, "assistant")
        XCTAssertEqual(detail.changedAt, AutomationDates.parse("2026-10-15T08:30:00Z"))
        XCTAssertEqual(detail.projectID, 3)
        XCTAssertEqual(detail.autoTools, [], "an older CLI without auto_tools decodes as []")
    }

    func testDecodesShowAutoTools() async throws {
        let show = #"{"id":2,"slug":"s","scope":"personal","path":"/p","name":"N","enabled":true,"runnable":true,"#
            + #""needs_confirmation":false,"auto_tools":[{"tool":"create_idea","always_asks":false},"#
            + #"{"tool":"bulk_dismiss","always_asks":true}]}"#
        let detail = try await cli(show).0.show(2)
        XCTAssertEqual(detail.autoTools, [AutomationAutoTool(tool: "create_idea", alwaysAsks: false),
                                          AutomationAutoTool(tool: "bulk_dismiss", alwaysAsks: true)])
    }

    func testIgnoresUnknownKeys() async throws {
        let run = #"{"run_id":1,"coalesced":false,"daemon_running":true,"future":{"x":[1]}}"#
        let runResult = try await cli(run).0.run(1)
        XCTAssertEqual(runResult.runID, 1)
        let templates = #"[{"name":"new-mail-summary","title":"New mail summary","description":"d","#
            + #""scope":"personal","trigger_text":"Weekdays 09:00","permissions":["gmail:read"],"outputs":["inbox"],"#
            + #""files":["a.md"],"params":[],"installed":false}]"#
        let decoded = try await cli(templates).0.templates()
        XCTAssertEqual(decoded.map(\.name), ["new-mail-summary"])
        XCTAssertEqual(decoded.first?.triggerText, "Weekdays 09:00")
        let install = #"{"automation_id":9,"path":"/tmp/acme/new-mail-summary.md","installed":["x"]}"#
        let installed = try await cli(install).0.installTemplate("new-mail-summary", workbenchID: nil)
        XCTAssertEqual(installed.automationID, 9)
    }

    func testNonZeroExitSurfacesStderr() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "automation 7 cannot run: it is disabled"))
        do {
            _ = try await AutomationsCLI(runner: runner).run(7)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("automation 7 cannot run: it is disabled"),
                          error.localizedDescription)
        }
    }
    func testSessionLaunchedArgs() async throws {
        let (cli, runner) = cli(#"{"attached":true}"#)
        let attached = try await cli.sessionLaunched(step: 9, session: 4)
        XCTAssertEqual(runner.invocations, [["automations", "session-launched", "--step", "9", "--session", "4", "--json"]])
        XCTAssertTrue(attached)
        let refused = try await self.cli(#"{"attached":false}"#).0.sessionLaunched(step: 9, session: 4)
        XCTAssertFalse(refused)
    }

    func testSessionEndedArgs() async throws {
        let (cli, runner) = cli(#"{"ended":true}"#)
        let ended = try await cli.sessionEnded(step: 9, status: .launchFailed, error: "Codex was not found.")
        XCTAssertTrue(ended)
        let (stopped, stoppedRunner) = self.cli(#"{"ended":false}"#)
        let notWaiting = try await stopped.sessionEnded(step: 9, status: .stopped, error: nil)
        XCTAssertFalse(notWaiting)
        XCTAssertEqual(runner.invocations, [["automations", "session-ended", "--step", "9", "--status", "launch_failed",
                                             "--error", "Codex was not found.", "--json"]])
        XCTAssertEqual(stoppedRunner.invocations, [["automations", "session-ended", "--step", "9", "--status", "stopped",
                                                    "--json"]])
    }

    func testRescanWorkbenchArgs() async throws {
        let (cli, runner) = cli("[]")
        try await cli.rescan(workbenchID: 3)
        XCTAssertEqual(runner.invocations, [["automations", "rescan", "--workbench", "3"]])
    }
}

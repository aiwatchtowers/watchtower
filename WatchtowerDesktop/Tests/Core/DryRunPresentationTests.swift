import XCTest
@testable import WatchtowerCore

final class DryRunPresentationTests: XCTestCase {
    private func line(_ step: AutomationRunStep) -> String {
        DryRunPresentation.lines(steps: [step])[0]
    }

    func testWriteToolDryRunClipsArgs() {
        let args = #"{"project_key":"OPS","summary":""# + String(repeating: "x", count: 300) + #""}"#
        let got = line(AutomationRunStep(kind: "tool", name: "create_jira_issue", argsJSON: args, status: "dry_run"))
        XCTAssertEqual(got, "Would propose create_jira_issue " + String(args.prefix(200)) + "…")
        XCTAssertEqual(line(AutomationRunStep(kind: "tool", name: "create_jira_issue", argsJSON: "{}", status: "dry_run")),
                       "Would propose create_jira_issue {}")
    }

    func testOutputs() {
        XCTAssertEqual(line(AutomationRunStep(kind: "output", name: "inbox", argsJSON: #"{"title":"3 new threads","body":"b"}"#,
                                              status: "dry_run")),
                       "Would post to Inbox: 3 new threads")
        XCTAssertEqual(line(AutomationRunStep(kind: "output", name: "report", argsJSON: #"{"title":"OPS status","body":""}"#,
                                              status: "dry_run")),
                       "Would add a report: OPS status")
    }

    func testStateLLMDeniedRead() {
        XCTAssertEqual(line(AutomationRunStep(kind: "state", name: "set", status: "dry_run")), "Would save state")
        XCTAssertEqual(line(AutomationRunStep(kind: "llm", status: "ok", inputTokens: 1000, outputTokens: 234)),
                       "Asked the assistant · 1,234 tokens")
        XCTAssertEqual(line(AutomationRunStep(kind: "tool", name: "list_jira_issues", status: "denied",
                                              permission: "jira:read@OPS")),
                       "Denied — needs jira:read@OPS")
        XCTAssertEqual(line(AutomationRunStep(kind: "tool", name: "list_jira_issues", status: "ok")),
                       "Read list_jira_issues")
    }

    func testFallbackShowsKindStatusAndError() {
        XCTAssertEqual(line(AutomationRunStep(kind: "tool", name: "get_email", status: "error", error: "timeout")),
                       "tool get_email · error: timeout")
    }
}

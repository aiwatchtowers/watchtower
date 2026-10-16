import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The finish notice of a quick run (spec §12.7).
@MainActor
final class AutomationRunNotifierTests: XCTestCase {
    func testTitles() {
        let want: [(AutomationRunStatus, String)] = [
            (.succeeded, "Inbox sweep finished"),
            (.failed, "Inbox sweep failed"),
            (.budgetExceeded, "Inbox sweep stopped: budget exceeded"),
            (.timedOut, "Inbox sweep stopped: timed out"),
            (.cancelled, "Inbox sweep stopped: cancelled"),
            (.expired, "Inbox sweep stopped: expired")
        ]
        for (status, title) in want {
            XCTAssertEqual(AutomationRunNotifier.title(name: "Inbox sweep", status: status), title)
        }
    }

    func testBodyPrefersSummaryThenError() {
        XCTAssertEqual(AutomationRunNotifier.body(summary: "3 threads", error: "boom"), "3 threads")
        XCTAssertEqual(AutomationRunNotifier.body(summary: "", error: "boom"), "boom")
        XCTAssertEqual(AutomationRunNotifier.body(summary: "", error: ""), "")
    }

    func testIdentifierIsPerRun() {
        XCTAssertEqual(AutomationRunNotifier.identifier(runID: 9), "automation-run-9")
        XCTAssertEqual(AutomationRunNotifier.identifier(runID: 9), AutomationRunNotifier.identifier(runID: 9))
        XCTAssertNotEqual(AutomationRunNotifier.identifier(runID: 9), AutomationRunNotifier.identifier(runID: 10))
    }

    func testUserInfoCarriesAutomationAndRun() {
        let info = AutomationRunNotifier.userInfo(automationID: 4, runID: 9)
        XCTAssertEqual(info["type"] as? String, "automation_run")
        XCTAssertEqual(info["automationId"] as? Int64, 4)
        XCTAssertEqual(info["runId"] as? Int64, 9)
    }

    /// The notifier hands the center's call to the service unchanged.
    func testRunFinishedSendsTheRun() {
        var sent: [String] = []
        let notifier = AutomationRunNotifier { name, status, summary, error, automationID, runID in
            sent.append("\(name)|\(status.rawValue)|\(summary)|\(error)|\(automationID)|\(runID)")
        }
        notifier.runFinished(name: "Inbox sweep", status: .failed, summary: "", error: "boom",
                             automationID: 4, runID: 9)
        XCTAssertEqual(sent, ["Inbox sweep|failed||boom|4|9"])
    }
}

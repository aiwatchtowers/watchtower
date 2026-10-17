import XCTest
@testable import WatchtowerCore

/// #559: the warning about `llm()` over source data with auto on for a tool
/// that writes outside Watchtower (sample data: acme).
final class AutomationLLMWarningTests: XCTestCase {
    func testLineNeedsFeedsAndTools() {
        XCTAssertNil(AutomationLLMWarning.line(feedsSourcesToLLM: false, tools: ["send_slack_message"]))
        XCTAssertNil(AutomationLLMWarning.line(feedsSourcesToLLM: true, tools: []))
        XCTAssertEqual(
            AutomationLLMWarning.line(feedsSourcesToLLM: true, tools: ["add_jira_comment", "send_slack_message"]),
            "This recipe passes data from its sources to llm(). With auto on for add_jira_comment, send_slack_message, "
                + "text the model writes from other people's messages can be sent without asking you."
        )
    }

    /// The Save sheet warns for the paused External grants when the new text
    /// feeds its sources to `llm()`; a local tool is never named.
    func testSavePlanWarnsForExternalPausedGrantsOnly() throws {
        let show = #"{"id":7,"slug":"digest","scope":"personal","path":"/acme/digest.md","name":"Digest","#
            + #""enabled":true,"runnable":true,"needs_confirmation":false,"approval_hash":"h1","confirmed_hash":"h1","#
            + #""auto_tools":[{"tool":"send_slack_message","always_asks":false,"external":true},"#
            + #"{"tool":"create_idea","always_asks":false,"external":false}]}"#
        let current = try JSONDecoder().decode(AutomationDetail.self, from: Data(show.utf8))
        let grants = ["send_slack_message", "create_idea"].map {
            AutomationToolGrant(automationID: 7, tool: $0, grantHash: "h1", grantedAt: Date(timeIntervalSince1970: 0))
        }
        func validated(feeds: Bool) throws -> AutomationsCLI.ValidateResult {
            try JSONDecoder().decode(AutomationsCLI.ValidateResult.self,
                                     from: Data(#"{"ok":true,"approval_hash":"h2","feeds_sources_to_llm":\#(feeds)}"#.utf8))
        }
        let feeding = AutomationSavePlan.make(validated: try validated(feeds: true), current: current, grants: grants)
        XCTAssertEqual(feeding.pausedGrants, ["create_idea", "send_slack_message"])
        XCTAssertEqual(feeding.llmWarningTools, ["send_slack_message"])

        let plain = AutomationSavePlan.make(validated: try validated(feeds: false), current: current, grants: grants)
        XCTAssertEqual(plain.llmWarningTools, [])
    }
}

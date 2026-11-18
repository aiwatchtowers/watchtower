import XCTest
@testable import WatchtowerCore

/// Per-provider wording of the plan-limit codes (#1885): Claude's codes are
/// worded from `SubscriptionUsagePolicy.messages`, Codex keeps today's text.
final class PlansPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let shared = [
        "parse": "Couldn't read the subscription response. Retry to update.",
        "timeout": "The refresh timed out. Try again.",
        "busy": "Another refresh is running. Try again shortly.",
        "storage": "Couldn't read saved limits. Retry to reload.",
        "cancelled": "Refresh cancelled.",
        "feature_disabled": "Plan limits are turned off in Features."
    ]

    func testClaudeWordingForEveryCode() {
        let expected = shared.merging([
            "cli_missing": "Install Claude Code, then retry.",
            "unsupported_cli": "Update Claude Code to read plan limits, then retry.",
            "no_credentials": "Sign in to Claude Code with your Claude plan, then retry.",
            "unsupported_auth": "Claude Code is using an API key here, so plan limits don't apply.",
            "cloud_bedrock": "Claude Code is using Bedrock here, so plan limits don't apply.",
            "cloud_vertex": "Claude Code is using Vertex here, so plan limits don't apply.",
            "cloud_foundry": "Claude Code is using Foundry here, so plan limits don't apply.",
            "network": "Couldn't update Claude limits. Retry to update."
        ]) { $1 }
        XCTAssertEqual(Set(expected.keys), Set(PlansOperationError.codes))
        for (code, text) in expected {
            let actual = PlansPresentation.errorText(code, provider: .claude)
            XCTAssertEqual(actual, text, code)
            XCTAssertFalse(actual.localizedCaseInsensitiveContains("token"), code)
            XCTAssertFalse(actual.localizedCaseInsensitiveContains("keychain"), code)
            XCTAssertFalse(actual.contains("ANTHROPIC_"), code)
        }
    }

    func testCodexWordingUnchanged() {
        let expected = shared.merging([
            "cli_missing": "Install Codex, then retry.",
            "unsupported_cli": "Update Codex to read subscription limits, then retry.",
            "no_credentials": "Open Codex and sign in, then retry.",
            "unsupported_auth": "Sign in to Codex with a ChatGPT account, then retry.",
            "cloud_bedrock": "Couldn't update Codex limits. Retry to update.",
            "cloud_vertex": "Couldn't update Codex limits. Retry to update.",
            "cloud_foundry": "Couldn't update Codex limits. Retry to update.",
            "network": "Couldn't update Codex limits. Retry to update."
        ]) { $1 }
        XCTAssertEqual(Set(expected.keys), Set(PlansOperationError.codes))
        for (code, text) in expected { XCTAssertEqual(PlansPresentation.errorText(code, provider: .codex), text, code) }
        XCTAssertEqual(PlansPresentation.errorText("token_expired", provider: .codex), "Open Codex and sign in, then retry.")
    }

    func testLegacyTokenReasonsReadAsSignIn() throws {
        let signIn = "Sign in to Claude Code with your Claude plan, then retry."
        XCTAssertEqual(PlansPresentation.errorText("token_expired", provider: .claude), signIn)
        XCTAssertEqual(PlansPresentation.errorText("http_401", provider: .claude), signIn)
        let stored = PlanUsageStatus(state: "stale", reason: "token_expired", plan: "max", fetchedAt: now.addingTimeInterval(-60),
                                     lastError: "", limits: [], breakdown: [])
        let card = try PlansPresentation.card(provider: .claude, status: stored, error: nil, refreshing: false, now: now)
        XCTAssertEqual(card.summary, signIn)
    }
}

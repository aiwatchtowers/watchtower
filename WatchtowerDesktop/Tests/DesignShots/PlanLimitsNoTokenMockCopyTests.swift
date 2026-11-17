import WatchtowerCore
import XCTest

/// Pins the plan limits without a token spec's string table (#1885) so the
/// mockups and the spec text cannot drift. The implementation moves these
/// strings into `PlansPresentation.errorText` and pins them there.
@MainActor
final class PlanLimitsNoTokenMockCopyTests: XCTestCase {
    func testClaudeMessagesNameClaudeCodeAndTheFix() {
        typealias Copy = PlanLimitsNoTokenMockCopy
        XCTAssertEqual(Copy.cliMissing, "Install Claude Code, then retry.")
        XCTAssertEqual(Copy.cliOutdated, "Update Claude Code to read plan limits, then retry.")
        XCTAssertEqual(Copy.notSignedIn, "Sign in to Claude Code with your Claude plan, then retry.")
        XCTAssertEqual(Copy.apiKey, "Claude Code is using an API key here, so plan limits don't apply.")
        XCTAssertNotEqual(Copy.apiKey, Copy.notSignedIn, "an API key is not a sign-in problem")
        for text in [Copy.cliMissing, Copy.cliOutdated, Copy.notSignedIn, Copy.apiKey] {
            XCTAssertTrue(text.contains("Claude Code"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("keychain"), "the copy never mentions credentials")
            XCTAssertFalse(text.localizedCaseInsensitiveContains("token"), "the copy never mentions credentials")
            XCTAssertFalse(text.contains("ANTHROPIC_"), "the copy never names or quotes environment values")
        }
    }

    func testCloudProviderVariantsNameTheProvider() {
        typealias Copy = PlanLimitsNoTokenMockCopy
        XCTAssertEqual(Copy.cloudProvider("Bedrock"), "Claude Code is using Bedrock here, so plan limits don't apply.")
        XCTAssertEqual(Set(Copy.cloudProviders.keys), ["cloud_bedrock", "cloud_vertex", "cloud_foundry"])
        for (code, name) in Copy.cloudProviders {
            let text = Copy.cloudProvider(name)
            XCTAssertTrue(text.contains(name), code)
            XCTAssertNotEqual(text, Copy.apiKey, code)
        }
    }

    /// Codex keeps today's wording; a failed Claude read keeps production's.
    func testUnchangedCopyStaysProduction() {
        XCTAssertEqual(PlansPresentation.errorText("cli_missing", provider: .codex), "Install Codex, then retry.")
        XCTAssertEqual(PlansPresentation.errorText("unsupported_cli", provider: .codex),
                       "Update Codex to read subscription limits, then retry.")
        XCTAssertNil(PlanLimitsNoTokenShotFixtures.mockMessage(.readFailed))
    }

    func testEveryFrameHasAScreenAndAMenuShot() {
        let names = Set(PlanLimitsNoTokenShotFixtures.shots.map(\.name))
        for frame in PlanLimitsNoTokenShotFixtures.Frame.allCases {
            XCTAssertTrue(names.contains("plan-limits-nt-\(frame.rawValue)"), frame.rawValue)
            XCTAssertTrue(names.contains("plan-limits-nt-menu-\(frame.rawValue)"), frame.rawValue)
        }
    }
}

import XCTest
@testable import WatchtowerCore

/// #1769 spec §6: the disclosure copy equals the mockups' table (which lives
/// in this test target) and names the same providers as the Slack app
/// manifest's long description (`internal/slackmanifest`, read from the repo).
final class SlackDisclosureCopyTests: XCTestCase {
    private func manifestLongDescription() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignShots
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/slackmanifest/slack-app-manifest.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(obj as? [String: Any])
        let info = try XCTUnwrap(root["display_information"] as? [String: Any])
        return try XCTUnwrap(info["long_description"] as? String)
    }

    func testMatchesMockupsAndManifest() throws {
        XCTAssertEqual(SlackDisclosureCopy.setupTitle, SlackPolicyMockCopy.disclosureTitle)
        XCTAssertEqual(SlackDisclosureCopy.setupLines, SlackPolicyMockCopy.disclosureLines)
        XCTAssertEqual(SlackDisclosureCopy.connectLine(workspace: "acme"), SlackPolicyMockCopy.connectLine)
        XCTAssertEqual(SlackDisclosureCopy.privacyLink, SlackPolicyMockCopy.privacyLink)

        let long = try manifestLongDescription()
        let setup = SlackDisclosureCopy.setupLines.joined(separator: " ")
        for provider in ["Anthropic", "Claude", "OpenAI", "Codex", "Ollama"] {
            XCTAssertTrue(setup.contains(provider), "setupLines lack \(provider)")
            XCTAssertTrue(long.contains(provider), "manifest long_description lacks \(provider)")
        }
        XCTAssertTrue(long.contains(SlackDisclosureCopy.privacyURL.absoluteString))
    }

    func testConnectLineNamesTheWorkspace() {
        let line = SlackDisclosureCopy.connectLine(workspace: "globex")
        XCTAssertTrue(line.contains("globex"))
        XCTAssertFalse(line.contains("acme"))
    }
}

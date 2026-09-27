import XCTest
@testable import WatchtowerCore

/// `internal/chat/artifacts_examples.md` is embedded verbatim in the Go
/// `ArtifactsContract()` prompt; the Swift parser must accept exactly what
/// the prompt teaches (dual path, pinned from both sides).
final class ArtifactContractFixtureTests: XCTestCase {
    private static func fixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/artifacts_examples.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPromptExamplesParse() throws {
        let artifacts = ArtifactParser.parse(try Self.fixture(), final: true).artifacts
        XCTAssertEqual(artifacts.map(\.key), ["vendor-followup", "standup-note", "design-review"])
        XCTAssertEqual(artifacts.map(\.kind), ["email", "slack", "event"])
        XCTAssertTrue(artifacts.allSatisfy(\.isComplete))
        XCTAssertEqual(artifacts[0].meta["subject"], #"Contract "v2" — next steps"#)
        XCTAssertEqual(artifacts[1].meta["channel"], "1:C0123ABC")
        XCTAssertNotNil(ArtifactActions.slackTarget(meta: artifacts[1].meta))
        let actions = ArtifactActions.kindActions(for: artifacts[2], gmailConnected: false, slackLinks: nil)
        guard case .open(let url) = actions.first?.action else { return XCTFail("event must open a calendar URL") }
        XCTAssertTrue(url.absoluteString.contains("dates=20260930T070000Z%2F20260930T080000Z"))
    }
}

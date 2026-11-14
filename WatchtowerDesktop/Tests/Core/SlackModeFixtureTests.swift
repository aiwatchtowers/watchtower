import Foundation
import Testing
@testable import WatchtowerCore

/// SLACKMODE-01: the Swift twin derives the mode exactly as Go's
/// `internal/slackmode`, over the one shared fixture.
@Suite("SlackModeFixture")
struct SlackModeFixtureTests {
    @Test func testFixtureMatchesGo() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/slackmode/testdata/slack_mode_cases.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let cases = try #require(obj as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let full = try #require(c["full"] as? Bool)
            let live = try #require(c["live"] as? [String])
            let want = try #require(c["want"] as? String)
            #expect(SlackMode.derive(full: full, liveStatuses: live).rawValue == want, "\(c["name"] ?? "")")
        }
    }
}

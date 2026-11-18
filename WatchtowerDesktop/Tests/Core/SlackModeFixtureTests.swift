import Foundation
import Testing
@testable import WatchtowerCore

/// SLACKMODE-01: the Swift twin derives the mode exactly as Go's
/// `internal/slackmode`, over the one shared fixture. A case gives either
/// `live` (the verdicts) or `probes` (`slack_live_status` rows, reduced to
/// each provider's newest batch by `SlackModePresentation.liveVerdicts`).
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
            let live = try Self.live(c)
            let want = try #require(c["want"] as? String)
            #expect(SlackMode.derive(full: full, liveStatuses: live).rawValue == want, "\(c["name"] ?? "")")
        }
    }

    private static func live(_ c: [String: Any]) throws -> [String] {
        guard let probes = c["probes"] as? [[String: Any]] else {
            return try #require(c["live"] as? [String])
        }
        #expect(c["live"] == nil, "a case gives live or probes, not both")
        let rows = try probes.map { p in
            try SlackLiveStatusRow(
                teamID: #require(p["team"] as? String), provider: #require(p["provider"] as? String),
                status: #require(p["status"] as? String), errorClass: "", connectorID: "",
                checkedAt: #require(p["checked_at"] as? String))
        }
        return SlackModePresentation.liveVerdicts(rows)
    }
}

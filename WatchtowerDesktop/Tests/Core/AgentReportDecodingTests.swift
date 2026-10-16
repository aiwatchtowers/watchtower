import XCTest
@testable import WatchtowerCore

/// The fixtures are written by the Go builders over a seeded placeholder
/// database (`internal/agentreport` `TestDesktopReportFixtures`, `-update`
/// regenerates them); a renamed key on either side fails a test.
final class AgentReportDecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/Core/<this file>
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    func testOverviewDecodes() throws {
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
        XCTAssertEqual(ov.workbenchID, 1)
        XCTAssertTrue(ov.enabled)
        XCTAssertEqual(ov.totals.sessions, 2)
        XCTAssertEqual(ov.totals.tokens.cacheRead, 400)
        XCTAssertEqual(ov.time.tools.buildTest, 360_000)
        XCTAssertEqual(ov.time.backgroundMS, 785_000)
        XCTAssertEqual(ov.time.wallMS, 3_630_000)
        XCTAssertEqual(ov.subagents.background, 1)
        XCTAssertEqual(ov.subagents.avgParallel, 1)
        XCTAssertEqual(ov.commands.first?.class, "build_test")
        XCTAssertEqual(ov.commands.first?.avgMS, 120_000)
        XCTAssertEqual(ov.models.first?.cacheReadShare ?? 0, 0.2837, accuracy: 0.0001)
        XCTAssertEqual(ov.hints.map(\.id), ["H4", "H1", "H6"])
        XCTAssertEqual(ov.hints[1].evidence.map(\.kind), ["command", "target", "session"])
        XCTAssertEqual(ov.hints[2].estimateUSD, 15)
        XCTAssertEqual(ov.tasks.first?.targetID, 1)
        XCTAssertEqual(ov.tasks.first?.phases["in_review"], 567_000_000)
        XCTAssertEqual(ov.tasks.first?.shared, true)
        XCTAssertEqual(ov.sessions.map(\.oldFormat), [true, false])
        XCTAssertEqual(ov.sessions[1].prs, ["https://example.com/acme/app/pull/1"])
        XCTAssertEqual(ov.oldFormatSessions, 1)
    }

    func testSessionDetailDecodes() throws {
        let d = try JSONDecoder().decode(AgentSessionDetail.self, from: fixture("agent-report-session"))
        XCTAssertEqual(d.session.uuid, "11111111-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(d.lanes.count, 2)
        XCTAssertEqual(d.lanes[0].agentID, "")
        XCTAssertTrue(d.lanes[1].background)
        XCTAssertEqual(Set(d.lanes[0].segments.compactMap(\.timeCategory)), [.model, .tool, .background, .owner, .away])
        XCTAssertEqual(d.lanes[0].segments[5].toolClass, "build_test")
        XCTAssertEqual(d.lanes[0].segments[5].verb, "make test")
        XCTAssertEqual(d.lanes[1].agentID, "agent-1")
        XCTAssertEqual(d.lanes[1].subagentType, "general-purpose")
        XCTAssertEqual(d.lanes[1].segments.map(\.timeCategory), [.model, .tool, .model])
        XCTAssertEqual(d.hints.map(\.id), ["H4", "H1", "H6"])
    }

    func testUnknownCategoryDoesNotFailTheDecode() throws {
        let json = #"{"start":"a","end":"b","category":"future","tool_class":"","verb":""}"#
        let seg = try JSONDecoder().decode(AgentSegment.self, from: Data(json.utf8))
        XCTAssertNil(seg.timeCategory)
    }
}

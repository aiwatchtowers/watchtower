import XCTest
@testable import WatchtowerCore

/// The fixtures are the Go report structs (`internal/agentreport`) marshalled
/// with placeholder data; a renamed key on either side fails here.
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
        XCTAssertEqual(ov.totals.tokens.cacheWrite5m, 300)
        XCTAssertEqual(ov.time.tools.subagentsFG, 120000)
        XCTAssertEqual(ov.time.wallMS, 3_800_000)
        XCTAssertEqual(ov.subagents.avgParallel, 1.25)
        XCTAssertEqual(ov.commands.first?.class, "build_test")
        XCTAssertEqual(ov.commands.first?.avgMS, 180000)
        XCTAssertEqual(ov.models.first?.cacheReadShare, 0.91)
        XCTAssertEqual(ov.hints.map(\.id), ["H1", "H6"])
        XCTAssertEqual(ov.hints[0].evidence.map(\.kind), ["command", "target", "session"])
        XCTAssertEqual(ov.hints[1].evidence, [])
        XCTAssertEqual(ov.hints[1].estimateUSD, 9)
        XCTAssertEqual(ov.tasks.first?.targetID, 7)
        XCTAssertEqual(ov.tasks.first?.phases["in_review"], 2_200_000)
        XCTAssertEqual(ov.tasks.first?.shared, true)
        XCTAssertEqual(ov.sessions.map(\.oldFormat), [false, true])
        XCTAssertEqual(ov.sessions[0].prs, ["https://example.com/acme/app/pull/1"])
        XCTAssertEqual(ov.oldFormatSessions, 1)
    }

    func testSessionDetailDecodes() throws {
        let d = try JSONDecoder().decode(AgentSessionDetail.self, from: fixture("agent-report-session"))
        XCTAssertEqual(d.session.uuid, "11111111-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(d.lanes.count, 2)
        XCTAssertEqual(d.lanes[0].agentID, "")
        XCTAssertTrue(d.lanes[1].background)
        XCTAssertEqual(d.lanes[0].segments.map(\.timeCategory), [.model, .tool])
        XCTAssertEqual(d.lanes[0].segments[1].toolClass, "build_test")
        XCTAssertEqual(d.lanes[0].segments[1].verb, "make test")
        XCTAssertEqual(d.lanes[1].segments[0].timeCategory, .background)
        XCTAssertEqual(d.hints.count, 1)
    }

    func testUnknownCategoryDoesNotFailTheDecode() throws {
        let json = #"{"start":"a","end":"b","category":"future","tool_class":"","verb":""}"#
        let seg = try JSONDecoder().decode(AgentSegment.self, from: Data(json.utf8))
        XCTAssertNil(seg.timeCategory)
    }
}

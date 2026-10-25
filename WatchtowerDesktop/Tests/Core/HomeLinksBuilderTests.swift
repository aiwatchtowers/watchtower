import XCTest
@testable import WatchtowerCore

/// The links zone's pure builder: statuses, highlight, hidden tabs.
final class HomeLinksBuilderTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }
    private let now = Date(timeIntervalSince1970: 1_792_400_000)

    private func briefing(id: Int, date: String, createdAt: String) throws -> Briefing {
        let json = """
        {"id":\(id),"user_id":"U1","date":"\(date)","role":"","attention":"[]","your_day":"[]",
        "what_happened":"[]","team_pulse":"[]","coaching":"[]","model":"","input_tokens":0,
        "output_tokens":0,"cost_usd":0,"prompt_version":0,"created_at":"\(createdAt)"}
        """
        return try JSONDecoder().decode(Briefing.self, from: Data(json.utf8))
    }

    private func row(_ kind: HomeLinkKind, _ data: HomeLinksData) -> HomeLinkRow? {
        HomeLinksBuilder.links(data, allowed: Set(HomeLinkKind.allCases), now: now, calendar: calendar)
            .first { $0.kind == kind }
    }

    func testBriefingReadyTime() throws {
        var data = HomeLinksData()
        data.briefingToday = try briefing(id: 4, date: "2026-10-19", createdAt: "2026-10-19T08:05:00Z")
        let row = try XCTUnwrap(row(.briefing, data))
        XCTAssertEqual(row.status, "ready 08:05")
        XCTAssertEqual(row.link, .briefing(id: 4))
    }

    func testBriefingFallsBackToLatestWeekday() throws {
        var data = HomeLinksData()
        data.latestBriefing = try briefing(id: 3, date: "2026-10-16", createdAt: "2026-10-16T08:05:00Z")
        let row = try XCTUnwrap(row(.briefing, data))
        XCTAssertEqual(row.status, "Fri")
        XCTAssertEqual(row.link, .briefing(id: 3))
        XCTAssertNil(try XCTUnwrap(self.row(.briefing, HomeLinksData())).status)
    }

    func testCatchUpBadgeOnlyWhenUnacknowledged() throws {
        let plain = try XCTUnwrap(row(.catchUp, HomeLinksData()))
        XCTAssertNil(plain.status)
        XCTAssertFalse(plain.highlighted)
        XCTAssertEqual(plain.link, .catchUp)
    }

    func testDayPlanCounts() throws {
        var data = HomeLinksData()
        data.dayPlanDone = 2
        data.dayPlanTotal = 5
        XCTAssertEqual(row(.dayPlan, data)?.status, "2 of 5 done")
        // The plan opens today's Inbox day card (`InboxRoute.forFeature`).
        XCTAssertEqual(row(.dayPlan, data)?.link, .feature(.dayPlan))
        XCTAssertEqual(InboxRoute.forFeature(.dayPlan, today: "2026-10-19"),
                       InboxRoute(filter: .day, selection: .day("2026-10-19")))
        XCTAssertNil(row(.dayPlan, HomeLinksData())?.status)
        XCTAssertNil(row(.digests, data)?.status)
    }

    func testHiddenTabLinkLeftOut() {
        let rows = HomeLinksBuilder.links(HomeLinksData(), allowed: [.digests, .briefing], now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.kind), [.briefing, .digests])
    }
}

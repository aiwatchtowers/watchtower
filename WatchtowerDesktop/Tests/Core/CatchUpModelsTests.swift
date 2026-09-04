import XCTest
@testable import WatchtowerCore

final class CatchUpModelsTests: XCTestCase {

    // MARK: - Body decoding

    func testBodyDecodesTolerantly() throws {
        let raw = #"""
        {"topics":[{"title":"T","narrative":"n","priority":"high","refs":[{"area":"digests","id":1,"label":"#eng"}]}],
         "needs_you":[{"text":"ping","kind":"dm","refs":[]}]}
        """#
        let body = try JSONDecoder().decode(CatchUpRecapBody.self, from: Data(raw.utf8))
        XCTAssertEqual(body.topics.first?.refs.first?.compositeID, "digests:1")
        XCTAssertEqual(body.topics.first?.priority, "high")
        XCTAssertEqual(body.decisions, [], "missing key → empty")
        XCTAssertEqual(body.meetings, [], "missing key → empty")
        XCTAssertEqual(body.needsYou.first?.kind, "dm")
        XCTAssertFalse(body.isEmpty)

        let empty = try JSONDecoder().decode(CatchUpRecapBody.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
    }

    func testBodyItemsTolerateMissingFields() throws {
        // Partial model output: every item field falls back to "" / [].
        let raw = #"""
        {"topics":[{}],"decisions":[{}],"meetings":[{"title":"M"}],"needs_you":[{}]}
        """#
        let body = try JSONDecoder().decode(CatchUpRecapBody.self, from: Data(raw.utf8))
        XCTAssertEqual(body.topics.first, CatchUpTopic())
        XCTAssertEqual(body.decisions.first, CatchUpEntry())
        XCTAssertEqual(body.meetings.first, CatchUpMeeting(title: "M"))
        XCTAssertEqual(body.needsYou.first, CatchUpNeed())
        XCTAssertFalse(body.isEmpty, "present-but-empty items still count as content")
    }

    // MARK: - Coverage

    func testCoverageSummaryLine() throws {
        let raw = #"{"slack_to":1000,"streams_to":0,"meetings":2,"topup":"failed","topup_error":"lock"}"#
        let cov = try JSONDecoder().decode(CatchUpCoverage.self, from: Data(raw.utf8))
        XCTAssertEqual(cov.topupError, "lock")

        let line = cov.summaryLine { _ in "17:40" }
        XCTAssertEqual(line, "Slack to 17:40 · 2 meetings · top-up failed")
        XCTAssertEqual(CatchUpCoverage().summaryLine { _ in "" }, "No summaries in this window")
    }

    func testCoverageSummaryLineListsEverySourcePresent() {
        let cov = CatchUpCoverage(slackTo: 1000, streamsTo: 2000, meetings: 1, topup: "ok")
        let line = cov.summaryLine { $0 == 1000 ? "17:40" : "14:00" }
        XCTAssertEqual(line, "Slack to 17:40 · Jira/Gmail to 14:00 · 1 meeting")
    }

    func testCoverageDecodesTolerantly() throws {
        let cov = try JSONDecoder().decode(CatchUpCoverage.self, from: Data("{}".utf8))
        XCTAssertEqual(cov, CatchUpCoverage())
    }

    // MARK: - Window label

    func testWindowLabelSameDayAndMultiDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let from = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 9)))
        let sameDay = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 18, minute: 30)))
        XCTAssertEqual(CatchUpRecap.windowLabel(from: from, to: sameDay, calendar: cal), "Fri 4 Sep, 09:00 → 18:30")

        let later = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 9, minute: 15)))
        XCTAssertEqual(CatchUpRecap.windowLabel(from: from, to: later, calendar: cal), "4 Sep 09:00 – 6 Sep 09:15")
    }
}

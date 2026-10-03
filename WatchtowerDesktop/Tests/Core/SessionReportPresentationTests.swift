import XCTest
import WatchtowerCore

/// The Session view's and the row line's strings (spec
/// 2026-10-03-workbench-session-report Part 1, Part 7), over Go's goldens
/// where they fit. Times show in a pinned zone.
final class SessionReportPresentationTests: XCTestCase {
    private typealias Presentation = SessionReportPresentation
    private let utc = TimeZone.gmt

    // MARK: State and size

    func testHeroLine() {
        XCTAssertEqual(Presentation.heroLine(.init(done: 14, total: 15)), "14 / 15 tasks")
        XCTAssertEqual(Presentation.heroLine(.init(done: 0, total: 1)), "0 / 1 task")
        XCTAssertEqual(Presentation.heroLine(.init(done: 0, total: 0)), "No tasks yet")
        XCTAssertEqual(Presentation.progressFraction(.init(done: 3, total: 4)), 0.75)
        XCTAssertEqual(Presentation.progressFraction(.init(done: 0, total: 0)), 0)
    }

    func testRanFor() throws {
        XCTAssertEqual(Presentation.ranFor(try SessionReportTests.golden("session_report_314").session), "4d 8h",
                       "not finished: created to last activity")
        XCTAssertEqual(Presentation.ranFor(try SessionReportTests.golden("session_report_finished").session), "1d 7h",
                       "finished: created to the finish")
        XCTAssertEqual(Presentation.ranFor(.init(createdAt: "2026-10-02T09:00:00Z", lastActiveAt: "2026-10-02T12:20:30Z")), "3h 20m")
        XCTAssertEqual(Presentation.ranFor(.init(createdAt: "2026-10-02T09:00:00Z", lastActiveAt: "2026-10-02T09:12:00.500Z")), "12m")
        XCTAssertNil(Presentation.ranFor(.init(createdAt: "", lastActiveAt: "2026-10-02T09:12:00Z")))
    }

    // MARK: Done

    func testPhaseLinesFromTheGolden() throws {
        let r = try SessionReportTests.golden("session_report_314")
        XCTAssertEqual(Presentation.phaseLine(r.phases[0], timeZone: utc), .init(
            title: "Phase A: data layer", count: "7/7", span: "Sep 29, 09:01 – 11:07", isComplete: true
        ))
        XCTAssertEqual(Presentation.phaseLine(r.phases[2], timeZone: utc), .init(
            title: "Phase C: desktop view", count: "1/2", span: "Oct 1, 09:00 – …", isComplete: false
        ))
    }

    func testTimeSpanSameDay() {
        XCTAssertEqual(Presentation.timeSpan(from: "2026-09-29T09:01:00Z", to: "2026-09-29T11:07:00.000Z", timeZone: utc),
                       "Sep 29, 09:01 – 11:07")
    }

    func testTimeSpanAcrossMidnight() {
        XCTAssertEqual(Presentation.timeSpan(from: "2026-09-29T23:10:00Z", to: "2026-09-30T01:05:00Z", timeZone: utc),
                       "Sep 29, 23:10 – Sep 30, 01:05")
    }

    func testTimeSpanStillRunning() {
        XCTAssertEqual(Presentation.timeSpan(from: "2026-10-01T07:47:00Z", to: "", timeZone: utc), "Oct 1, 07:47 – …")
    }

    func testTimeSpanDaysAreTheViewersDays() throws {
        // Across midnight in UTC, but one night in Kyiv (UTC+3).
        let kyiv = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        XCTAssertEqual(Presentation.timeSpan(from: "2026-09-29T22:30:00Z", to: "2026-09-30T00:30:00Z", timeZone: kyiv),
                       "Sep 30, 01:30 – 03:30")
    }

    func testTimeSpanWithoutAStartIsNil() {
        XCTAssertNil(Presentation.timeSpan(from: "", to: "", timeZone: utc), "no leaf started yet")
        XCTAssertNil(Presentation.timeSpan(from: "garbage", to: "2026-09-30T00:30:00Z", timeZone: utc))
    }

    func testNextLine() throws {
        let r = try SessionReportTests.golden("session_report_finished")
        XCTAssertEqual(r.next.map(Presentation.nextLine), ["Next: #423 Document the export"])
    }

    // MARK: Now and pull requests

    func testNowDetail() throws {
        let r = try SessionReportTests.golden("session_report_finished")
        XCTAssertEqual(Presentation.nowDetail(r.now[0], timeZone: utc), "in progress · feat/export-ui · since Oct 2, 10:15")
        let bare = try JSONDecoder().decode(SessionReport.NowItem.self, from: Data(#"{"id": 1, "status": "in_review"}"#.utf8))
        XCTAssertEqual(Presentation.nowDetail(bare, timeZone: utc), "in review")
    }

    func testPRLines() throws {
        let finished = try SessionReportTests.golden("session_report_finished")
        XCTAssertEqual(Presentation.prLine(finished.prs[0], timeZone: utc),
                       .init(title: "PR #151 Export progress sheet", detail: "open · +180/−12"))
        XCTAssertEqual(Presentation.prLine(finished.prs[1], timeZone: utc),
                       .init(title: "PR #150 Exporter", detail: "merged Oct 2, 12:00 · +420/−35"))
        XCTAssertEqual(Presentation.prLine(.init(ref: "branch:feat/b", state: "open"), timeZone: utc),
                       .init(title: "feat/b", detail: "no PR yet"))
        XCTAssertEqual(Presentation.prLine(.init(ref: "branch:feat/c", state: "none"), timeZone: utc),
                       .init(title: "feat/c", detail: "no PR yet"), "gh checked the branch and found no PR")
        XCTAssertEqual(Presentation.prLine(.init(ref: "branch:feat/a", state: "merged"), timeZone: utc),
                       .init(title: "feat/a", detail: "merged"), "a branch merged without a PR")
        XCTAssertEqual(Presentation.prLine(.init(ref: "pr:9", prNumber: 9), timeZone: utc),
                       .init(title: "PR #9", detail: "not checked"))
        XCTAssertEqual(Presentation.prLine(.init(ref: "pr:9", prNumber: 9, state: "closed"), timeZone: utc),
                       .init(title: "PR #9", detail: "closed"))
    }

    /// The 314 golden lists `branch:feature/session-report` as its own entry,
    /// never checked, beside `pr:147` of the same target: until a refresh
    /// links them it must read "not checked", not claim there is no PR.
    func testAnUnknownBranchBesideItsPR() throws {
        let r = try SessionReportTests.golden("session_report_314")
        XCTAssertEqual(r.prs.map { Presentation.prLine($0, timeZone: utc) }, [
            .init(title: "PR #147 Session report", detail: "open · +1200/−80"),
            .init(title: "feature/session-report", detail: "not checked"),
            .init(title: "feature/session-report-ui", detail: "not checked")
        ])
        let row = SessionReportSummary(sessionID: r.session.id, targetID: r.session.targetID,
                                       done: r.progress.done, total: r.progress.total, prLine: "PR #147 open")
        XCTAssertEqual(Presentation.rowCaption(row), "#314 · 14/15 · PR #147 open")
    }

    // MARK: Agent's last word

    func testAgentsLastWordWhenFinished() throws {
        let r = try SessionReportTests.golden("session_report_finished")
        XCTAssertEqual(Presentation.lastWord(r.session), .init(
            title: "Agent's last word",
            text: "Exporter merged in PR #150.\nThe progress sheet is open in PR #151 and waits on your answer about the file name.",
            isPlaceholder: false
        ))
    }

    func testPreviousSummaryWhenNotFinishedAndASummaryIsKept() {
        let session = SessionReport.Session(finishedAt: "", finishSummary: "Shipped the exporter.\n")
        XCTAssertEqual(Presentation.lastWord(session), .init(title: "Previous summary", text: "Shipped the exporter.", isPlaceholder: false))
    }

    func testNoSummaryIsThePlaceholder() throws {
        let r = try SessionReportTests.golden("session_report_314")
        XCTAssertEqual(Presentation.lastWord(r.session), .init(title: "Agent's last word", text: Presentation.lastWordEmptyText, isPlaceholder: true))
        XCTAssertEqual(Presentation.lastWord(.init(finishedAt: "2026-10-02T15:59:30.000Z", finishSummary: "  ")).isPlaceholder, true)
    }

    func testEmptyTexts() {
        XCTAssertEqual(Presentation.onYouEmptyText, "Nothing — the agent is not waiting for you.")
        XCTAssertEqual(Presentation.noSessionText, "Pick a session")
    }

    // MARK: Session rows

    func testRowCaption() {
        let row = SessionReportSummary(sessionID: 1, targetID: 314, done: 14, total: 15, prLine: "PR #147 open")
        XCTAssertEqual(Presentation.rowCaption(row), "#314 · 14/15 · PR #147 open")
        XCTAssertEqual(Presentation.rowCaption(row, stale: true), "#314 · 14/15 · PR #147 open · stale")
    }

    func testRowCaptionWithoutATicket() {
        XCTAssertEqual(Presentation.rowCaption(.init(sessionID: 1, done: 2, total: 3, prLine: "2 PRs merged")), "2/3 · 2 PRs merged")
    }

    func testRowCaptionWithoutAPR() {
        XCTAssertEqual(Presentation.rowCaption(.init(sessionID: 1, targetID: 314, done: 14, total: 15)), "#314 · 14/15")
        XCTAssertEqual(Presentation.rowCaption(.init(sessionID: 1, targetID: 314, prLine: "no PR yet")), "#314 · no PR yet",
                       "no X/Y when nothing is in scope")
    }

    func testRowCaptionEmptyAndStale() {
        XCTAssertEqual(Presentation.rowCaption(.init(sessionID: 1)), "")
        XCTAssertEqual(Presentation.rowCaption(.init(sessionID: 1), stale: true), "stale", "a failure is never a blank caption")
    }
}

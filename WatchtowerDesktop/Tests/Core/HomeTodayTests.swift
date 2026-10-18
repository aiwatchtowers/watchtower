import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Home's Today cards: which show, in what order, and their wording. The
/// meeting, waiting and targets cards are gone: the feed carries them.
final class HomeTodayTests: XCTestCase {
    private let calendar = Calendar.current
    private var now: Date!
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        // A fixed morning keeps "later today" and "tomorrow" on their own days.
        now = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()))
        db = try TestDatabase.create()
    }

    // MARK: - Fixtures

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func todayAt(hour: Int, minute: Int = 0, days: Int = 0) throws -> Date {
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: days, to: now))
        return try XCTUnwrap(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day))
    }

    private func format(_ pattern: String, _ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }

    private func briefing(attention: String = "[]", yourDay: String = "[]") -> Briefing {
        // swiftlint:disable:next force_try
        try! Briefing(row: Row([
            "id": 7, "user_id": "U001", "date": format("yyyy-MM-dd", now), "role": "engineer",
            "attention": attention, "your_day": yourDay, "what_happened": "[]", "team_pulse": "[]",
            "coaching": "[]", "model": "haiku", "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0,
            "prompt_version": 1, "created_at": iso(now)
        ]))
    }

    private func recap(status: String = "ready", acknowledged: Bool = false, from: Date) -> CatchUpRecap {
        var values: [String: (any DatabaseValueConvertible)?] = [
            "id": 3, "period_from": from.timeIntervalSince1970, "period_to": now.timeIntervalSince1970,
            "status": status, "tldr": "Two threads need you", "created_at": iso(now)
        ]
        if acknowledged { values["acknowledged_at"] = iso(now) }
        return CatchUpRecap(row: Row(values), now: now)
    }

    private func homeAsks(_ specs: [(workbench: String, title: String, kind: String, session: Bool)]) throws
        -> WorkbenchAskRows {
        try db.write { d in
            var projects: [String: Int64] = [:]
            for (i, spec) in specs.enumerated() {
                let project = try projects[spec.workbench]
                    ?? TestDatabase.insertWorkbench(d, name: spec.workbench, folder: "/tmp/\(spec.workbench)")
                projects[spec.workbench] = project
                var session: Int64?
                if spec.session {
                    try d.execute(
                        sql: """
                            INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
                            VALUES (?, 'shell', 'Session', ?)
                            """,
                        arguments: [project, "/tmp/\(spec.workbench)"])
                    session = d.lastInsertedRowID
                }
                try TestDatabase.insertOwnerAsk(d, projectID: project, sessionID: session, kind: spec.kind,
                                                title: spec.title,
                                                docPath: spec.kind == "review" ? "docs/spec.md" : "",
                                                createdAt: self.iso(self.now.addingTimeInterval(Double(i - 60) * 60)))
            }
            return try OwnerAskQueries.openAsksAllWorkbenches(d)
        }
    }

    private func fullData() throws -> HomeTodayData {
        var data = HomeTodayData()
        data.briefing = briefing(yourDay: #"[{"text":"Standup at 10"}]"#)
        data.asks = try homeAsks([("acme", "Check the build", "check", false)])
        data.pendingRecap = recap(from: now.addingTimeInterval(-86400))
        data.suggestion = HomeInstructionSuggestion(id: 4, text: "Run the tests first")
        return data
    }

    private func cards(_ data: HomeTodayData, allowed: Set<TodayCardKind> = Set(TodayCardKind.allCases))
        -> [TodayCard] {
        HomeTodayBuilder.cards(data, allowed: allowed, now: now, calendar: calendar)
    }

    // MARK: - Which cards

    func testCardShowsOnlyWithContent() {
        var data = HomeTodayData()
        data.suggestion = HomeInstructionSuggestion(id: 4, text: "Run the tests first")
        XCTAssertEqual(cards(data).map(\.kind), [.instructionSuggestion])
    }

    /// Owner ask #308: Since you were away leads.
    func testFixedOrder() throws {
        XCTAssertEqual(cards(try fullData()).map(\.kind),
                       [.sinceYouWereAway, .briefing, .agentsWaiting, .instructionSuggestion])
    }

    func testAllowedFiltersCards() throws {
        var allowed = Set(TodayCardKind.allCases)
        allowed.remove(.sinceYouWereAway)
        let kinds = cards(try fullData(), allowed: allowed).map(\.kind)
        XCTAssertFalse(kinds.contains(.sinceYouWereAway))
        XCTAssertEqual(kinds.count, TodayCardKind.allCases.count - 1)
    }

    func testInstructionSuggestionCardCopy() throws {
        var data = HomeTodayData()
        data.suggestion = HomeInstructionSuggestion(id: 4, text: "Run the tests first")
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.kind, .instructionSuggestion)
        XCTAssertEqual(card.suggestionID, 4)
        XCTAssertEqual(card.body, "You keep telling agents: \u{201C}Run the tests first\u{201D} — add to your instructions?")
    }

    // MARK: - Agents waiting

    func testAsksAcrossAllWorkbenches() throws {
        var data = HomeTodayData()
        data.asks = try homeAsks([("acme", "Review the spec", "review", true), ("beta", "Which way?", "question", false)])
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.kind, .agentsWaiting)
        XCTAssertEqual(card.eyebrow, "AGENTS WAITING · 2")
        XCTAssertEqual(card.link, .workbenches)
        XCTAssertEqual(card.items.map(\.chip), ["Review", "Question"])
        XCTAssertEqual(card.items.map(\.detail), ["acme", "beta"])
        let expected = data.asks.rows.map {
            HomeLink.workbench(.forAsk(projectID: $0.ask.projectID, sessionID: $0.ask.sessionID, askID: $0.ask.id))
        }
        XCTAssertEqual(card.items.map(\.link), expected)
        XCTAssertNotNil(data.asks.rows[0].ask.sessionID)
    }

    func testAgentsWaitingShowsThreeOldestAndCountsAll() throws {
        var data = HomeTodayData()
        data.asks = try homeAsks((0..<4).map { ("acme", "Ask \($0)", "check", false) })
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "AGENTS WAITING · 4")
        XCTAssertEqual(card.items.map(\.title), ["Ask 0", "Ask 1", "Ask 2"])
    }

    // MARK: - Briefing

    func testBriefingSummaryIsFirstItemOfFirstNonEmptySection() throws {
        let filled = briefing(attention: "[]", yourDay: #"[{"text":"Standup at 10"}]"#)
        XCTAssertEqual(HomeTodayBuilder.briefingSummary(filled), "Standup at 10")
        var data = HomeTodayData()
        data.briefing = filled
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "BRIEFING")
        XCTAssertEqual(card.body, "Standup at 10")
        XCTAssertEqual(card.link, .briefing(id: 7))

        let empty = briefing()
        XCTAssertNil(HomeTodayBuilder.briefingSummary(empty))
        data.briefing = empty
        XCTAssertTrue(cards(data).isEmpty)
    }

    // MARK: - Since you were away

    func testRecapCardNeedsReadyUnacknowledged() throws {
        let from = try todayAt(hour: 18, minute: 30, days: -1)
        var data = HomeTodayData()
        data.pendingRecap = recap(status: "building", from: from)
        XCTAssertTrue(cards(data).isEmpty)
        data.pendingRecap = recap(acknowledged: true, from: from)
        XCTAssertTrue(cards(data).isEmpty)
        data.pendingRecap = recap(from: from)
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "SINCE YOU WERE AWAY · SINCE " + format("EEE", from).uppercased() + " 18:30")
        XCTAssertEqual(card.body, "Two threads need you")
        XCTAssertEqual(card.link, .catchUp)
    }

    // MARK: - Snapshot

    private func todaySnapshot(
        _ zone: GettingReadyZone,
        today: [TodayCard] = [],
        failed: Bool = false,
        failedKinds: Set<TodayCardKind> = []
    ) -> HomeSnapshot {
        HomeSnapshot(gettingReady: zone, firstSync: nil, today: today, todayReadFailed: failed,
                     todayFailed: failedKinds,
                     feed: HomeFeedBuilder.feed(HomeFeedData(), now: now, calendar: calendar, expanded: false, hidden: []))
    }

    func testEmptyDataIsNothingNeedsYou() {
        let today = cards(HomeTodayData())
        XCTAssertTrue(today.isEmpty)
        XCTAssertTrue(todaySnapshot(.hidden, today: today).nothingNeedsYou)
    }

    func testAllReadyZoneStillNothingNeedsYou() {
        XCTAssertTrue(todaySnapshot(.allReady).nothingNeedsYou)
    }

    func testShownZoneIsNotNothingNeedsYou() {
        XCTAssertFalse(todaySnapshot(.shown(cards: [], sourceRows: [])).nothingNeedsYou)
    }

    func testFailedReadIsNotNothingNeedsYou() {
        let all = todaySnapshot(.hidden, failed: true, failedKinds: Set(TodayCardKind.allCases))
        XCTAssertFalse(all.nothingNeedsYou)
        XCTAssertTrue(all.showsReadError)
    }

    /// Review Focus 3: one failed card read with every other card empty is
    /// the read error, never the all-clear.
    func testOneFailedReadIsNotNothingNeedsYou() {
        var data = HomeTodayData()
        data.failed = [.briefing]
        let today = cards(data)
        XCTAssertTrue(today.isEmpty)
        let partial = todaySnapshot(.hidden, today: today, failedKinds: [.briefing])
        XCTAssertFalse(partial.todayReadFailed)
        XCTAssertFalse(partial.nothingNeedsYou)
        XCTAssertTrue(partial.showsReadError)
    }

    func testFailedReadBesideACardIsNoReadError() {
        var data = HomeTodayData()
        data.suggestion = HomeInstructionSuggestion(id: 4, text: "Run the tests first")
        let partial = todaySnapshot(.hidden, today: cards(data), failedKinds: [.briefing])
        XCTAssertFalse(partial.nothingNeedsYou)
        XCTAssertFalse(partial.showsReadError)
    }
}

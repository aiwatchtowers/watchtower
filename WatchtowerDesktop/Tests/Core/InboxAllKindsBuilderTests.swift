import XCTest
import GRDB
@testable import WatchtowerCore

/// The all-kinds Inbox list: filters, the pinned day card, unread-only
/// tracks and earlier days in All, ideas awaiting a verdict, decisions as
/// informational cards.
final class InboxAllKindsBuilderTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }

    private let today = "2026-10-22"

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(AutomationDates.parse(text))
    }

    private func now() throws -> Date { try date("2026-10-22T08:00:00Z") } // 10:00 Berlin

    private func output(_ id: Int64, at text: String) throws -> AutomationOutputCard {
        AutomationOutputCard(id: id, automationID: 1, automationName: "Triage", runID: 4, title: "Card \(id)",
                             body: "B", priority: "medium", createdAt: try date(text))
    }

    private func proposal(_ id: Int64) -> AgentAction {
        AgentAction(row: Row(["id": id, "tool": "create_target"]))
    }

    private func idea(_ id: Int, kind: String = "idea", status: String = "proposed", updated: String = "2026-10-20T10:00:00Z") -> Idea {
        Idea(row: Row(["id": id, "kind": kind, "status": status, "title": "Idea \(id)", "updated_at": updated]))
    }

    private func track(_ id: Int, unread: Bool) -> Track {
        Track(row: Row(["id": id, "text": "Track \(id)", "read_at": unread ? nil : "2026-10-20T10:00:00Z",
                        "has_updates": false] as [String: (any DatabaseValueConvertible)?]))
    }

    private func trackCard(_ id: Int, unread: Bool, at text: String = "2026-10-20T10:00:00Z") throws -> InboxTrackCard {
        InboxTrackCard(track: track(id, unread: unread), lastEventAt: try date(text), newEventCount: 0)
    }

    private func briefing(_ id: Int, day: String, read: Bool) throws -> Briefing {
        try Briefing(row: Row([
            "id": id, "user_id": "u", "date": day, "role": "", "attention": "[]", "your_day": "[]",
            "what_happened": "[]", "team_pulse": "[]", "coaching": "[]", "model": "", "input_tokens": 0,
            "output_tokens": 0, "cost_usd": 0.0, "prompt_version": 1,
            "read_at": read ? "2026-10-21T10:00:00Z" : nil, "created_at": "\(day)T05:00:00Z"
        ] as [String: (any DatabaseValueConvertible)?]))
    }

    private func dayCard(_ day: String, read: Bool, stamp: String) throws -> InboxDayCard {
        InboxDayCard(date: day, briefing: try briefing(1, day: day, read: read), plan: nil, planDone: 0, planTotal: 0,
                     stamp: try date(stamp))
    }

    private func message(_ id: Int, at text: String) throws -> HomeFeedInboxRow {
        let item = InboxItem(row: Row(["id": id, "snippet": "Msg \(id)"]))
        return HomeFeedInboxRow(item: item, stamp: try date(text), who: "A", whereText: nil)
    }

    private func build(_ feed: InboxFeedSnapshot, _ filter: InboxFilter = .all, dayDone: String? = nil) throws
        -> [InboxSection] {
        InboxListBuilder.sections(feed, filter: filter, dayDone: dayDone, today: today, now: try now(), calendar: berlin)
    }

    func testNeedsYourDecisionHoldsProposalsAndIdeasAwaitingAVerdict() throws {
        let feed = InboxFeedSnapshot(proposals: [proposal(1)], ideas: [idea(2), idea(3, status: "active")])
        let sections = try build(feed)
        XCTAssertEqual(sections.map(\.title), ["Needs your decision"])
        XCTAssertEqual(sections[0].items.map(\.id), [.proposal(1), .idea(2)])
    }

    func testDecisionsAreInformationalAndNeverAwaitAVerdict() throws {
        let decision = idea(4, kind: "decision", status: "proposed")
        XCTAssertFalse(decision.awaitsVerdict)
        let feed = InboxFeedSnapshot(ideas: [decision])
        XCTAssertEqual(try build(feed), [])
        let ideas = try build(feed, .ideas)
        XCTAssertEqual(ideas.map(\.title), ["Earlier"])
        XCTAssertEqual(ideas[0].items.map(\.id), [.idea(4)])
    }

    func testIdeasFilterListsAwaitingFirstThenTheRegistryByUpdate() throws {
        let feed = InboxFeedSnapshot(ideas: [idea(1, status: "active", updated: "2026-10-18T10:00:00Z"),
                                             idea(2), idea(3, status: "active", updated: "2026-10-21T10:00:00Z")])
        let sections = try build(feed, .ideas)
        XCTAssertEqual(sections.map(\.title), ["Needs your decision", "Earlier"])
        XCTAssertEqual(sections[0].items.map(\.id), [.idea(2)])
        XCTAssertEqual(sections[1].items.map(\.id), [.idea(3), .idea(1)])
    }

    func testProposalsShowInAllAndAutomationsOnly() throws {
        let feed = InboxFeedSnapshot(proposals: [proposal(1)])
        for filter in InboxFilter.allCases {
            let shown = try build(feed, filter).flatMap(\.items).map(\.id)
            XCTAssertEqual(shown, filter == .all || filter == .automations ? [.proposal(1)] : [], "\(filter)")
        }
    }

    func testTodaysDayCardIsPinnedFirstUntilDone() throws {
        let feed = InboxFeedSnapshot(outputs: [try output(5, at: "2026-10-22T07:00:00Z")],
                                     days: [try dayCard(today, read: true, stamp: "2026-10-22T05:00:00Z")])
        // Stamp 07:00 Berlin, output 09:00 Berlin: pinned puts the day first, done sorts by time.
        let pinned = try build(feed).flatMap(\.items).map(\.id)
        XCTAssertEqual(pinned, [.day(today), .output(5)])
        let done = try build(feed, dayDone: today).flatMap(\.items).map(\.id)
        XCTAssertEqual(done, [.output(5), .day(today)])
    }

    func testEarlierDayCardsInAllOnlyWhileUnread() throws {
        let read = InboxDayCard(date: "2026-10-20", briefing: try briefing(1, day: "2026-10-20", read: true), plan: nil,
                                planDone: 0, planTotal: 0, stamp: try date("2026-10-20T05:00:00Z"))
        let unread = InboxDayCard(date: "2026-10-21", briefing: try briefing(2, day: "2026-10-21", read: false), plan: nil,
                                  planDone: 0, planTotal: 0, stamp: try date("2026-10-21T05:00:00Z"))
        let feed = InboxFeedSnapshot(days: [read, unread])
        XCTAssertEqual(try build(feed).flatMap(\.items).map(\.id), [.day("2026-10-21")])
        XCTAssertEqual(try build(feed, .day).flatMap(\.items).map(\.id), [.day("2026-10-21"), .day("2026-10-20")])
    }

    func testAllShowsOnlyUnreadTracks() throws {
        let read = try (0..<300).map { try trackCard($0, unread: false) }
        let unread = try [trackCard(1000, unread: true), trackCard(1001, unread: true)]
        let feed = InboxFeedSnapshot(tracks: read + unread)
        XCTAssertEqual(try build(feed).flatMap(\.items).count, 2)
        XCTAssertEqual(try build(feed, .tracks).flatMap(\.items).count, 302)
    }

    func testTrackSortsByItsLastEvent() throws {
        let feed = InboxFeedSnapshot(outputs: [try output(5, at: "2026-10-22T07:00:00Z")],
                                     tracks: [try trackCard(9, unread: true, at: "2026-10-22T07:30:00Z")])
        let today = try XCTUnwrap(try build(feed).first { $0.title == "Today" })
        XCTAssertEqual(today.items.map(\.id), [.track(9), .output(5)])
    }

    func testMessagesSortByTheirOwnTime() throws {
        let feed = InboxFeedSnapshot(outputs: [try output(5, at: "2026-10-22T06:00:00Z")],
                                     messages: [try message(1, at: "2026-10-22T05:00:00Z"),
                                                try message(2, at: "2026-10-22T07:00:00Z")])
        XCTAssertEqual(try build(feed).flatMap(\.items).map(\.id), [.message(2), .output(5), .message(1)])
    }

    func testFilterShowsOnlyItsKind() throws {
        let feed = InboxFeedSnapshot(
            proposals: [proposal(1)],
            reminders: [Reminder(row: Row(["id": Int64(2), "remind_at": "2026-10-22T07:00:00Z", "note": "Ping"]))],
            outputs: [try output(3, at: "2026-10-22T07:00:00Z")],
            days: [try dayCard(today, read: false, stamp: "2026-10-22T05:00:00Z")],
            tracks: [try trackCard(4, unread: true)], ideas: [idea(5, status: "active")],
            messages: [try message(6, at: "2026-10-22T07:00:00Z")]
        )
        let expected: [InboxFilter: [InboxSelection]] = [
            .day: [.day(today)], .messages: [.message(6)], .tracks: [.track(4)], .ideas: [.idea(5)],
            .automations: [.proposal(1), .output(3), .reminder(2)]
        ]
        for (filter, ids) in expected {
            XCTAssertEqual(Set(try build(feed, filter).flatMap(\.items).map(\.id)), Set(ids), "\(filter)")
        }
        XCTAssertEqual(try build(feed).flatMap(\.items).count, 6) // everything but the active idea
    }

    func testFilterTitlesAndEmptyKeys() {
        XCTAssertEqual(InboxFilter.allCases.map(\.title), ["All", "Day", "Messages", "Tracks", "Ideas", "Automations"])
        XCTAssertEqual(InboxFilter.allCases.map(\.emptyCopyKey),
                       ["inbox", "briefings", "inboxMessages", "tracks", "ideas", "inboxAutomations"])
    }

    func testSelectionAfterWorksAcrossKinds() throws {
        let feed = InboxFeedSnapshot(tracks: [try trackCard(9, unread: true, at: "2026-10-22T07:30:00Z")],
                                     messages: [try message(1, at: "2026-10-22T07:00:00Z")])
        let sections = try build(feed)
        XCTAssertEqual(InboxListBuilder.selection(after: .track(9), in: sections), .message(1))
    }
}

import XCTest
import GRDB
@testable import WatchtowerCore

/// The root's day cards and the legacy entries' lists (inbox builder B):
/// today's card and its placeholder, unread earlier days, ideas awaiting a
/// verdict, decisions as informational cards, Track my threads' Stopped
/// fold; each list shows only its own kind.
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

    private func build(_ feed: InboxFeedSnapshot, _ list: InboxLegacyList, showsStopped: Bool = false) throws
        -> [InboxSection] {
        InboxListBuilder.sections(feed, list: list, now: try now(), calendar: berlin, showsStopped: showsStopped)
    }

    private func rootDays(_ feed: InboxFeedSnapshot) throws -> [InboxDayCard] {
        InboxListBuilder.rootDays(feed, today: today, now: try now(), calendar: berlin)
    }

    // MARK: - Today's placeholder (T11b, G4)

    func testTodayWithNothingStillHasItsDayCard() throws {
        let days = try rootDays(InboxFeedSnapshot())
        XCTAssertEqual(days.map(\.date), [today])
        XCTAssertTrue(days[0].isEmpty)
        XCTAssertFalse(days[0].isUnread, "the placeholder is never unread, so never in the badge")
        XCTAssertEqual(days[0].stamp, berlin.startOfDay(for: try now()))
        for list in InboxLegacyList.allCases {
            XCTAssertEqual(try build(InboxFeedSnapshot(), list), [], "\(list)")
        }
        var noOwner = InboxFeedSnapshot()
        noOwner.ownerKnown = false
        XCTAssertEqual(try rootDays(noOwner), [], "no owner: the root stays empty and says why")
        var bothOff = InboxFeedSnapshot()
        bothOff.briefingOn = false
        bothOff.dayPlanOn = false
        XCTAssertEqual(try rootDays(bothOff), [], "both features off: no placeholder")
    }

    func testThePlaceholderIsOnlyForTodayAndOnlyWhenItHasNoCard() throws {
        let real = try dayCard(today, read: true, stamp: "2026-10-22T05:00:00Z")
        XCTAssertEqual(try rootDays(InboxFeedSnapshot(days: [real])), [real])

        let past = try dayCard("2026-10-21", read: false, stamp: "2026-10-21T05:00:00Z")
        let days = try rootDays(InboxFeedSnapshot(days: [past]))
        XCTAssertEqual(days.map(\.date), [today], "a past date never gets a placeholder, nor a row")
        XCTAssertTrue(days[0].isEmpty)
    }

    /// One brief row: the root lists today's day only, an unread past day
    /// included (the Earlier line counts it).
    func testRootDaysAreTodayOnly() throws {
        let read = InboxDayCard(date: "2026-10-20", briefing: try briefing(1, day: "2026-10-20", read: true), plan: nil,
                                planDone: 0, planTotal: 0, stamp: try date("2026-10-20T05:00:00Z"))
        let unread = InboxDayCard(date: "2026-10-21", briefing: try briefing(2, day: "2026-10-21", read: false), plan: nil,
                                  planDone: 0, planTotal: 0, stamp: try date("2026-10-21T05:00:00Z"))
        let todays = try dayCard(today, read: true, stamp: "2026-10-22T05:00:00Z")
        let feed = InboxFeedSnapshot(days: [todays, read, unread])
        XCTAssertEqual(try rootDays(feed).map(\.date), [today])
    }

    // MARK: - The legacy lists

    func testDecisionsAreInformationalAndNeverAwaitAVerdict() throws {
        let decision = idea(4, kind: "decision", status: "proposed")
        XCTAssertFalse(decision.awaitsVerdict)
        let ideas = try build(InboxFeedSnapshot(ideas: [decision]), .ideas)
        XCTAssertEqual(ideas.map(\.title), ["Earlier"])
        XCTAssertEqual(ideas[0].items.map(\.id), [.idea(4)])
    }

    func testIdeaFinderListsAwaitingFirstThenTheRegistryByUpdate() throws {
        let feed = InboxFeedSnapshot(ideas: [idea(1, status: "active", updated: "2026-10-18T10:00:00Z"),
                                             idea(2), idea(3, status: "active", updated: "2026-10-21T10:00:00Z")])
        let sections = try build(feed, .ideas)
        XCTAssertEqual(sections.map(\.title), ["Needs your decision", "Earlier"])
        XCTAssertEqual(sections[0].items.map(\.id), [.idea(2)])
        XCTAssertEqual(sections[1].items.map(\.id), [.idea(3), .idea(1)])
    }

    /// Track my threads lists every open track, read or not.
    func testTrackMyThreadsListsEveryTrack() throws {
        let read = try (0..<300).map { try trackCard($0, unread: false) }
        let unread = try [trackCard(1000, unread: true), trackCard(1001, unread: true)]
        XCTAssertEqual(try build(InboxFeedSnapshot(tracks: read + unread), .tracks).flatMap(\.items).count, 302)
    }

    /// Stopped tracks sit only in Track my threads' `Stopped · N` fold,
    /// closed by default; no other list shows them, unread or not.
    func testTrackMyThreadsFoldsStoppedTracks() throws {
        let stopped = try [trackCard(7, unread: true), trackCard(8, unread: false)]
        let feed = InboxFeedSnapshot(tracks: [try trackCard(1, unread: true)], stoppedTracks: stopped)

        let folded = try build(feed, .tracks)
        let fold = try XCTUnwrap(folded.last)
        XCTAssertEqual(fold.title, "Stopped · 2")
        XCTAssertTrue(fold.foldable)
        XCTAssertTrue(fold.items.isEmpty)
        XCTAssertEqual(folded.flatMap(\.items).map(\.id), [.track(1)])

        let open = try build(feed, .tracks, showsStopped: true)
        XCTAssertEqual(open.last?.items.map(\.id), [.track(7), .track(8)])
        XCTAssertEqual(open.dropLast().flatMap(\.items).map(\.id), [.track(1)])

        for list in InboxLegacyList.allCases where list != .tracks {
            let sections = try build(feed, list, showsStopped: true)
            XCTAssertFalse(sections.contains(where: \.foldable), "\(list)")
            XCTAssertFalse(sections.flatMap(\.items).contains { [.track(7), .track(8)].contains($0.id) }, "\(list)")
        }
        // No stopped track, no fold.
        XCTAssertFalse(try build(InboxFeedSnapshot(tracks: feed.tracks), .tracks).contains(where: \.foldable))
    }

    func testMessagesSortByTheirOwnTime() throws {
        let feed = InboxFeedSnapshot(messages: [try message(1, at: "2026-10-22T05:00:00Z"),
                                                try message(2, at: "2026-10-22T07:00:00Z")])
        XCTAssertEqual(try build(feed, .messages).flatMap(\.items).map(\.id), [.message(2), .message(1)])
    }

    /// Each list shows only its own kind; proposals, reminders, automation
    /// cards, days and built-in notices are in none (Needs approval and the
    /// folders draw them).
    func testEachListShowsOnlyItsKind() throws {
        var feed = InboxFeedSnapshot(
            proposals: [proposal(1)],
            reminders: [Reminder(row: Row(["id": Int64(2), "remind_at": "2026-10-22T07:00:00Z", "note": "Ping"]))],
            outputs: [try output(3, at: "2026-10-22T07:00:00Z")],
            days: [try dayCard(today, read: false, stamp: "2026-10-22T05:00:00Z")],
            tracks: [try trackCard(4, unread: true)], ideas: [idea(5, status: "active")],
            messages: [try message(6, at: "2026-10-22T07:00:00Z")]
        )
        feed.builtinNotices = [BuiltinUpgradeNotice(builtinID: "morning-brief", error: "config unreadable",
                                                    updatedAt: .distantPast)]
        let expected: [InboxLegacyList: [InboxSelection]] = [
            .messages: [.message(6)], .tracks: [.track(4)], .ideas: [.idea(5)]
        ]
        for (list, ids) in expected {
            XCTAssertEqual(try build(feed, list).flatMap(\.items).map(\.id), ids, "\(list)")
        }
    }

    func testListTitlesAndEmptyKeys() {
        XCTAssertEqual(InboxLegacyList.allCases.map(\.title), ["Track my threads", "Idea finder", "Messages"])
        XCTAssertEqual(InboxLegacyList.allCases.map(\.emptyCopyKey), ["tracks", "ideas", "inboxMessages"])
    }

    func testSelectionAfterWorksInAList() throws {
        let feed = InboxFeedSnapshot(messages: [try message(1, at: "2026-10-22T07:00:00Z"),
                                                try message(2, at: "2026-10-21T07:00:00Z")])
        let sections = try build(feed, .messages)
        XCTAssertEqual(InboxListBuilder.selection(after: .message(1), in: sections), .message(2))
    }
}

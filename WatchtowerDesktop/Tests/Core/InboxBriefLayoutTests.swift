import GRDB
import XCTest
@testable import WatchtowerCore

/// What the Morning brief's pane puts where (the mockup's order): the lead,
/// Start here, Waiting on you and Moved overnight.
final class InboxBriefLayoutTests: XCTestCase {
    private func briefing(attention: [String] = [], yourDay: [String] = []) throws -> Briefing {
        func json(_ texts: [String]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: texts.map { ["text": $0] })
            return try XCTUnwrap(String(bytes: data, encoding: .utf8))
        }
        return try Briefing(row: Row([
            "id": 1, "user_id": "u", "date": "2026-11-11", "role": "", "attention": try json(attention),
            "your_day": try json(yourDay), "what_happened": "[]", "team_pulse": "[]", "coaching": "[]",
            "model": "", "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "prompt_version": 1,
            "read_at": nil, "created_at": "2026-11-11T06:02:00Z"
        ] as [String: (any DatabaseValueConvertible)?]))
    }

    private func message(_ id: Int, minutesAgo: Double) -> HomeFeedInboxRow {
        let item = InboxItem(row: Row(["id": id, "snippet": "Message \(id)"]
            as [String: (any DatabaseValueConvertible)?]))
        return HomeFeedInboxRow(item: item, stamp: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                                who: "Colleague \(id)", whereText: "#acme")
    }

    private func track(_ id: Int, minutesAgo: Double, newEvents: Int) -> InboxTrackCard {
        let track = Track(row: Row(["id": id, "text": "Track \(id)", "read_at": "2026-11-10T10:00:00Z"]
            as [String: (any DatabaseValueConvertible)?]))
        return InboxTrackCard(track: track, lastEventAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                              newEventCount: newEvents)
    }

    func testLeadFallsBackToYourDay() throws {
        XCTAssertEqual(InboxBriefLayout.lead(try briefing(attention: ["Review ACME-12"], yourDay: ["Standup"])),
                       "Review ACME-12")
        XCTAssertEqual(InboxBriefLayout.lead(try briefing(yourDay: ["Standup", "Design sync"])), "Standup")
    }

    func testLeadNilWhenEmpty() throws {
        XCTAssertNil(InboxBriefLayout.lead(try briefing()))
    }

    func testStartHereIsTopThree() throws {
        let four = try briefing(attention: ["One", "Two", "Three", "Four"])
        XCTAssertEqual(InboxBriefLayout.startHere(four).map(\.text), ["One", "Two", "Three"])
        XCTAssertEqual(InboxBriefLayout.startHere(try briefing(attention: ["One"])).map(\.text), ["One"])
        XCTAssertEqual(InboxBriefLayout.startHere(try briefing()).count, 0)
    }

    func testWaitingOnYouTopThreeNewest() {
        let rows = [message(1, minutesAgo: 30), message(2, minutesAgo: 5), message(3, minutesAgo: 90),
                    message(4, minutesAgo: 10)]
        XCTAssertEqual(InboxBriefLayout.waitingOnYou(rows).map(\.item.id), [2, 4, 1])
        XCTAssertEqual(InboxBriefLayout.waitingOnYou([]).count, 0)
    }

    func testMovedOvernightUnreadOnly() {
        let tracks = [track(1, minutesAgo: 60, newEvents: 1), track(2, minutesAgo: 5, newEvents: 0),
                      track(3, minutesAgo: 10, newEvents: 2), track(4, minutesAgo: 120, newEvents: 1),
                      track(5, minutesAgo: 1, newEvents: 3)]
        XCTAssertEqual(InboxBriefLayout.movedOvernight(tracks).map(\.track.id), [5, 3, 1],
                       "unread only, newest event first, at most three")
        XCTAssertEqual(InboxBriefLayout.movedOvernight([track(2, minutesAgo: 5, newEvents: 0)]).count, 0)
    }
}

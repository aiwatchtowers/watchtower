import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Chats list (iPhone chat spec §6.2, mockup 1a): sections, dot precedence, the older fold and the title filter.
final class ChatListModelTests: XCTestCase {
    private typealias Fixture = ChatFixture
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    func testPinnedThenRecentThenOlderFolded() {
        let list = ChatList(conversations: [
            Fixture.conversation(1, "Release checklist", ago: 120, state: .waiting, pinned: true),
            Fixture.conversation(2, "Old but pinned", ago: 30 * 86_400, pinned: true),
            Fixture.conversation(3, "Q3 roadmap summary", ago: 10, state: .answering),
            Fixture.conversation(4, "Meeting prep", ago: 6.9 * 86_400),
            Fixture.conversation(5, "Vendor contracts", ago: 7.1 * 86_400),
            Fixture.conversation(6, "Budget", ago: 40 * 86_400)
        ])
        let model = ChatListModel(list: list, now: Fixture.now, calendar: calendar)
        XCTAssertEqual(model.sections.map(\.title), ["Pinned", "Recent"])
        XCTAssertEqual(model.sections[0].rows.map(\.id), [1, 2], "pinned stays pinned whatever its age")
        XCTAssertEqual(model.sections[1].rows.map(\.id), [3, 4], "the last 7 days")
        XCTAssertEqual(model.older.map(\.id), [5, 6])
        XCTAssertEqual(model.olderLabel, "2 older")
        XCTAssertEqual(model.rowCount, 6)
    }

    func testEmptySectionsAreLeftOutAndNoFoldWithoutOlderChats() {
        let model = ChatListModel(list: ChatList(conversations: [Fixture.conversation(1)]), now: Fixture.now)
        XCTAssertEqual(model.sections.map(\.title), ["Recent"])
        XCTAssertNil(model.olderLabel)
    }

    func testDotsFollowTheMacsPrecedenceAndOnlyWaitingIsOrange() {
        let rows = [ChatList.State.waiting, .answering, .unread, .read, ChatList.State(rawValue: "newer")].enumerated().map {
            ChatListModel.row(Fixture.conversation(Int64($0.offset), state: $0.element), now: Fixture.now, calendar: calendar)
        }
        XCTAssertEqual(rows.map(\.tone), [.orange, .blue, .primary, .secondary, .secondary])
        XCTAssertEqual(rows.map(\.isRing), [false, false, false, true, true])
        XCTAssertEqual(rows.map(\.isWaiting), [true, false, false, false, false])
        XCTAssertEqual(rows.filter { $0.tone == .orange }.map(\.toneUse.role), [.waiting])
    }

    func testTheSecondLineIsTheStateOrTheProjectAndLastLine() {
        func row(_ state: ChatList.State, project: String? = nil, last: String = "") -> ChatListModel.Row {
            ChatListModel.row(
                Fixture.conversation(1, state: state, project: project, lastLine: last), now: Fixture.now, calendar: calendar
            )
        }
        let waiting = row(.waiting, project: "acme-platform", last: "x")
        XCTAssertEqual(waiting.detail, "Waiting for your approval")
        XCTAssertNil(waiting.project, "a state line is the state alone")
        XCTAssertEqual(row(.answering, last: "x").detail, "Answering…")
        let unread = row(.unread, project: "acme-platform", last: "Colleague B leads it")
        XCTAssertEqual(unread.project, "acme-platform")
        XCTAssertEqual(unread.detail, "New answer")
        let read = row(.read, last: "Email draft ready")
        XCTAssertEqual(read.detail, "Email draft ready")
        XCTAssertNil(read.project)
        XCTAssertEqual(row(.read, project: "acme-platform").spokenLabel, "Chat, project acme-platform, 1m")
    }

    func testTheTitleFilterKeepsMatchingTitlesUnderTitlesWithNothingFolded() {
        let list = ChatList(conversations: [
            Fixture.conversation(1, "Who owns the billing API?"),
            Fixture.conversation(2, "Q3 roadmap"),
            Fixture.conversation(3, "Billing v1 notes", ago: 60 * 86_400),
            Fixture.conversation(4, "Pinned billing", pinned: true)
        ])
        let model = ChatListModel(list: list, now: Fixture.now, query: " BILLING ")
        XCTAssertEqual(model.sections.map(\.title), ["Titles"])
        XCTAssertEqual(model.sections[0].rows.map(\.id), [1, 3, 4], "the held order, older ones included")
        XCTAssertTrue(model.older.isEmpty)
        XCTAssertTrue(ChatListModel(list: list, now: Fixture.now, query: "zzz").sections.isEmpty)
    }

    func testHiddenRowsAreLeftOut() {
        let list = ChatList(conversations: [Fixture.conversation(1), Fixture.conversation(2)])
        let model = ChatListModel(list: list, now: Fixture.now, hidden: [1])
        XCTAssertEqual(model.sections.flatMap(\.rows).map(\.id), [2])
    }

    func testAges() {
        let now = Fixture.now
        func age(_ seconds: TimeInterval) -> String { ChatAge.label(now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        XCTAssertEqual(age(5), "now")
        XCTAssertEqual(age(-30), "now", "a stamp ahead of the phone's clock")
        XCTAssertEqual(age(14 * 60), "14m")
        XCTAssertEqual(age(3 * 3_600), "3h")
        // 1_800_000_000 is Friday 2027-01-15 08:00 UTC.
        XCTAssertEqual(age(4 * 86_400), "Mon")
        XCTAssertEqual(age(10 * 86_400), "Jan 5")
        XCTAssertEqual(age(120 * 86_400), "Sep 17, 2026")
    }
}

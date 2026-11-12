import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

/// Slack today's reading pane (inbox redesign phase 5): its header from the
/// state, Mark All Seen at the drawn version, yesterday's note and the
/// folded line of channels with nothing for the owner.
@MainActor
final class SlackTodayPaneTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }

    private func card(read: Bool, written: String = "2026-10-22T10:20:00Z") throws -> AutomationOutputCard {
        AutomationOutputCard(
            id: 7, automationID: 9, automationName: "Slack today", runID: 3, title: "Slack today", body: "",
            priority: "medium", createdAt: try date(written), readAt: read ? try date(written) : nil,
            outputKey: "slack-today", contentHash: "h1", writtenAt: try date(written), changedAt: try date(written))
    }

    private func summary(day: String = "2026-10-22") throws -> SlackTodaySummary {
        try XCTUnwrap(SlackTodaySummary.decode(stateJSON: #"{"today":{"v":1,"day":"\#(day)","messages":900,"#
            + #""missed_yesterday":0,"channels":{"#
            + #""C1":{"name":"acme-release","n":23,"more":2,"link":"https://example.com/r"},"#
            + #""C2":{"name":"acme-random","n":800},"#
            + #""C3":{"name":"@Colleague A","n":1}},"#
            + #""quiet_rest":{"channels":40,"messages":19},"more_rest":{"channels":0,"lines":0}}}"#))
    }

    private func pane(
        card: AutomationOutputCard,
        summary: SlackTodaySummary?,
        now: String = "2026-10-22T10:30:00Z",
        quietShown: Bool = false,
        onMarkAllSeen: @escaping () -> Void = {}
    ) throws -> SlackTodayPane {
        SlackTodayPane(card: card, summary: summary, now: try date(now), calendar: Self.utc, menu: nil,
                       onMarkAllSeen: onMarkAllSeen, onReactionCommands: nil, quietShown: quietShown)
    }

    func testHeaderAndMarkAllSeen() throws {
        var pressed = 0
        let sut = try pane(card: card(read: false), summary: summary()) { pressed += 1 }
        XCTAssertNoThrow(try sut.inspect().find(text: "Slack today"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Today · 900 messages in 43 channels · 1 with news for you"))
        let button = try sut.inspect().find(button: "Mark All Seen")
        XCTAssertFalse(button.isDisabled())
        try button.tap()
        XCTAssertEqual(pressed, 1)
        XCTAssertThrowsError(try sut.inspect().find(text: SlackTodayPaneText.staleNoteText))

        let seen = try pane(card: card(read: true), summary: summary())
        XCTAssertTrue(try seen.inspect().find(button: "Mark All Seen").isDisabled(),
                      "the drawn version is already seen")
    }

    func testStaleDayShowsYesterdayNote() throws {
        let sut = try pane(card: card(read: true, written: "2026-10-22T21:00:00Z"), summary: summary(),
                           now: "2026-10-23T07:00:00Z")
        XCTAssertNoThrow(try sut.inspect().find(text: "Nothing yet today"))
        XCTAssertNoThrow(try sut.inspect().find(text: "This is yesterday's list. Today's starts after the next sync."))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "slackToday.quietLine"),
                             "the fold is today's only")
    }

    func testQuietChannelsFold() throws {
        let folded = try pane(card: card(read: true), summary: summary())
        let line = try folded.inspect().find(viewWithAccessibilityIdentifier: "slackToday.quietLine")
        XCTAssertNoThrow(try line.find(text: "42 channels with nothing for you · 820 messages"))
        XCTAssertThrowsError(try folded.inspect().find(text: "#acme-random · 800 messages"), "folded by default")

        let open = try pane(card: card(read: true), summary: summary(), quietShown: true)
        XCTAssertNoThrow(try open.inspect().find(text: "#acme-random · 800 messages"))
        XCTAssertNoThrow(try open.inspect().find(text: "@Colleague A · 1 message"))
        XCTAssertNoThrow(try open.inspect().find(text: "and 40 more channels"))
        XCTAssertThrowsError(try open.inspect().find(text: "#acme-release · 23 messages"), "news is not quiet")

        let noQuiet = try XCTUnwrap(SlackTodaySummary.decode(stateJSON: #"{"today":{"v":1,"day":"2026-10-22","#
            + #""messages":2,"missed_yesterday":0,"channels":{"C1":{"name":"acme-ops","n":2,"more":1,"link":""}},"#
            + #""quiet_rest":{"channels":0,"messages":0},"more_rest":{"channels":0,"lines":0}}}"#))
        let none = try pane(card: card(read: true), summary: noQuiet)
        XCTAssertThrowsError(try none.inspect().find(viewWithAccessibilityIdentifier: "slackToday.quietLine"))
    }
}

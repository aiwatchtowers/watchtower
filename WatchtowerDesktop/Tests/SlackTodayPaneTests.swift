import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

/// Slack today's reading pane (inbox redesign phase 5): its header from the
/// state, Mark All Seen at the drawn version, yesterday's note and the
/// folded line of conversations with nothing for the owner.
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

    private func state(day: String = "2026-10-22") throws -> SlackTodayState {
        try Self.read(#"{"today":{"v":1,"day":"\#(day)","messages":900,"#
            + #""missed_earlier":0,"skipped_older":0,"channels":{"#
            + #""C1":{"name":"acme-release","n":23,"more":2,"link":"https://example.com/r"},"#
            + #""C2":{"name":"acme-random","n":800},"#
            + #""C3":{"name":"@Colleague A","n":1}},"#
            + #""quiet_rest":{"channels":40,"messages":19},"more_rest":{"channels":0,"lines":0}}}"#)
    }

    /// A state that must decode as read.
    private static func read(_ json: String) throws -> SlackTodayState {
        .read(try XCTUnwrap(SlackTodayState.decode(stateJSON: json).summary))
    }

    private func pane(
        card: AutomationOutputCard,
        state: SlackTodayState,
        now: String = "2026-10-22T10:30:00Z",
        quietShown: Bool = false,
        onMarkAllSeen: @escaping () -> Void = {}
    ) throws -> SlackTodayPane {
        SlackTodayPane(card: card, state: state, now: try date(now), calendar: Self.utc, menu: nil,
                       onMarkAllSeen: onMarkAllSeen, onReactionCommands: nil, quietShown: quietShown)
    }

    func testHeaderAndMarkAllSeen() throws {
        var pressed = 0
        let sut = try pane(card: card(read: false), state: state()) { pressed += 1 }
        XCTAssertNoThrow(try sut.inspect().find(text: "Slack today"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Today · 900 messages in 43 conversations · 1 with news for you"))
        let button = try sut.inspect().find(button: "Mark All Seen")
        XCTAssertFalse(button.isDisabled())
        try button.tap()
        XCTAssertEqual(pressed, 1)
        XCTAssertThrowsError(try sut.inspect().find(text: SlackTodayPaneText.staleNoteText))

        let seen = try pane(card: card(read: true), state: state())
        XCTAssertTrue(try seen.inspect().find(button: "Mark All Seen").isDisabled(),
                      "the drawn version is already seen")
    }

    func testStaleDayShowsYesterdayNote() throws {
        let sut = try pane(card: card(read: true, written: "2026-10-22T21:00:00Z"), state: state(),
                           now: "2026-10-23T07:00:00Z")
        XCTAssertNoThrow(try sut.inspect().find(text: "Nothing yet today"))
        XCTAssertNoThrow(try sut.inspect().find(text: "This is yesterday's list. Today's starts after the next sync."))
        XCTAssertThrowsError(try sut.inspect().find(viewWithAccessibilityIdentifier: "slackToday.quietLine"),
                             "the fold is today's only")
    }

    func testQuietChannelsFold() throws {
        let folded = try pane(card: card(read: true), state: state())
        let line = try folded.inspect().find(viewWithAccessibilityIdentifier: "slackToday.quietLine")
        XCTAssertNoThrow(try line.find(text: "42 conversations with nothing for you · 820 messages"))
        XCTAssertThrowsError(try folded.inspect().find(text: "#acme-random · 800 messages"), "folded by default")

        let open = try pane(card: card(read: true), state: state(), quietShown: true)
        XCTAssertNoThrow(try open.inspect().find(text: "#acme-random · 800 messages"))
        XCTAssertNoThrow(try open.inspect().find(text: "@Colleague A · 1 message"))
        XCTAssertNoThrow(try open.inspect().find(text: "and 40 more conversations"))
        XCTAssertThrowsError(try open.inspect().find(text: "#acme-release · 23 messages"), "news is not quiet")

        let noQuiet = try Self.read(#"{"today":{"v":1,"day":"2026-10-22","#
            + #""messages":2,"missed_earlier":0,"skipped_older":0,"channels":{"C1":{"name":"acme-ops","n":2,"more":1,"link":""}},"#
            + #""quiet_rest":{"channels":0,"messages":0},"more_rest":{"channels":0,"lines":0}}}"#)
        let none = try pane(card: card(read: true), state: noQuiet)
        XCTAssertThrowsError(try none.inspect().find(viewWithAccessibilityIdentifier: "slackToday.quietLine"))
    }

    /// A state this version cannot read: the header says so (never "Nothing
    /// yet today"), no fold; the card's date still decides the note.
    func testUnreadableStateSaysSo() throws {
        let today = try pane(card: card(read: false), state: .unreadable)
        XCTAssertNoThrow(try today.inspect().find(text: "Today's numbers can't be read"))
        XCTAssertThrowsError(try today.inspect().find(text: "Nothing yet today"))
        XCTAssertThrowsError(try today.inspect().find(viewWithAccessibilityIdentifier: "slackToday.quietLine"))
        XCTAssertThrowsError(try today.inspect().find(text: SlackTodayPaneText.staleNoteText))

        let yesterday = try pane(card: card(read: true, written: "2026-10-22T21:00:00Z"), state: .unreadable,
                                 now: "2026-10-23T07:00:00Z")
        XCTAssertNoThrow(try yesterday.inspect().find(text: "Today's numbers can't be read"))
        XCTAssertNoThrow(try yesterday.inspect().find(text: SlackTodayPaneText.staleNoteText))
    }

    /// The pane's header is the artifact header: Mark All Seen first, then
    /// Run Now (when the ⋯ offers it), the ⋯ and the `?`.
    func testHeaderIsTheArtifactHeader() throws {
        var commands: [InboxMenuCommand] = []
        let menu = InboxArtifactMenuState(
            entries: InboxArtifactMenuContent(offersRunNow: true).entries
        ) { commands.append($0) }
        let sut = SlackTodayPane(card: try card(read: false), state: try state(), now: try date("2026-10-22T10:30:00Z"),
                                 calendar: Self.utc, menu: menu, onMarkAllSeen: {}, onReactionCommands: {})
        let header = try sut.inspect().find(InboxArtifactPaneHeader.self)
        XCTAssertNoThrow(try header.find(viewWithAccessibilityIdentifier: "slackToday.markAllSeen"))
        try header.find(viewWithAccessibilityIdentifier: "inbox.paneHeader.runNow").button().tap()
        XCTAssertEqual(commands, [.runNow])
        XCTAssertNoThrow(try header.find(InboxArtifactMenuButton.self))
        XCTAssertNoThrow(try header.find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
    }
}

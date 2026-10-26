import SwiftUI
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The parts the redesign mockups (`docs/design/mobile/mockups.html`) add
/// to the design layer: inputs in, visible strings and tones out. An
/// extension, so `MOBILE_FILTER=DesignSystemTests` runs them.
extension DesignSystemTests {
    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    // MARK: - StateLine (mockups 3, 4, 8)

    /// A working session counts up in m:ss from `stateAt`, h:mm:ss past an
    /// hour; a waiting one shows its age; an unknown `stateAt` shows the
    /// caption alone; a future `stateAt` clamps to 0:00.
    func testTheStateLineTimer() {
        func line(_ seconds: TimeInterval?, waiting: Bool = false) -> StateLineModel {
            StateLineModel(
                glyph: waiting ? "hand.raised.fill" : nil, tone: waiting ? .waitingForYou : .green,
                caption: waiting ? "Needs approval" : "Working", isWaiting: waiting,
                stateAt: seconds.map { now.addingTimeInterval(-$0) }, now: now
            )
        }
        XCTAssertEqual(line(194).visibleText, "Working · 3:14")
        XCTAssertEqual(line(760).visibleText, "Working · 12:40")
        XCTAssertEqual(line(3_723).visibleText, "Working · 1:02:03")
        XCTAssertEqual(line(-30).visibleText, "Working · 0:00")
        XCTAssertEqual(line(nil).visibleText, "Working")
        XCTAssertEqual(line(70, waiting: true).visibleText, "Needs approval · 1m")
        XCTAssertTrue(line(70, waiting: true).isWaiting)
        XCTAssertEqual(line(70, waiting: true).toneUse.role, .session(isWaiting: true))
        XCTAssertEqual(line(194).toneUse, ToneUse(element: "state line", tone: .green, role: .session(isWaiting: false)))
    }

    /// Mockup 8: with the Mac not online the state is "as of" the last
    /// contact and the timer stops.
    func testTheStateLineIsAsOfTheLastContactWhenTheMacIsAway() {
        let model = StateLineModel(
            glyph: nil, tone: .green, caption: "Working", isWaiting: false,
            stateAt: now.addingTimeInterval(-3_000), now: now, asOf: now.addingTimeInterval(-720)
        )
        XCTAssertEqual(model.visibleText, "Working · as of 12 min ago")
    }

    func testLastSeenPhrases() {
        XCTAssertEqual(LastSeen.phrase(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(LastSeen.phrase(now.addingTimeInterval(-720), now: now), "12 min ago")
        XCTAssertEqual(LastSeen.phrase(now.addingTimeInterval(-3 * 3_600), now: now), "3 h ago")
        XCTAssertEqual(LastSeen.phrase(now.addingTimeInterval(-2 * 86_400), now: now), "2 d ago")
        XCTAssertEqual(LastSeen.phrase(now.addingTimeInterval(60), now: now), "just now")
    }

    // MARK: - MacStatusChip (mockups 1, 7)

    func testTheMacStatusChip() {
        let seen = now.addingTimeInterval(-720)
        let cases: [(String, MacChipState, String, PhoneTone)] = [
            ("MacBook Pro", .online, "MacBook Pro · online", .green),
            ("MacBook Pro", .asleep(lastSeen: seen), "MacBook Pro · asleep · last seen 12 min ago", .gray),
            ("MacBook Pro", .offline(lastSeen: seen), "MacBook Pro · offline · last seen 12 min ago", .secondary),
            ("MacBook Pro", .offline(lastSeen: nil), "MacBook Pro · offline", .secondary),
            ("", .online, "Mac · online", .green),
            ("MacBook Pro", .notLinked, "No Mac linked", .secondary)
        ]
        for (name, state, text, tone) in cases {
            let chip = MacStatusChipModel(macName: name, state: state, now: now)
            XCTAssertEqual(chip.text, text)
            XCTAssertEqual(chip.tone, tone, text)
            XCTAssertEqual(chip.toneUse.role, .mac)
            XCTAssertNotEqual(chip.tone, .orange, "the Mac chip is never orange")
        }
    }

    // MARK: - ChatBubble (mockups 3, 4, 8)

    /// The owner right on a solid accent bubble with white text (mockups 3,
    /// 4, 8 and the Desktop `UserMessageBubble`), the agent left with no
    /// bubble, Watchtower lines centred captions, a subagent on the rest
    /// fill.
    func testTheChatBubbleRoles() {
        XCTAssertEqual(ChatBubble.fill(.owner), .accentColor)
        XCTAssertEqual(ChatBubble.textColor(.owner), .white)
        XCTAssertEqual(ChatBubble.textColor(.agent), .primary)
        XCTAssertNil(ChatBubble.fill(.agent))
        XCTAssertNil(ChatBubble.fill(.watchtower))
        XCTAssertEqual(ChatBubble.fill(.subagent), Fill.rest)
        XCTAssertEqual(ChatBubble.alignment(.owner), .trailing)
        XCTAssertEqual(ChatBubble.alignment(.agent), .leading)
        XCTAssertEqual(ChatBubble.alignment(.watchtower), .center)
        XCTAssertEqual(ChatBubble.alignment(.subagent), .leading)
    }

    // MARK: - WorkchatComposerBar (mockups 3, 4, 8)

    func testTheComposerBarModes() {
        let empty = ComposerBarModel(text: "  ", mode: .message)
        XCTAssertEqual(empty.placeholder, "Message the session…")
        XCTAssertTrue(empty.isFieldEnabled)
        XCTAssertFalse(empty.canSend, "nothing to send")
        XCTAssertTrue(ComposerBarModel(text: "Ship it", mode: .message).canSend)
        XCTAssertFalse(ComposerBarModel(text: "Ship it", mode: .message, isSending: true).canSend)

        let above = ComposerBarModel(text: "", mode: .answerAbove)
        XCTAssertEqual(above.placeholder, "Answer the request above")
        XCTAssertFalse(above.isFieldEnabled)
        XCTAssertFalse(ComposerBarModel(text: "x", mode: .answerAbove).canSend)

        let off = ComposerBarModel(text: "x", mode: .unavailable("Typing is off in Settings"))
        XCTAssertEqual(off.placeholder, "Typing is off in Settings")
        XCTAssertFalse(off.isFieldEnabled)
        XCTAssertFalse(off.canSend)
    }

    // MARK: - Inline cards (mockup 4)

    func testTheInlinePermissionCard() {
        XCTAssertEqual(InlinePermissionCard.title(toolName: "Bash"), "Bash")
        XCTAssertEqual(InlinePermissionCard.title(toolName: ""), "Permission request")
        XCTAssertEqual(InlinePermissionCard.buttonTitles(allowBlocked: false), ["Allow once", "Deny"])
        XCTAssertEqual(InlinePermissionCard.buttonTitles(allowBlocked: true), ["Deny"], "a blocked allow leaves Deny only")
    }

    func testTheInlineAskCard() {
        XCTAssertEqual(InlineAskCard.header(askID: 110, kind: "question"), "Ask #110 · question")
        XCTAssertEqual(InlineAskCard.header(askID: 7, kind: ""), "Ask #7")
        XCTAssertEqual(InlineAskCard.recommendedLabel, "recommended")
    }

    // MARK: - BoardCard (mockup 5)

    /// The Desktop board card: number, priority chip with a dot (high red,
    /// low blue, medium gray: the phone's orange is waiting only), status
    /// chip in the status tone, a counter, a bar grey while partial and
    /// green when complete, and the live sessions.
    func testTheBoardCard() {
        let card = BoardCardModel(
            number: 1, title: "Billing export for acme", status: .inProgress, statusText: "In Progress",
            priority: .high, counter: "1/2", progress: 0.55, liveSessions: 1
        )
        XCTAssertEqual(card.numberText, "#1")
        XCTAssertEqual(card.glyph, "circle.dotted.circle")
        XCTAssertEqual(card.tone, .blue)
        XCTAssertEqual(card.chips, [PillItem(text: "High", tone: .red, dot: true), PillItem(text: "In Progress", tone: .blue)])
        XCTAssertEqual(card.counter, "1/2")
        XCTAssertEqual(card.progressTone, .gray)
        XCTAssertEqual(card.sessionsText, "1 session")

        let medium = BoardCardModel(number: 343, title: "Session report", status: .todo, statusText: "To Do", priority: .medium, liveSessions: 2)
        XCTAssertEqual(medium.chips, [PillItem(text: "Medium", tone: .gray, dot: true), PillItem(text: "To Do", tone: .secondary)])
        let unknown = BoardCardModel(number: 9, title: "x", status: .todo, statusText: "To Do", priority: WorkbenchTargetPriority(rawValue: "newer"))
        XCTAssertEqual(unknown.chips, [PillItem(text: "To Do", tone: .secondary)], "a priority from a newer Mac draws no chip")
        XCTAssertEqual(medium.sessionsText, "2 sessions")
        XCTAssertNil(medium.progress)

        let complete = BoardCardModel(number: 2, title: "x", status: .done, statusText: "Done", priority: .low, progress: 1)
        XCTAssertEqual(complete.progressTone, .green)
        XCTAssertTrue(complete.isDone)
        XCTAssertNil(complete.sessionsText)
        XCTAssertEqual(complete.chips.first, PillItem(text: "Low", tone: .blue, dot: true))
        for use in card.toneUses + medium.toneUses + complete.toneUses {
            XCTAssertNotEqual(use.tone, .orange, use.element)
        }
    }

    // MARK: - CalendarRow (mockup 7)

    func testTheCalendarRow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 14, minute: 30)))
        func row(_ minutes: Int, at now: Date, isNext: Bool = false, location: String = "", recordings: Int = 0) -> CalendarRowModel {
            CalendarRowModel(
                start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), title: "Design critique",
                location: location, attendees: 4, recordings: recordings, isNext: isNext, now: now,
                calendar: calendar, locale: locale
            )
        }
        let next = row(30, at: start.addingTimeInterval(-25 * 60), isNext: true, location: "meet.example.com")
        XCTAssertEqual(next.timeText, "14:30")
        XCTAssertEqual(next.durationText, "30m")
        XCTAssertEqual(next.state, .next)
        XCTAssertEqual(next.detail, "in 25 min · meet.example.com")
        XCTAssertEqual(next.attendeesText, "4")

        let current = row(45, at: start.addingTimeInterval(60))
        XCTAssertEqual(current.state, .now)
        XCTAssertEqual(current.timeTone, .green)
        XCTAssertNil(current.detail)

        let past = row(60, at: start.addingTimeInterval(7_200), location: "Room 2", recordings: 1)
        XCTAssertEqual(past.state, .other)
        XCTAssertEqual(past.durationText, "1h")
        XCTAssertEqual(past.detail, "Room 2 · 1 rec")
        XCTAssertNil(past.timeTone)
        XCTAssertEqual(row(90, at: start).durationText, "1h 30m")

        XCTAssertEqual(CalendarRowModel.plate(.now), PhoneTone.green.color.opacity(Fill.selectedOpacity))
        XCTAssertEqual(CalendarRowModel.plate(.next), PhoneTone.accent.color.opacity(Fill.selectedOpacity))
        XCTAssertEqual(CalendarRowModel.plate(.other), Fill.rest)
    }

    // MARK: - Rows inside a card (mockups 1, 2, 9, 16)

    /// Rows grouped on one card are split by a hairline in the separator
    /// colour; rows outside a card have none.
    func testRowsInsideACardAreSplitByAHairline() {
        XCTAssertEqual(CardRowDivider.lineWidth, Stroke.hairline)
        XCTAssertEqual(CardRowDivider.color, Stroke.hairlineColor)
        XCTAssertEqual(CardRowDivider().inset, 0)
    }

    // MARK: - Bars and Settings (mockups 9–12, 16)

    /// The pair reads secondary then primary, like the mockup's Request
    /// changes · Approve.
    func testThePrimaryActionBarOrder() {
        XCTAssertEqual(PrimaryActionBar(primary: BarAction(title: "Send") {}).titles, ["Send"])
        XCTAssertEqual(
            PrimaryActionBar(primary: BarAction(title: "Approve") {}, secondary: BarAction(title: "Request changes") {}).titles,
            ["Request changes", "Approve"]
        )
    }

    /// Mockup 16's small switch: green on (`Tone.success`), the card fill off.
    func testTheSmallSwitchTrack() {
        XCTAssertEqual(SmallSwitchStyle.trackFill(isOn: true), PhoneTone.green.color)
        XCTAssertEqual(SmallSwitchStyle.trackFill(isOn: false), Fill.card)
    }
}

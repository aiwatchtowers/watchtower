import XCTest
import GRDB
@testable import WatchtowerCore

/// The Inbox list: proposals first, then today's and older automation cards
/// and due reminders, newest first, split on the given calendar's day.
final class InboxListBuilderTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(AutomationDates.parse(text))
    }

    private func output(_ id: Int64, at text: String) throws -> AutomationOutputCard {
        AutomationOutputCard(id: id, automationID: 1, automationName: "Triage", runID: 4, title: "Card \(id)",
                             body: "B", priority: "medium", createdAt: try date(text))
    }

    private func reminder(_ id: Int64, due: String) -> Reminder {
        Reminder(row: Row(["id": id, "remind_at": due, "note": "Ping"]))
    }

    private func proposal(_ id: Int64) -> AgentAction {
        AgentAction(row: Row(["id": id, "tool": "create_target"]))
    }

    func testSectionsAreProposalsTodayEarlier() throws {
        let now = try date("2026-10-21T15:00:00Z")
        let all = InboxListBuilder.sections(
            proposals: [proposal(1)], reminders: [],
            outputs: [try output(2, at: "2026-10-21T10:00:00Z"), try output(3, at: "2026-10-19T10:00:00Z")],
            now: now, calendar: utc
        )
        XCTAssertEqual(all.map(\.title), ["Needs your decision", "Today", "Earlier"])
        XCTAssertEqual(all.map { $0.items.map(\.id) }, [[.proposal(1)], [.output(2)], [.output(3)]])

        let noProposals = InboxListBuilder.sections(
            proposals: [], reminders: [], outputs: [try output(3, at: "2026-10-19T10:00:00Z")], now: now, calendar: utc
        )
        XCTAssertEqual(noProposals.map(\.title), ["Earlier"])
        XCTAssertEqual(InboxListBuilder.sections(proposals: [], reminders: [], outputs: [], now: now, calendar: utc),
                       [])
    }

    func testTodayMixesOutputsAndRemindersByTime() throws {
        let now = try date("2026-10-21T15:00:00Z")
        let sections = InboxListBuilder.sections(
            proposals: [],
            reminders: [reminder(7, due: "2026-10-21T11:00:00Z"), reminder(8, due: "2026-10-20T09:00:00Z")],
            outputs: [try output(2, at: "2026-10-21T10:00:00Z"), try output(3, at: "2026-10-20T12:00:00Z")],
            now: now, calendar: utc
        )
        XCTAssertEqual(sections.map(\.title), ["Today", "Earlier"])
        XCTAssertEqual(sections[0].items.map(\.id), [.reminder(7), .output(2)])
        XCTAssertEqual(sections[1].items.map(\.id), [.output(3), .reminder(8)])
    }

    /// Done or Dismiss on the selected row moves to the row below it, or to
    /// the one above when it was the last; nothing when it was alone.
    func testSelectionAfterMovesDownThenUp() throws {
        let now = try date("2026-10-21T15:00:00Z")
        let sections = InboxListBuilder.sections(
            proposals: [proposal(1)], reminders: [],
            outputs: [try output(2, at: "2026-10-21T10:00:00Z"), try output(3, at: "2026-10-19T10:00:00Z")],
            now: now, calendar: utc
        )
        XCTAssertEqual(InboxListBuilder.selection(after: .proposal(1), in: sections), .output(2))
        XCTAssertEqual(InboxListBuilder.selection(after: .output(2), in: sections), .output(3), "across sections")
        XCTAssertEqual(InboxListBuilder.selection(after: .output(3), in: sections), .output(2), "the last moves up")
        XCTAssertNil(InboxListBuilder.selection(after: .output(9), in: sections), "not listed")
        let alone = [InboxSection(title: "Today", items: [.output(try output(2, at: "2026-10-21T10:00:00Z"))])]
        XCTAssertNil(InboxListBuilder.selection(after: .output(2), in: alone))
    }

    func testCalendarDayBoundary() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        // 10:00 on Oct 21 in Tokyo; 14:59 UTC on Oct 20 is 23:59 on Oct 20 there.
        let now = try date("2026-10-21T01:00:00Z")
        let sections = InboxListBuilder.sections(
            proposals: [], reminders: [],
            outputs: [try output(2, at: "2026-10-20T15:00:00Z"), try output(3, at: "2026-10-20T14:59:00Z")],
            now: now, calendar: tokyo
        )
        XCTAssertEqual(sections.map(\.title), ["Today", "Earlier"])
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [[.output(2)], [.output(3)]])
    }
}

/// The card's words: the list preview, source lines, and the default texts of
/// Discuss in Chat and Hand to Agent.
final class InboxCardTextsTests: XCTestCase {
    private func card(
        title: String = "Two threads need you",
        body: String = "**Acme** asked twice.",
        link: String = ""
    ) -> AutomationOutputCard {
        AutomationOutputCard(id: 5, automationID: 1, automationName: "Mail summary", runID: 42, title: title,
                             body: body, priority: "medium",
                             createdAt: AutomationDates.parse("2026-10-21T10:00:00Z") ?? Date(), link: link)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    func testPreviewStripsMarkdown() {
        XCTAssertEqual(InboxCardTexts.preview("# Hi\n**bold** [x](https://example.com)"), "Hi bold x")
        XCTAssertEqual(InboxCardTexts.preview("- one\n- two\n\n`code`  here"), "one two code here")
        XCTAssertEqual(InboxCardTexts.preview(""), "")
    }

    func testPreviewClipsAt140() {
        let preview = InboxCardTexts.preview(String(repeating: "word ", count: 60))
        XCTAssertEqual(preview.count, 140)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertFalse(preview.contains("\n"))
        let short = String(repeating: "a", count: 140)
        XCTAssertEqual(InboxCardTexts.preview(short), short)
    }

    func testTargetTitleIsFirstLineClipped() {
        XCTAssertEqual(InboxCardTexts.targetTitle(fromTask: "\n  Fix the build  \nDetails follow"), "Fix the build")
        let long = String(repeating: "é", count: InboxCardTexts.targetTitleLimit + 20)
        let title = InboxCardTexts.targetTitle(fromTask: long)
        XCTAssertEqual(title.unicodeScalars.count, InboxCardTexts.targetTitleLimit)
        // Go's `workbench target add` cap (`WorkbenchNewTargetRequest.titleLimit`).
        XCTAssertEqual(InboxCardTexts.targetTitleLimit, 200)
    }

    func testDiscussMessageHasTitleAndBody() {
        let message = InboxCardTexts.discussMessage(card())
        XCTAssertTrue(message.contains("Two threads need you"), message)
        XCTAssertTrue(message.contains("**Acme** asked twice."), message)
    }

    func testHandToAgentTaskStartsWithTheTitle() {
        let task = InboxCardTexts.handToAgentTask(card(link: "https://example.com/t/1"))
        XCTAssertEqual(InboxCardTexts.targetTitle(fromTask: task), "Two threads need you")
        XCTAssertTrue(task.contains("**Acme** asked twice."), task)
        XCTAssertTrue(task.contains("https://example.com/t/1"), task)
    }

    func testAttachmentCarriesTheCard() {
        let markdown = InboxCardTexts.attachmentMarkdown(card(link: "https://example.com/t/1"))
        for part in ["Two threads need you", "Mail summary", "run #42", "https://example.com/t/1",
                     "**Acme** asked twice."] {
            XCTAssertTrue(markdown.contains(part), part)
        }
    }

    func testStampedLines() throws {
        let now = try XCTUnwrap(AutomationDates.parse("2026-10-21T15:00:00Z"))
        let today = try XCTUnwrap(AutomationDates.parse("2026-10-21T14:00:00Z"))
        let earlier = try XCTUnwrap(AutomationDates.parse("2026-10-18T09:30:00Z"))
        XCTAssertEqual(InboxCardTexts.stamped("Reminder", at: today, now: now, calendar: utc), "Reminder · 14:00")
        XCTAssertEqual(InboxCardTexts.stamped("Assistant proposal", at: earlier, now: now, calendar: utc),
                       "Assistant proposal · Oct 18")
    }

    func testSourceLines() throws {
        let now = try XCTUnwrap(AutomationDates.parse("2026-10-21T15:00:00Z"))
        XCTAssertEqual(InboxCardTexts.sourceLine(card(), now: now, calendar: utc), "Mail summary · 10:00")
        let later = try XCTUnwrap(AutomationDates.parse("2026-10-23T15:00:00Z"))
        XCTAssertEqual(InboxCardTexts.sourceLine(card(), now: later, calendar: utc), "Mail summary · Oct 21")
        XCTAssertEqual(InboxCardTexts.readingSourceLine(card(), calendar: utc),
                       "ϟ Mail summary · run #42 · Oct 21, 10:00")
    }
}

import GRDB
import XCTest
@testable import WatchtowerCore

/// The list's sections (spec "The list"): Needs you / Today / Running in
/// the root, Today / Earlier in an owner folder, and the root's Earlier
/// line for past briefs.
final class InboxRootSectionsTests: XCTestCase {
    private static let kyiv: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .current
        return calendar
    }()

    private static let today = "2026-11-11"

    /// Wed 11 Nov 2026, 08:02 in Kyiv (UTC+2).
    private func now() throws -> Date { try date("2026-11-11T06:02:00Z") }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }

    private func artifact(_ id: Int64, automation: Int64 = 1, changed: String) throws -> InboxFolderEntry {
        .artifact(AutomationOutputCard(
            id: id, automationID: automation, automationName: "A\(id)", runID: 1, title: "A\(id)", body: "",
            priority: "", createdAt: try date(changed), changedAt: try date(changed)))
    }

    private func brief(_ id: Int64, applied: String) -> InboxFolderEntry {
        .brief(AgentAction(row: Row(["id": id, "tool": "brief_context", "status": "applied", "applied_at": applied])))
    }

    private func day(_ date: String, read: Bool) throws -> InboxDayCard {
        let briefing = try Briefing(row: Row([
            "id": 1, "user_id": "u", "date": date, "role": "", "attention": "[]", "your_day": "[]",
            "what_happened": "[]", "team_pulse": "[]", "coaching": "[]", "model": "", "input_tokens": 0,
            "output_tokens": 0, "cost_usd": 0.0, "prompt_version": 1,
            "read_at": read ? "2026-11-11T05:00:00Z" : nil, "created_at": "\(date)T05:00:00Z"
        ] as [String: (any DatabaseValueConvertible)?]))
        return InboxDayCard(date: date, briefing: briefing, plan: nil, planDone: 0, planTotal: 0,
                            stamp: try self.date("\(date)T05:00:00Z"))
    }

    private func build(
        _ entries: [InboxFolderEntry], folder: InboxFolderKind = .root
    ) throws -> [(InboxRootSection, [String])] {
        let sections = InboxRootSections.build(
            entries: entries, folder: folder, waitingForMeAutomationID: 3, mailWaitingAutomationID: nil, slackTodayAutomationID: nil,
            now: try now(), calendar: Self.kyiv)
        return sections.map { ($0.0, $0.1.map(\.id)) }
    }

    private func assertSections(
        _ actual: [(InboxRootSection, [String])],
        _ expected: [(InboxRootSection, [String])],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
    }

    // MARK: - Sections

    func testRootOrder() throws {
        let entries: [InboxFolderEntry] = [
            try artifact(10, changed: "2026-11-10T12:00:00Z"),
            .legacyIdeas,
            brief(1, applied: "2026-11-11T05:00:00Z"),
            try artifact(11, changed: "2026-11-11T05:30:00Z"),
            .legacyTracks,
            try artifact(7, automation: 3, changed: "2026-11-09T09:00:00Z"),
            .legacyDay(try day(Self.today, read: false))
        ]
        assertSections(try build(entries), [
            (.needsYou, ["artifact:7", "brief:1"]),
            (.today, ["day:\(Self.today)", "artifact:11"]),
            (.running, ["tracks", "ideas", "artifact:10"])
        ])
    }

    func testRootNewestFirstWithinSections() throws {
        let entries: [InboxFolderEntry] = [
            .legacyMessages,
            brief(1, applied: "2026-11-10T09:00:00Z"),
            brief(2, applied: "2026-11-11T04:00:00Z"),
            try artifact(10, changed: "2026-11-11T01:00:00Z"),
            try artifact(11, changed: "2026-11-11T05:00:00Z"),
            try artifact(12, changed: "2026-11-01T05:00:00Z"),
            try artifact(13, changed: "2026-11-09T05:00:00Z")
        ]
        assertSections(try build(entries), [
            (.needsYou, ["messages", "brief:2", "brief:1"]),
            (.today, ["artifact:11", "artifact:10"]),
            (.running, ["artifact:13", "artifact:12"])
        ])
    }

    func testEmptySectionsAreLeftOut() throws {
        assertSections(try build([.legacyTracks]), [(.running, ["tracks"])])
        assertSections(try build([]), [])
        XCTAssertEqual(try build([.legacyTracks], folder: .approvals).count, 0, "Needs approval builds its own")
    }

    func testOwnerFolderTodayAndEarlier() throws {
        let entries: [InboxFolderEntry] = [
            try artifact(1, changed: "2026-11-11T05:00:00Z"),
            try artifact(2, changed: "2026-11-10T21:59:00Z"),
            try artifact(3, changed: "2026-11-10T22:00:00Z"),
            try artifact(4, changed: "2026-11-01T05:00:00Z")
        ]
        assertSections(try build(entries, folder: .owner), [
            (.today, ["artifact:1", "artifact:3"]),
            (.earlier, ["artifact:2", "artifact:4"])
        ])
    }

    func testRootOnlyTreeKeepsApprovalsInNeedsYou() throws {
        let action = AgentAction(row: Row(["id": 9, "tool": "create_track", "status": "pending"]))
        let notice = BuiltinUpgradeNotice(builtinID: "morning-brief", error: "failed", updatedAt: try now())
        let entries: [InboxFolderEntry] = [
            .approval(NeedsApprovalItem(.action(action))),
            .builtinNotice(notice),
            .legacyMessages,
            brief(1, applied: "2026-11-11T05:00:00Z")
        ]
        assertSections(try build(entries), [
            (.needsYou, ["messages", "brief:1", "approval:action:9", "notice:morning-brief"])
        ])
    }

    func testThreadBriefsOlderThan24HoursLeaveNeedsYou() throws {
        let entries = [brief(1, applied: "2026-11-11T04:02:00Z"), brief(2, applied: "2026-11-10T05:02:00Z")]
        assertSections(try build(entries), [(.needsYou, ["brief:1"])])
    }

    // MARK: - The Earlier line

    private func earlierLine(_ days: [InboxDayCard]) throws -> InboxEarlierLine? {
        InboxRootSections.earlierLine(days: days, today: Self.today, now: try now(), calendar: Self.kyiv)
    }

    func testEarlierLineCountsPastThirtyDays() throws {
        let days = [
            try day(Self.today, read: false),
            try day("2026-11-10", read: false),
            try day("2026-11-09", read: true),
            try day("2026-11-01", read: false),
            try day("2026-10-20", read: true),
            // The window's oldest date: 30 dates, today included.
            try day("2026-10-13", read: true),
            try day("2026-10-12", read: false)
        ]
        let line = try XCTUnwrap(try earlierLine(days))
        XCTAssertEqual(line, InboxEarlierLine(pastThisMonth: 5, notOpened: 2))
        XCTAssertEqual(line.text, "Past briefs are inside Morning brief · 5 this month, 2 not opened")
    }

    func testEarlierLineWithoutUnread() throws {
        let days = try ["2026-11-10", "2026-11-09", "2026-11-01", "2026-10-20", "2026-10-13"].map {
            try day($0, read: true)
        }
        XCTAssertEqual(try earlierLine(days)?.text, "Past briefs are inside Morning brief · 5 this month")
    }

    func testNoEarlierLineWithoutPastBriefs() throws {
        XCTAssertNil(try earlierLine([]))
        XCTAssertNil(try earlierLine([try day(Self.today, read: false)]), "today's is not a past brief")
        XCTAssertNil(try earlierLine([try day("2026-10-01", read: false)]), "older than 30 days")
        XCTAssertNil(try earlierLine([try day("2026-10-12", read: false)]), "the 31st date back")
        XCTAssertNil(try earlierLine([.placeholder(date: "2026-11-10", stamp: try now())]), "nothing written")
    }
}

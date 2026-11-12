import XCTest
import GRDB
@testable import WatchtowerCore

/// `ClosedAskListModel` (#1713 spec): day groups, chips, detail lines,
/// search and the counts of the closed asks list.
final class ClosedAskListModelTests: XCTestCase {
    private typealias Model = ClosedAskListModel

    /// Berlin, so local days differ from UTC ones.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    /// 2026-11-10 15:00 in Berlin (14:00Z), a Tuesday.
    private let now = Date(timeIntervalSince1970: 1_794_319_200)

    private func ask(
        _ id: Int64,
        created: String = "2026-11-10T10:00:00Z",
        kind: String = "question",
        title: String? = nil,
        status: String = "answered",
        reason: String = "",
        payload: String = "{}",
        answer: String = "",
        run: Int64? = nil
    ) throws -> OwnerAsk {
        try OwnerAsk(row: Row([
            "id": id, "project_id": 1, "level": "full", "origin": "agent", "kind": kind,
            "title": title ?? "Ask \(id)", "status": status, "withdrawn_reason": reason, "answer": answer,
            "payload": payload, "created_at": created, "automation_run_id": run
        ]))
    }

    private func answer(
        verdict: String = "",
        answers: String = "[]",
        checklist: String = "[]",
        comments: String = "[]",
        note: String = "",
        dismissed: Bool = false
    ) -> String {
        #"{"verdict":"\#(verdict)","answers":\#(answers),"checklist":\#(checklist),"comments":\#(comments),"note":"\#(note)""#
            + (dismissed ? #","dismissed":true}"# : "}")
    }

    private func sections(
        _ asks: [OwnerAsk],
        query: String = "",
        replacements: [Int64: Int64] = [:],
        labels: [Int64: String] = [:]
    ) -> [Model.Section] {
        Model.sections(asks: asks, replacements: replacements, labels: labels, query: query, now: now, calendar: calendar)
    }

    // MARK: - Groups

    func testGroupsByLocalDayNewestFirst() throws {
        let list = sections([
            try ask(5, created: "2026-11-10T13:00:00Z"),
            // 23:30Z on the 9th is 00:30 on the 10th in Berlin: today.
            try ask(4, created: "2026-11-09T23:30:00Z"),
            // 22:30Z on the 9th is 23:30 on the 9th in Berlin: yesterday.
            try ask(3, created: "2026-11-09T22:30:00Z"),
            try ask(2, created: "2026-11-07T09:00:00Z"),
            try ask(1, created: "2025-12-31T09:00:00Z")
        ])
        XCTAssertEqual(list.map(\.title), ["Today", "Yesterday", "Saturday, 7 November", "Wednesday, 31 December 2025"])
        XCTAssertEqual(list.map { $0.rows.map(\.id) }, [[5, 4], [3], [2], [1]])
        XCTAssertEqual(list[0].rows.map(\.time), ["14:00", "00:30"], "the local time filed")
    }

    func testAnotherTimeZoneMovesTheDay() throws {
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        let list = sections([try ask(1, created: "2026-11-10T03:00:00Z")])
        XCTAssertEqual(list.map(\.title), ["Yesterday"], "22:00 on the 9th in New York")
        XCTAssertEqual(list.first?.rows.first?.time, "22:00")
    }

    func testAnUnparseableDateGoesToALastGroup() throws {
        let list = sections([try ask(2, created: "not a date"), try ask(1, created: "2026-11-10T09:00:00Z")])
        XCTAssertEqual(list.map(\.title), ["Today", "Unknown date"])
        XCTAssertEqual(list.last?.rows.map(\.id), [2])
        XCTAssertEqual(list.last?.rows.first?.time, "")
    }

    func testEmptyListHasNoSections() {
        XCTAssertEqual(sections([]), [])
    }

    // MARK: - Chips

    func testChipOfEveryStatus() throws {
        XCTAssertEqual(Model.chip(for: try ask(1, status: "answered")), .answered)
        XCTAssertEqual(Model.chip(for: try ask(1, status: "delivered")), .delivered)
        XCTAssertEqual(Model.chip(for: try ask(1, status: "withdrawn", reason: "agent")), .withdrawn)
        XCTAssertEqual(Model.chip(for: try ask(1, status: "withdrawn", reason: "superseded")), .replaced)
        XCTAssertEqual(Model.chip(for: try ask(1, status: "delivered", answer: answer(dismissed: true))), .dismissed)
        XCTAssertEqual(Model.chip(for: try ask(1, status: "answered", answer: answer(dismissed: true))), .dismissed)
    }

    func testChipTones() {
        XCTAssertEqual(Model.Chip.answered.toneName, "blue")
        XCTAssertEqual(Model.Chip.delivered.toneName, "green")
        XCTAssertEqual(Model.Chip.withdrawn.toneName, "gray")
        XCTAssertEqual(Model.Chip.replaced.toneName, "gray")
        XCTAssertEqual(Model.Chip.dismissed.toneName, "gray")
    }

    // MARK: - Detail

    func testDetailOfAReplacedAsk() throws {
        let old = try ask(1, status: "withdrawn", reason: "superseded")
        XCTAssertEqual(Model.detail(for: old, replacedBy: 9, automationLabel: nil), "replaced by #9")
        XCTAssertEqual(Model.detail(for: old, replacedBy: nil, automationLabel: nil), "replaced by a newer ask")
    }

    func testDetailOfAWithdrawnAsk() throws {
        XCTAssertEqual(Model.detail(for: try ask(1, status: "withdrawn", reason: "agent"), replacedBy: nil, automationLabel: nil),
                       "withdrawn by the agent")
    }

    func testDetailOfADismissedAsk() throws {
        let noted = try ask(1, answer: answer(note: "Not needed any more", dismissed: true))
        XCTAssertEqual(Model.detail(for: noted, replacedBy: nil, automationLabel: nil), "Not needed any more")
        let bare = try ask(2, answer: answer(dismissed: true))
        XCTAssertEqual(Model.detail(for: bare, replacedBy: nil, automationLabel: nil), "")
    }

    func testDetailOfAReview() throws {
        let comment = #"{"quote":"q","prefix":"","suffix":"","heading":"","body":"b"}"#
        let approved = try ask(1, kind: "review", answer: answer(verdict: "approved"))
        XCTAssertEqual(Model.detail(for: approved, replacedBy: nil, automationLabel: nil), "Approved")
        let changes = try ask(2, kind: "review", answer: answer(verdict: "changes", comments: "[\(comment),\(comment)]",
                                                                note: "Keep the old flag"))
        XCTAssertEqual(Model.detail(for: changes, replacedBy: nil, automationLabel: nil),
                       "Changes requested · 2 comments · “Keep the old flag”")
        let one = try ask(3, kind: "review", answer: answer(verdict: "approved", comments: "[\(comment)]"))
        XCTAssertEqual(Model.detail(for: one, replacedBy: nil, automationLabel: nil), "Approved · 1 comment")
    }

    func testDetailOfAQuestionKeepsQuestionOrder() throws {
        let payload = #"{"questions":[{"id":"a","question":"Store?","options":[{"label":"Server table"},{"label":"Cookie"}]},"#
            + #"{"id":"b","question":"When?","options":[{"label":"Now"},{"label":"Later"}]}]}"#
        let answers = #"[{"id":"b","labels":["Later"],"other":""},{"id":"a","labels":["Server table"],"other":"keep the cookie"}]"#
        let question = try ask(1, payload: payload, answer: answer(answers: answers))
        XCTAssertEqual(Model.detail(for: question, replacedBy: nil, automationLabel: nil),
                       "Server table; keep the cookie; Later")
    }

    func testDetailOfACheck() throws {
        let payload = #"{"checklist":[{"id":"1","text":"one"},{"id":"2","text":"two"},{"id":"3","text":"three"}]}"#
        let marks = #"[{"id":"1","state":"ok","note":""},{"id":"2","state":"ok","note":""},{"id":"3","state":"broken","note":""}]"#
        let check = try ask(1, kind: "check", payload: payload, answer: answer(checklist: marks))
        let summary = OwnerAskPresentation.checkSummary(check.payload.checklist, marks: ["1": .ok, "2": .ok, "3": .broken])
        XCTAssertEqual(Model.detail(for: check, replacedBy: nil, automationLabel: nil), summary)
        XCTAssertFalse(Model.detail(for: check, replacedBy: nil, automationLabel: nil).isEmpty)
    }

    func testDetailWithNoAnswerIsEmpty() throws {
        XCTAssertEqual(Model.detail(for: try ask(1, status: "answered"), replacedBy: nil, automationLabel: nil), "")
    }

    func testAnAutomationLabelLeadsTheDetail() throws {
        let run = try ask(1, status: "withdrawn", reason: "agent", run: 12)
        XCTAssertEqual(Model.detail(for: run, replacedBy: nil, automationLabel: "⚙ Nightly export · run #12"),
                       "⚙ Nightly export · run #12 · withdrawn by the agent")
        let bare = try ask(2, run: 12)
        XCTAssertEqual(Model.detail(for: bare, replacedBy: nil, automationLabel: "⚙ Nightly export · run #12"),
                       "⚙ Nightly export · run #12")
    }

    func testRowCaptionStartsWithTheNumber() throws {
        let rows = sections([try ask(7, status: "withdrawn", reason: "agent"), try ask(6)]).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.caption), ["#7 · withdrawn by the agent", "#6"])
    }

    // MARK: - Search

    func testSearchMatchesTitleNumberChipAndDetail() throws {
        let asks = [
            try ask(412, title: "Plan: login redirect", status: "withdrawn", reason: "superseded"),
            try ask(411, title: "Should the retry wait?", answer: answer(answers: #"[{"id":"a","labels":["Yes"],"other":"use the backoff"}]"#)),
            try ask(410, title: "Rename the package", status: "delivered")
        ]
        func ids(_ query: String) -> [Int64] {
            sections(asks, query: query, replacements: [412: 500]).flatMap(\.rows).map(\.id)
        }
        XCTAssertEqual(ids("LOGIN"), [412], "case-insensitive title")
        XCTAssertEqual(ids("#410"), [410])
        XCTAssertEqual(ids("410"), [410])
        XCTAssertEqual(ids("replaced"), [412], "the chip word")
        XCTAssertEqual(ids("#500"), [412], "the detail")
        XCTAssertEqual(ids("backoff"), [411], "the answer")
        XCTAssertEqual(ids("delivered"), [410])
        XCTAssertEqual(ids("  "), [412, 411, 410], "a blank query filters nothing")
        XCTAssertEqual(ids("postgres"), [])
    }

    func testSearchIgnoresDiacritics() throws {
        let asks = [try ask(1, title: "Café opening hours")]
        XCTAssertEqual(sections(asks, query: "cafe").flatMap(\.rows).map(\.id), [1])
    }

    func testSearchThreshold() {
        XCTAssertEqual(Model.searchThreshold, 10)
        XCTAssertFalse(Model.showsSearch(total: 9))
        XCTAssertTrue(Model.showsSearch(total: 10))
    }

    func testKeyActions() {
        typealias Press = OwnerAskKeyMap.Press
        XCTAssertEqual(Model.keyAction(for: Press(key: .upArrow)), .up)
        XCTAssertEqual(Model.keyAction(for: Press(key: .downArrow)), .down)
        XCTAssertEqual(Model.keyAction(for: Press(key: .returnKey)), .open)
        XCTAssertEqual(Model.keyAction(for: Press(key: .escape)), .escape)
        XCTAssertNil(Model.keyAction(for: Press(key: .escape, isRepeat: true)), "a held Esc closes nothing")
        XCTAssertNil(Model.keyAction(for: Press(key: .escape, otherModifiers: true)))
        XCTAssertEqual(Model.keyAction(for: Press(key: .character("f"), otherModifiers: true)), .search, "⌘F")
        XCTAssertNil(Model.keyAction(for: Press(key: .character("f"))), "a bare F types nothing here")
        XCTAssertNil(Model.keyAction(for: Press(key: .returnKey, otherModifiers: true)))
        XCTAssertNil(Model.keyAction(for: Press(key: .tab)))
    }

    func testCountText() {
        XCTAssertEqual(Model.countText(shown: 84, total: 84, searching: false), "84")
        XCTAssertEqual(Model.countText(shown: 4, total: 84, searching: true), "4 of 84")
        XCTAssertEqual(Model.countText(shown: 0, total: 84, searching: true), "0 of 84")
    }
}

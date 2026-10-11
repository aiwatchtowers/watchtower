import XCTest
import GRDB
@testable import WatchtowerCore

/// The one-tap row of a Quick ask's banner and stack card (spec 2026-10-10
/// Part 9.1–9.2), as `OwnerAskQuickRow` lays it out.
final class OwnerAskQuickActionsTests: XCTestCase {
    private func ask(
        level: String = "quick",
        kind: String = "question",
        options: String = #"[{"label":"Yes"},{"label":"No"}]"#,
        questionID: String = "1",
        multi: Bool = false
    ) throws -> OwnerAsk {
        let payload = #"{"questions":[{"id":"\#(questionID)","question":"Flag?","multi":\#(multi),"options":\#(options)}]}"#
        return try OwnerAsk(row: Row([
            "id": 4, "project_id": 1, "level": level, "origin": "agent", "kind": kind, "title": "t",
            "payload": payload, "status": "open"
        ]))
    }

    func testRecommendedFirstAndProminent() throws {
        let options = #"[{"label":"Keep"},{"label":"Drop","description":"Remove the flag","recommended":true},{"label":"Later"}]"#
        let row = try XCTUnwrap(OwnerAskQuickRow(ask: try ask(options: options)))

        XCTAssertEqual(row.choices.map(\.label), ["Drop", "Keep", "Later"], "the recommended one first, the rest in stored order")
        XCTAssertEqual(row.choices.map(\.isProminent), [true, false, false])
        XCTAssertFalse(row.isReplyOnly)
    }

    func testAnOptionsDescriptionIsItsTooltip() throws {
        let options = #"[{"label":"Keep","description":"Leave it on"},{"label":"Drop"}]"#
        let row = try XCTUnwrap(OwnerAskQuickRow(ask: try ask(options: options)))

        XCTAssertEqual(row.choices.map(\.tooltip), ["Leave it on", nil], "no description, no tooltip")
    }

    func testNoRecommendedOptionLeavesTheStoredOrderAndNoProminence() throws {
        let row = try XCTUnwrap(OwnerAskQuickRow(ask: try ask()))

        XCTAssertEqual(row.choices.map(\.label), ["Yes", "No"])
        XCTAssertEqual(row.choices.map(\.isProminent), [false, false])
    }

    /// E18: a question raised from chat with no options gets only Reply.
    func testZeroOptionsShowsOnlyReply() throws {
        let row = try XCTUnwrap(OwnerAskQuickRow(ask: try ask(options: "[]", questionID: "q1")))

        XCTAssertTrue(row.choices.isEmpty)
        XCTAssertTrue(row.isReplyOnly)
        XCTAssertEqual(row.reply("staging-2"), .reply("staging-2", questionID: "q1"))
    }

    /// A Full ask has no one-tap row: the banner keeps Open, the stack card
    /// opens the drawer.
    func testAFullAskKeepsTheOpenButton() throws {
        XCTAssertNil(OwnerAskQuickRow(ask: try ask(level: "full")))
        let check = try OwnerAsk(row: Row([
            "id": 5, "project_id": 1, "level": "quick", "origin": "agent", "kind": "check", "title": "t",
            "payload": #"{"checklist":[{"text":"Launch"}]}"#, "status": "open"
        ]))
        XCTAssertNil(OwnerAskQuickRow(ask: check), "only a question has a one-tap row")
        XCTAssertNil(OwnerAskQuickRow(ask: try ask(multi: true)), "one tap is one label")
    }

    func testTheRowIsOffWhileAnsweringAndOnceAnswered() {
        XCTAssertTrue(OwnerAskQuickRow.isEnabled(answering: false, answered: false))
        XCTAssertFalse(OwnerAskQuickRow.isEnabled(answering: true, answered: false))
        XCTAssertFalse(OwnerAskQuickRow.isEnabled(answering: false, answered: true))
    }

    /// The Reply text lives in the ask's draft, as the question's "Other":
    /// the drawer (Details) shows it, and it replaces a picked label.
    func testTheReplyTextIsTheQuestionsOtherInTheDraft() {
        var draft = OwnerAskDraft()
        draft.picks["1"] = .init(labels: ["Yes"])
        draft.setReplyText("use staging", for: "1")
        XCTAssertEqual(draft.replyText(for: "1"), "use staging")
        XCTAssertEqual(draft.picks["1"], .init(labels: [], other: "use staging"))
        XCTAssertEqual(OwnerAskDraft().replyText(for: "1"), "")
    }

    /// The answers carry the ask's own question id — Go's default "1" here,
    /// never a hard-coded "q1".
    func testTheAnswersUseTheAsksOwnQuestionID() throws {
        let row = try XCTUnwrap(OwnerAskQuickRow(ask: try ask()))

        XCTAssertEqual(row.answer(picking: "No"), .quick(label: "No", questionID: "1"))
        XCTAssertEqual(row.reply("  later  "), .reply("later", questionID: "1"))
        XCTAssertNil(row.reply(" \n "), "a blank Reply sends nothing")
    }
}

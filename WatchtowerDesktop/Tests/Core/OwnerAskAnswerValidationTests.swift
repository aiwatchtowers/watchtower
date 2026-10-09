import XCTest
import GRDB
@testable import WatchtowerCore

/// A structured answer (the phone's, mobile POC spec §6.2) is checked by the
/// rules a Desktop draft is (`OwnerAskDraft.isAnswerable`), after the same
/// normalising: text trimmed, unmarked check items `skipped`.
final class OwnerAskAnswerValidationTests: XCTestCase {
    private func ask(_ kind: String, payload: String = "{}") throws -> OwnerAsk {
        try OwnerAsk(row: Row([
            "id": 7, "project_id": 1, "kind": kind, "title": "Ask", "status": "open", "payload": payload, "doc_path": ""
        ]))
    }

    private static let questions = #"""
        {"questions":[
          {"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]},
          {"id":"b","question":"Where?","multi":true,"options":[{"label":"Here"},{"label":"There"}]}
        ]}
        """#

    private static let checklist = #"{"checklist":[{"id":"1","text":"Launch"},{"id":"2","text":"Quit"},{"id":"3","text":"Undo"}]}"#

    private func problem(_ answer: OwnerAskAnswer, for ask: OwnerAsk) -> OwnerAskAnswerProblem? {
        answer.normalized(for: ask).problem(kind: ask.kind, payload: ask.payload)
    }

    func testAReviewNeedsAVerdict() throws {
        let review = try ask("review")
        XCTAssertEqual(problem(OwnerAskAnswer(note: "Fine"), for: review), .verdictRequired)
        XCTAssertNil(problem(OwnerAskAnswer(verdict: .approved), for: review))
    }

    func testEveryQuestionNeedsALabelOrAnOther() throws {
        let question = try ask("question", payload: Self.questions)
        XCTAssertEqual(problem(OwnerAskAnswer(answers: [.init(id: "a", labels: ["Yes"])]), for: question),
                       .questionUnanswered(id: "b"))
        XCTAssertEqual(problem(OwnerAskAnswer(answers: [.init(id: "a", labels: ["Yes"]), .init(id: "b", other: "  ")]),
                               for: question),
                       .emptyQuestionAnswer(index: 1), "a blank Other is no answer")
        XCTAssertNil(problem(OwnerAskAnswer(answers: [.init(id: "a", labels: ["Yes"]), .init(id: "b", other: " Later ")]),
                             for: question))
    }

    func testLabelsMustExistAmongTheOptions() throws {
        let question = try ask("question", payload: Self.questions)
        let answer = OwnerAskAnswer(answers: [.init(id: "a", labels: ["Maybe"]), .init(id: "b", labels: ["Here"])])
        XCTAssertEqual(problem(answer, for: question), .unknownLabel(index: 0, id: "a", label: "Maybe"))
    }

    func testChecklistIDsMustExistAndUnmarkedItemsGoSkipped() throws {
        let check = try ask("check", payload: Self.checklist)
        XCTAssertEqual(problem(OwnerAskAnswer(checklist: [.init(id: "9", state: .ok)]), for: check),
                       .unknownCheckItem(index: 0, id: "9"))
        let partial = OwnerAskAnswer(checklist: [.init(id: "2", state: .broken, note: " crashes ")])
        XCTAssertNil(problem(partial, for: check), "unmarked items may be left out, as a draft leaves them")
        XCTAssertEqual(partial.normalized(for: check).checklist, [
            .init(id: "2", state: .broken, note: "crashes"),
            .init(id: "1", state: .skipped),
            .init(id: "3", state: .skipped)
        ])
    }

    func testCommentBodiesMustBeNonEmpty() throws {
        let review = try ask("review")
        let anchor = CommentAnchor(quote: "Rollout", prefix: "## ", suffix: " order", heading: "Rollout")
        let answer = OwnerAskAnswer(verdict: .changes, comments: [.init(anchor: anchor, body: " \n ")])
        XCTAssertEqual(problem(answer, for: review), .commentBodyRequired(index: 0),
                       "a blank comment is refused, not dropped as a draft's is")
    }

    /// The same rules as a draft: what a draft would store passes unchanged.
    func testADraftsAnswerIsAlreadyNormalised() throws {
        let check = try ask("check", payload: Self.checklist)
        var draft = OwnerAskDraft()
        draft.checks["2"] = .broken
        draft.checkNotes["2"] = " crashes "
        draft.note = " thanks "
        let stored = draft.answer(for: check)
        XCTAssertEqual(stored.normalized(for: check), stored)
        XCTAssertEqual(draft.problem(for: check), problem(stored, for: check))
    }
}

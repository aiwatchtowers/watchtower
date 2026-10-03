import XCTest
import GRDB
@testable import WatchtowerCore

@MainActor
final class OwnerAskDraftsTests: XCTestCase {
    private func ask(_ kind: String, payload: String = "{}", docPath: String = "") throws -> OwnerAsk {
        try OwnerAsk(row: Row([
            "id": 7, "project_id": 1, "kind": kind, "title": "Ask", "status": "open", "payload": payload,
            "doc_path": docPath
        ]))
    }

    private static let questions = #"""
        {"questions":[
          {"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]},
          {"id":"b","question":"Where?","multi":true,"options":[{"label":"Here"},{"label":"There"}]}
        ]}
        """#

    private static let checklist = #"{"checklist":[{"id":"1","text":"Launch"},{"id":"2","text":"Quit"},{"id":"3","text":"Undo"}]}"#

    func testAnEmptyDraftIsNotADraft() {
        let drafts = OwnerAskDrafts()
        XCTAssertTrue(OwnerAskDraft().isEmpty)
        drafts.update(7) { $0.note = "  \n" }
        XCTAssertEqual(drafts.count, 0, "whitespace alone is nothing to lose")
        drafts.update(7) { $0.note = "Looks fine" }
        XCTAssertEqual(drafts.count, 1)
        drafts.update(8) { $0.verdict = .approved }
        XCTAssertEqual(drafts.count, 2)
        drafts.discard(7)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(drafts.askDraft(for: 7).isEmpty)
    }

    func testAQuestionAnswerFollowsThePayloadOrderAndTrims() throws {
        var draft = OwnerAskDraft()
        draft.picks["b"] = .init(labels: ["Here", "There"], other: "  ")
        draft.picks["a"] = .init(labels: [], other: " Later ")
        draft.note = " thanks "
        let answer = draft.answer(for: try ask("question", payload: Self.questions))
        XCTAssertEqual(answer.answers, [
            .init(id: "a", labels: [], other: "Later"),
            .init(id: "b", labels: ["Here", "There"], other: "")
        ])
        XCTAssertNil(answer.verdict, "only a review carries a verdict")
        XCTAssertEqual(answer.note, "thanks")
    }

    func testACheckLeavesUnmarkedItemsSkipped() throws {
        var draft = OwnerAskDraft()
        draft.checks["2"] = .broken
        draft.checkNotes["2"] = " crashes "
        draft.checks["1"] = .ok
        let check = try ask("check", payload: Self.checklist)
        XCTAssertTrue(draft.isAnswerable(for: check), "a check with unmarked items can be answered")
        XCTAssertEqual(draft.answer(for: check).checklist, [
            .init(id: "1", state: .ok),
            .init(id: "2", state: .broken, note: "crashes"),
            .init(id: "3", state: .skipped)
        ])
    }

    func testAReviewNeedsAVerdictAndKeepsItsNonEmptyComments() throws {
        let review = try ask("review", docPath: "docs/spec.md")
        var draft = OwnerAskDraft()
        XCTAssertFalse(draft.isAnswerable(for: review))
        draft.verdict = .changes
        let anchor = CommentAnchor(quote: "Rollout", prefix: "## ", suffix: " order", heading: "Rollout")
        draft.comments = [
            OwnerAskCommentDraft(anchor: anchor, body: " Too early "),
            OwnerAskCommentDraft(anchor: anchor, body: " ")
        ]
        XCTAssertTrue(draft.isAnswerable(for: review))
        let answer = draft.answer(for: review)
        XCTAssertEqual(answer.verdict, .changes)
        XCTAssertEqual(answer.comments, [OwnerAskAnswer.Comment(anchor: anchor, body: "Too early")])
    }

    func testEveryQuestionNeedsAPick() throws {
        let question = try ask("question", payload: Self.questions)
        var draft = OwnerAskDraft()
        draft.picks["a"] = .init(labels: ["Yes"])
        XCTAssertFalse(draft.isAnswerable(for: question))
        draft.picks["b"] = .init(other: "Elsewhere")
        XCTAssertTrue(draft.isAnswerable(for: question))
    }

    func testABrokenItemNeedsANoteAndTheNoteItsBound() throws {
        let check = try ask("check", payload: Self.checklist)
        var draft = OwnerAskDraft()
        draft.checks["2"] = .broken
        XCTAssertFalse(draft.isAnswerable(for: check), "Go refuses a broken item without a note")
        XCTAssertEqual(draft.problem(for: check), .brokenWithoutNote(index: 1))
        draft.checkNotes["2"] = "   "
        XCTAssertFalse(draft.isAnswerable(for: check), "blank is no note")
        draft.checkNotes["2"] = "Quit hangs"
        XCTAssertTrue(draft.isAnswerable(for: check))
        draft.note = String(repeating: "x", count: 4001)
        XCTAssertEqual(draft.problem(for: check), .noteTooLong)
    }

    func testCommentsGoOnlyWithAReview() throws {
        var draft = OwnerAskDraft()
        draft.comments = [OwnerAskCommentDraft(anchor: CommentAnchor(quote: "q", prefix: "", suffix: "", heading: ""), body: "fix")]
        let check = try ask("check", payload: Self.checklist)
        XCTAssertTrue(draft.answer(for: check).comments.isEmpty)
        XCTAssertTrue(draft.isAnswerable(for: check))
    }
}

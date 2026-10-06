import XCTest
import GRDB
@testable import WatchtowerCore

final class OwnerAskPresentationTests: XCTestCase {
    private static let question = #"{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}"#

    private func ask(
        _ kind: OwnerAskKind,
        questions: Bool = false,
        checklist: String = "[]",
        status: String = "open",
        reason: String = ""
    ) throws -> OwnerAsk {
        let payload = #"{"questions":[\#(questions ? Self.question : "")],"checklist":\#(checklist)}"#
        return try OwnerAsk(row: Row([
            "id": 4, "project_id": 1, "kind": kind.rawValue, "title": "t", "payload": payload,
            "status": status, "withdrawn_reason": reason
        ]))
    }

    /// Board #366: a "Waiting for you" row's next step by kind, counted.
    func testNextStepPerKindSingularAndPlural() throws {
        let step = { (ask: OwnerAsk) in OwnerAskPresentation.nextStep(for: ask) }
        XCTAssertEqual(step(try ask(.review)), "Review doc")
        XCTAssertEqual(step(try ask(.question, questions: true)), "Answer 1 question")
        XCTAssertEqual(step(try ask(.check, checklist: #"[{"text":"Launch"}]"#)), "Run 1 check")
        XCTAssertEqual(step(try ask(.check, checklist: #"[{"text":"Launch"},{"text":"Quit"}]"#)), "Run 2 checks")
        XCTAssertEqual(step(try ask(.check)), "Run checks", "no items: the verb and the plural noun")
        XCTAssertEqual(step(try ask(.question)), "Answer questions")
        let second = Self.question.replacingOccurrences(of: #""id":"a""#, with: #""id":"b""#)
        let two = try OwnerAsk(row: Row([
            "id": 5, "project_id": 1, "kind": "question", "title": "t", "status": "open",
            "payload": #"{"questions":[\#(Self.question),\#(second)]}"#
        ]))
        XCTAssertEqual(step(two), "Answer 2 questions")
    }

    func testAnswerActionsPerKind() {
        let labels = { (kind: OwnerAskKind) in OwnerAskPresentation.answerActions(for: kind).map(\.label) }
        XCTAssertEqual(labels(.review), ["Request changes", "Approve"])
        XCTAssertEqual(labels(.check), ["Send"])
        XCTAssertEqual(labels(.question), ["Answer"])
        XCTAssertEqual(OwnerAskPresentation.answerActions(for: .review).map(\.verdict), [.changes, .approved],
                       "a review's buttons carry the verdict they answer with")
        XCTAssertEqual(OwnerAskPresentation.answerActions(for: .check).map(\.verdict), [nil])
    }

    /// Owner ask #90: ⌘↩ presses the primary button, ⌘⇧↩ a review's
    /// Request changes and nothing on the other kinds.
    func testKeyActionPerKind() throws {
        let key = { (ask: OwnerAsk, shift: Bool) in OwnerAskPresentation.keyAction(for: ask, draft: OwnerAskDraft(), shift: shift) }
        XCTAssertEqual(key(try ask(.review), false)?.verdict, .approved)
        XCTAssertEqual(key(try ask(.review), true)?.verdict, .changes)
        XCTAssertEqual(key(try ask(.question, questions: true), false)?.label, "Answer")
        XCTAssertNil(key(try ask(.question, questions: true), true))
        let check = try ask(.check, checklist: #"[{"text":"Launch"}]"#)
        XCTAssertEqual(key(check, false)?.label, "Send (1 unmarked)", "the button as the bar shows it")
        XCTAssertNil(key(check, true))
        let review = OwnerAskPresentation.answerActions(for: .review)
        XCTAssertEqual(review.map(OwnerAskPresentation.keyLabel), ["⌘⇧↩", "⌘↩"])
    }

    func testAQuestionAnswersOnlyOnceEveryQuestionHasAPick() throws {
        let ask = try ask(.question, questions: true)
        let action = try XCTUnwrap(OwnerAskPresentation.answerActions(for: .question).first)
        var draft = OwnerAskDraft()
        XCTAssertFalse(OwnerAskPresentation.canAnswer(ask, draft: draft, with: action, answering: false))
        draft.picks["a"] = .init(labels: ["Yes"])
        XCTAssertTrue(OwnerAskPresentation.canAnswer(ask, draft: draft, with: action, answering: false))
        XCTAssertFalse(OwnerAskPresentation.canAnswer(ask, draft: draft, with: action, answering: true),
                       "never while an answer is being written")
    }

    func testAReviewNeedsAVerdictWhichItsButtonsGive() throws {
        let ask = try ask(.review, questions: true)
        let approve = try XCTUnwrap(OwnerAskPresentation.answerActions(for: .review).last)
        var draft = OwnerAskDraft()
        XCTAssertFalse(draft.isAnswerable(for: ask), "no verdict, no pick")
        XCTAssertFalse(OwnerAskPresentation.canAnswer(ask, draft: draft, with: approve, answering: false),
                       "a review's questions still need their picks")
        draft.picks["a"] = .init(labels: ["No"])
        XCTAssertFalse(draft.isAnswerable(for: ask), "the draft alone still has no verdict")
        XCTAssertTrue(OwnerAskPresentation.canAnswer(ask, draft: draft, with: approve, answering: false))
        let plain = OwnerAskPresentation.AnswerAction(label: "Answer", verdict: nil, isPrimary: true)
        XCTAssertFalse(OwnerAskPresentation.canAnswer(ask, draft: draft, with: plain, answering: false),
                       "a review is never answered without a verdict")
    }

    func testACheckAnswersWithUnmarkedItems() throws {
        let ask = try ask(.check, checklist: #"[{"text":"Launch"},{"text":"Quit"}]"#)
        let send = try XCTUnwrap(OwnerAskPresentation.answerActions(for: .check).first)
        XCTAssertTrue(OwnerAskPresentation.canAnswer(ask, draft: OwnerAskDraft(), with: send, answering: false))
    }

    func testAClosedAskIsNeverAnswered() throws {
        let ask = try ask(.check, status: "withdrawn", reason: "agent")
        let send = try XCTUnwrap(OwnerAskPresentation.answerActions(for: .check).first)
        XCTAssertFalse(OwnerAskPresentation.canAnswer(ask, draft: OwnerAskDraft(), with: send, answering: false))
    }

    func testCheckSummary() {
        let items = ["1", "2", "3", "4"].map { OwnerAskCheckItem(id: $0, text: "step \($0)") }
        XCTAssertEqual(OwnerAskPresentation.checkSummary(items, marks: ["1": .ok, "2": .broken]), "1 ok · 1 broken · 2 unmarked")
        XCTAssertEqual(OwnerAskPresentation.checkSummary(Array(items.prefix(3)), marks: ["1": .ok, "2": .broken]),
                       "1 ok · 1 broken · 1 unmarked")
        XCTAssertEqual(OwnerAskPresentation.checkSummary(items, marks: ["1": .ok, "2": .ok, "3": .skipped, "4": .ok]),
                       "3 ok · 1 skipped", "an empty count is left out")
        XCTAssertEqual(OwnerAskPresentation.checkSummary(items, marks: ["gone": .ok]), "4 unmarked",
                       "a mark for an item the payload lacks counts for nothing")
        XCTAssertEqual(OwnerAskPresentation.checkSummary([], marks: [:]), "")
    }

    func testPositionLabel() {
        XCTAssertEqual(OwnerAskPresentation.positionLabel(2, of: 5), "2 of 5")
    }

    func testStatusLineOfAClosedAsk() throws {
        XCTAssertEqual(OwnerAskPresentation.askStatusLine(try ask(.question, status: "answered"), replacedBy: nil), "Answered")
        XCTAssertEqual(OwnerAskPresentation.askStatusLine(try ask(.question, status: "delivered"), replacedBy: nil), "Delivered")
        XCTAssertEqual(OwnerAskPresentation.askStatusLine(try ask(.question, status: "withdrawn", reason: "agent"), replacedBy: nil),
                       "withdrawn by the agent")
        let superseded = try ask(.review, status: "withdrawn", reason: "superseded")
        XCTAssertEqual(OwnerAskPresentation.askStatusLine(superseded, replacedBy: 12), "replaced by #12")
        XCTAssertEqual(OwnerAskPresentation.askStatusLine(superseded, replacedBy: nil), "replaced by a newer ask")
        XCTAssertEqual(OwnerAskPresentation.askStatusLine(try ask(.question), replacedBy: nil), "Waiting for you")
    }

    func testAStoredAnswerReadsBackAsPicksAndMarks() {
        let answer = OwnerAskAnswer(
            answers: [.init(id: "a", labels: ["Yes"]), .init(id: "b", labels: [], other: "Later")],
            checklist: [.init(id: "1", state: .broken, note: "crashes")]
        )
        XCTAssertEqual(OwnerAskPresentation.answerPicks(from: answer), ["a": .init(labels: ["Yes"]), "b": .init(labels: [], other: "Later")])
        XCTAssertEqual(OwnerAskPresentation.answerMarks(from: answer), ["1": .broken])
        XCTAssertEqual(OwnerAskPresentation.answerNotes(from: answer), ["1": "crashes"])
    }

    func testSendNamesTheUnmarkedItems() throws {
        let ask = try ask(.check, checklist: #"[{"text":"Launch"},{"text":"Quit"},{"text":"Undo"}]"#)
        var draft = OwnerAskDraft()
        XCTAssertEqual(OwnerAskPresentation.answerActions(for: ask, draft: draft).map(\.label), ["Send (3 unmarked)"])
        draft.checks["1"] = .ok
        XCTAssertEqual(OwnerAskPresentation.answerActions(for: ask, draft: draft).map(\.label), ["Send (2 unmarked)"])
        draft.checks["2"] = .skipped
        draft.checks["3"] = .ok
        XCTAssertEqual(OwnerAskPresentation.answerActions(for: ask, draft: draft).map(\.label), ["Send"])
        let review = try self.ask(.review)
        XCTAssertEqual(OwnerAskPresentation.answerActions(for: review, draft: draft).map(\.label), ["Request changes", "Approve"])
    }

    func testABrokenItemWithoutANoteBlocksSendAndSaysWhy() throws {
        let ask = try ask(.check, checklist: #"[{"text":"Launch"},{"text":"Quit"}]"#)
        let send = try XCTUnwrap(OwnerAskPresentation.answerActions(for: .check).first)
        var draft = OwnerAskDraft()
        draft.checks["1"] = .broken
        XCTAssertFalse(OwnerAskPresentation.canAnswer(ask, draft: draft, with: send, answering: false))
        XCTAssertEqual(OwnerAskPresentation.blocker(ask, draft: draft, with: send), "Add a note to each broken item")
        draft.checkNotes["1"] = "crashes on launch"
        XCTAssertTrue(OwnerAskPresentation.canAnswer(ask, draft: draft, with: send, answering: false))
        XCTAssertNil(OwnerAskPresentation.blocker(ask, draft: draft, with: send))
        draft.note = String(repeating: "x", count: 4001)
        XCTAssertFalse(OwnerAskPresentation.canAnswer(ask, draft: draft, with: send, answering: false))
        XCTAssertEqual(OwnerAskPresentation.blocker(ask, draft: draft, with: send), "Shorten the note to 4000 characters")
    }

    func testAnUnpickedQuestionSaysWhy() throws {
        let ask = try ask(.question, questions: true)
        let action = try XCTUnwrap(OwnerAskPresentation.answerActions(for: .question).first)
        XCTAssertEqual(OwnerAskPresentation.blocker(ask, draft: OwnerAskDraft(), with: action), "Answer every question")
    }
}

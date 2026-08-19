import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Pure-logic coverage for `TargetExtractFill` — the projection that decides
/// what an "Extract with AI" result does to the New Target form: fill it in
/// place (single proposal), hand off to the selection sheet (2+), or report
/// that the model found nothing.
final class TargetExtractFillTests: XCTestCase {
    private func emptyDraft() -> TargetDraft {
        TargetDraft(
            text: "",
            intent: "",
            level: "day",
            priority: "medium",
            periodStart: "",
            periodEnd: "",
            hasExplicitPeriod: false,
            subItems: [],
            parentID: nil
        )
    }

    private func proposal(
        text: String = "Ship the extract fix",
        intent: String = "so the button stops swallowing results",
        level: String = "week",
        priority: String = "high",
        periodStart: String = "2026-08-18",
        periodEnd: String = "2026-08-25",
        parentId: Int? = nil,
        subItems: [TargetSubItem] = []
    ) -> ProposedTarget {
        ProposedTarget(
            text: text,
            intent: intent,
            level: level,
            customLabel: "",
            levelConfidence: 0.8,
            periodStart: periodStart,
            periodEnd: periodEnd,
            priority: priority,
            parentId: parentId,
            secondaryLinks: [],
            subItems: subItems
        )
    }

    // MARK: - Outcome selection

    func testNoProposalsReportsNothingFound() {
        let outcome = TargetExtractFill.apply([], to: emptyDraft())
        XCTAssertEqual(outcome, .nothing)
    }

    func testMultipleProposalsHandOffToPreviewSheet() {
        let outcome = TargetExtractFill.apply(
            [proposal(text: "first"), proposal(text: "second")],
            to: emptyDraft()
        )
        XCTAssertEqual(outcome, .needsPreview)
    }

    func testSingleProposalFillsTheForm() throws {
        let outcome = TargetExtractFill.apply([proposal()], to: emptyDraft())
        guard case let .filled(draft) = outcome else {
            return XCTFail("expected a single proposal to fill the form, got \(outcome)")
        }
        XCTAssertEqual(draft.text, "Ship the extract fix")
        XCTAssertEqual(draft.intent, "so the button stops swallowing results")
        XCTAssertEqual(draft.level, "week")
        XCTAssertEqual(draft.priority, "high")
        XCTAssertEqual(draft.periodStart, "2026-08-18")
        XCTAssertEqual(draft.periodEnd, "2026-08-25")
        XCTAssertTrue(draft.hasExplicitPeriod, "a proposed period must survive into the created target")
    }

    // MARK: - What the user typed wins

    func testUserWrittenContextIsNotOverwritten() throws {
        var draft = emptyDraft()
        draft.intent = "mine, hand-written"
        let outcome = TargetExtractFill.apply([proposal()], to: draft)
        guard case let .filled(filled) = outcome else { return XCTFail("expected .filled") }
        XCTAssertEqual(filled.intent, "mine, hand-written")
    }

    func testUserPickedParentIsNotOverwritten() throws {
        var draft = emptyDraft()
        draft.parentID = 42
        let outcome = TargetExtractFill.apply([proposal(parentId: 7)], to: draft)
        guard case let .filled(filled) = outcome else { return XCTFail("expected .filled") }
        XCTAssertEqual(filled.parentID, 42)
    }

    func testProposedParentFillsAnUnsetParent() throws {
        let outcome = TargetExtractFill.apply([proposal(parentId: 7)], to: emptyDraft())
        guard case let .filled(filled) = outcome else { return XCTFail("expected .filled") }
        XCTAssertEqual(filled.parentID, 7)
    }

    func testExistingChecklistItemsAreKeptAndProposedOnesAppended() throws {
        var draft = emptyDraft()
        draft.subItems = [TargetSubItem(text: "typed by hand", done: false)]
        let outcome = TargetExtractFill.apply(
            [proposal(subItems: [TargetSubItem(text: "from the model", done: false)])],
            to: draft
        )
        guard case let .filled(filled) = outcome else { return XCTFail("expected .filled") }
        XCTAssertEqual(filled.subItems.map(\.text), ["typed by hand", "from the model"])
    }

    // MARK: - Degenerate proposals

    func testProposalWithoutAPeriodLeavesTheFormsPeriodAlone() throws {
        let outcome = TargetExtractFill.apply(
            [proposal(periodStart: "", periodEnd: "")],
            to: emptyDraft()
        )
        guard case let .filled(filled) = outcome else { return XCTFail("expected .filled") }
        XCTAssertEqual(filled.periodStart, "")
        XCTAssertEqual(filled.periodEnd, "")
        XCTAssertFalse(filled.hasExplicitPeriod)
    }

    func testProposalWithBlankFieldsKeepsWhatTheUserAlreadyHas() throws {
        var draft = emptyDraft()
        draft.text = "typed goal"
        draft.level = "month"
        draft.priority = "low"
        let outcome = TargetExtractFill.apply(
            [proposal(text: "", intent: "", level: "", priority: "")],
            to: draft
        )
        guard case let .filled(filled) = outcome else { return XCTFail("expected .filled") }
        XCTAssertEqual(filled.text, "typed goal")
        XCTAssertEqual(filled.level, "month")
        XCTAssertEqual(filled.priority, "low")
    }

    // MARK: - Request composition

    func testContextIsSentAlongsideTheGoalText() {
        let composed = TargetExtractFill.composeInput(text: "Fix the AI button", context: "it silently does nothing")
        XCTAssertTrue(composed.hasPrefix("Fix the AI button"))
        XCTAssertTrue(
            composed.contains("it silently does nothing"),
            "the 'Add context' field must reach the extractor, got: \(composed)"
        )
    }

    func testBlankContextLeavesTheTextUntouched() {
        XCTAssertEqual(
            TargetExtractFill.composeInput(text: "Fix the AI button", context: "   \n "),
            "Fix the AI button"
        )
    }
}

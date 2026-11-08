import XCTest
@testable import WatchtowerCore

final class SpecReviewCardActionsTests: XCTestCase {
    /// Spec 2026-11-08 §2: a card's buttons depend on what it is.
    func testTableMatchesSpec() {
        let table: [(SpecReviewCardKind, [SpecReviewCardButton])] = [
            (.asAgreed, [.discuss, .notUseful]),
            (.actionable, [.fix, .skip, .discuss, .notUseful]),
            (.fromDiscussion, [.fix, .skip, .discuss, .notUseful]),
            (.checkToVerify, [.discuss, .checked]),
            (.thesis, [.discuss]),
            (.dispute, [.reviewerRight, .authorRight, .discuss]),
            (.fixedByAuthor, [.reopen, .discuss]),
            (.unanswered, [.fix, .skip, .discuss])
        ]
        for (kind, buttons) in table {
            XCTAssertEqual(SpecReviewCardActions.buttons(for: kind), buttons, "\(kind)")
        }
        XCTAssertEqual(table.count, SpecReviewCardKind.allCases.count, "every kind is pinned")
    }

    func testAsAgreedHasNothingToFix() {
        XCTAssertFalse(SpecReviewCardActions.buttons(for: .asAgreed).contains(.fix))
        XCTAssertFalse(SpecReviewCardActions.buttons(for: .thesis).contains(.fix))
    }
}

import Foundation

/// What a spec review card is, for the buttons it offers (spec 2026-11-08
/// §2). The findings screen's cards, a summary's thesis and the finished
/// author loop's cards.
package enum SpecReviewCardKind: CaseIterable, Sendable {
    /// An agreement the document matches: nothing to fix.
    case asAgreed
    /// A differing or missing agreement, a decision taken alone, a blind
    /// spot, or a check with a concern.
    case actionable
    /// A check without a concern: something for the owner to verify.
    case checkToVerify
    /// One thesis of the summary.
    case thesis
    /// A loop finding the reviewer and the author argued over.
    case dispute
    /// A loop finding the author fixed and the reviewer confirmed.
    case fixedByAuthor
    /// A loop finding the author never answered.
    case unanswered
    /// A finding the owner added from a Discuss thread.
    case fromDiscussion
}

/// One button on a card. **Skip** and **Checked** write the same `ok`
/// mark (today's **Fine as is**); **Fix** writes a `comment` mark.
package enum SpecReviewCardButton: Sendable {
    case fix, skip, discuss, notUseful, checked, reviewerRight, authorRight, reopen
}

/// Spec 2026-11-08 §2's table: the buttons each kind of card offers, in
/// the order they are drawn.
package enum SpecReviewCardActions {
    package static func buttons(for kind: SpecReviewCardKind) -> [SpecReviewCardButton] {
        switch kind {
        case .asAgreed: [.discuss, .notUseful]
        case .actionable, .fromDiscussion: [.fix, .skip, .discuss, .notUseful]
        case .checkToVerify: [.discuss, .checked]
        case .thesis: [.discuss]
        case .dispute: [.reviewerRight, .authorRight, .discuss]
        case .fixedByAuthor: [.reopen, .discuss]
        case .unanswered: [.fix, .skip, .discuss]
        }
    }
}

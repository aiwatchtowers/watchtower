import WatchtowerKit

/// An ask kind's word and the Mac's kind icon
/// (`WatchtowerCore/Services/OwnerAskPresentation.swift:136-142`), shared
/// by the ask rows (design pass spec §2.7) and the ask form's header (A1).
/// A kind from a newer Mac reads as its capitalised raw value with the
/// question icon.
enum AskKindStyle {
    static func name(_ kind: OwnerAsk.Kind) -> String {
        switch kind {
        case .review: "Review"
        case .check: "Check"
        case .question: "Question"
        default: kind.rawValue.capitalized
        }
    }

    static func icon(_ kind: OwnerAsk.Kind) -> String {
        switch kind {
        case .review: "doc.text.magnifyingglass"
        case .check: "checklist"
        default: "questionmark.bubble"
        }
    }
}

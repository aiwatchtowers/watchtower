import Foundation

/// A field of the approval hash (Go's `ApprovalFields`; the two budget
/// fields are one). AUTO-06: each one is on screen wherever a save or
/// confirm press can land.
package enum AutomationHashedField: String, CaseIterable, Hashable, Sendable {
    case script, permissions, outputs, scope, trigger, missed, budget, concurrency, artifacts

    /// The field of a `validate`/`show` change (`budget_tokens` and
    /// `budget_minutes` are the budget); nil for one this does not know.
    package init?(changeField: String) {
        switch changeField {
        case "budget_tokens", "budget_minutes": self = .budget
        default: self.init(rawValue: changeField)
        }
    }
}

extension AutomationEditorStep {
    /// The hashed fields the step's own boxes show: What it collects has It
    /// may, Sends and the recipe (**Show recipe**); When it runs has When,
    /// Each run, Missed and Concurrency and the Inbox cards; Look shows
    /// none. The scope is shown by none of them.
    package var shownFields: Set<AutomationHashedField> {
        switch self {
        case .collects: [.script, .permissions, .outputs]
        case .look: []
        case .schedule: [.trigger, .missed, .budget, .concurrency, .artifacts]
        }
    }
}

/// The editor's pinned row above the footer (AUTO-06, owner's answer in
/// ask #486): the hashed fields a save or confirm pressed on this step would
/// confirm and the step does not show. For an edit with a known diff, the
/// changed fields as the Changed box words them ("Changed"); for a new
/// recipe, one never confirmed, or an unknown diff, every field with its
/// value ("Also confirms").
package struct AutomationSaveConfirmationRow: Equatable, Sendable {
    package struct Item: Equatable, Sendable {
        /// nil for a change of a field this build does not know: never
        /// taken as shown, so always in the row.
        package let field: AutomationHashedField?
        package let text: String

        package init(field: AutomationHashedField?, text: String) {
            self.field = field
            self.text = text
        }
    }

    package static let changedTitle = "Changed"
    package static let valuesTitle = "Also confirms"

    package let title: String
    package let items: [Item]
}

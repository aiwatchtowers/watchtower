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
/// ask #486): what a save or confirm pressed on this step confirms that the
/// step does not show. For an edit with a known diff, every changed field as
/// the Changed box words them ("Changed") — the box is only on What it
/// collects; for a new recipe, one never confirmed, or an unknown diff, the
/// fields the step does not show with their values ("Also confirms"), under
/// the box's "First confirmation" / unknown-diff line (`note`).
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
    /// The Changed box's line for an edit with nothing to compare
    /// (`AutomationChangePresentation.firstConfirmation`/`unknownChanges`).
    package let note: String?
    package let items: [Item]
    /// The row's last line: the Inbox folder the save puts the cards in
    /// (`InboxNewArtifactRoute.placementText`). Placement, not a hashed
    /// item: what the press confirms never depends on it (AUTO-06).
    package var placement: String?

    package init(title: String, note: String?, items: [Item], placement: String? = nil) {
        self.title = title
        self.note = note
        self.items = items
        self.placement = placement
    }
}

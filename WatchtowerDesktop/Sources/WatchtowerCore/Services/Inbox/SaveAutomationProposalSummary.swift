import Foundation

/// A `save_automation` proposal in the Inbox reading pane: its title, where
/// the recipe goes, when it runs and the first of what it may do. The whole
/// recipe is read and saved in the editor (**Open Draft**).
package struct SaveAutomationProposalSummary: Equatable, Sendable {
    package let name: String
    /// "Personal", or the workbench's name ("Workbench #3" when not known).
    package let scope: String
    package let when: String
    /// The first two permissions in words, then "and N more"; "Nothing" with none.
    package let mayLine: String

    package init(model: SaveAutomationCardModel, workbenchName: (Int64) -> String?) {
        name = model.title
        scope = model.workbenchID.map { workbenchName($0) ?? "Workbench #\($0)" } ?? "Personal"
        when = model.whenLine
        let lines = model.permissions.map(AutomationCardPresentation.permissionLine)
        let shown = lines.prefix(2).joined(separator: ", ")
        mayLine = switch lines.count {
        case 0: "Nothing"
        case 1, 2: shown
        default: "\(shown) and \(lines.count - 2) more"
        }
    }
}

/// Where a `save_automation` proposal's **Open Draft** opens the editor: over
/// the saved automation an edit replaces (`savedID`, the automation at the
/// proposal's path), else as a new draft in the proposal's scope. A
/// workbench that is gone opens nothing.
package enum SaveProposalDraftOpening: Equatable, Sendable {
    case existing(Int64)
    case newDraft(AutomationScopeChoice)
    case workbenchGone(Int64)

    package init(model: SaveAutomationCardModel, savedID: Int64?, workbenches: [Workbench]) {
        if !model.isNew, let savedID {
            self = .existing(savedID)
        } else if let id = model.workbenchID {
            self = workbenches.first { $0.id == id }.map { .newDraft(.forWorkbench($0)) } ?? .workbenchGone(id)
        } else {
            self = .newDraft(.personal)
        }
    }
}

import Foundation
import WatchtowerInterface

/// A pending `save_automation` proposal in the Inbox reading pane, as the
/// tower's feed words it (`Card.approval`, Go `SummarizeSaveAutomation`):
/// its title and its "For", "When" and "It may" lines. The whole recipe is
/// read and saved in the editor (**Open Draft**).
package struct SaveAutomationProposalSummary: Equatable, Sendable {
    /// One line of the summary: its label ("For") and its value ("Personal").
    package struct Line: Equatable, Sendable {
        package let label: String
        package let value: String

        package init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    package let name: String
    package let lines: [Line]

    /// Go's title and summary lines; each "<label>: <value>" line is split
    /// at its first ": ". No approval (no feed yet) draws nothing.
    package init(approval: Approval?) {
        name = approval?.title ?? ""
        lines = (approval?.summary ?? "").split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let text = String(raw)
            guard let colon = text.range(of: ": ") else { return Line(label: "", value: text) }
            return Line(label: String(text[..<colon.lowerBound]), value: String(text[colon.upperBound...]))
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

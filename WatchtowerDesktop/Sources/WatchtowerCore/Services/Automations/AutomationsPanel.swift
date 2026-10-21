import Foundation

/// Where a new automation lives, chosen once in "What is it for?" and never
/// changed afterwards (ask #469): the owner's personal recipes, or one
/// workbench's. `folder` is the workbench's folder path.
package enum AutomationScopeChoice: Hashable, Sendable {
    case personal
    case workbench(id: Int64, name: String, folder: String)

    /// One workbench's scope, its folder as the full path.
    package static func forWorkbench(_ workbench: Workbench) -> Self {
        .workbench(id: workbench.id, name: workbench.name, folder: workbench.folderPath)
    }

    /// The workbench's id; nil for personal.
    package var workbenchID: Int64? {
        if case let .workbench(id, _, _) = self { return id }
        return nil
    }

    /// The directory the recipe file goes to: `<workspace>/automations`, or
    /// `<folder>/.watchtower/automations` for a workbench.
    package func recipeDir(workspaceDir: String) -> String {
        switch self {
        case .personal:
            URL(fileURLWithPath: workspaceDir).appendingPathComponent("automations", isDirectory: true).path
        case let .workbench(_, _, folder):
            URL(fileURLWithPath: folder)
                .appendingPathComponent(".watchtower", isDirectory: true)
                .appendingPathComponent("automations", isDirectory: true).path
        }
    }
}

/// How the New automation flow starts. A set `fixedScope` (a workbench
/// header's **New Automation…**) skips "What is it for?".
package struct AutomationNewFlow: Equatable, Sendable {
    package var fixedScope: AutomationScopeChoice?
    package var composerPrefill: String?

    package init(fixedScope: AutomationScopeChoice? = nil, composerPrefill: String? = nil) {
        self.fixedScope = fixedScope
        self.composerPrefill = composerPrefill
    }
}

/// What the editor panel edits: a saved automation (`review: true` is the
/// "Needs your confirmation" banner's **Review…**), or a new draft keyed by
/// its chat's context id.
package enum AutomationEditorTarget: Hashable, Sendable {
    case existing(Int64, review: Bool)
    case newDraft(contextID: String, scope: AutomationScopeChoice, startText: String?)

    /// The recipe text a new draft starts from; nil for a saved automation.
    package var startText: String? {
        switch self {
        case .existing: nil
        case let .newDraft(_, _, startText): startText
        }
    }
}

/// The Automations tab's right panel.
package enum AutomationsPanel: Equatable, Sendable {
    case empty
    case card(Int64)
    case new(AutomationNewFlow)
    case template(name: String, scope: AutomationScopeChoice)
    case editor(AutomationEditorTarget)
}

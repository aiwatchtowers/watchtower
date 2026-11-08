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
    /// **+ New Artifact…** from an Inbox folder: the folder the saved
    /// automation is routed to; nil (the root, or any other way in) sends
    /// no route.
    package var route: InboxNewArtifactRoute?

    package init(
        fixedScope: AutomationScopeChoice? = nil,
        composerPrefill: String? = nil,
        route: InboxNewArtifactRoute? = nil
    ) {
        self.fixedScope = fixedScope
        self.composerPrefill = composerPrefill
        self.route = route
    }
}

/// The Inbox folder a new automation goes to once saved (its id, and its
/// title for the lines that name it).
package struct InboxNewArtifactRoute: Equatable, Hashable, Sendable {
    package let folderID: Int64
    package let title: String

    package init(folderID: Int64, title: String) {
        self.folderID = folderID
        self.title = title
    }
}

/// A saved automation whose route did not land: the folder it was meant
/// for and why ("Saved. The folder was not created: <reason>").
package struct InboxRouteFailure: Equatable, Sendable {
    package let route: InboxNewArtifactRoute
    package let reason: String

    package init(route: InboxNewArtifactRoute, reason: String) {
        self.route = route
        self.reason = reason
    }
}

/// What the editor panel edits: a saved automation (a `startText` — an
/// Inbox proposal's recipe — replaces the loaded file in the buffer,
/// unsaved), or a new draft keyed by its chat's context id (a `startText`
/// is its starting text; nil is the chat's newest draft).
package enum AutomationEditorTarget: Hashable, Sendable {
    case existing(Int64, startText: String? = nil)
    case newDraft(contextID: String, scope: AutomationScopeChoice, startText: String?)
}

/// The editor's draft-column step (Inbox builder A, spec "The Look step"):
/// what the recipe collects, how its Inbox card looks, when it runs. Kept
/// per editor key in `AutomationEditorCenter`.
package enum AutomationEditorStep: String, CaseIterable, Hashable, Sendable {
    case collects
    case look
    case schedule

    /// The step picker's segment title.
    package var title: String {
        switch self {
        case .collects: "What it collects"
        case .look: "Look"
        case .schedule: "When it runs"
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

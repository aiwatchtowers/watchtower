import Foundation

/// How a new automation starts ("How do you want to start?"): the editor
/// chat, or one template by its `name`.
package enum AutomationStart: Hashable, Sendable {
    case words
    case template(String)
}

/// The choices of "How do you want to start?" for one scope.
package enum AutomationNewChoice {
    /// **Describe it in words** first, then the templates whose `scope`
    /// matches the chosen scope, in the CLI's order.
    package static func starts(templates: [AutomationTemplate], scope: AutomationScopeChoice) -> [AutomationStart] {
        let wanted = scope.workbenchID == nil ? "personal" : "workbench"
        return [.words] + templates.filter { $0.scope == wanted }.map { .template($0.name) }
    }
}

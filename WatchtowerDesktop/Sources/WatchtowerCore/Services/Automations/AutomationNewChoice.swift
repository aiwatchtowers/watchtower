import Foundation

/// How a new automation starts ("How do you want to start?"): the editor
/// chat, the chat on a watch recipe (`.watch`, Personal only), or one
/// template by its `name`.
package enum AutomationStart: Hashable, Sendable {
    case words
    case watch
    case template(String)
}

/// The choices of "How do you want to start?" for one scope.
package enum AutomationNewChoice {
    /// **Describe it in words** first, then (Personal only) the watch tile,
    /// then the templates whose `scope` matches the chosen scope, in the
    /// CLI's order. A watch recipe is Personal only (Go `track:scan` is
    /// `personalOnly`).
    package static func starts(templates: [AutomationTemplate], scope: AutomationScopeChoice) -> [AutomationStart] {
        let personal = scope.workbenchID == nil
        let wanted = personal ? "personal" : "workbench"
        let first: [AutomationStart] = personal ? [.words, .watch] : [.words]
        return first + templates.filter { $0.scope == wanted }.map { .template($0.name) }
    }
}

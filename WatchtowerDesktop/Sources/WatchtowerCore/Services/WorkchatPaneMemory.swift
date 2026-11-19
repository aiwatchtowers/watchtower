import Foundation
import Observation

/// The owner's toggles in a Workchat pane, kept in memory while the app runs
/// (#2065 spec §2, §3): nothing is persisted. A pane is `"session-<id>"` or, for a
/// subagent screen, `"session-<id>/<toolUseID>"`. Until the owner toggles, the
/// caller's default holds.
@MainActor
@Observable
package final class WorkchatPaneMemory {
    private var doneOpenByPane: [String: Bool] = [:]
    private var stepsOpenByPane: [String: Bool] = [:]

    package init() {}

    /// Whether the 👥 list's Done section is open in `pane`.
    package func doneOpen(_ pane: String, default value: Bool) -> Bool {
        doneOpenByPane[pane] ?? value
    }

    package func setDoneOpen(_ pane: String, _ open: Bool) {
        doneOpenByPane[pane] = open
    }

    /// Whether the live steps list is open in `pane`: open until the owner
    /// closes it (#2065 spec §3, C1).
    package func stepsOpen(_ pane: String) -> Bool {
        stepsOpenByPane[pane] ?? true
    }

    package func toggleSteps(_ pane: String) {
        stepsOpenByPane[pane] = !stepsOpen(pane)
    }
}

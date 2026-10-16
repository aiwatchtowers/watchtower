import Foundation

/// How often the Automations view model re-reads the tables (R-P3-8): fast
/// while a run is active, slower while the tab is visible, and only for the
/// sidebar badge otherwise.
package enum AutomationsPollPolicy {
    package static func interval(hasActiveRuns: Bool, tabVisible: Bool) -> Duration {
        if hasActiveRuns { return .seconds(2) }
        if tabVisible { return .seconds(10) }
        return .seconds(60)
    }
}

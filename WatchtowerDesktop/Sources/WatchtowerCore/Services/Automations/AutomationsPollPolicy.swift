import Foundation

/// How often the Automations view model re-reads the tables (R-P3-8): fast
/// while a run is active or a quick-run start is watched for its finish
/// notice (spec §12.7), slower while the tab is visible, and only for the
/// sidebar badge otherwise.
package enum AutomationsPollPolicy {
    package static func interval(hasActiveRuns: Bool, hasWatchedRuns: Bool, tabVisible: Bool) -> Duration {
        if hasActiveRuns || hasWatchedRuns { return .seconds(2) }
        if tabVisible { return .seconds(10) }
        return .seconds(60)
    }
}

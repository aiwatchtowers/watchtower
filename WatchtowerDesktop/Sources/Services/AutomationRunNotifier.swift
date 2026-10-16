import Foundation
import WatchtowerCore

/// The finish notice of a run started from the "Run Automation…" palette or
/// the tray (spec §12.7). No Settings toggle of its own: the owner asked for
/// it by starting the run (ruling R-P3-17); macOS notification permission
/// still applies. A click opens the run on its card (`NotificationDelegate.route`).
///
/// Main-actor through `AutomationRunNotifying`; its texts are `nonisolated`
/// for `NotificationService`.
final class AutomationRunNotifier: AutomationRunNotifying {
    typealias Send = (_ name: String, _ status: AutomationRunStatus, _ summary: String, _ error: String,
                      _ automationID: Int64, _ runID: Int64) -> Void

    private let send: Send

    init(send: @escaping Send = NotificationService.shared.sendAutomationRunFinished) {
        self.send = send
    }

    func runFinished(
        name: String,
        status: AutomationRunStatus,
        summary: String,
        error: String,
        automationID: Int64,
        runID: Int64
    ) {
        send(name, status, summary, error, automationID, runID)
    }

    nonisolated static let pushType = "automation_run"

    /// "<name> finished", "<name> failed", "<name> stopped: <status in words>".
    nonisolated static func title(name: String, status: AutomationRunStatus) -> String {
        switch status {
        case .succeeded: "\(name) finished"
        case .failed: "\(name) failed"
        default: "\(name) stopped: \(status.rawValue.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// The run's summary, else its error, else nothing.
    nonisolated static func body(summary: String, error: String) -> String {
        summary.isEmpty ? error : summary
    }

    /// One notice per run, even when posted twice.
    nonisolated static func identifier(runID: Int64) -> String {
        "automation-run-\(runID)"
    }

    nonisolated static func userInfo(automationID: Int64, runID: Int64) -> [String: Any] {
        [
            "type": pushType,
            NotificationForwarding.automationIDKey: automationID,
            NotificationForwarding.runIDKey: runID
        ]
    }
}

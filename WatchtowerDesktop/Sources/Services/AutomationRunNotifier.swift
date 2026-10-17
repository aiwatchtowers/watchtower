import Foundation
import WatchtowerCore

/// The finish notice of a run started from the "Run Automation…" palette or
/// the tray (spec §12.7), and the failure notices of `AutomationFailureWatch`
/// (#584). No Settings toggle of its own (ruling R-P3-17); macOS notification
/// permission still applies. A click opens the run on its card
/// (`NotificationDelegate.route`).
///
/// Main-actor through `AutomationRunNotifying`; its texts are `nonisolated`
/// for `NotificationService`.
final class AutomationRunNotifier: AutomationRunNotifying {
    typealias Send = (_ name: String, _ status: AutomationRunStatus, _ summary: String, _ error: String,
                      _ automationID: Int64, _ runID: Int64) -> Void
    typealias SendDisabled = (_ name: String, _ reason: String, _ automationID: Int64, _ runID: Int64) -> Void

    private let send: Send
    private let sendDisabled: SendDisabled

    init(
        send: @escaping Send = NotificationService.shared.sendAutomationRunFinished,
        sendDisabled: @escaping SendDisabled = NotificationService.shared.sendAutomationDisabled
    ) {
        self.send = send
        self.sendDisabled = sendDisabled
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

    func automationDisabled(name: String, reason: String, automationID: Int64, runID: Int64) {
        sendDisabled(name, reason, automationID, runID)
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

    /// "<name> was disabled".
    nonisolated static func disabledTitle(name: String) -> String {
        "\(name) was disabled"
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

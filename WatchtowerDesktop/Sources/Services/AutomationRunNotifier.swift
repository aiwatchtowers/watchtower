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
    typealias SendDisabled = (_ name: String, _ reason: String, _ automationID: Int64, _ runID: Int64?) -> Void
    /// A summary notice: its title and identifier.
    typealias SendSummary = (_ title: String, _ identifier: String) -> Void

    private let send: Send
    private let sendDisabled: SendDisabled
    private let sendSummary: SendSummary

    init(
        send: @escaping Send = NotificationService.shared.sendAutomationRunFinished,
        sendDisabled: @escaping SendDisabled = NotificationService.shared.sendAutomationDisabled,
        sendSummary: @escaping SendSummary = NotificationService.shared.sendAutomationsSummary
    ) {
        self.send = send
        self.sendDisabled = sendDisabled
        self.sendSummary = sendSummary
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

    func automationDisabled(name: String, reason: String, automationID: Int64, runID: Int64?) {
        sendDisabled(name, reason, automationID, runID)
    }

    func automationsFailed(count: Int) {
        sendSummary(Self.failuresTitle(count: count), "automation-failures")
    }

    func automationsDisabled(count: Int) {
        sendSummary(Self.disabledSummaryTitle(count: count), "automation-disables")
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

    /// "3 automations failed".
    nonisolated static func failuresTitle(count: Int) -> String {
        "\(count) automations failed"
    }

    /// "3 automations were disabled".
    nonisolated static func disabledSummaryTitle(count: Int) -> String {
        "\(count) automations were disabled"
    }

    /// The disabled notice: the run's identifier when it has one (it then
    /// replaces that run's finish notice), else one per automation.
    nonisolated static func disabledIdentifier(automationID: Int64, runID: Int64?) -> String {
        runID.map { identifier(runID: $0) } ?? "automation-disabled-\(automationID)"
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

    /// No run: the click opens the automation's card, or the tab without an
    /// automation either.
    nonisolated static func userInfo(automationID: Int64?, runID: Int64?) -> [String: Any] {
        guard let automationID else { return ["type": pushType] }
        guard let runID else { return ["type": pushType, NotificationForwarding.automationIDKey: automationID] }
        return userInfo(automationID: automationID, runID: runID)
    }
}

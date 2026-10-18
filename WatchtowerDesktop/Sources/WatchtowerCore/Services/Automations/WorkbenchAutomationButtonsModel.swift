import Foundation

/// The workbench header's automation buttons (spec §12.4): which show, what
/// a click does, how each looks. A click on a runnable button only queues
/// a run through `AutomationsViewModel.runNow` (`automations run <id>
/// --json`, AUTO-09); every other state opens something instead.
package enum WorkbenchAutomationButtonsModel {
    package enum Action: Equatable, Sendable {
        /// A `confirm: true` recipe: "Run <label>?" first.
        case confirmThenRun(label: String)
        case run
        /// A run in progress opens on its card; no second run starts.
        case openRun(Int64)
        /// The P3 confirmation sheet ("Confirm and enable" for a disabled recipe).
        case openConfirmSheet
        case openCard
    }

    /// The first `maxVisible` in the header, the rest in the "More" menu —
    /// both in the given (slug) order.
    package static func layout(
        _ buttons: [AutomationHeaderButton], maxVisible: Int = 4
    ) -> (visible: [AutomationHeaderButton], overflow: [AutomationHeaderButton]) {
        (Array(buttons.prefix(maxVisible)), Array(buttons.dropFirst(maxVisible)))
    }

    /// An active run wins over the recipe's state: it is what the owner
    /// wants to see, and a second click must not start another.
    package static func action(for button: AutomationHeaderButton) -> Action {
        if let runID = button.activeRunID { return .openRun(runID) }
        switch button.state {
        case .runnable: return button.confirm ? .confirmThenRun(label: button.label) : .run
        case .needsConfirmation: return .openConfirmSheet
        case .disabled, .parseError: return .openCard
        }
    }

    package static func isDimmed(_ button: AutomationHeaderButton) -> Bool {
        button.state != .runnable
    }

    /// What a click does instead of a run, or why the button is dimmed; nil
    /// for a runnable one (the view says "Run <label>"). An active run wins,
    /// as it does in `action(for:)`.
    package static func help(for button: AutomationHeaderButton) -> String? {
        if button.activeRunID != nil { return "Running — show the run" }
        return switch button.state {
        case .runnable: nil
        case .needsConfirmation: "Needs your confirmation"
        case .disabled: "Disabled"
        case .parseError: "Parse error"
        }
    }

    /// A queued, running or waiting run, or the run call still in flight.
    package static func isSpinning(_ button: AutomationHeaderButton, busy: Bool) -> Bool {
        button.activeRunID != nil || busy
    }

    package static func confirmTitle(label: String) -> String {
        "Run \(label)?"
    }

    /// Carries out a click. `.confirmThenRun` does nothing here: the view
    /// shows the dialog, whose **Run** performs `.run`. `open` shows the
    /// Automations tab on an automation's card, with a run's steps open.
    /// False only when the run call failed (`vm.lastError` says why) or
    /// another call on the automation was in flight.
    @MainActor
    @discardableResult
    package static func perform(
        _ action: Action,
        on button: AutomationHeaderButton,
        vm: AutomationsViewModel,
        open: (_ automationID: Int64, _ runID: Int64?) -> Void
    ) async -> Bool {
        switch action {
        case .confirmThenRun:
            break
        case .run:
            return await vm.runNow(button.automationID)
        case let .openRun(runID):
            open(button.automationID, runID)
        case .openConfirmSheet:
            vm.pendingConfirmID = button.automationID
            open(button.automationID, nil)
        case .openCard:
            open(button.automationID, nil)
        }
        return true
    }
}

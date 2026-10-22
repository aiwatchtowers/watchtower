import Foundation
import Observation

/// A built-in's card (spec §5): which text runs (the shipped one, the owner's
/// confirmed or unconfirmed copy, or the shipped one because the copy cannot
/// be used), the "Built-in version updated" banner with **Show changes**,
/// the Costs line, **Reset to built-in** with its inline confirm row, and
/// **Run Now**. Everything is read from `automations show --json`'s
/// `builtin` block; every write goes through the CLI.
@MainActor
@Observable
package final class BuiltinAutomationCardModel {
    package enum CardState: Equatable, Sendable {
        /// The shipped text runs.
        case shipped
        /// The owner's copy runs.
        case ownCopyConfirmed
        /// The owner's copy is waiting for the owner's confirmation.
        case ownCopyUnconfirmed
        /// The owner's copy file cannot be used (why); the shipped text runs.
        case copyError(String)
    }

    nonisolated package static let noCostLine = "No AI cost in the last 7 days"
    nonisolated package static let costNotReportedLine = "Cost not reported"
    nonisolated package static func costLine(_ usd: Double) -> String {
        String(format: "About $%.2f in the last 7 days", usd)
    }

    /// The indexed row; the owner of the card replaces it when the row changes.
    package var automation: Automation
    /// The last successful `show`'s `builtin` block (kept when a reload fails).
    package var detail: BuiltinAutomationDetail? { shown?.builtin }
    package private(set) var loadError: String?
    /// The inline "Reset — your changes are lost" row is shown.
    package private(set) var resetConfirming = false
    package var showingChanges = false
    package private(set) var isWorking = false
    /// Why the card's last Turn On/Off, When save or Save and Turn On did not
    /// land (those go through the app's feature manager and config, not
    /// this model's CLI); nil after the next success.
    package var actionError: String?
    /// The last **Run Now** was queued: it runs at the next sync.
    package private(set) var runQueued = false
    /// The last `show`: its `needs_confirmation` and `recipe_text` win over the row's.
    private var shown: AutomationDetail?
    /// The `loadError` the last failed Run Now set: its success clears only that one.
    private var runNowError: String?

    @ObservationIgnored private let cli: AutomationsCLI

    package init(automation: Automation, cli: AutomationsCLI) {
        self.automation = automation
        self.cli = cli
    }

    package var cardState: CardState {
        if let copyError = detail?.copyError, !copyError.isEmpty { return .copyError(copyError) }
        guard detail?.overridden ?? automation.overridden else { return .shipped }
        return (shown?.needsConfirmation ?? automation.needsConfirmation) ? .ownCopyUnconfirmed : .ownCopyConfirmed
    }

    /// "Built-in version updated": the owner's copy was made from an older shipped text.
    package var updateBanner: Bool {
        guard let detail else { return false }
        return detail.overridden && detail.updateAvailable
    }

    package var costsLine: String {
        guard let costs = detail?.costs, costs.reported else { return Self.costNotReportedLine }
        return costs.usd > 0 ? Self.costLine(costs.usd) : Self.noCostLine
    }

    /// The shipped text → the owner's copy, only while **Show changes** is on.
    package var changes: OwnerAskSnapshotDiff? {
        guard showingChanges, let detail, detail.overridden else { return nil }
        return OwnerAskSnapshotDiff(previous: detail.shippedText, current: shown?.recipeText ?? automation.recipeText)
    }

    package func load() async {
        do {
            shown = try await cli.show(automation.id)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            loadError = AutomationsViewModel.message(for: error)
        }
    }

    package func beginReset() {
        resetConfirming = true
    }

    package func cancelReset() {
        resetConfirming = false
    }

    /// Resets to the shipped text. The confirm row stays until the CLI
    /// succeeds; a failure is kept in `loadError`.
    package func confirmReset() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await cli.reset(automation.id)
            resetConfirming = false
            showingChanges = false
            loadError = nil
        } catch {
            loadError = AutomationsViewModel.message(for: error)
            return
        }
        await load()
    }

    /// Queues a manual run; it runs at the built-in's slot in the next sync
    /// cycle (the CLI wakes the daemon).
    package func runNow() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        runQueued = false
        do {
            _ = try await cli.run(automation.id)
            runQueued = true
            if let runNowError, loadError == runNowError { loadError = nil }
            runNowError = nil
        } catch {
            let message = AutomationsViewModel.message(for: error)
            loadError = message
            runNowError = message
        }
    }
}

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
    /// No cost reported, but tokens were (the pipelines report no cost).
    nonisolated package static func tokensLine(_ tokens: Int64) -> String {
        "\(tokens.formatted(.number.locale(Locale(identifier: "en_US")))) tokens in the last 7 days (cost not reported)"
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
    /// The last **Run Now** was queued and has not finished yet: it runs at
    /// the next sync. Cleared once the row shows that run finished
    /// (`observe(_:)`).
    package var runQueued: Bool { queuedRunID != nil }
    /// The When fields the owner changed, by config key (only the changed ones).
    package var parameterEdits: [String: String] = [:]
    /// The run the last Run Now queued, until the list shows it finished.
    private var queuedRunID: Int64?
    /// The last `show`: its `needs_confirmation` and `recipe_text` win over the row's.
    private var shown: AutomationDetail?
    /// The `loadError` the last failed Run Now set: its success clears only that one.
    private var runNowError: String?

    @ObservationIgnored private let cli: AutomationsCLI

    package init(automation: Automation, cli: AutomationsCLI) {
        self.automation = automation
        self.cli = cli
    }

    /// The recipe description under the header: the last `show`'s, else the row's.
    package var lede: String {
        if let text = shown?.description.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        let recipe = [shown?.recipeText, automation.recipeText, detail?.shippedText]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return AutomationRowSummary.description(recipeText: recipe)
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
        guard let costs = detail?.costs else { return Self.costNotReportedLine }
        guard costs.reported else { return costs.tokens > 0 ? Self.tokensLine(costs.tokens) : Self.costNotReportedLine }
        return costs.usd > 0 ? Self.costLine(costs.usd) : Self.noCostLine
    }

    /// The shipped text → the owner's copy, only while **Show changes** is on.
    package var changes: OwnerAskSnapshotDiff? {
        guard showingChanges, let detail, detail.overridden else { return nil }
        return OwnerAskSnapshotDiff(previous: detail.shippedText, current: shown?.recipeText ?? automation.recipeText)
    }

    /// The newest list row: its automation, and whether the run Run Now
    /// queued has finished (the newest finished run is that one or later).
    package func observe(_ item: AutomationListItem) {
        automation = item.automation
        if let queued = queuedRunID, let last = item.lastRun?.id, last >= queued { queuedRunID = nil }
    }

    // MARK: - When fields

    /// Some field differs from the value `show` read.
    package var parametersChanged: Bool {
        (detail?.parameters ?? []).contains { parameter in
            parameterEdits[parameter.key].map { $0 != parameter.value } ?? false
        }
    }

    /// The first edited field that is not a valid value, said for the owner:
    /// an hour is 0–23, a clock is HH:MM, a count a whole number from 0, an
    /// interval a whole number of hours from 1; and
    /// the backlog's at-least never above its at-most.
    package var invalidParameter: String? {
        let parameters = detail?.parameters ?? []
        for parameter in parameters {
            guard let value = parameterEdits[parameter.key] else { continue }
            switch parameter.kind {
            case .hour:
                if Int(value).map({ (0...23).contains($0) }) != true { return "\(parameter.label): pick an hour" }
            case .clock:
                if !Self.isClock(value) { return "\(parameter.label): use HH:MM, for example 09:00" }
            case .count:
                if !Self.isCount(value) { return "\(parameter.label): use a whole number, 0 or more" }
            case .interval:
                if !Self.isInterval(value) { return "\(parameter.label): use a whole number of hours, 1 or more" }
            case .dictionary:
                // The table is edited by its own editor, never as a field value.
                continue
            }
        }
        let shown = { (key: String) in parameters.first { $0.key == key } }
        if let least = shown(Self.minBacklogKey), let most = shown(Self.maxBacklogKey),
           let low = Int(parameterEdits[least.key] ?? least.value),
           let high = Int(parameterEdits[most.key] ?? most.value), low > high {
            return "\(least.label) can't be more than \(most.label.lowercased())"
        }
        return nil
    }

    /// The backlog bounds' config keys (twin: Go `builtin` Morning brief params).
    nonisolated package static let minBacklogKey = "day_plan.min_backlog"
    nonisolated package static let maxBacklogKey = "day_plan.max_backlog"

    /// Idea finder's interval (twin: Go `builtin` Idea finder param).
    nonisolated package static let ideasIntervalKey = "ideas.mine_interval_hours"
    /// An interval stepper's range, in hours (the old Settings stepper's;
    /// Go has no maximum, so a larger stored value shows clamped).
    nonisolated package static let intervalRange = 1...48

    /// A count field's text: a whole number, 0 or more.
    nonisolated package static func isCount(_ text: String) -> Bool {
        Int(text).map { $0 >= 0 } ?? false
    }

    /// An interval field's text: a whole number of hours, 1 or more.
    nonisolated package static func isInterval(_ text: String) -> Bool {
        Int(text).map { $0 >= 1 } ?? false
    }

    /// "HH:MM", 00:00–23:59.
    nonisolated package static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    /// The When **Save**: the changed fields through `write` (the app's
    /// config writer and daemon restart). One card write at a time: a press
    /// while another runs is ignored.
    package func saveParameters(_ write: ([String: String]) async -> String?) async {
        guard !isWorking, parametersChanged, invalidParameter == nil else { return }
        isWorking = true
        defer { isWorking = false }
        let values = parameterEdits
        actionError = await write(values)
        if actionError == nil { parameterEdits = [:] }
        await load()
    }

    // MARK: - On/off

    /// **Turn On** / **Turn Off** (and **Save and Turn On**): the built-in's
    /// feature ids through `write` (the app's feature manager and daemon
    /// restart), then a reload. One card write at a time: a press while
    /// another runs is ignored. With no `show` yet it is read first.
    package func setEnabled(_ on: Bool, _ write: ([String], Bool) async -> String?) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        if detail == nil { await load() }
        guard let ids = detail?.featureIDs, !ids.isEmpty else {
            actionError = loadError ?? Self.unknownFeatures
            return
        }
        actionError = await write(ids, on)
        await load()
    }

    nonisolated package static let unknownFeatures = "Its features are not known, so it was not turned on or off."

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
        queuedRunID = nil
        do {
            queuedRunID = try await cli.run(automation.id).runID
            if let runNowError, loadError == runNowError { loadError = nil }
            runNowError = nil
        } catch {
            let message = AutomationsViewModel.message(for: error)
            loadError = message
            runNowError = message
        }
    }
}

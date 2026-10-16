import Foundation
import GRDB
import Observation

/// Posts the finish notice of a run started from the "Run Automation…"
/// palette or the tray (spec §12.7). Implemented over `NotificationService`
/// in plan Task 15; `NoopAutomationRunNotifier` until then.
@MainActor
package protocol AutomationRunNotifying {
    func runFinished(
        name: String,
        status: AutomationRunStatus,
        summary: String,
        error: String,
        automationID: Int64,
        runID: Int64
    )
}

package struct NoopAutomationRunNotifier: AutomationRunNotifying {
    package init() {}

    package func runFinished(
        name: String,
        status: AutomationRunStatus,
        summary: String,
        error: String,
        automationID: Int64,
        runID: Int64
    ) {}
}

/// Quick run (spec §12.7): the rows of the "Run Automation…" palette (⌃⌘R)
/// and the tray's "Run automation ▸", what activating one does, and the
/// finish watch of the runs started there. Owned by `AppState`, so a watch
/// survives a closed palette and navigation. A run goes through
/// `automations run <id> --json` like the card's **Run now**; a dimmed row
/// runs nothing (Review Focus 8). The daemon writes the runs from another
/// process, so the watch rides `AutomationsViewModel`'s poll, which calls
/// `checkWatched()` each tick and polls fast while `hasWatchedRuns`.
@MainActor
@Observable
package final class QuickRunCenter {
    package enum Origin: Equatable, Sendable {
        case palette, tray
    }

    package enum Outcome: Equatable, Sendable {
        case started(runID: Int64)
        case coalesced(runID: Int64)
        /// A `confirm: true` recipe: `pendingConfirm` is set, nothing ran.
        case askFirst
        /// An unconfirmed recipe: its confirmation sheet opens on the tab.
        case openedConfirmation
        /// A disabled or unreadable recipe: its card opens.
        case openedCard(Int64)
        /// A recipe with a run in progress: that run opens on its card.
        case openedRun(Int64)
        case refused(String)
    }

    /// A run started here, watched until it ends.
    package struct WatchedRun: Equatable, Sendable {
        package let automationID: Int64
        package let name: String
        package let origin: Origin
    }

    nonisolated package static let featureOffMessage = "Automations are turned off in Settings → Features"

    package private(set) var rows: [QuickRunRow] = []
    /// The `confirm: true` recipe whose "Run “<name>”?" sheet is up.
    package private(set) var pendingConfirm: QuickRunRow?
    /// Where `pendingConfirm` came from: the palette's sheet shows only a
    /// palette one (the tray asks in its own alert).
    package private(set) var pendingOrigin: Origin = .palette
    /// Keyed by run id.
    package private(set) var watched: [Int64: WatchedRun] = [:]
    package var hasWatchedRuns: Bool { !watched.isEmpty }
    /// The last refusal (the CLI's stderr) or failed read.
    package var lastError: String?
    /// Shows the Automations tab; `AppState` points it at its navigation.
    @ObservationIgnored package var showAutomationsTab: () -> Void = {}

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let viewModel: AutomationsViewModel
    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let notifier: AutomationRunNotifying
    @ObservationIgnored private let isFeatureEnabled: () -> Bool

    /// Registers itself as `viewModel`'s run watcher (held weakly there).
    package init(
        dbPool: DatabasePool,
        viewModel: AutomationsViewModel,
        cli: AutomationsCLI,
        notifier: AutomationRunNotifying,
        isFeatureEnabled: @escaping () -> Bool
    ) {
        self.dbPool = dbPool
        self.viewModel = viewModel
        self.cli = cli
        self.notifier = notifier
        self.isFeatureEnabled = isFeatureEnabled
        viewModel.runWatcher = self
    }

    // MARK: - Rows

    /// Re-reads the list and the workbench names (on opening the palette or the tray menu).
    package func reload() {
        viewModel.refresh()
        rebuildRows()
    }

    private func rebuildRows() {
        do {
            let names = try dbPool.read { db in
                Dictionary(try WorkbenchQueries.fetchAll(db).map { ($0.id, $0.name) }) { first, _ in first }
            }
            rows = QuickRunCatalog.rows(viewModel.items, workbenchNames: names)
        } catch {
            lastError = "Could not read workbenches: \(error.localizedDescription)"
            rows = QuickRunCatalog.rows(viewModel.items, workbenchNames: [:])
        }
    }

    // MARK: - Activate

    /// ↩ or a click on a row. Only a runnable row runs, and a `confirm: true`
    /// one only after `confirmRun()`; a dimmed row opens its confirmation
    /// sheet or its card instead.
    package func activate(_ row: QuickRunRow, origin: Origin) async -> Outcome {
        guard isFeatureEnabled() else { return refuse(Self.featureOffMessage) }
        switch row.state {
        case .runnable:
            guard !row.asksFirst else {
                pendingConfirm = row
                pendingOrigin = origin
                return .askFirst
            }
            return await start(row, origin: origin)
        case let .running(runID):
            viewModel.open(automationID: row.id, runID: runID)
            showAutomationsTab()
            return .openedRun(runID)
        case .needsConfirmation:
            viewModel.open(automationID: row.id, runID: nil)
            viewModel.pendingConfirmID = row.id
            showAutomationsTab()
            return .openedConfirmation
        case .disabled, .parseError:
            viewModel.open(automationID: row.id, runID: nil)
            showAutomationsTab()
            return .openedCard(row.id)
        }
    }

    /// **Run** in the "Run “<name>”?" sheet. A refusal keeps the sheet up with `lastError`.
    package func confirmRun() async {
        guard let row = pendingConfirm else { return }
        let outcome = await start(row, origin: pendingOrigin)
        if case .refused = outcome { return }
        if pendingConfirm == row { pendingConfirm = nil }
    }

    /// **Cancel** in the sheet: nothing runs.
    package func cancelConfirm() {
        pendingConfirm = nil
        lastError = nil
    }

    /// "Open Automations" in the palette's Other section.
    package func openAutomations() {
        showAutomationsTab()
    }

    private func start(_ row: QuickRunRow, origin: Origin) async -> Outcome {
        guard isFeatureEnabled() else { return refuse(Self.featureOffMessage) }
        lastError = nil
        do {
            let result = try await cli.run(row.id)
            watched[result.runID] = WatchedRun(automationID: row.id, name: row.name, origin: origin)
            viewModel.noteRunStarted()
            rebuildRows()
            return result.coalesced ? .coalesced(runID: result.runID) : .started(runID: result.runID)
        } catch {
            return refuse(AutomationsViewModel.message(for: error))
        }
    }

    private func refuse(_ message: String) -> Outcome {
        lastError = message
        return .refused(message)
    }

    // MARK: - Finish watch

    /// Reads the watched runs by id (not the list's last run, which may
    /// already be a newer one): an ended run posts its notice once and is
    /// dropped; a run whose row is gone (its automation deleted) is dropped
    /// without a notice.
    package func checkWatched() async {
        guard !watched.isEmpty else { return }
        let ids = Array(watched.keys)
        let runs: [AutomationRun]
        do {
            runs = try await dbPool.read { db in try AutomationQueries.fetchRuns(db, ids: ids) }
        } catch {
            lastError = "Could not read automation runs: \(error.localizedDescription)"
            return
        }
        let byID = Dictionary(runs.map { ($0.id, $0) }) { first, _ in first }
        // An overlapping check may have handled an id while this one read.
        for id in ids {
            guard let entry = watched[id] else { continue }
            guard let run = byID[id] else {
                watched[id] = nil
                continue
            }
            guard !run.status.isActive else { continue }
            watched[id] = nil
            notifier.runFinished(name: entry.name, status: run.status, summary: run.summary, error: run.error,
                                 automationID: entry.automationID, runID: id)
        }
    }
}

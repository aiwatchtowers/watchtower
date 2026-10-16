import Foundation
import GRDB
import Observation

/// The Automations tab and its sidebar badge (spec §12.1). Owned by
/// `AppState`, so a run, a dry run or a delete started on the tab survives
/// navigating away. Reads go through `AutomationQueries`; every write goes
/// through `AutomationsCLI` (spec §9.6). The daemon writes the tables from
/// another process, which `ValueObservation` never sees, so one stored poll
/// re-reads them at `AutomationsPollPolicy`'s cadence, plus a refresh on
/// appear and after every CLI call.
@MainActor
@Observable
package final class AutomationsViewModel {
    /// A dry run's outcome on the card, kept per automation id.
    package enum DryRunState: Equatable, Sendable {
        case running
        case done(runID: Int64, lines: [String], tokens: Int64, status: String)
        case failed(String)
    }

    /// The CLI call in flight for an automation; at most one at a time.
    package enum Operation: Equatable, Sendable {
        case running, dryRunning, enabling, deleting, cancelling
    }

    /// How many runs the card's history shows.
    nonisolated package static let runHistoryLimit = 20
    /// How many latest reports the card shows.
    nonisolated package static let reportLimit = 5

    package private(set) var items: [AutomationListItem] = []
    /// The sidebar badge: automations needing confirmation + runs waiting on the owner.
    package private(set) var attentionCount = 0
    /// Unread inbox outputs — the Inbox badge's automation share. The daemon
    /// writes them from another process, so this poll is what notices them.
    package private(set) var inboxOutputCount = 0
    /// Runs when `inboxOutputCount` changes, so the Inbox sidebar badge
    /// (`SidebarCountsViewModel`, which sees only this process's writes)
    /// re-reads.
    @ObservationIgnored package var onInboxOutputCountChanged: (() -> Void)?
    /// The automation whose card is open. Set it through `select(_:)` to load the card.
    package var selectedID: Int64?
    /// Run ids whose steps are shown in the history.
    package private(set) var expandedRuns: Set<Int64> = []
    /// Keyed by automation id.
    package private(set) var runs: [Int64: [AutomationRun]] = [:]
    /// Keyed by run id.
    package private(set) var steps: [Int64: [AutomationRunStep]] = [:]
    /// Keyed by automation id.
    package private(set) var reports: [Int64: [AutomationOutput]] = [:]
    /// Keyed by automation id.
    package private(set) var grants: [Int64: [AutomationToolGrant]] = [:]
    /// `show --json` of an opened card (description, `widening`, `changes`), keyed by automation id.
    package private(set) var details: [Int64: AutomationDetail] = [:]
    /// Why the last `show --json` failed, keyed by automation id.
    package private(set) var detailErrors: [Int64: String] = [:]
    /// Keyed by automation id.
    package private(set) var dryRuns: [Int64: DryRunState] = [:]
    /// Keyed by automation id.
    package private(set) var busy: [Int64: Operation] = [:]
    /// The last failed CLI call's stderr, or a failed read.
    package var lastError: String?
    /// The "New automation" chat's draft: its conversation is keyed by this
    /// id, so a half-written draft survives closing the sheet. A new one
    /// starts after a draft is saved (`startNewDraft`).
    package private(set) var newDraftID = UUID().uuidString

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tabVisible = false
    /// The run last opened as the newest, per automation id: it opens once.
    @ObservationIgnored private var expandedAsNewest: [Int64: Int64] = [:]

    package init(
        dbPool: DatabasePool,
        cli: AutomationsCLI,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.cli = cli
        self.now = now
        self.sleep = sleep
    }

    /// The next **+ New** opens a fresh chat; the saved draft's stays on disk.
    package func startNewDraft() {
        newDraftID = UUID().uuidString
    }

    // MARK: - Poll

    /// Reads once and starts the poll. Idempotent.
    package func start() {
        guard pollTask == nil else { return }
        refresh()
        schedulePoll()
    }

    /// Stops the poll (app quit). In-flight CLI calls finish on their own.
    package func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The tab appeared or disappeared: the poll's cadence follows (10 s
    /// while visible, 60 s for the badge only), and an appearing tab reads now.
    package func setTabVisible(_ visible: Bool) {
        guard visible != tabVisible else { return }
        tabVisible = visible
        if visible { refresh() }
        if pollTask != nil { schedulePoll() }
    }

    private var hasActiveRuns: Bool {
        items.contains { $0.activeRun != nil }
    }

    private var pollInterval: Duration {
        AutomationsPollPolicy.interval(hasActiveRuns: hasActiveRuns, tabVisible: tabVisible)
    }

    /// (Re)starts the loop: sleep for the interval the current state calls
    /// for, then read. Restarting makes a new cadence take effect at once.
    private func schedulePoll() {
        pollTask?.cancel()
        let sleep = self.sleep
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    // MARK: - Reads

    /// Re-reads the list, the badge and the open card.
    package func refresh() {
        do {
            let selected = selectedID
            let expanded = expandedRuns
            let date = now()
            let snapshot = try dbPool.read { db in
                try Snapshot.read(db, now: date, selected: selected, expanded: expanded)
            }
            apply(snapshot)
        } catch {
            lastError = "Could not read automations: \(error.localizedDescription)"
        }
    }

    private struct Snapshot {
        var items: [AutomationListItem]
        var attentionCount: Int
        var inboxOutputCount: Int
        var card: Card?
        var steps: [Int64: [AutomationRunStep]]

        struct Card {
            let automationID: Int64
            let runs: [AutomationRun]
            let reports: [AutomationOutput]
            let grants: [AutomationToolGrant]
        }

        static func read(_ db: Database, now: Date, selected: Int64?, expanded: Set<Int64>) throws -> Self {
            var card: Card?
            if let selected {
                card = Card(
                    automationID: selected,
                    runs: try AutomationQueries.fetchRuns(db, automationID: selected, limit: runHistoryLimit),
                    reports: try AutomationQueries.fetchReports(db, automationID: selected, limit: reportLimit),
                    grants: try AutomationQueries.fetchGrants(db, automationID: selected)
                )
            }
            var steps: [Int64: [AutomationRunStep]] = [:]
            for runID in expanded {
                steps[runID] = try AutomationQueries.fetchSteps(db, runID: runID)
            }
            return Self(
                items: try AutomationQueries.fetchList(db, now: now),
                attentionCount: try AutomationQueries.attentionCount(db),
                inboxOutputCount: try AutomationQueries.inboxOutputCount(db),
                card: card,
                steps: steps
            )
        }
    }

    private func apply(_ snapshot: Snapshot) {
        items = snapshot.items
        attentionCount = snapshot.attentionCount
        if snapshot.inboxOutputCount != inboxOutputCount {
            inboxOutputCount = snapshot.inboxOutputCount
            onInboxOutputCountChanged?()
        }
        for (runID, runSteps) in snapshot.steps { steps[runID] = runSteps }
        // The selection may have moved while the read ran; keep only what matches it.
        if let card = snapshot.card, card.automationID == selectedID {
            runs[card.automationID] = card.runs
            reports[card.automationID] = card.reports
            grants[card.automationID] = card.grants
        }
    }

    // MARK: - Selection

    /// Opens an automation's card (nil closes it) and reads it.
    package func select(_ id: Int64?) {
        if id != selectedID { expandedRuns = [] }
        selectedID = id
        if id != nil { refresh() }
    }

    /// Shows or hides a run's steps in the history.
    package func toggleRun(_ runID: Int64) {
        if expandedRuns.remove(runID) == nil {
            expandedRuns.insert(runID)
            refresh()
        }
    }

    /// The card's newest run opens expanded (mockup 1) the first time it is
    /// the newest; the owner's collapse then sticks across card appearances.
    package func expandNewestRun(_ id: Int64) {
        guard let newest = runs[id]?.first?.id, expandedAsNewest[id] != newest else { return }
        expandedAsNewest[id] = newest
        if !expandedRuns.contains(newest) { toggleRun(newest) }
    }

    /// Navigation into a card, optionally with one run's steps open (a
    /// notification, an Inbox card's label).
    package func open(automationID: Int64, runID: Int64?) {
        if automationID != selectedID { expandedRuns = [] }
        selectedID = automationID
        if let runID { expandedRuns.insert(runID) }
        refresh()
    }

    /// Reads the card's `show --json`. The card calls it on open and whenever
    /// the recipe's hashes change; a failure keeps the previous detail. A
    /// cancelled read (a fast row switch, leaving the tab) is not a failure.
    package func loadDetail(_ id: Int64) async {
        do {
            details[id] = try await cli.show(id)
            detailErrors[id] = nil
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            detailErrors[id] = Self.message(for: error)
        }
    }

    // MARK: - CLI operations

    package func runNow(_ id: Int64) async {
        await perform(.running, on: id) { cli in _ = try await cli.run(id) }
    }

    /// Repeats a failed (or interrupted) run: `automations run <id> --rerun-of <run>`.
    package func rerun(_ id: Int64, runID: Int64) async {
        await perform(.running, on: id) { cli in _ = try await cli.run(id, rerunOf: runID) }
    }

    /// Runs `automations dry-run` (the owner's click; it works for an
    /// unconfirmed recipe too) and renders the returned run's steps.
    package func dryRun(_ id: Int64) async {
        guard busy[id] == nil else { return }
        busy[id] = .dryRunning
        dryRuns[id] = .running
        do {
            let result = try await cli.dryRun(id)
            let runSteps = try await dbPool.read { db in try AutomationQueries.fetchSteps(db, runID: result.runID) }
            dryRuns[id] = .done(
                runID: result.runID,
                lines: DryRunPresentation.lines(steps: runSteps),
                tokens: result.inputTokens + result.outputTokens,
                status: result.status
            )
        } catch {
            dryRuns[id] = .failed(Self.message(for: error))
        }
        busy[id] = nil
        afterCLICall()
    }

    package func setEnabled(_ id: Int64, _ on: Bool) async {
        await perform(.enabling, on: id) { cli in try await cli.setEnabled(id, on) }
    }

    /// Deletes the recipe; the card's state goes only once the CLI succeeded.
    package func delete(_ id: Int64) async {
        let deleted = await perform(.deleting, on: id) { cli in try await cli.delete(id) }
        guard deleted else { return }
        if selectedID == id { select(nil) }
        runs[id] = nil
        reports[id] = nil
        grants[id] = nil
        details[id] = nil
        detailErrors[id] = nil
        dryRuns[id] = nil
        expandedAsNewest[id] = nil
    }

    package func cancel(runID: Int64) async {
        let owner = items.first { $0.activeRun?.id == runID }?.id
            ?? runs.first { $0.value.contains { $0.id == runID } }?.key
        guard let owner else {
            await call { cli in try await cli.cancel(runID: runID) }
            return
        }
        await perform(.cancelling, on: owner) { cli in try await cli.cancel(runID: runID) }
    }

    /// One CLI call marked busy on `id`; false when it failed (or another
    /// call on `id` is in flight). A failure leaves the list as it was and
    /// puts the CLI's stderr in `lastError`.
    @discardableResult
    private func perform(
        _ operation: Operation, on id: Int64, _ body: (AutomationsCLI) async throws -> Void
    ) async -> Bool {
        guard busy[id] == nil else { return false }
        busy[id] = operation
        defer { busy[id] = nil }
        return await call(body)
    }

    @discardableResult
    private func call(_ body: (AutomationsCLI) async throws -> Void) async -> Bool {
        var succeeded = true
        do {
            try await body(cli)
        } catch {
            lastError = Self.message(for: error)
            succeeded = false
        }
        afterCLICall()
        return succeeded
    }

    /// A CLI call may have started a run: read now, and restart the poll so
    /// an active run gets the fast cadence at once.
    private func afterCLICall() {
        refresh()
        if pollTask != nil { schedulePoll() }
    }

    private static func message(for error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "watchtower exited with code \(code)" : text
        }
        return error.localizedDescription
    }
}

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
    /// Automations needing confirmation + runs waiting on the owner.
    package private(set) var attentionCount = 0
    /// Automations whose newest run failed and whose card was not opened
    /// since (`AutomationFailureWatch`); 0 without a watch.
    package private(set) var unseenFailureCount = 0
    /// The sidebar badge.
    package var badgeCount: Int { attentionCount + unseenFailureCount }
    /// Unread inbox outputs — the Inbox badge's automation share. The daemon
    /// writes them from another process, so this poll is what notices them.
    package private(set) var inboxOutputCount = 0
    /// The workbench headers' `trigger.button` recipes, keyed by workbench
    /// id (spec §12.4); read with the list, so the poll keeps them current.
    private var headerButtonsByProject: [Int64: [AutomationHeaderButton]] = [:]
    /// Runs when `inboxOutputCount` changes, so the Inbox sidebar badge
    /// (`SidebarCountsViewModel`, which sees only this process's writes)
    /// re-reads.
    @ObservationIgnored package var onInboxOutputCountChanged: (() -> Void)?
    /// The automation whose card is open. Set it through `select(_:)` to load the card.
    package var selectedID: Int64?
    /// What the right panel shows: the empty state, a card, the New flow, a
    /// template, or the editor. `select(_:)` and `showCard(_:)` set a card,
    /// `showNew(_:)` the New flow, `showEditor(_:composerPrefill:)` the editor.
    package var panel: AutomationsPanel = .empty
    /// The New flow's composer text for the editor it continues to: put into
    /// an empty chat once; any other panel drops it.
    package private(set) var composerPrefill: String?
    /// New automation chats with a draft on disk (`AutomationDraftRows`),
    /// read with the list.
    package private(set) var draftRows: [AutomationDraftRow] = []
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
    /// `lastError` came from the list's own read: the next read that works
    /// clears it (a CLI failure stays until dismissed).
    @ObservationIgnored private var lastErrorIsRead = false
    // MARK: Templates

    /// `automations templates --json`; empty while the CLI has none (or P6's
    /// subcommand does not exist yet).
    package private(set) var templates: [AutomationTemplate] = []
    package private(set) var templatesLoading = false
    /// Why the template list could not be read; nil for "no templates".
    package private(set) var templatesError: String?
    /// An unconfirmed recipe picked in the "Run Automation…" palette or a
    /// header button: the tab opens its card (whose banner leads to the
    /// editor) through `consumePendingConfirm()`; held here so it opens when
    /// the tab appears.
    package var pendingConfirmID: Int64?
    /// Quick run's finish watch (`QuickRunCenter` registers itself): each
    /// poll tick checks it, and the poll stays fast while it watches a run.
    @ObservationIgnored package weak var runWatcher: QuickRunCenter?

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let failureWatch: AutomationFailureWatch?
    /// The app is active with a visible key window: only then does an open
    /// card count as seen.
    @ObservationIgnored private let isOwnerLooking: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tabVisible = false
    /// The run last opened as the newest, per automation id: it opens once.
    @ObservationIgnored private var expandedAsNewest: [Int64: Int64] = [:]

    package init(
        dbPool: DatabasePool,
        cli: AutomationsCLI,
        failureWatch: AutomationFailureWatch? = nil,
        isOwnerLooking: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.cli = cli
        self.failureWatch = failureWatch
        self.isOwnerLooking = isOwnerLooking
        self.now = now
        self.sleep = sleep
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
        AutomationsPollPolicy.interval(
            hasActiveRuns: hasActiveRuns,
            hasWatchedRuns: runWatcher?.hasWatchedRuns ?? false,
            tabVisible: tabVisible
        )
    }

    /// (Re)starts the loop: sleep for the interval the current state calls
    /// for, then read and check quick run's watched runs. Restarting makes
    /// a new cadence take effect at once.
    private func schedulePoll() {
        pollTask?.cancel()
        let sleep = self.sleep
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
                await self.runWatcher?.checkWatched()
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
            let failures = failureWatch != nil
            let databasePath = dbPool.path
            let snapshot = try dbPool.read { db in
                try Snapshot.read(db, now: date, selected: selected, expanded: expanded, failures: failures,
                                  databasePath: databasePath)
            }
            apply(snapshot)
            if lastErrorIsRead {
                lastError = nil
                lastErrorIsRead = false
            }
        } catch {
            lastError = "Could not read automations: \(error.localizedDescription)"
            lastErrorIsRead = true
        }
    }

    private struct Snapshot {
        var items: [AutomationListItem]
        var attentionCount: Int
        var inboxOutputCount: Int
        var headerButtons: [Int64: [AutomationHeaderButton]]
        /// `AutomationQueries.newestEndedRuns` and `allIDs`, read only with a failure watch.
        var endedRuns: [Int64: AutomationRun]
        var allIDs: Set<Int64>
        var card: Card?
        var steps: [Int64: [AutomationRunStep]]
        var drafts: [AutomationDraftRow]

        struct Card {
            let automationID: Int64
            let runs: [AutomationRun]
            let reports: [AutomationOutput]
            let grants: [AutomationToolGrant]
        }

        static func read(
            _ db: Database,
            now: Date,
            selected: Int64?,
            expanded: Set<Int64>,
            failures: Bool,
            databasePath: String
        ) throws -> Self {
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
            let items = try AutomationQueries.fetchList(db, now: now)
            let workbenchIDs = Set(try Int64.fetchAll(db, sql: "SELECT id FROM projects"))
            return Self(
                items: items,
                attentionCount: try AutomationQueries.attentionCount(db),
                inboxOutputCount: try AutomationQueries.inboxOutputCount(db),
                headerButtons: AutomationQueries.headerButtonsByProject(items),
                endedRuns: failures ? try AutomationQueries.newestEndedRuns(db) : [:],
                allIDs: failures ? try AutomationQueries.allIDs(db) : [],
                card: card,
                steps: steps,
                drafts: try AutomationDraftRows.load(db, databasePath: databasePath, liveWorkbenchIDs: workbenchIDs)
            )
        }
    }

    private func apply(_ snapshot: Snapshot) {
        items = snapshot.items
        if draftRows != snapshot.drafts { draftRows = snapshot.drafts }
        attentionCount = snapshot.attentionCount
        headerButtonsByProject = snapshot.headerButtons
        if snapshot.inboxOutputCount != inboxOutputCount {
            inboxOutputCount = snapshot.inboxOutputCount
            onInboxOutputCountChanged?()
        }
        for (runID, runSteps) in snapshot.steps { steps[runID] = runSteps }
        applyFailures(snapshot.endedRuns, existing: snapshot.allIDs)
        // The selection may have moved while the read ran; keep only what matches it.
        if let card = snapshot.card, card.automationID == selectedID {
            runs[card.automationID] = card.runs
            reports[card.automationID] = card.reports
            grants[card.automationID] = card.grants
        }
    }

    /// The open card on a visible tab of an active app is seen; then new
    /// failures notify and the badge's failure share is counted.
    private func applyFailures(_ runs: [Int64: AutomationRun], existing: Set<Int64>) {
        guard let failureWatch else { return }
        if tabVisible, let selectedID, isOwnerLooking() {
            failureWatch.markSeen(selectedID, runs: runs)
        }
        failureWatch.notify(items, runs: runs, existing: existing, now: now())
        unseenFailureCount = failureWatch.unseenCount(items, runs: runs)
    }

    /// Workbench `projectID`'s header buttons, in slug order.
    package func headerButtons(projectID: Int64) -> [AutomationHeaderButton] {
        headerButtonsByProject[projectID] ?? []
    }

    // MARK: - Selection

    /// Opens an automation's card (nil closes it) and reads it.
    package func select(_ id: Int64?) {
        if id != selectedID { expandedRuns = [] }
        selectedID = id
        panel = id.map(AutomationsPanel.card) ?? .empty
        composerPrefill = nil
        if id != nil { refresh() }
    }

    /// Shows an automation's card in the panel and selects its row.
    package func showCard(_ id: Int64) {
        select(id)
    }

    /// Opens the New automation flow; no row stays selected meanwhile.
    package func showNew(_ flow: AutomationNewFlow) {
        if selectedID != nil { expandedRuns = [] }
        selectedID = nil
        panel = .new(flow)
        composerPrefill = nil
    }

    /// Opens a template's panel; no row stays selected meanwhile.
    package func showTemplate(name: String, scope: AutomationScopeChoice) {
        if selectedID != nil { expandedRuns = [] }
        selectedID = nil
        panel = .template(name: name, scope: scope)
        composerPrefill = nil
    }

    /// Opens the editor: an edit keeps its row selected, a new draft selects
    /// none (its draft row, if any, shows as selected). `composerPrefill`
    /// goes into the editor chat's empty composer once.
    package func showEditor(_ target: AutomationEditorTarget, composerPrefill: String? = nil) {
        let id: Int64? = if case let .existing(id, _, _) = target { id } else { nil }
        if id != selectedID { expandedRuns = [] }
        selectedID = id
        panel = .editor(target)
        self.composerPrefill = composerPrefill
        if id != nil { refresh() }
    }

    /// The list's first row (`first`) is shown while the panel is empty, or
    /// in place of a card whose automation is gone; New, a template and the
    /// editor are never replaced by a list change.
    package func autoSelect(first: Int64?) {
        switch panel {
        case .empty:
            if let first { select(first) }
        case let .card(id) where !items.map(\.id).contains(id):
            select(first)
        case .card, .new, .template, .editor:
            break
        }
    }

    /// `pendingConfirmID` opens that automation's card and is cleared.
    package func consumePendingConfirm() {
        guard let id = pendingConfirmID else { return }
        pendingConfirmID = nil
        showCard(id)
    }

    /// **Discard Draft** of a new draft: its cache file goes (so it is no
    /// longer a row) and the panel empties. A draft never drafted by the
    /// assistant has no file; its in-memory draft is the editor center's.
    package func discardDraft(contextID: String) {
        if let row = draftRows.first(where: { $0.contextID == contextID }) {
            let url = AutomationDraftEntry.cacheURL(databasePath: dbPool.path, conversationID: row.conversationID)
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            } catch {
                lastError = "Could not remove the draft: \(error.localizedDescription)"
                lastErrorIsRead = false
            }
            draftRows.removeAll { $0.contextID == contextID }
        }
        if case let .editor(.newDraft(current, _, _)) = panel, current == contextID { select(nil) }
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
        panel = .card(automationID)
        composerPrefill = nil
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

    // MARK: - Templates

    /// Reads the gallery's templates. A CLI without the subcommand (older than
    /// P6 part 2) is the empty gallery, not an error: cobra answers
    /// `automations templates --json` there with "unknown flag: --json" (the
    /// parent takes any word, not the flag).
    package func loadTemplates() async {
        templatesLoading = true
        defer { templatesLoading = false }
        do {
            templates = try await cli.templates()
            templatesError = nil
        } catch {
            templates = []
            let message = Self.message(for: error)
            let unknown = ["unknown command", "unknown flag"].contains { message.localizedCaseInsensitiveContains($0) }
            templatesError = unknown ? nil : message
        }
    }

    // MARK: - CLI operations

    /// False when the call failed (`lastError` says why) or another call on `id` is in flight.
    @discardableResult
    package func runNow(_ id: Int64) async -> Bool {
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
            // The run already happened (and spent its tokens): a failed read
            // of its steps says so, so the owner does not pay for a retry.
            do {
                let runSteps = try await dbPool.read { db in try AutomationQueries.fetchSteps(db, runID: result.runID) }
                dryRuns[id] = .done(
                    runID: result.runID,
                    lines: DryRunPresentation.lines(steps: runSteps),
                    tokens: result.inputTokens + result.outputTokens,
                    status: result.status
                )
            } catch {
                dryRuns[id] = .failed(Self.stepsUnreadable(status: result.status,
                                                           tokens: result.inputTokens + result.outputTokens,
                                                           error: error))
            }
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
            lastErrorIsRead = false
            succeeded = false
        }
        afterCLICall()
        return succeeded
    }

    /// Quick run started a run through its own CLI call: read now and take
    /// the fast cadence at once.
    package func noteRunStarted() {
        afterCLICall()
    }

    /// A CLI call may have started a run: read now, and restart the poll so
    /// an active run gets the fast cadence at once.
    private func afterCLICall() {
        refresh()
        if pollTask != nil { schedulePoll() }
    }

    /// A dry run that finished but whose steps could not be read.
    package static func stepsUnreadable(status: String, tokens: Int64, error: Error) -> String {
        "Dry run finished (\(status), \(AutomationCardPresentation.number(tokens)) tokens); could not load its steps: "
            + error.localizedDescription
    }

    /// A failed CLI call in words: its stderr, else the exit code.
    package static func message(for error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "watchtower exited with code \(code)" : text
        }
        return error.localizedDescription
    }
}

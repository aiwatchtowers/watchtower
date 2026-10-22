import Foundation
import GRDB

/// The card the Inbox reading pane shows.
package enum InboxSelection: Hashable, Sendable {
    case proposal(Int64)
    case reminder(Int64)
    case output(Int64)
    case day(String) // "YYYY-MM-DD"
    case track(Int)
    case idea(Int)
    case message(Int)
}

/// The Inbox — every kind of card (C1 §5): pending agent-action proposals,
/// due reminders and open automation inbox outputs (STRIP-01 amended, spec
/// §14.4), the day cards, tracks, ideas and open messages, read as one
/// `InboxFeedQueries.read`. AppState-owned so it
/// survives navigation away from the Dashboard (the `SlackAccountsViewModel`
/// house pattern): `refresh()` on appear / after a mutation, not live GRDB
/// observation — cross-process daemon/CLI writes don't fire `ValueObservation`
/// (`AgentActionFeed`'s doc comment explains why).
///
/// Composes `AgentActionFeed` rather than reimplementing its CLI plumbing —
/// approve/reject/retry route through it, so `Registry.Apply`'s exactly-once
/// claim and the envelope-error surfacing stay in one place. Reminder
/// done/snooze are direct GRDB writes (Swift-owned, no daemon contention,
/// the `inbox_feedback` dual-path precedent), so they need no CLI round trip;
/// so are an output's opening, Done and Dismiss, the only automation columns
/// Swift writes (`read_at`/`done_at`/`dismissed_at`, spec §9.6, ask #475).
/// They await the writer off the main thread (board #670): one write per card
/// at a time, and the card leaves the strip only once its write landed.
/// The other kinds' writes: opening a day card marks its briefing read,
/// opening a message its `read_at`; a track's Done and Stop watching are
/// GRDB writes (a custom track's through `CustomTrackControlling`); a
/// message's Done / Hide / Snooze run `watchtower inbox …` (Go owns those
/// rows). A row already gone at the press is quiet: it leaves on the refresh.
@MainActor
@Observable
package final class ActionStripViewModel {
    /// Everything the list can show, as the last `refresh()` read it.
    package private(set) var feed = InboxFeedSnapshot()
    package var actionRows: [AgentAction] { feed.proposals }
    package var reminderRows: [Reminder] { feed.reminders }
    /// Open `kind='inbox'` automation outputs (read or not; neither done nor
    /// dismissed), newest first.
    package var outputRows: [AutomationOutputCard] { feed.outputs }
    /// The card the reading pane shows; set through `select(_:)`.
    package var selection: InboxSelection?
    /// The filter bar's segment, remembered per viewer.
    package var filter: InboxFilter {
        didSet {
            defaults.set(filter.rawValue, forKey: Self.filterKey)
            rebuildSections()
        }
    }
    /// The date whose day card the owner marked Done (it then stops being pinned), remembered per viewer.
    package private(set) var dayDone: String?
    /// How many dates the Day filter reads; `showOlderDays()` adds a page.
    package var dayLimit = ActionStripViewModel.dayPage
    /// Action id → "⚙ <automation> · run #<n>" for the rows an automation
    /// run proposed (`context_type='automation_run'`).
    package private(set) var actionLabels: [Int64: String] = [:]
    /// `finished_at` of the latest successful `reaction-commands` daemon run
    /// — the cheat sheet's "last check". Nil until the phase has run once.
    package private(set) var lastReactionCheck: String?
    package var lastError: String?

    private let dbPool: DatabasePool
    /// nil = the installed CLI, found at press time.
    private let cliRunner: CLIRunnerProtocol?
    private let customTrackControls: any CustomTrackControlling
    private let defaults: UserDefaults
    /// One write per card (board #670).
    private let pendingWrites = PendingWrites()
    private var refreshGate = ForegroundRefreshGate()
    private var pollTask: Task<Void, Never>?
    /// The refresh under way; a call meanwhile waits for it and asks for one more read.
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false

    package static let filterKey = "inbox.filter"
    package static let dayDoneKey = "inbox.dayCardDone"
    package static let dayPage = 30
    /// The safety-net poll while on screen (board #731): daemon and CLI
    /// writes come from other processes, which GRDB observation cannot see.
    private static let pollInterval: Duration = .seconds(30)
    /// Exposed so a view can reuse its `inFlight`/card helpers if it ever
    /// needs to render one of these rows the way a chat surface does.
    package let actionFeed: AgentActionFeed

    /// `customTrackControls` nil = C1's direct writes (`DirectCustomTrackControls`).
    package init(
        dbPool: DatabasePool,
        cliRunner: CLIRunnerProtocol? = nil,
        customTrackControls: (any CustomTrackControlling)? = nil,
        defaults: UserDefaults = .standard,
        automationsWake: (() async throws -> Void)? = nil
    ) {
        self.dbPool = dbPool
        self.cliRunner = cliRunner
        self.customTrackControls = customTrackControls ?? DirectCustomTrackControls(
            dbPool: dbPool, scanService: TrackScanService(runner: cliRunner ?? InstalledCLIRunner()))
        self.defaults = defaults
        self.filter = defaults.string(forKey: Self.filterKey).flatMap(InboxFilter.init(rawValue:)) ?? .all
        self.dayDone = defaults.string(forKey: Self.dayDoneKey)
        self.actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner, automationsWake: automationsWake)
    }

    /// The Inbox sidebar badge (R1, spec §6.1): Needs your decision (proposals
    /// awaiting the owner, ideas awaiting a verdict) + unread Messages + 1 when
    /// the latest briefing is unread + due reminders. Unread automation outputs
    /// and track cards show only as the list's unread dots.
    /// Each source tolerates a schema that predates it (its table missing
    /// counts 0); any other read error is thrown, never folded into 0.
    nonisolated package static func badgeCount(_ db: Database, nowUTC: String) throws -> Int {
        try zeroIfTableMissing { try AgentActionQueries.awaitingOwnerCount(db) }
            + zeroIfTableMissing { try ReminderQueries.dueCount(db, nowUTC: nowUTC) }
            + zeroIfTableMissing { try IdeaQueries.countForReview(db) }
            + zeroIfTableMissing { try InboxQueries.unreadOpenMessageCount(db, nowUTC: nowUTC) }
            + zeroIfTableMissing { try BriefingQueries.latestUnreadCount(db) }
    }

    /// `count()`, or 0 when its table does not exist yet (an older schema).
    nonisolated package static func zeroIfTableMissing(_ count: () throws -> Int) throws -> Int {
        do {
            return try count()
        } catch let error as DatabaseError where isMissingTable(error) {
            return 0
        }
    }

    /// An older schema's missing table ("no such table"), the only error the readers fold into "empty".
    nonisolated package static func isMissingTable(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_ERROR && (error.message ?? "").hasPrefix("no such table")
    }

    /// The card labels for `rows`: an automation run's row gets its run's
    /// label, or "⚙ automation · run #<n>" when the run (and with it the
    /// automation) is gone. Other rows get none.
    nonisolated package static func labels(for rows: [AgentAction], runLabels: [Int64: String]) -> [Int64: String] {
        var out: [Int64: String] = [:]
        for row in rows {
            guard let runID = automationRunID(row) else { continue }
            out[row.id] = runLabels[runID] ?? "⚙ automation · run #\(runID)"
        }
        return out
    }

    /// The run an automation row was proposed by; nil for any other row.
    nonisolated package static func automationRunID(_ row: AgentAction) -> Int64? {
        guard row.contextType == AgentActionFeed.automationRunContext else { return nil }
        return Int64(row.contextID)
    }

    /// One-shot refetch of every kind (plus the automation labels and the
    /// reaction phase's last check), inside one read off the main thread. The
    /// only thing that can surface a row a subprocess (CLI action commands,
    /// the daemon's phases, an automation run) wrote. Reads only (STRIP-02).
    /// A selected card that is gone now gives way to the next row still listed.
    ///
    /// Calls never overlap: a call while a read is under way waits for it and
    /// then for one more read, so every caller returns after a read that
    /// started after its call (several waiting calls share that one read).
    package func refresh() async {
        if let running = refreshTask {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                refreshAgain = false
                await readFeed()
            } while refreshAgain
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func readFeed() async {
        lastError = nil
        let now = Date()
        let nowUTC = AutomationDates.format(now)
        let today = HomeFeedBuilder.dayString(now, calendar: .current)
        let dayLimit = dayLimit
        do {
            let snapshot = try await dbPool.read { db in
                let feed = try InboxFeedQueries.read(db, nowUTC: nowUTC, today: today, dayLimit: dayLimit)
                let runLabels = try AutomationQueries.runLabels(
                    db, runIDs: feed.proposals.compactMap(Self.automationRunID))
                return (
                    feed: feed,
                    labels: Self.labels(for: feed.proposals, runLabels: runLabels),
                    lastCheck: try PipelineRunQueries.lastSuccessfulFinish(db, pipeline: "reaction-commands")
                )
            }
            let before = sections
            feed = snapshot.feed
            actionLabels = snapshot.labels
            lastReactionCheck = snapshot.lastCheck
            rebuildSections()
            keepSelectionListed(was: before)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The list as `InboxListBuilder` laid it out for the current filter;
    /// rebuilt on each read and on a filter or day Done change.
    package private(set) var sections: [InboxSection] = []

    private func rebuildSections() {
        let now = Date()
        sections = InboxListBuilder.sections(
            feed, filter: filter, dayDone: dayDone, today: HomeFeedBuilder.dayString(now, calendar: .current),
            now: now, calendar: .current)
    }

    /// The selected card left the list (resolved elsewhere, auto-resolved,
    /// dismissed): the next row of the old list still listed, else the one
    /// above it, else none.
    private func keepSelectionListed(was before: [InboxSection]) {
        guard let current = selection else { return }
        let listed = sections.flatMap(\.items).map(\.id)
        guard !listed.contains(current) else { return }
        let old = before.flatMap(\.items).map(\.id)
        guard let index = old.firstIndex(of: current) else {
            selection = nil
            return
        }
        let below = old[(index + 1)...].first(where: listed.contains)
        selection = below ?? old[..<index].last(where: listed.contains)
    }

    /// Routing entry (old links, Home): shows `filter` and opens `item`.
    package func open(_ filter: InboxFilter, select item: InboxSelection?) async {
        self.filter = filter
        await refresh()
        await select(item)
    }

    /// The Day filter reads one more page of dates; the returned refresh can be awaited.
    @discardableResult
    package func showOlderDays() -> Task<Void, Never> {
        dayLimit += Self.dayPage
        return Task { await refresh() }
    }

    /// Done on a day card: it stops being pinned on top of Today. A per-viewer
    /// convenience (R3), no database write.
    package func markDayDone(_ date: String) {
        dayDone = date
        defaults.set(date, forKey: Self.dayDoneKey)
        rebuildSections()
    }

    // MARK: - Polling (board #731)

    /// The Inbox went on or off screen: off screen the poll skips; back on
    /// screen after a skipped tick, one refresh at once. On screen starts the
    /// 30 s poll the first time.
    package func setOnScreen(_ onScreen: Bool) {
        if refreshGate.setOnScreen(onScreen) { onScreenRefresh = Task { await refresh() } }
        if onScreen { startPolling() }
    }

    /// The refresh `setOnScreen` started — held so tests can await it.
    package private(set) var onScreenRefresh: Task<Void, Never>?

    /// One tick of the 30 s poll (its loop's body; tests call it directly).
    package func pollTick() async {
        if refreshGate.tick() { await refresh() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = Self.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
                await self.pollTick()
            }
        }
    }

    /// A reminder's Done or Snooze is being written: its buttons wait.
    package func isWriting(reminder id: Int64) -> Bool {
        isWriting(.reminder(id))
    }

    /// An output's Done, Dismiss or Reply press is under way: its buttons
    /// wait (its opening does not hold them).
    package func isWriting(output id: Int64) -> Bool {
        isWriting(.output(id))
    }

    /// A press on `item`'s card is under way: its buttons wait (an opening does not hold them).
    package func isWriting(_ item: InboxSelection) -> Bool {
        pendingWrites.isPending(CardKey.card(item))
    }

    package func markReminderDone(_ id: Int64) async {
        await write(.card(.reminder(id))) { try ReminderQueries.markDone($0, id: id) }
    }

    package func snoozeReminder(_ id: Int64, until: String) async {
        await write(.card(.reminder(id)), { try ReminderQueries.snooze($0, id: id, until: until) }, onFailure: { error in
            // A reminder deleted elsewhere leaves the strip; `refresh` clears
            // `lastError`, so the reason is set after it.
            if error is RowNotFoundError { await self.refresh() }
        })
    }

    /// Shows `item` in the reading pane. Opening an unread card writes its
    /// read mark only: an output its `read_at`, a day card its briefing's
    /// `read_at` (CATCHUP-01's surface), a message its `read_at`; a track,
    /// idea, proposal or reminder writes nothing. The card stays listed, now
    /// read. The opening has a key of its own: the card's buttons do not wait
    /// for it, and a Done or Dismiss pressed meanwhile still lands.
    package func select(_ item: InboxSelection?) async {
        selection = item
        guard let item, let change = openingWrite(item) else { return }
        await write(.opening(item), change)
    }

    private func openingWrite(_ item: InboxSelection) -> (@Sendable (Database) throws -> Void)? {
        switch item {
        case .output(let id):
            guard outputRows.first(where: { $0.id == id })?.isUnread == true else { return nil }
            let now = Date()
            return { try AutomationQueries.markOutputOpened($0, id: id, now: now) }
        case .day(let date):
            guard let briefing = feed.days.first(where: { $0.date == date })?.briefing, !briefing.isRead else { return nil }
            let id = briefing.id
            return { try BriefingQueries.markRead($0, id: id) }
        case .message(let id):
            guard feed.messages.first(where: { $0.item.id == id })?.item.isUnread == true else { return nil }
            return { try InboxQueries.markRead($0, id: id) }
        case .proposal, .reminder, .track, .idea:
            return nil
        }
    }

    // MARK: - Tracks

    /// Done on a track card (R4): the track read (TRACKS-04, with its digests)
    /// and every event of it read, in one write.
    package func markTrackDone(_ id: Int) async {
        await write(.card(.track(id))) { db in
            try TrackQueries.markRead(db, id: id)
            try TrackEventQueries.markAllRead(db, trackId: id)
        }
    }

    /// Stop watching (R4): an auto track is dismissed (TRACKS-07); a custom
    /// track goes through the seam, which also turns its collection off. A
    /// track deleted meanwhile is quiet.
    package func stopWatching(_ track: Track) async {
        let id = track.id
        guard track.isCustom else {
            await write(.card(.track(id))) { db in
                do { try TrackQueries.dismiss(db, id: id) } catch is RowNotFoundError {}
            }
            return
        }
        let controls = customTrackControls
        await pendingWrites.run(CardKey.card(.track(id))) {
            lastError = nil
            do {
                try await controls.stopWatching(track)
                await refresh()
            } catch is RowNotFoundError {
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Messages

    /// Done on a message card: `watchtower inbox resolve <id>`.
    package func messageDone(_ id: Int) async {
        await runInboxCLI(id, ["inbox", "resolve", "\(id)"])
    }

    /// Hide on a message card: `watchtower inbox dismiss <id>`.
    package func hideMessage(_ id: Int) async {
        await runInboxCLI(id, ["inbox", "dismiss", "\(id)"])
    }

    /// Snooze on a message card: `watchtower inbox snooze <id> <duration>`, `duration` "1d", "3d" or "1w".
    package func snoozeMessage(_ id: Int, duration: String) async {
        await runInboxCLI(id, ["inbox", "snooze", "\(id)", duration])
    }

    /// Go owns `inbox_items`' status, so the buttons run the CLI. Its
    /// resolve / dismiss / snooze never check the row they changed: a row
    /// already resolved elsewhere exits 0, and the card leaves on the refresh.
    private func runInboxCLI(_ id: Int, _ args: [String]) async {
        let runner = cliRunner
        await pendingWrites.run(CardKey.card(.message(id))) {
            lastError = nil
            guard let runner = runner ?? ProcessCLIRunner.makeDefault() else {
                lastError = HomeFeedActionError.cliUnavailable.localizedDescription
                return
            }
            do {
                _ = try await runner.run(args: args, timeout: HomeFeedActionError.cliTimeout)
                await refresh()
            } catch {
                await refresh()
                lastError = error.localizedDescription
            }
        }
    }

    /// Done on an output card: writes `done_at` only. The card leaves the
    /// strip only once the write landed; a failure keeps it and says why.
    package func markOutputDone(_ id: Int64) async {
        let now = Date()
        await write(.card(.output(id)), { try AutomationQueries.markOutputDone($0, id: id, now: now) },
                    onSuccess: { self.deselect(.output(id)) })
    }

    /// Dismiss on an output card: writes `dismissed_at` only.
    package func dismissOutput(_ id: Int64) async {
        let now = Date()
        await write(.card(.output(id)), { try AutomationQueries.dismissOutput($0, id: id, now: now) },
                    onSuccess: { self.deselect(.output(id)) })
    }

    /// A Reply button: `watchtower automations reply` records the press and
    /// queues one run, then wakes the daemon (AUTO-09); the Desktop writes
    /// nothing for it (STRIP-02). One press per card at a time; the card then
    /// shows its sent state, and a refusal ("Sent — run #7", a recipe that
    /// cannot run) keeps it and says why.
    package func pressReply(outputID: Int64, action: Int) async {
        let runner = cliRunner
        await pendingWrites.run(CardKey.card(.output(outputID))) {
            lastError = nil
            guard let runner = runner ?? ProcessCLIRunner.makeDefault() else {
                lastError = CLIRunnerError.binaryNotFound.localizedDescription
                return
            }
            do {
                _ = try await AutomationsCLI(runner: runner).reply(outputID: outputID, action: action)
                await refresh()
            } catch {
                await refresh()
                lastError = Self.replyRefusal(AutomationsViewModel.message(for: error))
            }
        }
    }

    /// The CLI's refusal without cobra's "Error: " lead ("Sent — run #7").
    nonisolated static func replyRefusal(_ message: String) -> String {
        let lead = "Error: "
        return message.hasPrefix(lead) ? String(message.dropFirst(lead.count)) : message
    }

    /// A card that left the Inbox is no longer shown.
    private func deselect(_ item: InboxSelection) {
        if selection == item { selection = nil }
    }

    private enum CardKey: Hashable {
        /// A press on the card (Done, Dismiss, Snooze, Reply, Stop watching).
        case card(InboxSelection)
        /// The card's read mark on opening.
        case opening(InboxSelection)
    }

    /// One write per card: a second press while it waits does nothing.
    private func write(
        _ key: CardKey,
        _ change: @escaping @Sendable (Database) throws -> Void,
        onSuccess: () -> Void = {},
        onFailure: (Error) async -> Void = { _ in }
    ) async {
        let pool = dbPool
        await pendingWrites.run(key) {
            lastError = nil
            do {
                try await pool.write(change)
                onSuccess()
                await refresh()
            } catch {
                await onFailure(error)
                lastError = error.localizedDescription
            }
        }
    }

    package func approve(_ id: Int64, shownArgs: String, patch: String? = nil) async {
        await actionFeed.approve(id, shownArgs: shownArgs, patch: patch)
        await refresh()
        adoptFeedError()
    }

    package func reject(_ id: Int64) async {
        await actionFeed.reject(id)
        await refresh()
        adoptFeedError()
    }

    package func retry(_ id: Int64) async {
        await actionFeed.retry(id)
        await refresh()
        adoptFeedError()
    }

    package func dismiss(_ id: Int64) async {
        await actionFeed.dismiss(id)
        await refresh()
        adoptFeedError()
    }

    /// `actionFeed.lastError` carries only feed-wide failures (a row's own
    /// failure lives in `rowErrors`, on its card); a bare "call it and move
    /// on" would swallow that from anything observing only the strip's own
    /// `lastError`. Runs AFTER
    /// `refresh()`, which clears `lastError` on entry — otherwise refresh's
    /// own reset would immediately wipe the error this just adopted. Synced
    /// unconditionally when `refresh()` itself succeeded (not just when
    /// non-nil): a later successful call where the feed's own error cleared
    /// back to nil must clear the strip's copy too, not leave it stuck on a
    /// stale failure. Guarded on `lastError == nil` so a genuine `refresh()`
    /// read failure (the strip's own DB read, unrelated to the feed) is never
    /// overwritten by a stale/absent feed error.
    private func adoptFeedError() {
        guard lastError == nil else { return }
        lastError = actionFeed.lastError
    }
}

/// The installed CLI, found at each call: the scan runner when no other is given.
package struct InstalledCLIRunner: CLIRunnerProtocol {
    package init() {}

    package func run(args: [String]) async throws -> Data {
        guard let runner = ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
        return try await runner.run(args: args)
    }
}

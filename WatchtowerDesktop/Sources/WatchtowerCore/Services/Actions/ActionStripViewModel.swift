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
    /// A built-in's failed move to Automations, by its built-in id.
    case builtinNotice(String)
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
            if !showingLegacyList { defaults.set(filter.rawValue, forKey: Self.filterKey) }
            rebuildSections()
        }
    }
    /// A legacy list or a route sets the filter for this session only: the
    /// remembered filter is the owner's own choice, never a legacy entry's
    /// or a route's (`showSessionFilter`).
    private var showingLegacyList = false
    /// The Tracks filter's Stopped fold is open (per session).
    package var showsStopped = false {
        didSet { rebuildSections() }
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
    /// A failed press on a row with a `ref` (spec "Native row actions",
    /// Failure), by the row's record: the row keeps it with **Retry** until
    /// its next press or until the record leaves. `refresh()` keeps it
    /// (it clears only `lastError`). A proposal's failures live in
    /// `actionFeed.rowErrors`.
    package private(set) var rowErrors: [InboxSelection: InboxRowFailure] = [:]
    /// Called once a `refresh()` read is done (the 30 s poll and every
    /// press included): the sidebar's Inbox badge counts the same rows, and
    /// its observation never sees the daemon's writes, so AppState refreshes
    /// the counts here (the `onRecapsChanged` precedent).
    @ObservationIgnored package var onFeedRefreshed: (@MainActor () async -> Void)?
    /// The feature registry ids turned off (AppState's feature visibility);
    /// a change re-reads, since the read gates today's placeholder on them.
    package var disabledFeatures: Set<String> = [] {
        didSet {
            folderMenu.approvalsEnabled = !disabledFeatures.contains(Self.approvalsFeatureID)
            if disabledFeatures != oldValue { Task { await refresh() } }
        }
    }
    /// The Inbox's folder menu (inbox builder B): here so a folder write
    /// still running when the Inbox leaves the screen lands in the state it
    /// finds on return. Every `refresh()` re-reads it.
    package let folderMenu: InboxFolderMenuModel
    /// Needs approval's feature (`approval-cards`).
    package static let approvalsFeatureID = "approval-cards"

    private let dbPool: DatabasePool
    /// nil = the installed CLI, found at press time.
    private let cliRunner: CLIRunnerProtocol?
    private let customTrackControls: any CustomTrackControlling
    private let defaults: UserDefaults
    /// The moment the list is read and laid out at (Today, Earlier, due
    /// reminders); the design shots fix it.
    private let clock: @Sendable () -> Date
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
    /// `findCLI` is how the folder menu (and so the rows' writes) finds the
    /// binary when `cliRunner` is nil; tests pass `{ nil }` for a missing one.
    package init(
        dbPool: DatabasePool,
        cliRunner: CLIRunnerProtocol? = nil,
        customTrackControls: (any CustomTrackControlling)? = nil,
        defaults: UserDefaults = .standard,
        automationsWake: (() async throws -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        findCLI: @escaping @MainActor () -> (any CLIRunnerProtocol)? = { ProcessCLIRunner.makeDefault() }
    ) {
        self.dbPool = dbPool
        self.clock = clock
        self.cliRunner = cliRunner
        self.customTrackControls = customTrackControls ?? DirectCustomTrackControls(
            dbPool: dbPool, scanService: TrackScanService(runner: cliRunner ?? InstalledCLIRunner()))
        self.defaults = defaults
        self.filter = defaults.string(forKey: Self.filterKey).flatMap(InboxFilter.init(rawValue:)) ?? .all
        self.dayDone = defaults.string(forKey: Self.dayDoneKey)
        self.actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner, automationsWake: automationsWake)
        self.folderMenu = InboxFolderMenuModel(
            dbPool: dbPool, runner: { cliRunner ?? findCLI() }, clock: clock)
    }

    /// The Inbox sidebar badge: the sum of the counts of every folder the
    /// menu shows (inbox builder B, `InboxFolderCounts`). It keeps every
    /// term of the 2026-10-18 badge as a folder's legacy count — Needs
    /// approval: proposals awaiting the owner, due reminders, built-in
    /// upgrade notices (C2); the root: ideas awaiting a verdict, unread
    /// Messages (while that entry stands in for Waiting for me) and 1 when
    /// the latest briefing is unread — and adds the automation artifacts:
    /// 1 per unread one, or its rows that wait on the owner. Track cards
    /// stay unread dots only. Each source tolerates a schema that predates
    /// it (its table missing counts 0); any other read error is thrown,
    /// never folded into 0.
    nonisolated package static func badgeCount(_ db: Database, nowUTC: String) throws -> Int {
        let snapshot = try InboxFolderMenuSnapshot.read(db, nowUTC: nowUTC)
        return InboxFolderCounts.badge(counts: snapshot.counts, tree: snapshot.tree)
    }

    /// The badge's terms from before the folders, by the folder that shows
    /// them now: Needs approval (the root on a database without it) and the
    /// root.
    nonisolated package static func legacyCounts(
        _ db: Database,
        nowUTC: String,
        tree: InboxFolderTree,
        messagesStandIn: Bool
    ) throws -> [Int64: Int] {
        let approvals = try zeroIfTableMissing { try AgentActionQueries.awaitingOwnerCount(db) }
            + zeroIfTableMissing { try ReminderQueries.dueCount(db, nowUTC: nowUTC) }
            + zeroIfTableMissing { try BuiltinUpgradeNotice.load(db).count }
        let messages = messagesStandIn
            ? try zeroIfTableMissing { try InboxQueries.unreadOpenMessageCount(db, nowUTC: nowUTC) } : 0
        let root = try zeroIfTableMissing { try IdeaQueries.countForReview(db) }
            + messages
            + zeroIfTableMissing { try BriefingQueries.latestUnreadCount(db) }
        var out: [Int64: Int] = [tree.root.id: root]
        out[tree.approvals?.id ?? tree.root.id, default: 0] += approvals
        return out
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
    /// A selected card that is gone now gives way to the next row still listed;
    /// a selected folder entry to the next entry, shown in the pane but never
    /// marked read (only the owner's gesture writes a read mark).
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
        await onFeedRefreshed?()
    }

    private func readFeed() async {
        lastError = nil
        let now = clock()
        let nowUTC = AutomationDates.format(now)
        let dayLimit = dayLimit
        let disabledFeatures = disabledFeatures
        do {
            // The feed, the labels and the folders in one read: the folder
            // menu, its counts and every folder's entries see the same
            // moment as the cards (the render-time check, spec "What 'open'
            // means").
            let snapshot = try await dbPool.read { db in
                let feed = try InboxFeedQueries.read(
                    db, nowUTC: nowUTC, dayLimit: dayLimit, disabledFeatures: disabledFeatures)
                let runLabels = try AutomationQueries.runLabels(
                    db, runIDs: feed.proposals.compactMap(Self.automationRunID))
                return (
                    feed: feed,
                    labels: Self.labels(for: feed.proposals, runLabels: runLabels),
                    lastCheck: try PipelineRunQueries.lastSuccessfulFinish(db, pipeline: "reaction-commands"),
                    folders: try InboxFolderMenuSnapshot.read(db, nowUTC: nowUTC)
                )
            }
            let before = sections
            let entriesBefore = folderEntries.map(\.id)
            feed = snapshot.feed
            actionLabels = snapshot.labels
            lastReactionCheck = snapshot.lastCheck
            folderMenu.receive(snapshot.folders)
            hasRead = true
            dropLeftRowErrors()
            firstReadError = nil
            rebuildSections()
            keepSelectionListed(was: before)
            keepEntryListed(was: entriesBefore)
        } catch {
            // The previous feed, tree and entries stay under the error line.
            lastError = error.localizedDescription
            folderMenu.receiveFailure(error.localizedDescription)
            if !hasRead { firstReadError = error.localizedDescription }
        }
    }

    // MARK: - Folders (inbox builder B)

    /// A read has landed: before it the folders show nothing (not even
    /// today's placeholder day, which waits on the read's owner check),
    /// and the Inbox a spinner rather than its empty state.
    package private(set) var hasRead = false

    /// Why no read has landed yet: the Inbox shows an error state with
    /// Try Again in place of its spinner. Cleared by the first read that lands.
    package private(set) var firstReadError: String?

    /// The selected folder's entries (`InboxFolderEntries`), from the last read.
    package var folderEntries: [InboxFolderEntry] {
        guard hasRead, let folder = folderMenu.tree.folder(folderMenu.selectedFolderID) else { return [] }
        return InboxFolderEntries.build(folder: folder, entryInputs)
    }

    /// What the selected folder's entries are composed from.
    package var entryInputs: InboxFolderEntries.Inputs {
        InboxFolderEntries.Inputs(
            feed: feed, folders: folderMenu.snapshot,
            approvalsOn: !disabledFeatures.contains(Self.approvalsFeatureID), dayDone: dayDone,
            selectedDay: entrySelection.flatMap(Self.dayOfEntry), now: clock())
    }

    /// The date of a day entry's id (`day:<yyyy-MM-dd>`), else nil.
    private static func dayOfEntry(_ id: String) -> String? {
        id.hasPrefix("day:") ? String(id.dropFirst("day:".count)) : nil
    }

    /// The selected folder's list column.
    package var folderList: InboxFolderListContent {
        let folder = folderMenu.tree.folder(folderMenu.selectedFolderID) ?? folderMenu.tree.root
        let inputs = entryInputs
        let rows = folderEntries.map { InboxFolderEntries.row($0, inputs) }
        return InboxFolderListContent(
            folderKind: folder.kind, folderTitle: folder.title, rows: rows, selection: entrySelection)
    }

    /// The entry the reading pane shows (`InboxFolderEntry.id`); nil = none.
    package private(set) var entrySelection: String?

    /// The legacy list opened from the root (Track my threads, Idea finder,
    /// Messages): today's list for it, with its own reading pane.
    package private(set) var legacyList: InboxFilter?

    package var selectedEntry: InboxFolderEntry? {
        guard let entrySelection else { return nil }
        return folderEntries.first { $0.id == entrySelection }
    }

    /// The menu picked a folder: its list, nothing selected yet.
    package func selectFolder(_ id: Int64) {
        folderMenu.select(id)
        entrySelection = nil
        legacyList = nil
        selection = nil
    }

    /// Opens an entry: an artifact or a day writes its read mark on opening
    /// (`select`); a legacy list opens today's list for it.
    package func selectEntry(_ id: String?) async {
        guard let opening = showEntry(id) else { return }
        await select(opening)
    }

    /// `selectEntry` without its read mark: selects the entry, opens a
    /// legacy entry's list, and returns the card whose opening `select`
    /// still has to write (an artifact or a day), else nil.
    private func showEntry(_ id: String?) -> InboxSelection? {
        entrySelection = id
        guard let entry = selectedEntry else { return nil }
        if let list = entry.legacyList {
            openLegacy(list)
            return nil
        }
        switch entry {
        case let .artifact(card):
            selection = .output(card.id)
            return .output(card.id)
        case let .legacyDay(card):
            selection = .day(card.date)
            return .day(card.date)
        case .legacyTracks, .legacyIdeas, .legacyMessages, .approval, .builtinNotice:
            selection = nil
            return nil
        }
    }

    /// Opens today's list for a legacy entry (its filter's list and pane).
    package func openLegacy(_ list: InboxFilter) {
        legacyList = list
        showSessionFilter(list)
        selection = nil
    }

    private func showSessionFilter(_ list: InboxFilter) {
        showingLegacyList = true
        filter = list
        showingLegacyList = false
    }

    /// Back from a legacy list to its folder.
    package func closeLegacy() {
        legacyList = nil
        selection = nil
    }

    /// The selected entry left the folder (done elsewhere, auto-resolved,
    /// closed): the next entry of the old list still listed, else the one
    /// above it, else none — as `keepSelectionListed` does for cards.
    private func keepEntryListed(was before: [String]) {
        guard let current = entrySelection else { return }
        let listed = folderEntries.map(\.id)
        guard !listed.contains(current) else { return }
        guard let index = before.firstIndex(of: current) else {
            entrySelection = nil
            return
        }
        let below = before[(index + 1)...].first(where: listed.contains)
        // A click's path without its write: a legacy entry's list opens, an
        // artifact or a day is selected, and no read mark is written — a
        // poll or refresh never marks anything read (STRIP-02).
        _ = showEntry(below ?? before[..<index].last(where: listed.contains))
    }

    // MARK: - Needs approval's note

    /// The note's press state (Turn On under way, its failure).
    package let approvalsNote = NeedsApprovalNoteModel()

    /// The note Needs approval shows (off, stopped, last run failed), or nil.
    package var approvalsNoteState: NeedsApprovalNoteContent.State? {
        folderMenu.snapshot.needsApproval.noteState(featureOn: !disabledFeatures.contains(Self.approvalsFeatureID))
    }

    package var approvalsNoteContent: NeedsApprovalNoteContent? {
        approvalsNote.content(approvalsNoteState)
    }

    /// The note's button: Turn On (off, stopped) through `turnOn` — the
    /// built-in card's own `AppState.setBuiltinEnabled(["approval-cards"],
    /// on: true)` — or Run History through `runHistory(automation, run)`.
    package func pressApprovalsNote(
        turnOn: () async -> String?,
        runHistory: (Int64, Int64?) -> Void
    ) async {
        guard let state = approvalsNoteState else { return }
        switch state {
        case .off, .stopped:
            await approvalsNote.turnOn(on: state, turnOn) { await refresh() }
        case .lastRunFailed:
            guard let target = NeedsApprovalNoteModel.runHistory(folderMenu.snapshot.needsApproval) else { return }
            runHistory(target.automationID, target.runID)
        }
    }

    /// The list as `InboxListBuilder` laid it out for the current filter;
    /// rebuilt on each read and on a filter or day Done change.
    package private(set) var sections: [InboxSection] = []

    private func rebuildSections() {
        let now = clock()
        sections = InboxListBuilder.sections(
            feed, filter: filter, dayDone: dayDone, today: HomeFeedBuilder.dayString(now, calendar: .current),
            now: now, calendar: .current, showsStopped: showsStopped, placeholdsToday: true)
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
    /// A day past the loaded pages reads older pages until it is listed;
    /// a day that is nowhere selects nothing. A stopped track opens the
    /// Tracks filter's Stopped fold; a merged idea opens the idea it was
    /// merged into. Anything else not listed selects nothing, so the pane
    /// never opens on a card the next refresh would drop.
    ///
    /// Until the routes name folders (Task 16), the folders follow the
    /// filter: Tracks, Ideas and Messages open their legacy list over the
    /// root; a day, an automation card, a proposal, a reminder or a notice
    /// opens the folder that lists it with its entry selected.
    package func open(_ filter: InboxFilter, select item: InboxSelection?) async {
        await openFilter(filter, select: item)
        followRoute(filter, item: selection)
    }

    /// The folder and entry for a route that named a filter and a card.
    private func followRoute(_ filter: InboxFilter, item: InboxSelection?) {
        let tree = folderMenu.tree
        legacyList = nil
        let list: InboxFilter? = switch (filter, item) {
        case (.tracks, _), (_, .track?): .tracks
        case (.ideas, _), (_, .idea?): .ideas
        case (.messages, _), (_, .message?): .messages
        default: nil
        }
        if let list {
            // The card stays selected: its kind's list holds it too.
            folderMenu.select(tree.root.id)
            entrySelection = InboxFolderEntry.legacyID(list)
            legacyList = list
            showSessionFilter(list)
            return
        }
        switch item {
        case .proposal?, .reminder?, .builtinNotice?:
            folderMenu.select((tree.approvals ?? tree.root).id)
            entrySelection = nil
        case let .output(id)?:
            let folder = folderMenu.snapshot.cards.first { $0.value.contains { $0.id == id } }?.key ?? tree.root.id
            folderMenu.select(folder)
            entrySelection = "artifact:\(id)"
        case let .day(date)?:
            folderMenu.select(tree.root.id)
            entrySelection = "day:\(date)"
        case .track?, .idea?, .message?, nil:
            folderMenu.select(tree.root.id)
            entrySelection = nil
        }
        if let entrySelection, !folderEntries.contains(where: { $0.id == entrySelection }) {
            self.entrySelection = nil
        }
    }

    private func openFilter(_ filter: InboxFilter, select item: InboxSelection?) async {
        showSessionFilter(filter)
        await refresh()
        switch item {
        case .track(let id)?:
            if !isListed(.track(id)), feed.stoppedTracks.contains(where: { $0.track.id == id }) {
                showsStopped = true
            }
            await select(isListed(.track(id)) ? item : nil)
            return
        case .idea(let id)?:
            let listed = isListed(.idea(id)) ? id : await mergeTarget(of: id)
            await select(listed.map(InboxSelection.idea))
            return
        case .day?:
            break
        default:
            await select(item.flatMap { isListed($0) ? $0 : nil })
            return
        }
        guard case .day(let date)? = item else { return }
        // Stops on a failed read and on a page that added no date.
        while lastError == nil, !isListed(.day(date)), feed.hasOlderDays,
              let oldest = feed.days.last?.date, date < oldest {
            let before = feed.days.count
            await showOlderDays().value
            if feed.days.count == before { break }
        }
        await select(isListed(.day(date)) ? item : nil)
    }

    /// The listed idea a merged one ended up in (merges can chain), or nil.
    private func mergeTarget(of id: Int) async -> Int? {
        do {
            let ids = try await dbPool.read { db -> [Int] in
                var chain: [Int] = []
                var next = try IdeaQueries.fetchOne(db, id: id)?.mergedIntoID
                while let current = next, chain.count < Self.mergeHops, !chain.contains(current) {
                    chain.append(current)
                    next = try IdeaQueries.fetchOne(db, id: current)?.mergedIntoID
                }
                return chain
            }
            return ids.first { isListed(.idea($0)) }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private static let mergeHops = 8

    private func isListed(_ item: InboxSelection) -> Bool {
        sections.contains { $0.items.contains { $0.id == item } }
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

    /// Done on a reminder: a direct GRDB write (STRIP-02), then `inbox
    /// approvals changed` so Needs approval's recipe redraws (STRIP-03).
    package func markReminderDone(_ id: Int64) async {
        // Labeled: `onFailure` before it also takes a closure.
        // swiftlint:disable trailing_closure
        await write(.card(.reminder(id)), { try ReminderQueries.markDone($0, id: id) },
                    press: .done, onSuccess: { await self.reminderChanged(id) })
        // swiftlint:enable trailing_closure
    }

    /// Snooze on a reminder (Snooze 1h is the only one the cards offer).
    package func snoozeReminder(_ id: Int64, until: String) async {
        await write(.card(.reminder(id)), { try ReminderQueries.snooze($0, id: id, until: until) },
                    press: .snoozeHour, onFailure: { error in
            // A reminder deleted elsewhere leaves the strip; `refresh` clears
            // `lastError`, so the reason is set after it.
            if error is RowNotFoundError { await self.refresh() }
        }, onSuccess: { await self.reminderChanged(id) })
    }

    /// `watchtower inbox approvals changed --ref reminder:<id>`: queues one
    /// run of Needs approval (AUTO-09: it only queues). Its failure is not
    /// shown: the render-time check already hides the closed reminder, and
    /// the daemon's sweep redraws (spec "Desktop reminder writes").
    private func reminderChanged(_ id: Int64) async {
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else { return }
        _ = try? await runner.run(args: ["inbox", "approvals", "changed", "--ref", "reminder:\(id)"])
    }

    /// Shows `item` in the reading pane. Opening an unread card writes its
    /// read mark only: an output its `read_at`, a day card its briefing's
    /// `read_at` (CATCHUP-01's surface), a message its `read_at`; a track,
    /// idea, proposal, reminder or built-in notice writes nothing. The card stays listed, now
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
            guard let card = outputRows.first(where: { $0.id == id }), card.isUnread else { return nil }
            let now = Date()
            let hash = card.contentHash
            // A card rewritten under the view stays unread: the mark is for
            // the version drawn, and the refresh after the write shows the new one.
            return { _ = try AutomationQueries.markOutputOpened($0, id: id, contentHash: hash, now: now) }
        case .day(let date):
            guard let briefing = feed.days.first(where: { $0.date == date })?.briefing, !briefing.isRead else { return nil }
            let id = briefing.id
            return { try BriefingQueries.markRead($0, id: id) }
        case .message(let id):
            guard feed.messages.first(where: { $0.item.id == id })?.item.isUnread == true else { return nil }
            return { try InboxQueries.markRead($0, id: id) }
        case .proposal, .reminder, .track, .idea, .builtinNotice:
            return nil
        }
    }

    // MARK: - Tracks

    /// Done on a track card (R4): the track read (TRACKS-04, with its digests)
    /// and every event of it read, in one write.
    package func markTrackDone(_ id: Int) async {
        await write(.card(.track(id)), { db in
            try TrackQueries.markRead(db, id: id)
            try TrackEventQueries.markAllRead(db, trackId: id)
        }, press: .done)
    }

    /// Stop watching (R4): an auto track is dismissed (TRACKS-07); a custom
    /// track goes through the seam, which also turns its collection off. A
    /// track deleted meanwhile is quiet.
    package func stopWatching(_ track: Track) async {
        let id = track.id
        guard track.isCustom else {
            await write(.card(.track(id)), { db in
                do { try TrackQueries.dismiss(db, id: id) } catch is RowNotFoundError {}
            }, press: .stopWatching)
            return
        }
        await throughSeam(track, press: .stopWatching) { try await $0.stopWatching(track) }
    }

    /// Restore on a stopped card (the undo of Stop watching, TRACKS-07's
    /// `RestoreTrack`): an auto track is restored; a custom track goes
    /// through the seam, which also resumes its collection. The card moves
    /// from the Stopped fold back to the tracks. A track deleted meanwhile is quiet.
    package func restoreTrack(_ track: Track) async {
        let id = track.id
        guard track.isCustom else {
            await write(.card(.track(id))) { db in
                do { try TrackQueries.restore(db, id: id) } catch is RowNotFoundError {}
            }
            return
        }
        await throughSeam(track) { try await $0.resumeWatching(track) }
    }

    /// One seam call per card at a time, then a read; a vanished row is quiet.
    private func throughSeam(
        _ track: Track,
        press: InboxRowPress? = nil,
        _ call: @escaping (any CustomTrackControlling) async throws -> Void
    ) async {
        let controls = customTrackControls
        let item = InboxSelection.track(track.id)
        await pendingWrites.run(CardKey.card(item)) {
            lastError = nil
            if press != nil { rowErrors[item] = nil }
            do {
                try await call(controls)
                await refresh()
            } catch is RowNotFoundError {
                await refresh()
            } catch {
                lastError = error.localizedDescription
                if let press { rowErrors[item] = InboxRowFailure(message: error.localizedDescription, press: press) }
            }
        }
    }

    // MARK: - Messages

    /// Done on a message card: `watchtower inbox resolve <id>`.
    package func messageDone(_ id: Int) async {
        await runInboxCLI(id, ["inbox", "resolve", "\(id)"], press: .done)
    }

    /// Hide on a message card: `watchtower inbox dismiss <id>`.
    package func hideMessage(_ id: Int) async {
        await runInboxCLI(id, ["inbox", "dismiss", "\(id)"], press: .hide)
    }

    /// Snooze on a message card: `watchtower inbox snooze <id> <duration>`, `duration` "1d", "3d" or "1w".
    package func snoozeMessage(_ id: Int, duration: String) async {
        await runInboxCLI(id, ["inbox", "snooze", "\(id)", duration], press: .snooze(duration: duration))
    }

    /// Go owns `inbox_items`' status, so the buttons run the CLI. Its
    /// resolve / dismiss / snooze never check the row they changed: a row
    /// already resolved elsewhere exits 0, and the card leaves on the refresh.
    private func runInboxCLI(_ id: Int, _ args: [String], press: InboxRowPress) async {
        let runner = cliRunner
        let item = InboxSelection.message(id)
        await pendingWrites.run(CardKey.card(item)) {
            lastError = nil
            rowErrors[item] = nil
            guard let runner = runner ?? ProcessCLIRunner.makeDefault() else {
                lastError = HomeFeedActionError.cliUnavailable.localizedDescription
                rowErrors[item] = InboxRowFailure(message: lastError ?? "", press: press)
                return
            }
            do {
                _ = try await runner.run(args: args, timeout: HomeFeedActionError.cliTimeout)
                await refresh()
            } catch {
                await refresh()
                lastError = error.localizedDescription
                rowErrors[item] = InboxRowFailure(message: error.localizedDescription, press: press)
            }
        }
    }

    /// Done on an output card: writes `done_at` only, at the version drawn.
    /// The card leaves the strip only once the write landed; a card
    /// rewritten under the view (its hash moved) changes nothing and is
    /// read again, so the new version shows; a failure keeps it and says why.
    package func markOutputDone(_ id: Int64) async {
        let now = Date()
        let hash = drawnHash(id)
        await guardedWrite(.output(id)) { try AutomationQueries.markOutputDone($0, id: id, contentHash: hash, now: now) }
    }

    /// Dismiss on an output card: writes `dismissed_at` only, at the version drawn.
    package func dismissOutput(_ id: Int64) async {
        let now = Date()
        let hash = drawnHash(id)
        await guardedWrite(.output(id)) { try AutomationQueries.dismissOutput($0, id: id, contentHash: hash, now: now) }
    }

    /// The content hash of output `id` as the list drew it; `""` (a row from
    /// before the blocks migration, or one no longer listed) otherwise.
    private func drawnHash(_ id: Int64) -> String {
        outputRows.first { $0.id == id }?.contentHash ?? ""
    }

    /// A read-state write that may change nothing: the card is deselected
    /// only when its row changed; either way the list is read again, so a
    /// card rewritten meanwhile shows as the database has it.
    private func guardedWrite(_ item: InboxSelection, _ change: @escaping @Sendable (Database) throws -> Bool) async {
        let pool = dbPool
        await pendingWrites.run(CardKey.card(item)) {
            lastError = nil
            do {
                if try await pool.write(change) { deselect(item) }
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// A Reply button: `watchtower automations reply` records the press and
    /// queues one run, then wakes the daemon (AUTO-09); the Desktop writes
    /// nothing for it (STRIP-02). One press per card at a time; the card then
    /// shows its sent state, and a refusal ("Sent — run #7", a recipe that
    /// cannot run) keeps it and says why.
    /// `action` is the press's index in the card's flattened action list and
    /// `contentHash` the version drawn: a card rewritten since is refused by
    /// the CLI ("This card changed — look again") and nothing is queued.
    package func pressReply(outputID: Int64, action: Int, contentHash: String) async {
        let runner = cliRunner
        await pendingWrites.run(CardKey.card(.output(outputID))) {
            lastError = nil
            guard let runner = runner ?? ProcessCLIRunner.makeDefault() else {
                lastError = CLIRunnerError.binaryNotFound.localizedDescription
                return
            }
            do {
                _ = try await AutomationsCLI(runner: runner)
                    .reply(outputID: outputID, action: action, contentHash: contentHash)
                await refresh()
            } catch {
                await refresh()
                lastError = Self.replyRefusal(AutomationsViewModel.message(for: error))
            }
        }
    }

    /// **Retry** on a built-in's failed move: `automations upgrade-builtins`
    /// runs every pending move again, then — when one landed — the daemon
    /// restarts so it stops the old phase for that producer. The Desktop
    /// writes nothing (STRIP-02); the card leaves once the next read has no
    /// `failed` row for it, and a move that failed again shows its new error.
    package func retryBuiltinUpgrade(_ builtinID: String, restart: @MainActor () async throws -> Void) async {
        let runner = cliRunner
        await pendingWrites.run(CardKey.card(.builtinNotice(builtinID))) {
            lastError = nil
            guard let runner = runner ?? ProcessCLIRunner.makeDefault() else {
                lastError = CLIRunnerError.binaryNotFound.localizedDescription
                return
            }
            do {
                let results = try await AutomationsCLI(runner: runner).upgradeBuiltins()
                if results.contains(where: { $0.status == "done" }) { try await restart() }
                await refresh()
            } catch {
                await refresh()
                lastError = AutomationsViewModel.message(for: error)
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
    /// `press` is a row's native press: its failure is also kept on the row
    /// (`rowErrors`), except a vanished record's, which leaves quietly.
    private func write(
        _ key: CardKey,
        _ change: @escaping @Sendable (Database) throws -> Void,
        press: InboxRowPress? = nil,
        onFailure: (Error) async -> Void = { _ in },
        onSuccess: () async -> Void = {}
    ) async {
        let pool = dbPool
        await pendingWrites.run(key) {
            lastError = nil
            let item: InboxSelection? = if press != nil, case let .card(item) = key { item } else { nil }
            if let item { rowErrors[item] = nil }
            do {
                try await pool.write(change)
                await refresh()
                await onSuccess()
            } catch {
                await onFailure(error)
                lastError = error.localizedDescription
                if let item, let press, !(error is RowNotFoundError) {
                    rowErrors[item] = InboxRowFailure(message: error.localizedDescription, press: press)
                }
            }
        }
    }

    /// A row's press whose write lives outside the strip (an idea verdict
    /// through `IdeasViewModel`, a track's Make a Task): one per row at a
    /// time, the row busy meanwhile (`isWriting`); `body` returns the
    /// failure's message, which stays on the row with **Retry**, or nil.
    /// Then the Inbox reads again.
    package func runRowPress(
        _ item: InboxSelection, press: InboxRowPress, _ body: @escaping @MainActor () async -> String?
    ) async {
        await pendingWrites.run(CardKey.card(item)) {
            rowErrors[item] = nil
            let failure = await body()
            await refresh()
            // A record gone meanwhile leaves quietly, as `RowNotFoundError` does.
            if let failure, isOpenRecord(item) {
                rowErrors[item] = InboxRowFailure(message: failure, press: press)
            }
        }
    }

    /// A row error whose record is no longer shown goes with its row.
    private func dropLeftRowErrors() {
        guard !rowErrors.isEmpty else { return }
        rowErrors = rowErrors.filter { item, _ in isOpenRecord(item) }
    }

    /// The last read still lists `item`'s record.
    private func isOpenRecord(_ item: InboxSelection) -> Bool {
        switch item {
        case let .message(id): feed.messages.contains { $0.item.id == id }
        case let .track(id): feed.tracks.contains { $0.track.id == id }
        case let .idea(id): feed.ideas.contains { $0.id == id }
        case let .reminder(id): feed.reminders.contains { $0.id == id }
        case .proposal, .output, .day, .builtinNotice: false
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

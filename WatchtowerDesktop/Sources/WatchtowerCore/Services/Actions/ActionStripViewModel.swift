import Foundation
import GRDB
import WatchtowerInterface

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
/// `InboxRecords.read` (the records the tower's feed names). AppState-owned so it
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
    /// Track my threads' Stopped fold is open (per session).
    package var showsStopped = false {
        didSet { rebuildSections() }
    }
    /// Days a route opened that the feed does not list (a day read
    /// already): their records are read too, so the pane can show them.
    private var routedDays: Set<String> = []
    /// Action id → "⚙ <automation> · run #<n>" for the rows an automation
    /// run proposed (`context_type='automation_run'`).
    package private(set) var actionLabels: [Int64: String] = [:]
    /// `finished_at` of the latest successful `reaction-commands` daemon run
    /// — the cheat sheet's "last check". Nil until the phase has run once.
    package private(set) var lastReactionCheck: String?
    package var lastError: String?
    /// The newest proposal of each Inbox target button the list can show
    /// (its outputs' and its proposals' `automation_output` contexts), by
    /// context id, as the last `refresh()` read it.
    package private(set) var targetProposals: [String: AgentAction] = [:]
    /// Of those, the applied rows whose task still exists.
    package private(set) var targetTasks: [Int64: Int64] = [:]
    /// The target buttons whose propose is running (one per context).
    package private(set) var proposingTargets: Set<String> = []
    /// Why a target button's last propose failed, by context id; survives
    /// navigation, cleared by the next propose that lands or exits 3 and by
    /// a read that finds a row newer than the one seen at the press.
    private var targetPressErrors: [String: TargetPressFailure] = [:]
    /// A failed press on a row with a `ref` (spec "Native row actions",
    /// Failure), by the row's record: the row keeps it with **Retry** until
    /// its next press or until the record leaves. `refresh()` keeps it
    /// (it clears only `lastError`). A proposal's failures live in
    /// `actionFeed.rowErrors`.
    package private(set) var rowErrors: [InboxSelection: InboxRowFailure] = [:]
    /// The open Reply composers by `inbox_items` id (Reply from a row): the
    /// text typed and the last refusal. Kept across refresh and navigation,
    /// dropped once the reply is proposed, on Cancel, or with its row.
    package private(set) var replyDrafts: [Int: InboxReplyDraft] = [:]
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
            folderMenu.disabledFeatures = disabledFeatures
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

    /// The folder the owner last picked in the menu, remembered per viewer;
    /// one that no longer exists opens the root.
    package static let folderKey = "inbox.folder"
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
        self.actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner, automationsWake: automationsWake)
        self.folderMenu = InboxFolderMenuModel(
            dbPool: dbPool, runner: { cliRunner ?? findCLI() }, clock: clock)
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
        let ids = towerFeed.map(InboxRecords.IDs.init(feed:)) ?? InboxRecords.IDs()
        let routedDays = routedDays
        let disabledFeatures = disabledFeatures
        do {
            // The feed, the labels and the folders in one read: the folder
            // menu, its counts and every folder's entries see the same
            // moment as the cards (the render-time check, spec "What 'open'
            // means").
            let snapshot = try await dbPool.read { db in
                let feed = try InboxRecords.read(
                    db, ids: ids, extraDates: routedDays, disabledFeatures: disabledFeatures, now: now)
                let runLabels = try AutomationQueries.runLabels(
                    db, runIDs: feed.proposals.compactMap(Self.automationRunID))
                let buttons = try AgentActionQueries.newestButtonProposals(
                    db, outputIDs: feed.outputs.map(\.id),
                    contextIDs: feed.proposals.filter { $0.contextType == AgentActionQueries.buttonContextType }
                        .map(\.contextID))
                let tasks = try AgentActionQueries.actionsWithTask(
                    db, actionIDs: buttons.values.filter { $0.status == "applied" }.map(\.id))
                return (
                    feed: feed,
                    buttons: buttons,
                    tasks: tasks,
                    labels: Self.labels(for: feed.proposals, runLabels: runLabels),
                    lastCheck: try PipelineRunQueries.lastSuccessfulFinish(db, pipeline: "reaction-commands"),
                    folders: try InboxFolderMenuSnapshot.read(db, nowUTC: nowUTC, disabledFeatures: disabledFeatures)
                )
            }
            let before = sections
            let entriesBefore = folderEntries.map(\.id)
            feed = snapshot.feed
            actionLabels = snapshot.labels
            lastReactionCheck = snapshot.lastCheck
            targetProposals = snapshot.buttons
            targetTasks = snapshot.tasks
            targetPressErrors = targetPressErrors.filter { context, failure in
                snapshot.buttons[context]?.id == failure.seenRowID
            }
            folderMenu.receive(snapshot.folders)
            if !hasRead { restoreSavedFolder() }
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

    /// The selected folder's entries, from the last read: the tower's feed
    /// decides them when one is wired (`towerFeed`), else the local builder.
    package var folderEntries: [InboxFolderEntry] {
        towerListed?.map(\.entry) ?? []
    }

    // MARK: - The tower (mobile Inbox spec §5.1)

    /// The pool the panes' records are read from (tests list its rows).
    package var databasePool: DatabasePool { dbPool }

    /// The tower's last feed: with one, the folders' lists, their order,
    /// counts, row texts, ref states and the badge are Go's
    /// (`InboxTowerEntries`); the GRDB read only supplies the records the
    /// panes draw. Nil until a loader is attached and has answered.
    package private(set) var towerFeed: Feed?

    /// The loader the Inbox window opens and closes (`InboxFeedLoader`).
    @ObservationIgnored package private(set) var feedLoader: InboxFeedLoader?

    /// Reads the Inbox from the tower from now on: every feed the loader
    /// gets is laid over the folders and re-reads the panes' records.
    package func attach(_ loader: InboxFeedLoader) {
        feedLoader = loader
        loader.onFeed = { [weak self] feed in self?.receiveTowerFeed(feed) }
        if let feed = loader.feed { receiveTowerFeed(feed) }
        syncFeedWatch()
    }

    /// Takes a feed: the lists switch to it at once over the records already
    /// read, and a records read follows so a new card's record arrives.
    package func receiveTowerFeed(_ feed: Feed) {
        let before = sections
        let entriesBefore = folderEntries.map(\.id)
        towerFeed = feed
        folderMenu.towerFeed = feed
        rebuildSections()
        keepSelectionListed(was: before)
        keepEntryListed(was: entriesBefore)
        Task { await refresh() }
    }

    /// The Inbox's line about its feed (mockup §7): first load, a failed
    /// read, reconnecting, another version; nil while the list is current
    /// and when no loader is attached (the Inbox reads only the database).
    package func feedStatus(now: Date) -> InboxMacFeedStatus? {
        guard let feedLoader else { return nil }
        return InboxMacFeedStatus.resolve(
            hasList: feedLoader.feed != nil, shownAt: feedLoader.answeredAt, failure: feedLoader.failure,
            state: feedLoader.state, showsReconnectingLine: feedLoader.showsReconnectingLine, now: now)
    }

    /// The feed line's Retry or Restart: the client's retry, then a read.
    package func retryFeed() async {
        await feedLoader?.retry()
    }

    /// The feed's card `id` ("o12", "a7"); nil without a feed or such a card.
    package func feedCard(_ id: String) -> Card? {
        towerFeed?.cards.first { $0.id == id }
    }

    /// Proposal `id`'s approval card as the feed words it; nil when the
    /// feed does not list it.
    package func feedApproval(_ id: Int64) -> Approval? {
        feedCard("a\(id)")?.approval
    }

    /// What the feed says about a row's record (`Card.ref_facts`): the facts
    /// Go sends for an artifact's rows and for the Messages card's items.
    package func refFacts(_ ref: InboxRef) -> RefFacts? {
        guard let towerFeed else { return nil }
        let kind = RefKind(rawValue: ref.kind.rawValue)
        for card in towerFeed.cards where card.cardKind == .artifact || card.legacy?.kind == .messages {
            if let facts = card.refFacts.first(where: { $0.kind == kind && $0.id == ref.id }) { return facts }
        }
        return nil
    }

    /// The sidebar's Inbox badge from the tower: the sum of the visible
    /// folders' counts (`InboxRootModel.countBadge`); nil without a feed.
    package var towerBadge: Int? {
        towerFeed.map { InboxRootModel(feed: $0, platform: .mac).countBadge }
    }

    /// The tower's writer: with one (the app), every Inbox write is one
    /// `inbox.act` call; without one (tests) the local writers run.
    @ObservationIgnored package private(set) var towerWrites: InboxTowerWrites?

    /// Writes the Inbox through the tower from now on, the approvals'
    /// decisions included (`AgentActionFeed.towerDecide`).
    package func attachWrites(_ writes: InboxTowerWrites) {
        towerWrites = writes
        actionFeed.towerDecide = { [weak self] decision, id in await self?.decide(decision, id) }
    }

    /// An approval's decision as `inbox.act approval` on its card `a<id>`:
    /// Approve pinned to the arguments drawn, Edit…'s changes as `patch`.
    private func decide(_ decision: AgentActionFeed.TowerDecision, _ id: Int64) async -> String? {
        guard let towerWrites else { return nil }
        let params: ActParams
        switch decision {
        case let .approve(sha, patch):
            var json: WatchtowerInterface.RawJSON?
            if let patch {
                // Never approve without the owner's edits: an edit that does not encode fails the press.
                guard let encoded = try? WatchtowerInterface.RawJSON(data: Data(patch.utf8)) else { return TowerText.couldNotSend }
                json = encoded
            }
            params = ActParams(approvalVerb: .approve, argsSHA256: sha, patch: json)
        case .reject: params = ActParams(approvalVerb: .reject)
        case .retry: params = ActParams(approvalVerb: .retry)
        case .dismiss: params = ActParams(approvalVerb: .dismiss)
        }
        if case let .failed(sentence) = await towerWrites.act(target: "a\(id)", verb: .approval, params: params) {
            return sentence
        }
        return nil
    }

    /// One `inbox.act` write per card at a time, then a read. A failure stays
    /// on its row (`press`) with **Retry**, which re-sends the same request;
    /// a record gone meanwhile leaves quietly. Nil when no tower writes.
    @discardableResult
    private func towerWrite(
        _ key: CardKey,
        press: InboxRowPress? = nil,
        target: String,
        verb: ActVerb,
        params: ActParams
    ) async -> InboxTowerWrites.Outcome? {
        guard let towerWrites else { return nil }
        return await pendingWrites.run(key) {
            lastError = nil
            let item: InboxSelection? = if press != nil, case let .card(item) = key { item } else { nil }
            if let item { rowErrors[item] = nil }
            let outcome = await towerWrites.act(target: target, verb: verb, params: params)
            await refresh()
            if case let .failed(sentence) = outcome {
                let gone = item.map { !isOpenRecord($0) } ?? false
                if !gone { lastError = sentence }
                if let item, let press, !gone { rowErrors[item] = InboxRowFailure(message: sentence, press: press) }
            }
            return outcome
        }
    }

    /// The selected folder's entries and rows from the tower's feed; nil
    /// without one (or before the first local read, which brings the records).
    private var towerListed: [InboxTowerEntries.Listed]? {
        guard let towerFeed, hasRead else { return nil }
        return InboxTowerEntries.listed(
            folder: folderMenu.selectedFolderID, feed: towerFeed, records: feed,
            selectedDay: entrySelection.flatMap(Self.dayOfEntry), now: clock())
    }

    /// The date of a day entry's id (`day:<yyyy-MM-dd>`), else nil.
    private static func dayOfEntry(_ id: String) -> String? {
        id.hasPrefix("day:") ? String(id.dropFirst("day:".count)) : nil
    }

    /// The selected folder's list column.
    package var folderList: InboxFolderListContent {
        let folder = folderMenu.tree.folder(folderMenu.selectedFolderID) ?? folderMenu.tree.root
        let rows = towerListed?.map(\.row) ?? []
        return InboxFolderListContent(
            folderKind: folder.kind, folderTitle: folder.title, rows: rows, selection: entrySelection)
    }

    /// The entry the reading pane shows (`InboxFolderEntry.id`); nil = none.
    package private(set) var entrySelection: String?

    /// The legacy list opened from the root (Track my threads, Idea finder,
    /// Messages): today's list for it, with its own reading pane.
    package private(set) var legacyList: InboxLegacyList? {
        didSet { if legacyList != oldValue { rebuildSections() } }
    }

    package var selectedEntry: InboxFolderEntry? {
        guard let entrySelection else { return nil }
        return folderEntries.first { $0.id == entrySelection }
    }

    /// The menu picked a folder: its list, nothing selected yet. The pick
    /// is remembered (`inbox.folder`); a route's folder never is.
    package func selectFolder(_ id: Int64) {
        folderMenu.select(id)
        defaults.set(folderMenu.selectedFolderID, forKey: Self.folderKey)
        feedLoader?.navigate(to: folderMenu.selectedFolderID)
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
        case let .brief(action):
            // Its agent-action card; a brief has no read mark to write.
            selection = .proposal(action.id)
            return nil
        case .legacyTracks, .legacyIdeas, .legacyMessages, .approval, .builtinNotice:
            selection = nil
            return nil
        }
    }

    /// Opens today's list for a legacy entry, with its own reading pane.
    package func openLegacy(_ list: InboxLegacyList) {
        legacyList = list
        selection = nil
    }

    /// The first read: the folder the owner last picked, or the root when
    /// it no longer exists (or none was saved).
    private func restoreSavedFolder() {
        guard let saved = defaults.object(forKey: Self.folderKey) as? NSNumber else { return }
        folderMenu.select(saved.int64Value)
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

    /// The open legacy list as the feed lists it (`InboxTowerEntries.sections`); empty while
    /// none is open. Rebuilt on each read and when the list or its Stopped
    /// fold changes.
    package private(set) var sections: [InboxSection] = []

    private func rebuildSections() {
        guard let legacyList else {
            sections = []
            return
        }
        sections = towerFeed.map {
            InboxTowerEntries.sections(
                legacyList, feed: $0, records: feed, now: clock(), calendar: .current, showsStopped: showsStopped)
        } ?? []
    }

    /// The selected card left the list (resolved elsewhere, auto-resolved,
    /// dismissed): the next row of the old list still listed, else the one
    /// above it, else none. Outside a legacy list the card stays open while
    /// the read still holds it (a folder's entries follow `keepEntryListed`).
    private func keepSelectionListed(was before: [InboxSection]) {
        guard let current = selection else { return }
        guard legacyList != nil else {
            if !feedHolds(current) { selection = nil }
            return
        }
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

    /// Routing entry (old links, Home, a built-in's Show in Inbox): opens
    /// `folder` (nil = the folder that lists `entry`, else the root; a
    /// folder that no longer exists opens the root) and `entry` in it.
    /// - A track, an idea or a message opens its legacy list (Track my
    ///   threads, Idea finder, Messages) over the root with its card
    ///   selected when listed: a stopped track opens the Stopped fold, a
    ///   merged idea the idea it was merged into.
    /// - A day opens its Morning brief entry in the root; a day past the
    ///   loaded pages reads older pages until it is there.
    /// - A thread brief applied in the last 24 hours opens its root entry.
    /// - An automation card opens the folder that lists it; a proposal, a
    ///   reminder, a notice or one of Needs approval's cards opens Needs
    ///   approval.
    /// Anything not listed selects nothing, so the pane never opens on a
    /// card the next refresh would drop. The route's folder is not
    /// remembered (`inbox.folder` keeps the owner's own pick).
    package func open(folder: Int64?, select entry: InboxRoute.Entry?) async {
        await refresh()
        closeLegacy()
        entrySelection = nil
        if let folder { folderMenu.select(folderMenu.tree.folder(folder) == nil ? folderMenu.tree.root.id : folder) }
        switch entry {
        case nil:
            if folder == nil { folderMenu.select(folderMenu.tree.root.id) }
        case let .legacy(list):
            showLegacy(list)
        case let .card(item):
            await openCard(item, keepFolder: folder != nil)
        }
    }

    /// A legacy entry's list over the root, its entry selected.
    private func showLegacy(_ list: InboxLegacyList) {
        folderMenu.select(folderMenu.tree.root.id)
        entrySelection = InboxFolderEntry.legacy(list).id
        openLegacy(list)
    }

    /// The card `item` in the folder or legacy list that lists it
    /// (`keepFolder`: the route named the folder, which stays selected).
    private func openCard(_ item: InboxSelection, keepFolder: Bool) async {
        let tree = folderMenu.tree
        func show(_ folder: Int64, _ entry: String?) {
            if !keepFolder { folderMenu.select(folder) }
            entrySelection = entry
            if let entry, !folderEntries.contains(where: { $0.id == entry }) { entrySelection = nil }
        }
        switch item {
        case .track(let id):
            showLegacy(.tracks)
            if !isListed(item), feed.stoppedTracks.contains(where: { $0.track.id == id }) {
                showsStopped = true
            }
            await select(isListed(item) ? item : nil)
        case .idea(let id):
            showLegacy(.ideas)
            let listed = isListed(item) ? id : await mergeTarget(of: id)
            await select(listed.map(InboxSelection.idea))
        case .message:
            showLegacy(.messages)
            await select(isListed(item) ? item : nil)
        case .day(let date):
            // A day the feed does not list (read, not today) still opens:
            // its record is read by date, and the selected day stays listed.
            if !feed.days.contains(where: { $0.date == date }) {
                routedDays.insert(date)
                await refresh()
            }
            show(tree.root.id, "day:\(date)")
            if entrySelection != nil { await select(item) }
        case .output(let id):
            let folder = towerFeed?.cards.first { $0.id == "o\(id)" }?.folderID ?? tree.root.id
            if folder == tree.approvals?.id {
                // The recipe's card for an approval is drawn only through its approval.
                show(folder, nil)
                return
            }
            show(folder, "artifact:\(id)")
            if entrySelection != nil { await select(item) }
        case let .proposal(id):
            openProposal(id, show: show)
        case let .reminder(id):
            show((tree.approvals ?? tree.root).id, "approval:reminder:\(id)")
        case .builtinNotice(let builtinID):
            show((tree.approvals ?? tree.root).id, "notice:\(builtinID)")
        }
    }

    /// A proposal's card through `openCard`'s `show`: a thread brief applied
    /// in the last 24 hours is a root entry of its own (ask #609); any other
    /// proposal is selected in Needs approval's stack, so the stack scrolls to it.
    private func openProposal(_ id: Int64, show: (Int64, String?) -> Void) {
        let tree = folderMenu.tree
        guard feed.briefs.contains(where: { $0.id == id }) else {
            show((tree.approvals ?? tree.root).id, "approval:action:\(id)")
            return
        }
        show(tree.root.id, "brief:\(id)")
        if entrySelection != nil { selection = .proposal(id) }
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

    /// The last read still holds `item` as an open card (today's day is
    /// always held: its placeholder stands in for it).
    private func feedHolds(_ item: InboxSelection) -> Bool {
        switch item {
        case let .output(id): feed.outputs.contains { $0.id == id }
        case let .proposal(id): (feed.proposals + feed.briefs).contains { $0.id == id }
        case let .reminder(id): feed.reminders.contains { $0.id == id }
        case let .builtinNotice(id): feed.builtinNotices.contains { $0.builtinID == id }
        case let .day(date):
            date == HomeFeedBuilder.dayString(clock(), calendar: .current) || feed.days.contains { $0.date == date }
        case let .track(id): (feed.tracks + feed.stoppedTracks).contains { $0.track.id == id }
        case let .idea(id): feed.ideas.contains { $0.id == id }
        case let .message(id): feed.messages.contains { $0.item.id == id }
        }
    }

    private func isListed(_ item: InboxSelection) -> Bool {
        sections.contains { $0.items.contains { $0.id == item } }
    }

    // MARK: - Polling (board #731)

    /// The Inbox went on or off screen: off screen the poll skips; back on
    /// screen after a skipped tick, one refresh at once. On screen starts the
    /// 30 s poll the first time.
    package func setOnScreen(_ onScreen: Bool) {
        if refreshGate.setOnScreen(onScreen) { onScreenRefresh = Task { await refresh() } }
        if onScreen { startPolling() }
        inboxShown = onScreen
        syncFeedWatch()
    }

    /// The app's windows went on or off screen (`AppState.applyUIVisibility`):
    /// the tower's change watch stays open only while the Inbox is shown in
    /// a window on screen, never while the app sits in the tray.
    package func setWindowOnScreen(_ onScreen: Bool) {
        windowShown = onScreen
        syncFeedWatch()
    }

    @ObservationIgnored private var inboxShown = false
    @ObservationIgnored private var windowShown = true

    private func syncFeedWatch() {
        guard let feedLoader else { return }
        if inboxShown && windowShown { feedLoader.open() } else { feedLoader.close() }
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
    /// approvals changed` so Needs approval's recipe redraws (STRIP-03) —
    /// after the press settles, so the CLI process never holds the row busy.
    package func markReminderDone(_ id: Int64) async {
        if towerWrites != nil {
            // Go runs the reminder's approval hook in the same call.
            await towerWrite(.card(.reminder(id)), press: .done, target: "r\(id)", verb: .ref,
                             params: ActParams(refKind: .reminder, refID: id, refVerb: .done))
            return
        }
        guard await write(.card(.reminder(id)), { try ReminderQueries.markDone($0, id: id) }, press: .done)
        else { return }
        await reminderChanged(id)
    }

    /// Snooze on a reminder (Snooze 1h is the only one the cards offer).
    package func snoozeReminder(_ id: Int64, until: String) async {
        if towerWrites != nil {
            await towerWrite(.card(.reminder(id)), press: .snoozeHour, target: "r\(id)", verb: .ref,
                             params: ActParams(refKind: .reminder, refID: id, refVerb: .snooze, until: until))
            return
        }
        // Labeled: `change` before it also takes a closure.
        // swiftlint:disable trailing_closure
        let snoozed = await write(.card(.reminder(id)), { try ReminderQueries.snooze($0, id: id, until: until) },
                                  press: .snoozeHour, onFailure: { error in
            // A reminder deleted elsewhere leaves the strip; `refresh` clears
            // `lastError`, so the reason is set after it.
            if error is RowNotFoundError { await self.refresh() }
        })
        // swiftlint:enable trailing_closure
        if snoozed { await reminderChanged(id) }
    }

    /// `watchtower inbox approvals changed --ref reminder:<id>` through the
    /// one helper Home shares (`ReminderApprovalHook`): logged, never shown.
    private func reminderChanged(_ id: Int64) async {
        await ReminderApprovalHook.changed(id, runner: cliRunner ?? ProcessCLIRunner.makeDefault())
    }

    /// Shows `item` in the reading pane. Opening an unread card writes its
    /// read mark only: an output its `read_at`, a day card its briefing's
    /// `read_at` (CATCHUP-01's surface), a message its `read_at`; a track,
    /// idea, proposal, reminder or built-in notice writes nothing. The card stays listed, now
    /// read. The opening has a key of its own: the card's buttons do not wait
    /// for it, and a Done or Dismiss pressed meanwhile still lands.
    package func select(_ item: InboxSelection?) async {
        selection = item
        if towerWrites != nil {
            guard let item, let opening = towerOpening(item) else { return }
            await towerWrite(.opening(item), target: opening.target, verb: .read, params: opening.params)
            return
        }
        guard let item, let change = openingWrite(item) else { return }
        await write(.opening(item), change)
    }

    /// `openingWrite` through the tower: `inbox.act read` on the card drawn,
    /// only while it is unread.
    private func towerOpening(_ item: InboxSelection) -> (target: String, params: ActParams)? {
        switch item {
        case .output(let id):
            guard let card = outputRows.first(where: { $0.id == id }), card.isUnread else { return nil }
            return ("o\(id)", ActParams(contentHash: card.contentHash))
        case .day(let date):
            guard let briefing = feed.days.first(where: { $0.date == date })?.briefing, !briefing.isRead else { return nil }
            return ("brief-\(date)", ActParams())
        case .message(let id):
            guard feed.messages.first(where: { $0.item.id == id })?.item.isUnread == true else { return nil }
            return ("messages", ActParams(refKind: .inboxItem, refID: Int64(id)))
        case .proposal, .reminder, .track, .idea, .builtinNotice:
            return nil
        }
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
        if towerWrites != nil {
            await trackRef(id, .done, press: .done)
            return
        }
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
        if towerWrites != nil {
            // Go stops a custom track's collection too.
            await trackRef(id, .stop, press: .stopWatching)
            return
        }
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
        if towerWrites != nil {
            await trackRef(id, .restore, press: nil)
            return
        }
        guard track.isCustom else {
            await write(.card(.track(id))) { db in
                do { try TrackQueries.restore(db, id: id) } catch is RowNotFoundError {}
            }
            return
        }
        await throughSeam(track) { try await $0.resumeWatching(track) }
    }

    private func trackRef(_ id: Int, _ verb: RefVerb, press: InboxRowPress?) async {
        await towerWrite(.card(.track(id)), press: press, target: "tracks", verb: .ref,
                         params: ActParams(refKind: .track, refID: Int64(id), refVerb: verb))
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
        if towerWrites != nil { return await messageRef(id, .resolve, press: .done) }
        await runInboxCLI(id, ["inbox", "resolve", "\(id)"], press: .done)
    }

    /// Hide on a message card: `watchtower inbox dismiss <id>`.
    package func hideMessage(_ id: Int) async {
        if towerWrites != nil { return await messageRef(id, .dismiss, press: .hide) }
        await runInboxCLI(id, ["inbox", "dismiss", "\(id)"], press: .hide)
    }

    /// Snooze on a message card: `watchtower inbox snooze <id> <duration>`, `duration` "1d", "3d" or "1w".
    package func snoozeMessage(_ id: Int, duration: String) async {
        if towerWrites != nil {
            guard let until = Self.snoozeDate(duration, now: clock()) else { return }
            return await messageRef(id, .snooze, press: .snooze(duration: duration), until: until)
        }
        await runInboxCLI(id, ["inbox", "snooze", "\(id)", duration], press: .snooze(duration: duration))
    }

    private func messageRef(_ id: Int, _ verb: RefVerb, press: InboxRowPress, until: String? = nil) async {
        await towerWrite(.card(.message(id)), press: press, target: "messages", verb: .ref,
                         params: ActParams(refKind: .inboxItem, refID: Int64(id), refVerb: verb, until: until))
    }

    /// A message snooze's end as `watchtower inbox snooze` writes it: the
    /// local date `duration` ("1d", "3d", "1w") from `now`; nil for another form.
    nonisolated static func snoozeDate(_ duration: String, now: Date, calendar: Calendar = .current) -> String? {
        let text = duration.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last, let count = Int(text.dropLast()), count > 0 else { return nil }
        let days: Int
        switch unit {
        case "d": days = count
        case "w": days = count * 7
        default: return nil
        }
        guard let date = calendar.date(byAdding: .day, value: days, to: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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

    // MARK: - Reply from a row

    /// What sits under item `itemID`'s row for Reply: "Reply waiting for
    /// approval" while its reply is open in Needs approval, else its
    /// composer while one is open, else nothing.
    package func replyState(_ itemID: Int) -> InboxRowActionsContent.Reply? {
        if replyWaiting(itemID) { return .waiting }
        return replyDrafts[itemID].map { .composing(text: $0.text, error: $0.error) }
    }

    /// Item `itemID` has a Reply open (pending, approved or executing): one
    /// reply per item at a time. Go's `reply_waiting`; false when the feed
    /// has no facts for it.
    package func replyWaiting(_ itemID: Int) -> Bool {
        refFacts(InboxRef(kind: .inboxItem, id: Int64(itemID)))?.replyWaiting ?? false
    }

    /// Whether item `itemID`'s row has **Reply…**: Go's `reply` (a Slack,
    /// Jira or Linear item with its place); false when the feed has no
    /// facts for it.
    package func canReply(_ itemID: Int64) -> Bool {
        refFacts(InboxRef(kind: .inboxItem, id: itemID))?.reply ?? false
    }

    /// **Reply…**: opens the composer under the row (nothing written).
    package func startReply(_ itemID: Int) {
        guard replyDrafts[itemID] == nil, !replyWaiting(itemID) else { return }
        replyDrafts[itemID] = InboxReplyDraft()
    }

    /// Typing in the composer; held still while its propose runs, so the
    /// text that goes to Needs approval is the text on screen.
    package func editReply(_ itemID: Int, text: String) {
        guard !isWriting(.message(itemID)) else { return }
        replyDrafts[itemID]?.text = text
    }

    /// Cancel or Esc: the composer closes, nothing proposed. Not while its
    /// propose runs: the proposal would land with the composer gone.
    package func cancelReply(_ itemID: Int) {
        guard !isWriting(.message(itemID)) else { return }
        replyDrafts[itemID] = nil
    }

    /// **Propose Reply**: `watchtower actions propose --tool <reply tool>
    /// --surface inbox --context inbox_item:<id>` without `--approve` — a
    /// pending proposal that waits for the owner's Approve in Needs
    /// approval; the Desktop writes nothing and sends nothing. `host` is the
    /// title of what the row is on, for the reason ("Reply from <host>").
    /// One press per row at a time (the row is busy meanwhile). A refusal
    /// keeps the composer open with the CLI's message; never retried.
    package func proposeReply(_ itemID: Int, text: String, host: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, replyDrafts[itemID] != nil,
              let item = feed.messages.first(where: { $0.item.id == itemID })?.item,
              let tool = InboxReplyPolicy.tool(for: item) else { return }
        guard let args = InboxReplyPolicy.args(for: item, text: body, host: host) else {
            // The args could not be encoded (not expected): say so on the draft, never a silent no-op.
            replyDrafts[itemID]?.error = Self.replyNotBuilt
            return
        }
        if towerWrites != nil { return await towerProposeReply(itemID, text: body) }
        let runner = cliRunner
        let sent = replyDrafts[itemID]?.text
        await pendingWrites.run(CardKey.card(.message(itemID))) {
            replyDrafts[itemID]?.error = nil
            guard let runner = runner ?? ProcessCLIRunner.makeDefault() else {
                replyDrafts[itemID]?.error = HomeFeedActionError.cliUnavailable.localizedDescription
                return
            }
            let failure: String?
            do {
                let data = try await runner.run(
                    args: InboxReplyPolicy.arguments(itemID: itemID, tool: tool, args: args),
                    timeout: HomeFeedActionError.cliTimeout)
                failure = Self.proposeFailure(data)
            } catch {
                failure = Self.replyRefusal(AutomationsViewModel.message(for: error))
            }
            // Only the text that was sent: a newer one is never dropped without a word.
            if failure == nil, replyDrafts[itemID]?.text == sent { replyDrafts[itemID] = nil }
            await refresh()
            if let failure { replyDrafts[itemID]?.error = failure }
        }
    }

    /// Propose Reply through the tower: `inbox.act reply_propose` on the card
    /// the row is on (the open artifact, else Messages); Go builds the
    /// reply's tool and arguments. A refusal keeps the composer with Go's
    /// sentence; never retried.
    private func towerProposeReply(_ itemID: Int, text: String) async {
        guard let towerWrites else { return }
        let target = if case let .output(id)? = selection { "o\(id)" } else { "messages" }
        let sent = replyDrafts[itemID]?.text
        await pendingWrites.run(CardKey.card(.message(itemID))) {
            replyDrafts[itemID]?.error = nil
            let outcome = await towerWrites.act(
                target: target, verb: .replyPropose, params: ActParams(text: text, refKind: .inboxItem, refID: Int64(itemID)))
            if case .done = outcome, replyDrafts[itemID]?.text == sent { replyDrafts[itemID] = nil }
            await refresh()
            if case let .failed(sentence) = outcome { replyDrafts[itemID]?.error = sentence }
        }
    }

    /// The draft's error when its reply's args could not be built.
    nonisolated static let replyNotBuilt = "Couldn't prepare this reply. Try again, or reply in Slack."

    /// The failure an exit-0 `actions propose --json` answer carries: an
    /// envelope `error`, `ok` false, or an answer without the proposal's
    /// pinned `action.id` (`{}` included) — never taken for success.
    nonisolated static func proposeFailure(_ data: Data) -> String? {
        let unexpected = "Unexpected answer from watchtower"
        guard let env = try? JSONDecoder().decode(AgentActionFeed.Envelope.self, from: data) else {
            return unexpected
        }
        if let error = env.error, !error.isEmpty { return error }
        guard env.ok else { return "The reply was not proposed." }
        return (try? JSONDecoder().decode(ProposedAction.self, from: data)) == nil ? unexpected : nil
    }

    /// The one key a proposal's answer must carry: its row's id.
    private struct ProposedAction: Decodable {
        struct Action: Decodable { let id: Int64 }
        let action: Action
    }

    /// Done on an output card: writes `done_at` only, at the version drawn.
    /// The card leaves the strip only once the write landed; a card
    /// rewritten under the view (its hash moved) changes nothing and is
    /// read again, so the new version shows; a failure keeps it and says why.
    package func markOutputDone(_ id: Int64) async {
        let now = Date()
        let hash = drawnHash(id)
        if towerWrites != nil { return await closeOutput(id, .done, hash: hash) }
        await guardedWrite(.output(id)) { try AutomationQueries.markOutputDone($0, id: id, contentHash: hash, now: now) }
    }

    /// Dismiss on an output card: writes `dismissed_at` only, at the version drawn.
    package func dismissOutput(_ id: Int64) async {
        let now = Date()
        let hash = drawnHash(id)
        if towerWrites != nil { return await closeOutput(id, .dismiss, hash: hash) }
        await guardedWrite(.output(id)) { try AutomationQueries.dismissOutput($0, id: id, contentHash: hash, now: now) }
    }

    /// Done or Dismiss through the tower, at the version drawn: the card is
    /// deselected only when its row changed.
    private func closeOutput(_ id: Int64, _ verb: ActVerb, hash: String) async {
        let outcome = await towerWrite(.card(.output(id)), target: "o\(id)", verb: verb, params: ActParams(contentHash: hash))
        if outcome == .done(already: false) { deselect(.output(id)) }
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
        if towerWrites != nil {
            await towerWrite(.card(.output(outputID)), target: "o\(outputID)", verb: .press,
                             params: ActParams(contentHash: contentHash, index: action, actionKind: "reply"))
            return
        }
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
        /// A target button's propose, by its context id.
        case targetPress(String)
        /// The card's read mark on opening.
        case opening(InboxSelection)
    }

    /// One write per card: a second press while it waits does nothing.
    /// `press` is a row's native press: its failure is also kept on the row
    /// (`rowErrors`), except a vanished record's, which leaves quietly.
    /// True when the write landed (false too for a press that did not run).
    @discardableResult
    private func write(
        _ key: CardKey,
        _ change: @escaping @Sendable (Database) throws -> Void,
        press: InboxRowPress? = nil,
        onFailure: (Error) async -> Void = { _ in }
    ) async -> Bool {
        let pool = dbPool
        return await pendingWrites.run(key) {
            lastError = nil
            let item: InboxSelection? = if press != nil, case let .card(item) = key { item } else { nil }
            if let item { rowErrors[item] = nil }
            do {
                try await pool.write(change)
                await refresh()
                return true
            } catch {
                await onFailure(error)
                lastError = error.localizedDescription
                if let item, let press, !(error is RowNotFoundError) {
                    rowErrors[item] = InboxRowFailure(message: error.localizedDescription, press: press)
                }
                return false
            }
        } ?? false
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

    /// A row error or Reply draft whose record is no longer shown goes with its row.
    private func dropLeftRowErrors() {
        if !rowErrors.isEmpty {
            rowErrors = rowErrors.filter { item, _ in isOpenRecord(item) }
        }
        if !replyDrafts.isEmpty {
            // A draft whose reply now waits in Needs approval goes too (a
            // propose that timed out may have landed): it never comes back
            // with its old error once that reply is decided.
            replyDrafts = replyDrafts.filter { id, _ in isOpenRecord(.message(id)) && !replyWaiting(id) }
        }
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

    // MARK: - Inbox target buttons (Inbox builder A)

    /// A failed propose and the newest row of its context when it was pressed.
    private struct TargetPressFailure {
        let message: String
        let seenRowID: Int64?
    }

    /// The target button of `contextID` as drawn: Go's state of the feed's
    /// `action` (nil: idle) with the press addresses of its newest proposal
    /// and this Desktop's own processes on it.
    package func targetButton(contextID: String, action: CardAction?) -> InboxTargetButton {
        var button = InboxTargetButton(action: action)
        let row = targetProposals[contextID]
        button.proposalID = row?.id
        button.taskID = row.flatMap { targetTasks[$0.id] }
        button.inFlight = row.map { actionFeed.inFlight.contains($0.id) } ?? false
        button.pressError = targetPressErrors[contextID]?.message
        button.applyError = row.flatMap { actionFeed.rowErrors[$0.id]?.message }
        return button
    }

    /// The target button a proposal's approval card draws, when the feed
    /// says the proposal is its button's newest row (`Approval.target`);
    /// nil for any other row (an older row of a button is never offered
    /// Try again).
    package func targetButton(forApproval action: AgentAction) -> InboxTargetButton? {
        guard var button = InboxTargetButton(approval: feedApproval(action.id)) else { return nil }
        button.proposalID = action.id
        button.taskID = targetTasks[action.id]
        button.inFlight = actionFeed.inFlight.contains(action.id)
        button.applyError = actionFeed.rowErrors[action.id]?.message
        return button
    }

    /// A button's row with a newer row of the same button (the feed's
    /// `Approval.superseded`): nothing on its card may retry it (Go refuses it).
    package func isSupersededButtonRow(_ action: AgentAction) -> Bool {
        feedApproval(action.id)?.superseded ?? false
    }

    /// The press of an idle target button: one `actions propose`, never
    /// `--approve` (AUTO-02). One press per button at a time. Exit 3 means
    /// the button's state moved (an open proposal, its task exists): no
    /// banner, the read draws it. Any other failure is kept for the button.
    package func proposeTarget(_ press: InboxTargetPress) async {
        if let towerWrites { return await towerProposeTarget(press, towerWrites) }
        let runner = cliRunner
        let context = press.contextID
        await pendingWrites.run(CardKey.targetPress(context)) {
            proposingTargets.insert(context)
            defer { proposingTargets.remove(context) }
            let seen = targetProposals[context]?.id
            guard let runner = runner ?? ProcessCLIRunner.makeDefault() else {
                targetPressErrors[context] = TargetPressFailure(
                    message: CLIRunnerError.binaryNotFound.localizedDescription, seenRowID: seen)
                return
            }
            do {
                _ = try await runner.run(args: press.arguments)
                targetPressErrors[context] = nil
            } catch CLIRunnerError.nonZeroExit(AgentActionFeed.stateMovedExit, _) {
                targetPressErrors[context] = nil
            } catch {
                targetPressErrors[context] = TargetPressFailure(message: Self.pressRefusal(error), seenRowID: seen)
            }
            await refresh()
        }
    }

    /// A target button through the tower: `inbox.act press` of the drawn
    /// `target` action at the card's drawn version; Go proposes the
    /// `create_target` (never approved). A refusal is kept for the button.
    private func towerProposeTarget(_ press: InboxTargetPress, _ towerWrites: InboxTowerWrites) async {
        let context = press.contextID
        let parts = context.split(separator: ":")
        guard parts.count >= 2, let outputID = Int64(parts[0]), let index = Int(parts[1]) else { return }
        let hash = drawnHash(outputID)
        await pendingWrites.run(CardKey.targetPress(context)) {
            proposingTargets.insert(context)
            defer { proposingTargets.remove(context) }
            let seen = targetProposals[context]?.id
            let outcome = await towerWrites.act(
                target: "o\(outputID)", verb: .press, params: ActParams(contentHash: hash, index: index, actionKind: "target"))
            if case let .failed(sentence) = outcome {
                targetPressErrors[context] = TargetPressFailure(message: sentence, seenRowID: seen)
            } else {
                targetPressErrors[context] = nil
            }
            await refresh()
        }
    }

    /// **Try again** on a target button's stuck or failed row, or on its
    /// approval card: the same row, never a new proposal — `actions apply`
    /// for an approved or failed row, `actions apply --force` for one
    /// stranded in `executing`.
    package func tryAgainTarget(_ id: Int64) async {
        let row = targetProposals.values.first { $0.id == id } ?? actionRows.first { $0.id == id }
        await actionFeed.retry(id, force: row?.isExecuting == true)
        await refresh()
        adoptFeedError()
    }

    /// A waiting button's click: Needs approval, its approval card selected
    /// and scrolled to. When the read has no such row, the shown card stays
    /// and a short notice says why; the button keeps its waiting state.
    package func openProposal(_ id: Int64) async {
        if actionRows.contains(where: { $0.id == id }) {
            await open(folder: nil, select: .card(.proposal(id)))
        } else {
            lastError = Self.proposalNotListed(id)
        }
    }

    /// The notice of a waiting button whose approval card the list does not show.
    nonisolated static func proposalNotListed(_ id: Int64) -> String {
        "The approval for this task (#\(id)) isn't in the Inbox list yet."
    }

    /// A CLI refusal's own text (stderr's last line, `InboxFoldersCLI.lastLine`,
    /// without cobra's "Error: "), else the error's.
    nonisolated static func pressRefusal(_ error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let text = InboxFoldersCLI.lastLine(stderr)
            return text.isEmpty ? "watchtower exited with code \(code)" : replyRefusal(text)
        }
        return error.localizedDescription
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

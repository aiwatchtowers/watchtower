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
    /// Track my threads' Stopped fold is open (per session).
    package var showsStopped = false {
        didSet { rebuildSections() }
    }
    /// How many dates the read takes; `showOlderDays()` adds a page (a
    /// route to an old day reads pages until the day is there).
    package var dayLimit = ActionStripViewModel.dayPage
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
    /// How the bulk presses find the binary when `cliRunner` is nil.
    private let findCLI: @MainActor () -> (any CLIRunnerProtocol)?
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
    /// Re-reads on a day, zone or wake change (set once in `init`).
    @ObservationIgnored private var dayChangeObserver: InboxDayChangeObserver?

    /// The folder the owner last picked in the menu, remembered per viewer;
    /// one that no longer exists opens the root.
    package static let folderKey = "inbox.folder"
    /// The dates one page of the read takes. The Morning brief's History
    /// and the root's Earlier line rely on the first page holding every
    /// card of the last 30 dates (`InboxBriefDays.window`): lowering this
    /// below 30 breaks them.
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
    /// `dayChangeSignals`: each one re-reads (`refresh()`), since "today"
    /// (the people count, today's brief) moves with no database write; the
    /// app adds the wake from sleep to the system's two.
    package init(
        dbPool: DatabasePool,
        cliRunner: CLIRunnerProtocol? = nil,
        customTrackControls: (any CustomTrackControlling)? = nil,
        defaults: UserDefaults = .standard,
        automationsWake: (() async throws -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        findCLI: @escaping @MainActor () -> (any CLIRunnerProtocol)? = { ProcessCLIRunner.makeDefault() },
        dayChangeSignals: [InboxDayChangeObserver.Signal] = InboxDayChangeObserver.systemSignals()
    ) {
        self.dbPool = dbPool
        self.clock = clock
        self.cliRunner = cliRunner
        self.findCLI = findCLI
        self.customTrackControls = customTrackControls ?? DirectCustomTrackControls(
            dbPool: dbPool, scanService: TrackScanService(runner: cliRunner ?? InstalledCLIRunner()))
        self.defaults = defaults
        self.railHidden = defaults.bool(forKey: Self.railHiddenKey)
        self.actionFeed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner, automationsWake: automationsWake)
        self.folderMenu = InboxFolderMenuModel(
            dbPool: dbPool, runner: { cliRunner ?? findCLI() }, clock: clock)
        self.dayChangeObserver = InboxDayChangeObserver(signals: dayChangeSignals) { [weak self] in
            Task { await self?.refresh() }
        }
    }

    /// The Inbox sidebar badge (spec "Counts", STRIP badge amendment, ask
    /// #634): Needs approval's open approvals (proposals awaiting the owner,
    /// due reminders, built-in upgrade notices) + people waiting today (open
    /// messages whose `MAX(created_at, mentioned_at)` is at or after local
    /// midnight in `calendar`, `InboxToday`; 0 while Waiting for me is turned
    /// off). Ideas, briefings, Messages' unread count and every automation
    /// artifact, root or owner folder, stay out of it. One read, writing
    /// nothing; each source tolerates a schema that predates it (its table
    /// missing counts 0), any other read error is thrown, never folded into
    /// 0. `disabledFeatures` as in `InboxFolderMenuSnapshot.read`.
    nonisolated package static func badgeCount(
        _ db: Database, nowUTC: String, disabledFeatures: Set<String> = [], calendar: Calendar = .current
    ) throws -> Int {
        try InboxFolderMenuSnapshot.read(
            db, nowUTC: nowUTC, disabledFeatures: disabledFeatures, calendar: calendar).badge
    }

    /// The counts each folder shows outside its artifacts, by the folder
    /// that shows them: the root's people waiting today (`peopleWaitingToday`)
    /// + 1 while `today`'s briefing is unread; Needs approval's approvals
    /// (`approvalCount`), in the root on a tree without Needs approval.
    /// Ideas, unread messages and older briefings are not among them.
    nonisolated package static func legacyCounts(
        _ db: Database,
        nowUTC: String,
        today: String,
        tree: InboxFolderTree,
        peopleWaitingToday: Int
    ) throws -> [Int64: Int] {
        let root = try peopleWaitingToday + zeroIfTableMissing { try BriefingQueries.unreadCount(db, date: today) }
        var out: [Int64: Int] = [tree.root.id: root]
        out[tree.approvals?.id ?? tree.root.id, default: 0] += try approvalCount(db, nowUTC: nowUTC)
        return out
    }

    /// Needs approval's open approvals: proposals awaiting the owner, due
    /// reminders, built-in upgrade notices (C2).
    nonisolated package static func approvalCount(_ db: Database, nowUTC: String) throws -> Int {
        try zeroIfTableMissing { try AgentActionQueries.awaitingOwnerCount(db) }
            + zeroIfTableMissing { try ReminderQueries.dueCount(db, nowUTC: nowUTC) }
            + zeroIfTableMissing { try BuiltinUpgradeNotice.load(db).count }
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
                    folders: try InboxFolderMenuSnapshot.read(
                        db, nowUTC: nowUTC, disabledFeatures: disabledFeatures, calendar: Self.calendar)
                )
            }
            let before = sections
            let entriesBefore = listedFolder.rows.map(\.id)
            let firstRead = !hasRead
            feed = snapshot.feed
            ideaBatch = IdeaDailyBatch(defaults: defaults).today(ideas: feed.ideas, now: now, calendar: Self.calendar)
            if let opened = openedNewsTrackID, !feed.tracks.contains(where: { $0.track.id == opened }) {
                openedNewsTrackID = nil
            }
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
            resetStaleApproveAll()
            keepSelectionListed(was: before)
            if firstRead {
                showDefaultEntry()
            } else {
                keepEntryListed(was: entriesBefore)
            }
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
            approvalsOn: !disabledFeatures.contains(Self.approvalsFeatureID), now: clock(), calendar: Self.calendar,
            ideaBatch: ideaBatch)
    }

    /// The per-viewer key of `railHidden`.
    package static let railHiddenKey = "inbox.railHidden"

    /// The folder rail is collapsed (View → Hide Inbox Folders, ⌥⌘S),
    /// remembered per viewer (`inbox.railHidden`, default shown).
    package var railHidden = false {
        didSet { defaults.set(railHidden, forKey: Self.railHiddenKey) }
    }

    /// The list's search: one query for every folder, kept across
    /// navigation (this model is AppState-owned). Filtering never touches
    /// the selection.
    package var listQuery = ""

    /// The selected folder's list column as drawn: `listedFolder` filtered
    /// by `listQuery` (`InboxListFilter`), the Earlier line hidden while a
    /// search is on.
    package var folderList: InboxFolderListContent {
        var list = listedFolder
        guard !InboxListFilter.trimmed(listQuery).isEmpty else { return list }
        list.sections = InboxListFilter.apply(list.sections, query: listQuery)
        list.earlierLine = nil
        list.query = listQuery
        return list
    }

    /// The selected folder's whole list, no search applied: the root's and
    /// an owner folder's sections (`InboxRootSections`), the root's Earlier
    /// line, Needs approval's groups (`NeedsApprovalGroups.sections`). What
    /// keeps the selection listed (`keepEntryListed`) reads, so a search
    /// that hides the selected row never moves the selection.
    private var listedFolder: InboxFolderListContent {
        let folder = folderMenu.tree.folder(folderMenu.selectedFolderID) ?? folderMenu.tree.root
        let inputs = entryInputs
        let sections: [InboxListSection]
        if folder.kind == .approvals {
            sections = NeedsApprovalGroups.sections(
                folderEntries, openActions: folderMenu.snapshot.openActions, now: inputs.now,
                calendar: inputs.calendar) { InboxFolderEntries.row($0, inputs) }
        } else {
            let grouped = InboxRootSections.build(
                entries: folderEntries, folder: folder.kind,
                waitingForMeAutomationID: folderMenu.snapshot.waitingForMe.automationID,
                now: inputs.now, calendar: inputs.calendar)
            sections = grouped.map { section, entries in
                InboxListSection(id: section.rawValue, title: section.title,
                                 rows: entries.map { InboxFolderEntries.row($0, inputs) })
            }
        }
        let earlier = folder.kind == .root
            ? InboxRootSections.earlierLine(
                days: feed.days, today: HomeFeedBuilder.dayString(inputs.now, calendar: inputs.calendar),
                now: inputs.now, calendar: inputs.calendar)
            : nil
        return InboxFolderListContent(
            folderKind: folder.kind, folderTitle: folder.title, sections: sections, earlierLine: earlier,
            selection: entrySelection)
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

    /// The menu picked a folder: its list with its default entry
    /// (`defaultEntry`: the owner's last pick there, today's brief in the
    /// root, else the first entry). The pick is remembered
    /// (`inbox.folder`); a route's folder never is. Picking a folder is
    /// the owner's arrival there (`ownerArrived`, awaitable as `arrival`).
    package func selectFolder(_ id: Int64) {
        folderMenu.select(id)
        defaults.set(folderMenu.selectedFolderID, forKey: Self.folderKey)
        legacyList = nil
        selection = nil
        openedNewsTrackID = nil
        resetBriefDay()
        showDefaultEntry()
        arrival = Task { await ownerArrived() }
    }

    /// The `ownerArrived` a folder pick started — held so tests can await it.
    package private(set) var arrival: Task<Void, Never>?

    /// The per-viewer key of the entry the owner last opened in `folderID`.
    package static func entryKey(_ folderID: Int64) -> String {
        "inbox.entry.\(folderID)"
    }

    /// Opens an entry (the owner's click): remembered for its folder
    /// (`entryKey`); an artifact or a day writes its read mark on opening
    /// (`select`); a legacy list opens today's list for it. The Morning
    /// brief opens on today.
    package func selectEntry(_ id: String?) async {
        let key = Self.entryKey(folderMenu.selectedFolderID)
        if let id { defaults.set(id, forKey: key) } else { defaults.removeObject(forKey: key) }
        openedNewsTrackID = nil
        // A click on the Morning brief opens it on today (`showEntry` keeps
        // the day it shows for a day entry).
        resetBriefDay()
        guard let opening = showEntry(id) else { return }
        await select(opening)
    }

    /// The selected folder's default entry (`InboxFolderEntries.defaultEntry`),
    /// shown without a read mark (STRIP-02: a read writes nothing).
    private func showDefaultEntry() {
        let tree = folderMenu.tree
        let folder = tree.folder(folderMenu.selectedFolderID) ?? tree.root
        _ = showEntry(InboxFolderEntries.defaultEntry(
            entries: folderEntries, saved: defaults.string(forKey: Self.entryKey(folder.id)),
            folder: folder.kind, today: today, drawnRows: listedFolder.rows.map(\.id)))
    }

    /// The owner opened the Inbox (`ActionStripView.onAppear`) or picked a
    /// folder: a gesture, so the Morning brief day or the unread artifact
    /// the default pick put on screen is marked read now ("a brief is read
    /// once opened"), through `select`. Waits for the first read. A poll, a
    /// refresh or the midnight rollover never calls this (STRIP-02). It
    /// yields to a route (`beginRoute`, `open`): one pending, running or
    /// started while it waits marks nothing, since the card on screen is
    /// the route's, whose own opening writes its mark.
    package func ownerArrived() async {
        let generation = routeGeneration
        guard !routePending else { return }
        if !hasRead {
            if let running = refreshTask { await running.value } else { await refresh() }
        }
        guard !routePending, routeGeneration == generation else { return }
        switch selectedEntry {
        case let .legacyDay(card)?:
            await select(.day(briefDate ?? card.date))
        case let .artifact(card)?:
            await select(.output(card.id))
        default:
            return
        }
    }

    /// `selectEntry` without its read mark: selects the entry, opens
    /// Messages' legacy list (Track my threads and Idea finder show their
    /// own panes and close any open list), and returns the card whose opening `select`
    /// still has to write (an artifact or a day), else nil. An id that is
    /// no entry (none, a Needs approval group row) shows no card.
    private func showEntry(_ id: String?) -> InboxSelection? {
        entrySelection = id
        guard let entry = selectedEntry else {
            selection = nil
            return nil
        }
        if case .legacyDay = entry {} else { resetBriefDay() }
        switch entry {
        case .legacyMessages:
            openLegacy(.messages)
            return nil
        case .legacyTracks, .legacyIdeas:
            closeLegacy()
            return nil
        case let .artifact(card):
            selection = .output(card.id)
            return .output(card.id)
        case let .legacyDay(card):
            let date = briefDate ?? card.date
            selection = .day(date)
            return .day(date)
        case let .brief(action):
            // Its agent-action card; a brief has no read mark to write.
            selection = .proposal(action.id)
            return nil
        case .approval, .builtinNotice:
            selection = nil
            return nil
        }
    }

    /// Opens today's list for a legacy entry, with its own reading pane.
    package func openLegacy(_ list: InboxLegacyList) {
        legacyList = list
        selection = nil
    }

    // MARK: - Routes

    /// Routes announced by `beginRoute` whose `open` has not started yet.
    private var announcedRoutes = 0
    /// `open` calls running now.
    private var runningRoutes = 0
    /// A route into the Inbox is on its way (`beginRoute`) or running
    /// (`open`) — routes may overlap: the owner's arrival yields while any is.
    private var routePending: Bool { announcedRoutes + runningRoutes > 0 }
    /// Bumped by each route, so an arrival that waited sees one started.
    private var routeGeneration = 0

    /// A route into the Inbox starts (AppState, before it shows the Inbox,
    /// so the view's arrival sees it): the arrival marks nothing until
    /// `open` has opened the route's card. Each call is taken up by one
    /// `open`.
    package func beginRoute() {
        announcedRoutes += 1
        routeGeneration += 1
    }

    /// `open` starts: it takes up one announced route (an `open` with none
    /// announced counts on its own) and runs until `endOpen`.
    private func startOpen() {
        if announcedRoutes > 0 { announcedRoutes -= 1 }
        runningRoutes += 1
        routeGeneration += 1
    }

    private func endOpen() {
        runningRoutes -= 1
    }

    // MARK: - The Morning brief's day

    /// The day the Morning brief shows; nil = today.
    package private(set) var briefDate: String?

    /// The brief's History popover is open.
    package var briefHistoryShown = false

    /// The Morning brief back on today, its History closed.
    private func resetBriefDay() {
        briefDate = nil
        briefHistoryShown = false
    }

    /// The card the Morning brief shows: `briefDate`'s, or for today the
    /// root entry's card (its placeholder before anything is written).
    package var briefDay: InboxDayCard? {
        guard let briefDate else {
            let now = clock()
            return InboxListBuilder.rootDays(feed, today: today, now: now, calendar: Self.calendar).first
        }
        return feed.days.first { $0.date == briefDate }
    }

    /// The owner picked `date` (History, the stepper, a route to a day):
    /// the root's Morning brief entry opens on that day and its briefing
    /// is marked read when unread (`select`). A date with neither a
    /// briefing nor a plan in the read opens today with no read mark — the
    /// owner asked for another day. Nothing is selected while the root
    /// lists no Morning brief.
    package func showBriefDay(_ date: String) async {
        let today = today
        let held = feed.days.contains { $0.date == date && !$0.isEmpty }
        closeLegacy()
        folderMenu.select(folderMenu.tree.root.id)
        briefDate = held && date < today ? date : nil
        briefHistoryShown = false
        guard showEntry(InboxFolderEntry.dayID(today)) != nil else {
            entrySelection = nil
            briefDate = nil
            return
        }
        let shown = briefDate ?? today
        guard shown == date else { return }
        await select(.day(shown))
    }

    /// The stepper's ‹ (older) or › (newer): the next day with a brief or
    /// a plan (`InboxBriefDays.step`); nothing past the ends.
    package func stepBrief(_ step: InboxBriefDays.Step) async {
        guard let next = InboxBriefDays.step(from: briefDate ?? today, step, in: feed.days, today: today) else {
            return
        }
        await showBriefDay(next)
    }

    /// The Earlier line: the root's Morning brief with its History open.
    /// Nothing opens while the root lists no Morning brief.
    package func openBriefHistory() {
        let brief = InboxFolderEntry.dayID(today)
        if folderMenu.selectedFolderID != folderMenu.tree.root.id || entrySelection != brief {
            closeLegacy()
            folderMenu.select(folderMenu.tree.root.id)
            briefDate = nil
            guard showEntry(brief) != nil else {
                entrySelection = nil
                briefHistoryShown = false
                return
            }
        }
        briefHistoryShown = true
    }

    /// "yyyy-MM-dd" of the clock's now.
    private var today: String {
        HomeFeedBuilder.dayString(clock(), calendar: Self.calendar)
    }

    /// The one calendar the Inbox's days follow (the read's too): the
    /// system's, following a time-zone change.
    nonisolated private static let calendar = Calendar.autoupdatingCurrent

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
    /// closed): the next row of the old list (`listedFolder.rows`,
    /// sections in order, before any search) still listed, else the one above it, else none —
    /// as `keepSelectionListed` does for cards. A selected Needs approval
    /// group row stays while its group is listed. The Morning brief of a
    /// day that rolled over moves to today's. Nothing is re-selected
    /// once the owner cleared the selection.
    private func keepEntryListed(was before: [String]) {
        guard let current = entrySelection else { return }
        let drawn = listedFolder.rows.map(\.id)
        let entries = folderEntries.map(\.id)
        guard !drawn.contains(current), !entries.contains(current) else { return }
        let brief = InboxFolderEntry.dayID(today)
        if current.hasPrefix(InboxFolderEntry.dayID("")), entries.contains(brief) {
            _ = showEntry(brief)
            return
        }
        guard let index = before.firstIndex(of: current) else {
            entrySelection = nil
            selection = nil
            return
        }
        let listed = Set(drawn)
        let below = before[(index + 1)...].first(where: listed.contains)
        // A click's path without its write: a legacy entry's list opens, an
        // artifact or a day is selected, and no read mark is written — a
        // poll or refresh never marks anything read (STRIP-02).
        _ = showEntry(below ?? before[..<index].last(where: listed.contains))
    }

    // MARK: - Track my threads and Idea finder (phase 3)

    /// **Stop Tracking Quiet Ones…** on Track my threads' pane: plans with
    /// `planQuietTracks`, applies with `stopTrackingQuiet`.
    package var quietTracksPress: InboxBulkPressModel {
        if let model = quietTracksPressModel { return model }
        let model = bulkPress(plan: { try await $0.planQuietTracks() },
                              apply: { await $0.stopTrackingQuiet($1) })
        quietTracksPressModel = model
        return model
    }

    /// **Clear Old Ideas…** on Idea finder's pane: plans with
    /// `planOldIdeas`, applies with `clearOldIdeas`.
    package var oldIdeasPress: InboxBulkPressModel {
        if let model = oldIdeasPressModel { return model }
        let model = bulkPress(plan: { try await $0.planOldIdeas() },
                              apply: { await $0.clearOldIdeas($1) })
        oldIdeasPressModel = model
        return model
    }

    @ObservationIgnored private var quietTracksPressModel: InboxBulkPressModel?
    @ObservationIgnored private var oldIdeasPressModel: InboxBulkPressModel?

    /// A bulk press that reaches this model weakly (the `approveAllModel` way).
    private func bulkPress(
        plan: @escaping @MainActor (ActionStripViewModel) async throws -> InboxBulkPlan,
        apply: @escaping @MainActor (ActionStripViewModel, [String]) async -> InboxBulkResult
    ) -> InboxBulkPressModel {
        InboxBulkPressModel(
            plan: { [weak self] in
                guard let self else { throw ApproveAllError.closed }
                return try await plan(self)
            },
            apply: { [weak self] ids in
                guard let self else { return .failed(ApproveAllError.closed.localizedDescription) }
                return await apply(self, ids)
            })
    }

    /// Track my threads' news and quiet threads, from the last read.
    package var trackSummary: TrackThreadsSummary {
        TrackThreadsSummary.build(tracks: feed.tracks, now: clock())
    }

    /// Today's idea batch (`IdeaDailyBatch`), set by each read; the batch is
    /// kept in UserDefaults, so the read still writes nothing to the
    /// database (STRIP-02).
    package private(set) var ideaBatch = IdeaBatchState(
        batchIDs: [], remaining: [], keptToday: [], backlogCount: 0, olderCount: 0, nextAvailable: 0,
        size: IdeaDailyBatch.defaultSize)

    /// The Idea finder card's last failed press, kept here (AppState-owned)
    /// so it survives leaving the Inbox; shown only while its idea is the
    /// card on screen, cleared by the next press and by Dismiss.
    package var ideaBatchFailure: IdeaBatchFailure?

    /// **Next N**: a new batch from the last read's ideas.
    package func takeNextIdeaBatch() {
        ideaBatch = IdeaDailyBatch(defaults: defaults).next(ideas: feed.ideas, now: clock(), calendar: Self.calendar)
    }

    /// The news thread open in Track my threads' pane; nil = the news list.
    /// Reset by a folder or entry pick and a route; cleared by a read once
    /// the track is no longer active.
    package private(set) var openedNewsTrackID: Int?

    /// The opened thread's card; nil while it is not among the active tracks.
    package var openedNewsTrack: InboxTrackCard? {
        guard let openedNewsTrackID else { return nil }
        return feed.tracks.first { $0.track.id == openedNewsTrackID }
    }

    package func openNewsTrack(_ id: Int) {
        openedNewsTrackID = id
    }

    package func closeNewsTrack() {
        openedNewsTrackID = nil
    }

    /// A write on thread `id` landed: back to the news list only if that
    /// thread is still the one open (the owner may have opened another
    /// while it ran).
    package func closeNewsTrack(ifStill id: Int) {
        if openedNewsTrackID == id { openedNewsTrackID = nil }
    }

    private var tracksBulkCLI: TracksBulkCLI {
        TracksBulkCLI(runner: cliRunner ?? findCLI())
    }

    /// The threads quiet for `TrackNewsRule.quietDays`, as the CLI's dry run plans them.
    package func planQuietTracks() async throws -> InboxBulkPlan {
        try await tracksBulkCLI.planQuiet(days: TrackNewsRule.quietDays)
    }

    /// Stops tracking `ids` through the CLI, then reads. A failed call (a
    /// timeout, a lost answer) may have committed before it ended: one read
    /// of the ids that were active before the press turns it into `.partial`
    /// with the CLI's text when some of them did stop. A thread stopped
    /// elsewhere before the press is never credited. When the "active
    /// before" read itself failed there is nothing to reconcile against:
    /// the failure says some threads may have stopped.
    package func stopTrackingQuiet(_ ids: [String]) async -> InboxBulkResult {
        let numeric = ids.compactMap(Int64.init)
        let activeBefore: [Int64]?
        do {
            activeBefore = try await dbPool.read { try TrackQueries.ids($0, among: numeric, stopped: false) }
        } catch {
            InboxLog.logger.error("stop tracking quiet: active read failed: \(error.localizedDescription, privacy: .public)")
            activeBefore = nil
        }
        var result = await tracksBulkCLI.dismiss(ids: ids)
        if case let .failed(message) = result {
            if let activeBefore {
                result = await reconcileQuietStop(message, activeBefore: activeBefore, of: ids.count)
            } else {
                result = .failed(message + Self.quietStopUncheckedNote)
            }
        }
        await refresh()
        return result
    }

    /// Appended to a failed bulk stop whose outcome could not be checked.
    package static let quietStopUncheckedNote = " Some threads may have stopped — check All Threads."

    /// A failed bulk stop as `.partial` when some of `activeBefore` are now stopped.
    private func reconcileQuietStop(_ message: String, activeBefore: [Int64], of total: Int) async -> InboxBulkResult {
        guard !activeBefore.isEmpty else { return .failed(message) }
        do {
            let stopped = try await dbPool.read { try TrackQueries.ids($0, among: activeBefore, stopped: true) }.count
            return stopped > 0 ? .partial(done: stopped, of: total, error: message) : .failed(message)
        } catch {
            // The failure stands as the CLI reported it.
            InboxLog.logger.error("stop tracking quiet: reconcile read failed: \(error.localizedDescription, privacy: .public)")
            return .failed(message)
        }
    }

    /// The ideas awaiting a verdict for more than 30 days (one read).
    package func planOldIdeas() async throws -> InboxBulkPlan {
        let now = clock()
        let ids = try await dbPool.read { db in
            try IdeaQueries.fetchAwaitingVerdict(db).filter { IdeaDailyBatch.isOld($0, now: now) }.map(\.id)
        }
        return InboxBulkPlan(ids: ids.map(String.init), count: ids.count)
    }

    /// Drops `ids` (`IdeaQueries.dropMany`: one judged meanwhile is
    /// skipped), then reads.
    package func clearOldIdeas(_ ids: [String]) async -> InboxBulkResult {
        let numeric = ids.compactMap(Int.init)
        let result: InboxBulkResult
        do {
            let dropped = try await dbPool.write { try IdeaQueries.dropMany($0, ids: numeric) }
            result = .done(count: dropped, skipped: ids.count - dropped)
        } catch {
            result = .failed(error.localizedDescription)
        }
        await refresh()
        return result
    }

    // MARK: - Approve All (Needs approval groups)

    /// Each group's **Approve All** press, kept here (AppState-owned) so a
    /// run survives leaving the Inbox.
    @ObservationIgnored private var approveAllModels: [NeedsApprovalGroup: InboxBulkPressModel] = [:]

    /// `group`'s **Approve All** press: one per group, planned with
    /// `approveAllPlan` and applied with `approveAll(ids:)`.
    package func approveAllModel(_ group: NeedsApprovalGroup) -> InboxBulkPressModel {
        if let model = approveAllModels[group] { return model }
        let model = InboxBulkPressModel(
            plan: { [weak self] in
                guard let self else { throw ApproveAllError.closed }
                return try await approveAllPlan(group)
            },
            apply: { [weak self] ids in
                guard let self else { return .failed(ApproveAllError.closed.localizedDescription) }
                let result = await approveAll(ids: ids)
                approveAllFinishedIDs[group] = approvableIDs(group)
                return result
            })
        approveAllModels[group] = model
        return model
    }

    /// Why **Approve All** could not plan or run.
    private enum ApproveAllError: LocalizedError {
        case closed
        case unread(String)

        var errorDescription: String? {
            switch self {
            case .closed: "The Inbox is closed."
            case .unread(let reason): "The Inbox could not be read: \(reason)"
            }
        }
    }

    /// The args each planned row had when **Approve All** was planned (what
    /// the owner saw), by action id: `approveAll` approves with these, so a
    /// row whose args changed since is refused by Go and stops the run.
    /// A run's ids leave it when the run ends.
    @ObservationIgnored package private(set) var approveAllShownArgs: [Int64: String] = [:]

    /// Each group's approvable ids when its last press finished (nil: the
    /// group was not listed): a later read that lists other ids, or drops
    /// the group, puts its press back to idle (`resetStaleApproveAll`).
    @ObservationIgnored private var approveAllFinishedIDs: [NeedsApprovalGroup: [Int64]?] = [:]

    /// What **Approve All** would approve in `group` now: one read first,
    /// then its approvable ids (`NeedsApprovalGroups.approveAllIDs`), their
    /// args pinned (`approveAllShownArgs`); empty when the group offers none.
    /// Throws when no read has landed or that read failed — never an empty
    /// plan standing in for an Inbox it could not read.
    package func approveAllPlan(_ group: NeedsApprovalGroup) async throws -> InboxBulkPlan {
        await refresh()
        approveAllFinishedIDs[group] = approvableIDs(group)
        if let reason = hasRead ? lastError : (firstReadError ?? lastError ?? "nothing was read yet") {
            throw ApproveAllError.unread(reason)
        }
        let items = NeedsApprovalGroups.build(openApprovals).first { $0.0 == group }?.1 ?? []
        let ids = NeedsApprovalGroups.approveAllIDs(group, items) ?? []
        for item in items {
            guard case let .action(action) = item.record, ids.contains(action.id) else { continue }
            approveAllShownArgs[action.id] = action.argsJSON
        }
        return InboxBulkPlan(ids: ids.map(String.init), count: ids.count)
    }

    /// `group`'s rows **Approve All** could approve from the last read
    /// (`NeedsApprovalGroups.isBulkApprovable`, without the two-row and
    /// one-tool rules, so any change is seen); nil while it is not listed.
    private func approvableIDs(_ group: NeedsApprovalGroup) -> [Int64]? {
        guard let items = NeedsApprovalGroups.build(openApprovals).first(where: { $0.0 == group })?.1 else {
            return nil
        }
        return items.compactMap { item in
            guard case let .action(action) = item.record, NeedsApprovalGroups.isBulkApprovable(action) else {
                return nil
            }
            return action.id
        }
    }

    /// The error line after an Approve All run whose approved tracks are not
    /// all watched (`messages`: their `AgentActionFeed.startVerb` errors);
    /// nil when every one is.
    package static func notWatchedLine(_ messages: [String]) -> String? {
        guard let first = messages.first else { return nil }
        let reason = first.hasPrefix(AgentActionFeed.notWatchedPrefix)
            ? String(first.dropFirst(AgentActionFeed.notWatchedPrefix.count)) : first
        let tracks = messages.count == 1 ? "1 track is" : "\(messages.count) tracks are"
        return "Approved, but \(tracks) not watched yet: \(reason)"
    }

    /// After a read: a finished press whose group now lists other approvable
    /// ids (or is gone) goes back to idle, so its result line never speaks
    /// for rows it did not see.
    private func resetStaleApproveAll() {
        for (group, model) in approveAllModels {
            guard case .finished = model.state else { continue }
            let now = approvableIDs(group)
            if now == nil || approveAllFinishedIDs[group].map({ $0 != now }) ?? true {
                model.reset()
                approveAllFinishedIDs[group] = nil
            }
        }
    }

    /// Approves `ids` one by one through the per-action path
    /// (`AgentActionFeed.approve`, args pinned to what the plan read). One
    /// read first; skipped (counted, the run goes on): an id never planned,
    /// no longer open or pending (closed or failed meanwhile), no longer
    /// `NeedsApprovalGroups.isBulkApprovable`, or whose approve found its
    /// state moved (exit 3). An approved `create_track` whose `tracks start`
    /// failed counts as done; an applied row leaves Needs approval, so the
    /// run says so on the Inbox's error line (`notWatchedLine`). The first
    /// failure — a changed row's args
    /// refused by Go included — stops the run and selects that card while
    /// Needs approval is on screen, where its error shows; the rest are left
    /// for the owner. Ends with a read.
    package func approveAll(ids: [String]) async -> InboxBulkResult {
        await refresh()
        var done = 0
        var skipped = 0
        var failure: (row: AgentAction, message: String)?
        var notWatched: [String] = []
        for text in ids {
            guard let id = Int64(text), let shown = approveAllShownArgs[id],
                  folderMenu.snapshot.openActions.contains(id),
                  let row = feed.proposals.first(where: { $0.id == id }),
                  NeedsApprovalGroups.isBulkApprovable(row) else {
                skipped += 1
                continue
            }
            await actionFeed.approve(id, shownArgs: shown)
            // A `create_track` approved whose track is not watched yet
            // (`AgentActionFeed.startVerb`) was approved: it counts as done,
            // and its reason goes to the error line after the run.
            if let error = actionFeed.rowErrors[id] {
                guard error.verb == AgentActionFeed.startVerb else {
                    failure = (row, error.message)
                    break
                }
                notWatched.append(error.message)
            }
            if actionFeed.stateMovedRows.contains(id) {
                skipped += 1
            } else {
                done += 1
            }
        }
        await refresh()
        adoptFeedError()
        if lastError == nil, let line = Self.notWatchedLine(notWatched) {
            lastError = line
        }
        for text in ids {
            if let id = Int64(text) { approveAllShownArgs[id] = nil }
        }
        guard let failure else { return .done(count: done, skipped: skipped) }
        // Set after the last read so it is not moved off, and only while the
        // folder that lists the card is selected: the owner may have moved
        // on while the run went.
        let tree = folderMenu.tree
        if folderMenu.selectedFolderID == (tree.approvals ?? tree.root).id, legacyList == nil {
            entrySelection = InboxFolderEntry.approval(NeedsApprovalItem(.action(failure.row))).id
        }
        return .partial(done: done, of: ids.count, error: failure.message)
    }

    /// Needs approval's open approvals from the last read, whichever folder
    /// is selected (the root holds them on a tree without Needs approval).
    private var openApprovals: [NeedsApprovalItem] {
        guard hasRead else { return [] }
        let tree = folderMenu.tree
        let open = folderMenu.snapshot.openActions
        return InboxFolderEntries.build(folder: tree.approvals ?? tree.root, entryInputs).compactMap { entry in
            guard case let .approval(item) = entry, NeedsApprovalGroups.isOpen(item, openActions: open) else {
                return nil
            }
            return item
        }
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

    /// The open legacy list as `InboxListBuilder` laid it out; empty while
    /// none is open. Rebuilt on each read and when the list or its Stopped
    /// fold changes.
    package private(set) var sections: [InboxSection] = []

    private func rebuildSections() {
        guard let legacyList else {
            sections = []
            return
        }
        sections = InboxListBuilder.sections(
            feed, list: legacyList, now: clock(), calendar: .current, showsStopped: showsStopped)
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
    /// - A day opens the root's Morning brief on that day (`showBriefDay`);
    ///   a day past the loaded pages reads older pages until it is there.
    /// - A thread brief applied in the last 24 hours opens its root entry.
    /// - An automation card opens the folder that lists it; a proposal, a
    ///   reminder, a notice or one of Needs approval's cards opens Needs
    ///   approval.
    /// - No entry opens the folder's default entry (`defaultEntry`), with
    ///   no read mark.
    /// A card that is not listed opens its folder with nothing selected,
    /// so the pane never opens on a card the next refresh would drop. The
    /// route's folder is not remembered (`inbox.folder` keeps the owner's
    /// own pick).
    package func open(folder: Int64?, select entry: InboxRoute.Entry?) async {
        startOpen()
        defer { endOpen() }
        await refresh()
        closeLegacy()
        entrySelection = nil
        openedNewsTrackID = nil
        resetBriefDay()
        if let folder { folderMenu.select(folderMenu.tree.folder(folder) == nil ? folderMenu.tree.root.id : folder) }
        switch entry {
        case nil:
            if folder == nil { folderMenu.select(folderMenu.tree.root.id) }
            showDefaultEntry()
        case let .legacy(list):
            // Track my threads and Idea finder are panes of their own.
            showLegacy(list, openList: list == .messages)
        case let .card(item):
            await openCard(item, keepFolder: folder != nil)
        }
    }

    /// A legacy entry selected in the root, its list opened over it when
    /// `openList` (a card route; a route to the entry itself opens only
    /// Messages' list).
    private func showLegacy(_ list: InboxLegacyList, openList: Bool = true) {
        folderMenu.select(folderMenu.tree.root.id)
        entrySelection = InboxFolderEntry.legacy(list).id
        if openList { openLegacy(list) }
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
            // Stops on a failed read and on a page that added no date.
            while lastError == nil, !feed.days.contains(where: { $0.date == date }), feed.hasOlderDays,
                  let oldest = feed.days.last?.date, date < oldest {
                let before = feed.days.count
                await showOlderDays().value
                if feed.days.count == before { break }
            }
            await showBriefDay(date)
        case .output(let id):
            if folderMenu.snapshot.approvalArtifacts.values.contains(where: { $0.id == id }) {
                show((tree.approvals ?? tree.root).id, nil)
                return
            }
            let folder = folderMenu.snapshot.cards.first { $0.value.contains { $0.id == id } }?.key ?? tree.root.id
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
            date == today || feed.days.contains { $0.date == date }
        case let .track(id): (feed.tracks + feed.stoppedTracks).contains { $0.track.id == id }
        case let .idea(id): feed.ideas.contains { $0.id == id }
        case let .message(id): feed.messages.contains { $0.item.id == id }
        }
    }

    private func isListed(_ item: InboxSelection) -> Bool {
        sections.contains { $0.items.contains { $0.id == item } }
    }

    /// The read takes one more page of dates; the returned refresh can be awaited.
    @discardableResult
    package func showOlderDays() -> Task<Void, Never> {
        dayLimit += Self.dayPage
        return Task { await refresh() }
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
    /// approvals changed` so Needs approval's recipe redraws (STRIP-03) —
    /// after the press settles, so the CLI process never holds the row busy.
    package func markReminderDone(_ id: Int64) async {
        guard await write(.card(.reminder(id)), { try ReminderQueries.markDone($0, id: id) }, press: .done)
        else { return }
        await reminderChanged(id)
    }

    /// Snooze on a reminder (Snooze 1h is the only one the cards offer).
    package func snoozeReminder(_ id: Int64, until: String) async {
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
    /// and every event of it read, in one write. True when it landed.
    @discardableResult
    package func markTrackDone(_ id: Int) async -> Bool {
        await write(.card(.track(id)), { db in
            try TrackQueries.markRead(db, id: id)
            try TrackEventQueries.markAllRead(db, trackId: id)
        }, press: .done)
    }

    /// Stop watching (R4): an auto track is dismissed (TRACKS-07); a custom
    /// track goes through the seam, which also turns its collection off. A
    /// track deleted meanwhile is quiet. True when it landed (or the track
    /// was gone).
    @discardableResult
    package func stopWatching(_ track: Track) async -> Bool {
        let id = track.id
        guard track.isCustom else {
            return await write(.card(.track(id)), { db in
                do { try TrackQueries.dismiss(db, id: id) } catch is RowNotFoundError {}
            }, press: .stopWatching)
        }
        return await throughSeam(track, press: .stopWatching) { try await $0.stopWatching(track) }
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

    /// One seam call per card at a time, then a read; a vanished row is
    /// quiet. True when the call landed or the row was gone (false too for
    /// a press that did not run).
    @discardableResult
    private func throughSeam(
        _ track: Track,
        press: InboxRowPress? = nil,
        _ call: @escaping (any CustomTrackControlling) async throws -> Void
    ) async -> Bool {
        let controls = customTrackControls
        let item = InboxSelection.track(track.id)
        return await pendingWrites.run(CardKey.card(item)) {
            lastError = nil
            if press != nil { rowErrors[item] = nil }
            do {
                try await call(controls)
                await refresh()
                return true
            } catch is RowNotFoundError {
                await refresh()
                return true
            } catch {
                lastError = error.localizedDescription
                if let press { rowErrors[item] = InboxRowFailure(message: error.localizedDescription, press: press) }
                return false
            }
        } ?? false
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

    // MARK: - Reply from a row

    /// What sits under item `itemID`'s row for Reply: "Reply waiting for
    /// approval" while its reply is open in Needs approval, else its
    /// composer while one is open, else nothing.
    package func replyState(_ itemID: Int) -> InboxRowActionsContent.Reply? {
        if replyWaiting(itemID) { return .waiting }
        return replyDrafts[itemID].map { .composing(text: $0.text, error: $0.error) }
    }

    /// Item `itemID` has a Reply open (pending, approved or executing) in
    /// the last read: one reply per item at a time.
    package func replyWaiting(_ itemID: Int) -> Bool {
        feed.proposals.contains { InboxReplyPolicy.isOpenReply($0, itemID: itemID) }
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

    /// What the Desktop knows about the target button of `contextID`.
    package func targetFacts(contextID: String) -> InboxTargetButtonFacts {
        let row = targetProposals[contextID]
        return InboxTargetButtonFacts(
            proposal: row.map(InboxTargetButtonFacts.Proposal.init),
            taskID: row.flatMap { targetTasks[$0.id] },
            inFlight: row.map { actionFeed.inFlight.contains($0.id) } ?? false,
            pressError: targetPressErrors[contextID]?.message,
            applyError: row.flatMap { actionFeed.rowErrors[$0.id]?.message }
        )
    }

    /// The button facts of a `create_target` proposal an Inbox button made,
    /// when it is its button's newest row; nil for any other row (an older
    /// row of a button is never offered Try again).
    package func targetFacts(for action: AgentAction) -> InboxTargetButtonFacts? {
        guard action.tool == "create_target", action.contextType == AgentActionQueries.buttonContextType,
              targetProposals[action.contextID]?.id == action.id else { return nil }
        return targetFacts(contextID: action.contextID)
    }

    /// A button's row with a newer row of the same button: nothing on its
    /// card may retry it (Go refuses it with exit 3).
    package func isSupersededButtonRow(_ action: AgentAction) -> Bool {
        guard action.contextType == AgentActionQueries.buttonContextType,
              let newest = targetProposals[action.contextID] else { return false }
        return newest.id != action.id
    }

    /// The press of an idle target button: one `actions propose`, never
    /// `--approve` (AUTO-02). One press per button at a time. Exit 3 means
    /// the button's state moved (an open proposal, its task exists): no
    /// banner, the read draws it. Any other failure is kept for the button.
    package func proposeTarget(_ press: InboxTargetPress) async {
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

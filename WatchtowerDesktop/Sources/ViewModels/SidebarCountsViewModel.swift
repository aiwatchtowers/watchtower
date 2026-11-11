import AppKit
import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class SidebarCountsViewModel {
    /// The owner-gated track counts (OWNER-01's
    /// `testOwner01GoogleOnlyInstallCountsTracks`). No sidebar badge reads
    /// them since the Tracks tab moved into the Inbox (C1; the root's Track
    /// my threads entry since inbox builder B).
    var updatedTrackCount: Int = 0
    var totalTrackCount: Int = 0
    var unreadDigestCount: Int = 0
    /// Unread Gmail/Jira stream digests — the Digests tab's second feed source.
    var unreadStreamCount: Int = 0
    /// Unread decisions in the ledger (Digests → Decisions tab).
    var unreadDecisionCount: Int = 0
    var recommendationCount: Int = 0
    var activeTaskCount: Int = 0
    var overdueTaskCount: Int = 0
    /// The Inbox badge (`ActionStripViewModel.badgeCount`): Needs approval's
    /// open approvals + people waiting today. "Today" moves at local
    /// midnight with no database write, so it is also re-read then, after a
    /// wake, a day change and a time-zone change (`startObserving`).
    var inboxStripCount: Int = 0
    /// The feature ids the owner turned off (AppState's feature
    /// visibility): the Inbox badge counts no Waiting for me while
    /// attention detection is off. A change re-counts — the switch is the
    /// CLI's config write, which no table observation sees.
    var disabledFeatures: Set<String> = [] {
        didSet { if disabledFeatures != oldValue { Task { await refresh() } } }
    }

    /// Pending memory dispute flags — beliefs waiting for the owner's verdict.
    var memoryDisputedCount: Int = 0

    /// 1 while a finished absence recap is still waiting for "I'm caught up",
    /// 0 otherwise — one recap waiting is the whole signal, so this never counts
    /// higher.
    var unacknowledgedRecapCount: Int = 0

    /// The Catch-Up badge. Deliberately NOT an unread-source sum: catch-up is an
    /// on-demand document, and the only thing the tab has to announce is that a
    /// recap is ready to read.
    var catchUpTotalCount: Int { unacknowledgedRecapCount }

    /// The Digests sidebar badge — matches the Digests screen's own tab-header
    /// sum (`DigestListView.tabLabel`): Slack digests + Gmail/Jira stream
    /// digests + unread ledger decisions.
    var digestsBadgeCount: Int {
        unreadDigestCount + unreadStreamCount + unreadDecisionCount
    }

    /// The tables' change signals, one stream per (re)start; seamed so a
    /// test can fail one.
    typealias Changes = @Sendable (DatabasePool) -> AsyncThrowingStream<Void, Error>

    private let dbPool: DatabasePool
    private let changes: Changes
    private let backoff: RestartBackoff
    /// The wait before a restart; seamed so a test reads the pauses.
    private let pause: @Sendable (Duration) async -> Void
    private var observationTask: Task<Void, Never>?
    /// The moment and the zone the counts are read at; seamed so a test moves
    /// them. The zone is `.autoupdatingCurrent`'s, so a time-zone change moves
    /// "today" with it.
    private let clock: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    /// Waits until a moment (the next midnight's recount); seamed so a test
    /// never waits in real time.
    private let sleepUntil: @Sendable (Date) async -> Void
    /// Where the day change and the time-zone change are posted, and where
    /// the wake is.
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    /// The recount at the next local midnight, rescheduled by each one.
    @ObservationIgnored nonisolated(unsafe) private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private var dayChangeObserver: InboxDayChangeObserver?

    init(
        dbPool: DatabasePool,
        changes: @escaping Changes = SidebarCountsViewModel.tableChanges,
        backoff: RestartBackoff = RestartBackoff(),
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
        sleepUntil: @escaping @Sendable (Date) async -> Void = { await SidebarCountsViewModel.sleepUntil($0) },
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.dbPool = dbPool
        self.changes = changes
        self.backoff = backoff
        self.pause = pause
        self.clock = clock
        self.calendar = calendar
        self.sleepUntil = sleepUntil
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    deinit { midnightTask?.cancel() }

    /// Sleeps until `date` on the wall clock; returns early when cancelled.
    nonisolated static func sleepUntil(_ date: Date) async {
        let wait = date.timeIntervalSinceNow
        guard wait > 0 else { return }
        try? await Task.sleep(for: .seconds(wait))
    }

    /// A view model with its counts loaded and its observation started;
    /// nil when the calling task is cancelled meanwhile (a test's database
    /// going away, board #526).
    static func started(dbPool: DatabasePool, disabledFeatures: Set<String> = []) async -> SidebarCountsViewModel? {
        guard !Task.isCancelled else { return nil }
        let countsVM = SidebarCountsViewModel(dbPool: dbPool)
        countsVM.disabledFeatures = disabledFeatures
        await countsVM.loadInitial()
        guard !Task.isCancelled else { return nil }
        countsVM.startObserving()
        return countsVM
    }

    /// Loads the counts once and updates the published properties.
    /// Awaiting this guarantees the sidebar badges reflect real DB state before the splash screen hides.
    func loadInitial() async {
        let counts = await fetch()
        apply(counts)
    }

    /// Reloads the counts on demand. The observation below only sees writes made
    /// by THIS process, so a feature that shells out to the CLI (Catch-Up's
    /// `catchup run`) asks for a refresh once its child process is done —
    /// otherwise its badge keeps a stale count until the next in-process write.
    /// The daemon's automation inbox outputs arrive the same way: the
    /// Automations poll asks for a refresh when their unread count moves.
    func refresh() async {
        await loadInitial()
    }

    /// Begins observing the source tables and refreshes counts on each change.
    /// Idempotent — safe to call after `loadInitial()`. Every value reloads
    /// the counts, the first one too: a write landing between `loadInitial()`
    /// and the observation's start would otherwise be in the skipped first
    /// value and never show. A failed observation (a read error) starts again
    /// after a pause (`RestartBackoff`, board #526), and its first value
    /// reloads what changed meanwhile; before, one error froze the badges
    /// until a relaunch. The pause is back to its first length only after a
    /// change was delivered (a second value of one run): every start
    /// delivers one, so an error right after each start keeps doubling.
    func startObserving() {
        guard observationTask == nil else { return }
        startDayChangeRecounts()
        let pool = dbPool
        let changes = changes
        let pause = pause
        let initialBackoff = backoff
        observationTask = Task { [weak self] in
            var backoff = initialBackoff
            while !Task.isCancelled {
                do {
                    var values = 0
                    for try await _ in changes(pool) {
                        values += 1
                        if values == 2 { backoff.succeeded() }
                        guard !Task.isCancelled, let self else { return }
                        let counts = await self.fetch()
                        guard !Task.isCancelled else { return }
                        self.apply(counts)
                    }
                    return
                } catch {
                    // Stopped, or the view model is gone: nothing to restart for.
                    guard !Task.isCancelled, self != nil else { return }
                    let wait = backoff.failed()
                    print("SidebarCounts observation error, restarting in \(wait): \(error)")
                    await pause(wait)
                }
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        midnightTask?.cancel()
        midnightTask = nil
        dayChangeObserver = nil
    }

    /// The Inbox badge counts people waiting today, and "today" changes with
    /// no database write, which the table observation never sees: a recount
    /// one second after the next local midnight (rescheduled by each), and
    /// one after a day change, a time-zone change or a wake — a timer alone
    /// misses a Mac asleep past midnight and a new zone.
    private func startDayChangeRecounts() {
        scheduleMidnightRecount()
        let signals = InboxDayChangeObserver.systemSignals(center: notificationCenter) + [
            InboxDayChangeObserver.Signal(center: workspaceNotificationCenter, name: NSWorkspace.didWakeNotification)
        ]
        dayChangeObserver = InboxDayChangeObserver(signals: signals) { [weak self] in
            Task { await self?.recountForANewDay() }
        }
    }

    private func scheduleMidnightRecount() {
        midnightTask?.cancel()
        let at = InboxToday.nextMidnight(after: clock(), calendar: calendar()).addingTimeInterval(1)
        let sleepUntil = sleepUntil
        midnightTask = Task { [weak self] in
            await sleepUntil(at)
            guard !Task.isCancelled else { return }
            await self?.recountForANewDay()
        }
    }

    /// Re-reads the counts, then schedules the next midnight from the clock
    /// as it is now (a wake or a new zone moved it).
    private func recountForANewDay() async {
        await refresh()
        guard dayChangeObserver != nil else { return }
        scheduleMidnightRecount()
    }

    /// Observe row counts of every source table so any write (including
    /// read_at changes from Catch-Up mark-read on digests) signals a
    /// refresh, starting with one for the start itself.
    nonisolated static func tableChanges(_ pool: DatabasePool) -> AsyncThrowingStream<Void, Error> {
        let observation = ValueObservation.tracking { db -> [Int] in
            // agent_actions, reminders and automation_outputs are the
            // Inbox badge's own sources (inboxStripCount) — before the
            // inbox demolition the badge only ever re-fired because
            // inbox_items/situations happened to be in this list. An
            // output's Done/Dismiss changes no count, but GRDB re-fetches
            // on any write to a tracked table and nothing drops
            // duplicates, so it still refreshes the badge.
            // inbox_items is the badge's people-waiting-today term; day_plans
            // is the Day cards' other half;
            // builtin_migrations is the built-in upgrade notices' term (C2);
            // automations is Waiting for me / Needs approval turned on or off.
            let tables = ["tracks", "briefings", "targets", "digests",
                          "stream_digests", "catchup_recaps",
                          "memory_dispute_flags", "ideas",
                          "agent_actions", "reminders", "automation_outputs",
                          "inbox_items", "day_plans", "builtin_migrations", "automations"]
            return tables.map { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")) ?? 0 }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await _ in observation.values(in: pool) {
                        continuation.yield()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Counts {
        let updatedTrackCount: Int
        let totalTrackCount: Int
        let unreadDigestCount: Int
        // var (not let): user-independent, so the zero path (no workspace user
        // yet) still surfaces them, like inboxStripCount below.
        var unreadStreamCount: Int
        var unreadDecisionCount: Int
        let recommendationCount: Int
        let activeTaskCount: Int
        let overdueTaskCount: Int
        var inboxStripCount: Int
        var memoryDisputedCount: Int
        var unacknowledgedRecapCount: Int

        static let zero = Self(
            updatedTrackCount: 0,
            totalTrackCount: 0,
            unreadDigestCount: 0,
            unreadStreamCount: 0,
            unreadDecisionCount: 0,
            recommendationCount: 0,
            activeTaskCount: 0,
            overdueTaskCount: 0,
            inboxStripCount: 0,
            memoryDisputedCount: 0,
            unacknowledgedRecapCount: 0
        )
    }

    private func fetch() async -> Counts {
        let disabledFeatures = disabledFeatures
        let now = clock()
        let calendar = calendar()
        do {
            return try await dbPool.read { db -> Counts in
                // A ready recap still waiting for "I'm caught up". Computed
                // independently of the current user so the badge works even
                // before a workspace user is resolved, and tolerant of a
                // pre-catchup_recaps schema like the reads below it.
                let hasWaitingRecap = (try? CatchUpQueries.hasUnacknowledgedReady(db)) ?? false
                let waitingRecap = hasWaitingRecap ? 1 : 0
                // The Inbox badge: approvals + people waiting today,
                // user-independent and tolerant of a schema predating any of
                // its sources (a missing table counts 0; any other read error
                // fails the fetch).
                let stripCount = try ActionStripViewModel.badgeCount(
                    db, nowUTC: AutomationDates.format(now), disabledFeatures: disabledFeatures, calendar: calendar)
                // Memory disputes, tolerant of a pre-memory schema.
                let disputed = (try? MemoryQueries.fetchDisputedCount(db)) ?? 0
                // Digests-tab feed counts, tolerant of a pre-stream/ideas schema.
                // User-independent, so surfaced even before a workspace user.
                let unreadStream = (try? StreamDigestQueries.unreadCount(db)) ?? 0
                let unreadDecision = (try? IdeaQueries.unreadDecisionCount(db)) ?? 0

                let owner = try OwnerQueries.resolve(db)
                guard owner.isKnown else {
                    var zero = Counts.zero
                    zero.unacknowledgedRecapCount = waitingRecap
                    zero.inboxStripCount = stripCount
                    zero.memoryDisputedCount = disputed
                    zero.unreadStreamCount = unreadStream
                    zero.unreadDecisionCount = unreadDecision
                    return zero
                }
                let trackCounts = try TrackQueries.fetchCounts(db)
                let taskCounts = try TargetQueries.fetchCounts(db)

                let recCount: Int
                do {
                    // Channel stats match messages.user_id — only a Slack
                    // owner has any; a Google/Jira-keyed owner gets none.
                    if !owner.slackUserID.isEmpty {
                        let allStats = try ChannelStatsQueries.fetchAll(db, currentUserID: owner.slackUserID)
                        recCount = ChannelStatsQueries.computeRecommendations(from: allStats).count
                    } else {
                        recCount = 0
                    }
                } catch {
                    print("SidebarCounts recommendations count failed: \(error)")
                    recCount = 0
                }

                return Counts(
                    updatedTrackCount: trackCounts.updated,
                    totalTrackCount: trackCounts.total,
                    unreadDigestCount: try DigestQueries.unreadDigestCount(db),
                    unreadStreamCount: unreadStream,
                    unreadDecisionCount: unreadDecision,
                    recommendationCount: recCount,
                    activeTaskCount: taskCounts.active,
                    overdueTaskCount: taskCounts.overdue,
                    inboxStripCount: stripCount,
                    memoryDisputedCount: disputed,
                    unacknowledgedRecapCount: waitingRecap
                )
            }
        } catch {
            print("SidebarCounts fetch failed: \(error)")
            return .zero
        }
    }

    private func apply(_ c: Counts) {
        updatedTrackCount = c.updatedTrackCount
        totalTrackCount = c.totalTrackCount
        unreadDigestCount = c.unreadDigestCount
        unreadStreamCount = c.unreadStreamCount
        unreadDecisionCount = c.unreadDecisionCount
        recommendationCount = c.recommendationCount
        activeTaskCount = c.activeTaskCount
        overdueTaskCount = c.overdueTaskCount
        inboxStripCount = c.inboxStripCount
        memoryDisputedCount = c.memoryDisputedCount
        unacknowledgedRecapCount = c.unacknowledgedRecapCount
    }
}

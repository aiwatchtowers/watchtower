import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class SidebarCountsViewModel {
    var updatedTrackCount: Int = 0
    var totalTrackCount: Int = 0
    var unreadDigestCount: Int = 0
    /// Unread Gmail/Jira stream digests — the Digests tab's second feed source.
    var unreadStreamCount: Int = 0
    /// Unread decisions in the ledger (Digests → Decisions tab).
    var unreadDecisionCount: Int = 0
    var unreadBriefingCount: Int = 0
    var recommendationCount: Int = 0
    var activeTaskCount: Int = 0
    var overdueTaskCount: Int = 0
    /// What the Inbox tab actually shows since it became the action strip:
    /// proposals awaiting the owner + due reminders.
    var inboxStripCount: Int = 0

    /// Pending memory dispute flags — beliefs waiting for the owner's verdict.
    var memoryDisputedCount: Int = 0

    /// Ideas & Decisions awaiting owner review — freshly proposed, or flagged.
    var ideasCount: Int = 0

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

    private let dbPool: DatabasePool
    private var observationTask: Task<Void, Never>?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
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
    func refresh() async {
        await loadInitial()
    }

    /// Begins observing the source tables and refreshes counts on each change.
    /// Idempotent — safe to call after `loadInitial()`.
    func startObserving() {
        guard observationTask == nil else { return }
        let pool = dbPool
        observationTask = Task { [weak self] in
            // Observe row counts of every source table so any write (including
            // read_at changes from Catch-Up mark-read on digests) triggers a refresh.
            let observation = ValueObservation.tracking { db -> [Int] in
                // agent_actions and reminders are the Inbox badge's own two
                // sources (inboxStripCount) — before the inbox demolition the
                // badge only ever re-fired because inbox_items/situations
                // happened to be in this list.
                let tables = ["tracks", "briefings", "targets", "digests",
                              "stream_digests", "catchup_recaps",
                              "memory_dispute_flags", "ideas",
                              "agent_actions", "reminders"]
                return tables.map { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")) ?? 0 }
            }
            do {
                for try await _ in observation.values(in: pool).dropFirst() {
                    if Task.isCancelled { break }
                    guard let self else { break }
                    let counts = await self.fetch()
                    if Task.isCancelled { break }
                    self.apply(counts)
                }
            } catch {
                print("SidebarCounts observation error: \(error)")
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    private struct Counts {
        let updatedTrackCount: Int
        let totalTrackCount: Int
        let unreadDigestCount: Int
        // var (not let): user-independent, so the zero path (no workspace user
        // yet) still surfaces them, like inboxStripCount/ideasCount below.
        var unreadStreamCount: Int
        var unreadDecisionCount: Int
        let unreadBriefingCount: Int
        let recommendationCount: Int
        let activeTaskCount: Int
        let overdueTaskCount: Int
        var inboxStripCount: Int
        var memoryDisputedCount: Int
        var ideasCount: Int
        var unacknowledgedRecapCount: Int

        static let zero = Self(
            updatedTrackCount: 0,
            totalTrackCount: 0,
            unreadDigestCount: 0,
            unreadStreamCount: 0,
            unreadDecisionCount: 0,
            unreadBriefingCount: 0,
            recommendationCount: 0,
            activeTaskCount: 0,
            overdueTaskCount: 0,
            inboxStripCount: 0,
            memoryDisputedCount: 0,
            ideasCount: 0,
            unacknowledgedRecapCount: 0
        )
    }

    private func fetch() async -> Counts {
        do {
            return try await dbPool.read { db -> Counts in
                // A ready recap still waiting for "I'm caught up". Computed
                // independently of the current user so the badge works even
                // before a workspace user is resolved, and tolerant of a
                // pre-catchup_recaps schema like the reads below it.
                let hasWaitingRecap = (try? CatchUpQueries.hasUnacknowledgedReady(db)) ?? false
                let waitingRecap = hasWaitingRecap ? 1 : 0
                // The Inbox tab's strip: pending/failed proposals + due reminders,
                // user-independent and tolerant of a pre-agent-actions schema.
                let nowUTC = ISO8601DateFormatter().string(from: Date())
                let stripCount = ((try? AgentActionQueries.awaitingOwnerCount(db)) ?? 0)
                    + ((try? ReminderQueries.dueCount(db, nowUTC: nowUTC)) ?? 0)
                // Memory disputes, tolerant of a pre-memory schema.
                let disputed = (try? MemoryQueries.fetchDisputedCount(db)) ?? 0
                // Ideas awaiting review, tolerant of a pre-ideas-registry schema.
                let ideasForReview = (try? IdeaQueries.countForReview(db)) ?? 0
                // Digests-tab feed counts, tolerant of a pre-stream/ideas schema.
                // User-independent, so surfaced even before a workspace user.
                let unreadStream = (try? StreamDigestQueries.unreadCount(db)) ?? 0
                let unreadDecision = (try? IdeaQueries.unreadDecisionCount(db)) ?? 0

                guard let uid = try TrackQueries.fetchCurrentUserID(db) else {
                    var zero = Counts.zero
                    zero.unacknowledgedRecapCount = waitingRecap
                    zero.inboxStripCount = stripCount
                    zero.memoryDisputedCount = disputed
                    zero.ideasCount = ideasForReview
                    zero.unreadStreamCount = unreadStream
                    zero.unreadDecisionCount = unreadDecision
                    return zero
                }
                let trackCounts = try TrackQueries.fetchCounts(db)
                let taskCounts = try TargetQueries.fetchCounts(db)

                let recCount: Int
                do {
                    let allStats = try ChannelStatsQueries.fetchAll(db, currentUserID: uid)
                    recCount = ChannelStatsQueries.computeRecommendations(from: allStats).count
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
                    unreadBriefingCount: try BriefingQueries.unreadCount(db),
                    recommendationCount: recCount,
                    activeTaskCount: taskCounts.active,
                    overdueTaskCount: taskCounts.overdue,
                    inboxStripCount: stripCount,
                    memoryDisputedCount: disputed,
                    ideasCount: ideasForReview,
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
        unreadBriefingCount = c.unreadBriefingCount
        recommendationCount = c.recommendationCount
        activeTaskCount = c.activeTaskCount
        overdueTaskCount = c.overdueTaskCount
        inboxStripCount = c.inboxStripCount
        memoryDisputedCount = c.memoryDisputedCount
        ideasCount = c.ideasCount
        unacknowledgedRecapCount = c.unacknowledgedRecapCount
    }
}

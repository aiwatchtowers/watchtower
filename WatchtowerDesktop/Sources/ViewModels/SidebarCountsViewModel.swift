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
    var inboxPendingCount: Int = 0
    var inboxHighPriorityCount: Int = 0
    /// Open-situation count, driving the Dashboard sidebar badge (see D9 dashboard task).
    var situationsCount: Int = 0

    /// Pending memory dispute flags — beliefs waiting for the owner's verdict.
    var memoryDisputedCount: Int = 0

    /// Ideas & Decisions awaiting owner review — freshly proposed, or flagged.
    var ideasCount: Int = 0

    /// Pending themes of the active Catch-Up review session, or nil when no
    /// session is active. When present, it drives the Catch-Up badge.
    var pendingThemeCount: Int?

    /// The Catch-Up badge: pending themes of the active review session when one
    /// exists, otherwise the unread source sum (digests + tracks + inbox + briefings).
    var catchUpTotalCount: Int {
        if let pending = pendingThemeCount {
            return pending
        }
        return unreadDigestCount + updatedTrackCount + inboxPendingCount + unreadBriefingCount
    }

    /// The Digests sidebar badge — matches the Digests screen's own tab-header
    /// sum (`DigestListView.tabLabel`): Slack digests + Gmail/Jira stream
    /// digests + unread ledger decisions. Deliberately distinct from
    /// `catchUpTotalCount`, which keeps its own digests+tracks+inbox+briefings
    /// meaning.
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

    /// Begins observing the source tables and refreshes counts on each change.
    /// Idempotent — safe to call after `loadInitial()`.
    func startObserving() {
        guard observationTask == nil else { return }
        let pool = dbPool
        observationTask = Task { [weak self] in
            // Observe row counts of every source table so any write (including
            // read_at changes from Catch-Up mark-read on digests) triggers a refresh.
            let observation = ValueObservation.tracking { db -> [Int] in
                let tables = ["tracks", "briefings", "targets", "inbox_items", "digests",
                              "stream_digests", "catchup_sessions", "catchup_themes",
                              "situations", "memory_dispute_flags", "ideas"]
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
        // yet) still surfaces them, like situationsCount/ideasCount below.
        var unreadStreamCount: Int
        var unreadDecisionCount: Int
        let unreadBriefingCount: Int
        let recommendationCount: Int
        let activeTaskCount: Int
        let overdueTaskCount: Int
        let inboxPendingCount: Int
        let inboxHighPriorityCount: Int
        var situationsCount: Int
        var memoryDisputedCount: Int
        var ideasCount: Int
        var pendingThemeCount: Int?

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
            inboxPendingCount: 0,
            inboxHighPriorityCount: 0,
            situationsCount: 0,
            memoryDisputedCount: 0,
            ideasCount: 0,
            pendingThemeCount: nil
        )
    }

    /// Count of pending themes in the active Catch-Up session, or nil when no
    /// session is active (badge then falls back to the unread source sum).
    nonisolated private static func pendingThemeCount(_ db: Database) throws -> Int? {
        guard let session = try CatchUpQueries.fetchActiveSession(db) else { return nil }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM catchup_themes WHERE session_id = ? AND review_state = 'pending'",
            arguments: [session.id]
        ) ?? 0
    }

    private func fetch() async -> Counts {
        do {
            return try await dbPool.read { db -> Counts in
                // Pending themes of the active Catch-Up session, when one exists.
                // Computed independently of the current user so the badge works
                // even before a workspace user is resolved.
                let activeThemeCount = try Self.pendingThemeCount(db)
                // Open situations, likewise independent of the current user.
                let openSituations = try SituationQueries.openCount(db)
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
                    zero.pendingThemeCount = activeThemeCount
                    zero.situationsCount = openSituations
                    zero.memoryDisputedCount = disputed
                    zero.ideasCount = ideasForReview
                    zero.unreadStreamCount = unreadStream
                    zero.unreadDecisionCount = unreadDecision
                    return zero
                }
                let trackCounts = try TrackQueries.fetchCounts(db)
                let taskCounts = try TargetQueries.fetchCounts(db)

                let inboxCounts: (pending: Int, unread: Int, highPriority: Int)
                do {
                    inboxCounts = try InboxQueries.fetchCounts(db)
                } catch {
                    print("SidebarCounts inbox count failed: \(error)")
                    inboxCounts = (pending: 0, unread: 0, highPriority: 0)
                }

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
                    inboxPendingCount: inboxCounts.unread,
                    inboxHighPriorityCount: inboxCounts.highPriority,
                    situationsCount: openSituations,
                    memoryDisputedCount: disputed,
                    ideasCount: ideasForReview,
                    pendingThemeCount: activeThemeCount
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
        inboxPendingCount = c.inboxPendingCount
        inboxHighPriorityCount = c.inboxHighPriorityCount
        situationsCount = c.situationsCount
        memoryDisputedCount = c.memoryDisputedCount
        ideasCount = c.ideasCount
        pendingThemeCount = c.pendingThemeCount
    }
}

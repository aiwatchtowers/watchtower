import Foundation
import GRDB

@MainActor
@Observable
final class SidebarCountsViewModel {
    var updatedTrackCount: Int = 0
    var totalTrackCount: Int = 0
    var unreadDigestCount: Int = 0
    var unreadBriefingCount: Int = 0
    var recommendationCount: Int = 0
    var activeTaskCount: Int = 0
    var overdueTaskCount: Int = 0
    var inboxPendingCount: Int = 0
    var inboxHighPriorityCount: Int = 0

    /// Total unread feeding the Catch-Up badge: digests + tracks + inbox + briefings.
    var catchUpTotalCount: Int {
        unreadDigestCount + updatedTrackCount + inboxPendingCount + unreadBriefingCount
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
                let tables = ["tracks", "briefings", "targets", "inbox_items", "digests"]
                return try tables.map { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")) ?? 0 }
            }
            do {
                for try await _ in observation.values(in: pool).dropFirst() {
                    if Task.isCancelled { break }
                    guard let self else { break }
                    let counts = await self.fetch()
                    if Task.isCancelled { break }
                    self.apply(counts)
                }
            } catch {}
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
        let unreadBriefingCount: Int
        let recommendationCount: Int
        let activeTaskCount: Int
        let overdueTaskCount: Int
        let inboxPendingCount: Int
        let inboxHighPriorityCount: Int

        static let zero = Self(
            updatedTrackCount: 0,
            totalTrackCount: 0,
            unreadDigestCount: 0,
            unreadBriefingCount: 0,
            recommendationCount: 0,
            activeTaskCount: 0,
            overdueTaskCount: 0,
            inboxPendingCount: 0,
            inboxHighPriorityCount: 0
        )
    }

    private func fetch() async -> Counts {
        let result = try? await dbPool.read { db -> Counts in
            guard let uid = try TrackQueries.fetchCurrentUserID(db) else {
                return Counts.zero
            }
            let trackCounts = try TrackQueries.fetchCounts(db)
            let taskCounts = try TargetQueries.fetchCounts(db)
            let inboxCounts = (try? InboxQueries.fetchCounts(db)) ?? (pending: 0, unread: 0, highPriority: 0)

            let recCount: Int
            if let allStats = try? ChannelStatsQueries.fetchAll(db, currentUserID: uid) {
                recCount = ChannelStatsQueries.computeRecommendations(from: allStats).count
            } else {
                recCount = 0
            }

            return Counts(
                updatedTrackCount: trackCounts.updated,
                totalTrackCount: trackCounts.total,
                unreadDigestCount: try DigestQueries.unreadDigestCount(db),
                unreadBriefingCount: try BriefingQueries.unreadCount(db),
                recommendationCount: recCount,
                activeTaskCount: taskCounts.active,
                overdueTaskCount: taskCounts.overdue,
                inboxPendingCount: inboxCounts.unread,
                inboxHighPriorityCount: inboxCounts.highPriority
            )
        }
        return result ?? .zero
    }

    private func apply(_ c: Counts) {
        updatedTrackCount = c.updatedTrackCount
        totalTrackCount = c.totalTrackCount
        unreadDigestCount = c.unreadDigestCount
        unreadBriefingCount = c.unreadBriefingCount
        recommendationCount = c.recommendationCount
        activeTaskCount = c.activeTaskCount
        overdueTaskCount = c.overdueTaskCount
        inboxPendingCount = c.inboxPendingCount
        inboxHighPriorityCount = c.inboxHighPriorityCount
    }
}

import Foundation
import GRDB

/// Drives the secretary Dashboard — a single ranked feed of `Situation`s (clustered
/// signals + work updates) that replaces the old two-tier Inbox feed. See
/// `internal/inbox/compose.go` on the Go side and `SituationQueries` for the
/// underlying reads/writes.
@MainActor
@Observable
final class DashboardViewModel {
    var situations: [Situation] = []
    var openCount: Int = 0
    var isLoading = false
    var errorMessage: String?

    /// Page size for `fetchFeed`; overridable by tests to exercise pagination cheaply.
    var pageSize: Int = 50
    private var offset: Int = 0

    // Name caches for rendering member-signal originals (resolved lazily, on
    // `loadMemberSignals`, the same way InboxViewModel resolves conversation names).
    private(set) var senderNames: [String: String] = [:]
    private(set) var channelNames: [String: String] = [:]

    private let dbManager: DatabaseManager
    private var observationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// Interval for the safety-net poll. GRDB ValueObservation cannot see writes
    /// from the Go daemon (separate process, separate SQLite update hooks), so
    /// the feed needs a periodic reload to surface daemon-composed situations.
    private let pollInterval: Duration = .seconds(30)

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    func startObserving() {
        guard observationTask == nil else { return }
        load()
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM situations") ?? 0
            }
            .removeDuplicates()
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self?.load()
                }
            } catch {}
        }
        startPolling()
    }

    /// Force an immediate reload from disk. Called on tab-appear so daemon-composed
    /// situations surface even when the user takes no action while away.
    func refresh() {
        load()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self?.load()
            }
        }
    }

    func load() {
        isLoading = true
        do {
            let result = try dbManager.dbPool.read { db in
                let feed = try SituationQueries.fetchFeed(db, limit: self.pageSize, offset: 0)
                let count = try SituationQueries.openCount(db)
                return (feed, count)
            }
            situations = result.0
            openCount = result.1
            offset = result.0.count
            errorMessage = nil
        } catch {
            situations = []
            openCount = 0
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Appends the next page of the feed (infinite scroll).
    func loadMore() {
        do {
            let next = try dbManager.dbPool.read { db in
                try SituationQueries.fetchFeed(db, limit: pageSize, offset: offset)
            }
            situations.append(contentsOf: next)
            offset += next.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func done(_ situation: Situation) {
        do {
            try dbManager.dbPool.write { db in try SituationQueries.done(db, id: situation.id) }
            load()
        } catch {
            errorMessage = "Failed to mark done: \(error.localizedDescription)"
        }
    }

    func dismiss(_ situation: Situation) {
        do {
            try dbManager.dbPool.write { db in try SituationQueries.dismiss(db, id: situation.id) }
            load()
        } catch {
            errorMessage = "Failed to dismiss: \(error.localizedDescription)"
        }
    }

    func snooze(_ situation: Situation, until: String) {
        do {
            try dbManager.dbPool.write { db in try SituationQueries.snooze(db, id: situation.id, until: until) }
            load()
        } catch {
            errorMessage = "Failed to snooze: \(error.localizedDescription)"
        }
    }

    /// Records thumbs-up/down feedback for a situation (rating -1 derives a learned
    /// mute rule for its member signals' channels; +1 is a no-op — see
    /// `SituationQueries.recordFeedback`), then reloads.
    func submitFeedback(_ situation: Situation, rating: Int) {
        do {
            try dbManager.dbPool.write { db in
                try SituationQueries.recordFeedback(db, situationID: situation.id, rating: rating)
            }
            load()
        } catch {
            errorMessage = "Failed to submit feedback: \(error.localizedDescription)"
        }
    }

    /// Loads the situation's constituent inbox items (member signals) and resolves
    /// their sender/channel display names into the shared caches.
    @discardableResult
    func loadMemberSignals(_ situationID: Int) -> [InboxItem] {
        do {
            let items = try dbManager.dbPool.read { db in
                try SituationQueries.memberSignals(db, situationID: situationID)
            }
            resolveNames(for: items)
            return items
        } catch {
            errorMessage = "Failed to load member signals: \(error.localizedDescription)"
            return []
        }
    }

    func senderName(for item: InboxItem) -> String {
        senderNames[item.senderUserID] ?? (item.senderUserID.isEmpty ? "Unknown" : item.senderUserID)
    }

    func channelName(for item: InboxItem) -> String {
        if item.isDM { return "DM" }
        return channelNames[item.channelID] ?? item.channelID
    }

    private func resolveNames(for items: [InboxItem]) {
        guard !items.isEmpty else { return }
        let senderIDs = Set(items.map(\.senderUserID).filter { !$0.isEmpty })
        let channelIDs = Set(items.map(\.channelID).filter { !$0.isEmpty })
        do {
            let (sNames, cNames) = try dbManager.dbPool.read { db -> ([String: String], [String: String]) in
                var sn: [String: String] = [:]
                for uid in senderIDs {
                    sn[uid] = try UserQueries.fetchDisplayName(db, forID: uid)
                }
                var cn: [String: String] = [:]
                for cid in channelIDs {
                    if let name = try String.fetchOne(db, sql: "SELECT name FROM channels WHERE id = ?", arguments: [cid]) {
                        cn[cid] = name
                    }
                }
                return (sn, cn)
            }
            for (k, v) in sNames { senderNames[k] = v }
            for (k, v) in cNames { channelNames[k] = v }
        } catch {
            // Best-effort cache; the view falls back to raw IDs on lookup miss.
        }
    }
}

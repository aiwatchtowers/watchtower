import Foundation
import GRDB

/// Drives the dashboard's social-wall feed: a chronological list of `FeedEntry`
/// (situations, meetings, briefings, recaps, day plans) with type/importance/
/// hidden filters. AppState-owned so selection and filters survive navigation;
/// filter state persists in UserDefaults (UI preference, not DB state).
@MainActor
@Observable
final class FeedViewModel {
    private(set) var entries: [FeedEntry] = []
    var errorMessage: String?
    var selectedFeedItemID: Int64?

    /// Page size for the feed query; overridable by tests.
    var pageSize: Int = 50
    private var nextCursor: FeedItemQueries.FeedCursor?

    private var pollTask: Task<Void, Never>?

    /// Interval for the safety-net poll. GRDB ValueObservation cannot see writes
    /// from the Go daemon (separate process, separate SQLite update hooks), so
    /// the wall needs a periodic reload to surface daemon-published feed items —
    /// mirrors `DashboardViewModel.pollInterval`.
    private let pollInterval: Duration = .seconds(30)

    var typeFilter: Set<FeedItem.ItemType> {
        didSet { persistFilters(); load() }
    }
    var importantOnly: Bool {
        didSet { persistFilters(); load() }
    }
    var showHidden: Bool {
        didSet { persistFilters(); load() }
    }

    var selectedEntry: FeedEntry? {
        guard let id = selectedFeedItemID else { return nil }
        return entries.first { $0.id == id }
    }

    private let dbManager: DatabaseManager
    private let defaults: UserDefaults

    private static let typesKey = "feed.filter.types"
    private static let importantKey = "feed.filter.importantOnly"
    private static let hiddenKey = "feed.filter.showHidden"

    init(dbManager: DatabaseManager, defaults: UserDefaults = .standard) {
        self.dbManager = dbManager
        self.defaults = defaults
        if let raw = defaults.stringArray(forKey: Self.typesKey) {
            typeFilter = Set(raw.compactMap(FeedItem.ItemType.init(rawValue:)))
        } else {
            typeFilter = Set(FeedItem.ItemType.allCases)
        }
        importantOnly = defaults.bool(forKey: Self.importantKey)
        showHidden = defaults.bool(forKey: Self.hiddenKey)
    }

    private var filter: FeedItemQueries.Filter {
        FeedItemQueries.Filter(types: typeFilter, importantOnly: importantOnly, showHidden: showHidden)
    }

    func load() {
        nextCursor = nil
        do {
            let page = try dbManager.dbPool.read { db in
                try FeedItemQueries.fetchFeed(db, filter: self.filter, limit: self.pageSize)
            }
            entries = page.entries
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
        }
    }

    /// No-ops once the previous page's SQL query returned fewer rows than
    /// `pageSize` (exhausted) — `nextCursor` is nil in that case.
    func loadMore() {
        guard let cursor = nextCursor else { return }
        do {
            let page = try dbManager.dbPool.read { db in
                try FeedItemQueries.fetchFeed(db, filter: self.filter, limit: self.pageSize, before: cursor)
            }
            entries.append(contentsOf: page.entries)
            nextCursor = page.nextCursor
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
        }
    }

    func refresh() { load() }

    /// Starts the safety-net poll that reloads the wall every 30s so it keeps
    /// refreshing while visible (mirrors `DashboardViewModel.startObserving`'s
    /// poll half — the feed spans several source tables rather than one, so
    /// there's no single-table `ValueObservation` to mirror). Idempotent;
    /// cancel-safe.
    func startObserving() {
        guard pollTask == nil else { return }
        load()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self?.load()
            }
        }
    }

    /// Selects an entry and stamps `seen_at` (first-write-wins in the query).
    /// Reloads only when the entry was previously unseen, so the unread accent
    /// clears immediately — entry ids are stable across `load()`, so selection
    /// and scroll position are unaffected.
    func select(_ id: Int64?) {
        selectedFeedItemID = id
        guard let id else { return }
        let wasUnseen = entries.first { $0.id == id }?.item.seenAt == nil
        do {
            try dbManager.dbPool.write { db in
                try FeedItemQueries.markSeen(db, id: id)
            }
            if wasUnseen {
                load()
            }
        } catch {
            errorMessage = "Failed to mark seen: \(error.localizedDescription)"
        }
    }

    func hide(_ entry: FeedEntry) {
        mutate(entry) { db, id in try FeedItemQueries.hide(db, id: id) }
    }

    func unhide(_ entry: FeedEntry) {
        mutate(entry) { db, id in try FeedItemQueries.unhide(db, id: id) }
    }

    func toggleType(_ type: FeedItem.ItemType) {
        if typeFilter.contains(type) {
            typeFilter.remove(type)
        } else {
            typeFilter.insert(type)
        }
    }

    private func mutate(_ entry: FeedEntry, _ write: (Database, Int64) throws -> Void) {
        do {
            try dbManager.dbPool.write { db in
                try write(db, entry.id)
            }
            if selectedFeedItemID == entry.id {
                selectedFeedItemID = nil
            }
            load()
        } catch {
            errorMessage = "Failed to update feed item: \(error.localizedDescription)"
        }
    }

    private func persistFilters() {
        defaults.set(typeFilter.map(\.rawValue).sorted(), forKey: Self.typesKey)
        defaults.set(importantOnly, forKey: Self.importantKey)
        defaults.set(showHidden, forKey: Self.hiddenKey)
    }
}

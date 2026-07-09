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
    private var offset: Int = 0

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
        offset = 0
        do {
            entries = try dbManager.dbPool.read { db in
                try FeedItemQueries.fetchFeed(db, filter: self.filter, limit: self.pageSize, offset: 0)
            }
            offset = entries.count
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
        }
    }

    func loadMore() {
        do {
            let more = try dbManager.dbPool.read { db in
                try FeedItemQueries.fetchFeed(db, filter: self.filter, limit: self.pageSize, offset: self.offset)
            }
            entries.append(contentsOf: more)
            offset += more.count
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
        }
    }

    func refresh() { load() }

    /// Selects an entry and stamps `seen_at` (first-write-wins in the query).
    func select(_ id: Int64?) {
        selectedFeedItemID = id
        guard let id else { return }
        do {
            try dbManager.dbPool.write { db in
                try FeedItemQueries.markSeen(db, id: id)
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

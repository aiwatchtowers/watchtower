import Foundation
import GRDB
import OSLog
import WatchtowerCore

@MainActor
@Observable
final class SearchViewModel {
    var query = ""
    var results: [SearchResult] = []
    var guideHits: [GuideHit] = []
    var isSearching = false
    var errorMessage: String?
    private(set) var slackLinks: SlackLinkResolver?

    private let dbManager: DatabaseManager
    // Readable so tests can await the in-flight search instead of sleeping.
    private(set) var searchTask: Task<Void, Never>?
    // Bumped by every search() call: only the latest one owns the spinner.
    private var searchGeneration = 0

    /// Test seam: called on the main actor as a search enters each step, so a
    /// test can act at that exact point instead of guessing with sleeps.
    enum SearchStep { case debounce, reading }
    var onSearchStep: ((SearchStep) -> Void)?

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
        self.slackLinks = try? dbManager.dbPool.read { db in try SlackLinkResolver.load(db) }
    }

    func slackChannelURL(channelID: String) -> URL? {
        slackLinks?.channelURL(channelID)
    }

    func search() {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            guideHits = []
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            // Whatever way this search ends, it leaves the spinner off unless
            // a newer search() call has taken it over (#682).
            defer { if self.searchGeneration == generation { self.isSearching = false } }
            // Debounce
            self.onSearchStep?(.debounce)
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }

            // A stale search (cancelled, or the query moved on) writes nothing.
            @MainActor func isCurrent() -> Bool {
                if Task.isCancelled { return false }
                return self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            }
            // The sleep can finish before a cancel lands (the main actor was
            // busy), so it does not throw: a stale search must not turn the
            // spinner on (#682).
            guard isCurrent() else { return }
            self.isSearching = true
            self.onSearchStep?(.reading)
            // Guide pages ride along; a failure here must not hide Slack results.
            do {
                let hits = try await dbManager.dbPool.read { db in
                    try GuideQueries.search(db, query: trimmed)
                }
                if isCurrent() { self.guideHits = hits }
            } catch {
                if isCurrent() {
                    Logger(subsystem: "com.watchtower.desktop", category: "search")
                        .error("guide search failed: \(error.localizedDescription, privacy: .public)")
                    self.guideHits = []
                }
            }
            do {
                let found = try await dbManager.dbPool.read { db in
                    try SearchQueries.search(db, query: trimmed)
                }
                if isCurrent() {
                    self.results = found
                    self.errorMessage = nil
                }
            } catch {
                if isCurrent() {
                    self.errorMessage = error.localizedDescription
                    self.results = []
                }
            }
        }
    }
}

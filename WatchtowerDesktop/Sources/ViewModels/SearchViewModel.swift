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
    private var searchTask: Task<Void, Never>?

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
        self.slackLinks = try? dbManager.dbPool.read { db in try SlackLinkResolver.load(db) }
    }

    func slackChannelURL(channelID: String) -> URL? {
        slackLinks?.channelURL(channelID)
    }

    func search() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            guideHits = []
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            // Debounce
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }

            self.isSearching = true
            // Guide pages ride along; a failure here must not hide Slack results.
            do {
                self.guideHits = try await dbManager.dbPool.read { db in
                    try GuideQueries.search(db, query: trimmed)
                }
            } catch {
                if !Task.isCancelled {
                    Logger(subsystem: "com.watchtower.desktop", category: "search")
                        .error("guide search failed: \(error.localizedDescription, privacy: .public)")
                    self.guideHits = []
                }
            }
            do {
                self.results = try await dbManager.dbPool.read { db in
                    try SearchQueries.search(db, query: trimmed)
                }
                self.errorMessage = nil
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                    self.results = []
                }
            }
            self.isSearching = false
        }
    }
}

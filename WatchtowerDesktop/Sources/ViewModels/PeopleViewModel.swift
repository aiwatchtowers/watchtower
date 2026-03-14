import Foundation
import GRDB

@MainActor
@Observable
final class PeopleViewModel {
    var analyses: [UserAnalysis] = []
    var periodSummary: PeriodSummary?
    var searchText = ""
    var isLoading = false
    var errorMessage: String?
    var selectedWindow: Int = 0  // index into availableWindows
    var availableWindows: [(from: Double, to: Double)] = []

    private(set) var userNameCache: [String: String] = [:]
    private(set) var starredPeopleIDs: Set<String> = []
    private(set) var currentUserID: String?
    private let dbManager: DatabaseManager

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    func load() {
        isLoading = true
        do {
            let result = try dbManager.dbPool.read { db in
                let windows = try UserAnalysisQueries.fetchAvailableWindows(db)
                let users = try UserQueries.fetchAll(db, activeOnly: false)

                var nameMap: [String: String] = [:]
                for u in users {
                    let name = u.displayName.isEmpty ? u.name : u.displayName
                    nameMap[u.id] = name
                }

                let analyses: [UserAnalysis]
                let ps: PeriodSummary?
                if let window = windows.first {
                    analyses = try UserAnalysisQueries.fetchForWindow(
                        db, periodFrom: window.from, periodTo: window.to
                    )
                    ps = try UserAnalysisQueries.fetchPeriodSummary(
                        db, periodFrom: window.from, periodTo: window.to
                    )
                } else {
                    analyses = []
                    ps = nil
                }
                let profile = try ProfileQueries.fetchCurrentProfile(db)
                let starred = Set(profile?.decodedStarredPeople ?? [])
                let uid = profile?.slackUserID
                return (analyses, windows, nameMap, ps, starred, uid)
            }
            analyses = result.0
            availableWindows = result.1
            userNameCache = result.2
            periodSummary = result.3
            starredPeopleIDs = result.4
            currentUserID = result.5
            errorMessage = nil
        } catch {
            analyses = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadWindow(at index: Int) {
        guard index >= 0, index < availableWindows.count else { return }
        selectedWindow = index
        let window = availableWindows[index]
        do {
            let result = try dbManager.dbPool.read { db in
                let a = try UserAnalysisQueries.fetchForWindow(
                    db, periodFrom: window.from, periodTo: window.to
                )
                let ps = try UserAnalysisQueries.fetchPeriodSummary(
                    db, periodFrom: window.from, periodTo: window.to
                )
                return (a, ps)
            }
            analyses = result.0
            periodSummary = result.1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func userName(for userID: String) -> String {
        userNameCache[userID] ?? userID
    }

    func userHistory(userID: String) -> [UserAnalysis] {
        do {
            return try dbManager.dbPool.read { db in
                try UserAnalysisQueries.fetchByUser(db, userID: userID)
            }
        } catch {
            return []
        }
    }

    var currentWindowLabel: String {
        guard !availableWindows.isEmpty, selectedWindow < availableWindows.count else {
            return "No data"
        }
        let w = availableWindows[selectedWindow]
        let from = Date(timeIntervalSince1970: w.from)
        let to = Date(timeIntervalSince1970: w.to)
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: from)) – \(fmt.string(from: to))"
    }

    var redFlagCount: Int {
        analyses.filter { $0.hasRedFlags }.count
    }

    // MARK: - Starred People Management

    func isPersonStarred(_ userID: String) -> Bool {
        starredPeopleIDs.contains(userID)
    }

    func toggleStarredPerson(_ personUserID: String) {
        guard let userID = currentUserID else { return }
        let wasStarred = starredPeopleIDs.contains(personUserID)
        // Optimistic update
        if wasStarred {
            starredPeopleIDs.remove(personUserID)
        } else {
            starredPeopleIDs.insert(personUserID)
        }
        do {
            if wasStarred {
                try dbManager.removeStarredPerson(personUserID, for: userID)
            } else {
                try dbManager.addStarredPerson(personUserID, for: userID)
            }
        } catch {
            // Revert on failure
            if wasStarred {
                starredPeopleIDs.insert(personUserID)
            } else {
                starredPeopleIDs.remove(personUserID)
            }
            errorMessage = "Failed to update starred person: \(error.localizedDescription)"
        }
    }
}

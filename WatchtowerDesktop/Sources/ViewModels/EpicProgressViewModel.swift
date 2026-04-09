import Foundation
import GRDB

@MainActor
@Observable
final class EpicProgressViewModel {
    var epics: [EpicProgressItem] = []
    var withoutJiraWarnings: [WithoutJiraRow] = []
    var isLoading = false
    var errorMessage: String?

    private let dbManager: DatabaseManager
    private var observationTask: Task<Void, Never>?

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    func startObserving() {
        guard observationTask == nil else { return }
        load()
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jira_issues WHERE is_deleted = 0") ?? 0
            }
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self?.load()
                }
            } catch {}
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    func load() {
        isLoading = true
        do {
            let rows = try dbManager.dbPool.read { db in
                try JiraQueries.fetchEpicProgress(db)
            }
            epics = rows.map { EpicProgressItem(row: $0) }

            let since = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
            withoutJiraWarnings = try dbManager.dbPool.read { db in
                try JiraQueries.fetchChannelsWithoutJira(db, since: since)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// Computed epic progress item with derived metrics.
struct EpicProgressItem: Identifiable {
    var id: String { row.epicKey }
    let row: EpicProgressRow

    /// Weekly velocity: monthly resolved / 4
    var velocity: Double {
        Double(row.monthlyResolvedCount) / 4.0
    }

    /// Forecast: weeks remaining at current velocity.
    /// Returns nil if velocity is zero (cannot estimate).
    var forecastWeeks: Double? {
        guard velocity > 0 else { return nil }
        let remaining = Double(row.totalIssues - row.doneIssues)
        return remaining / velocity
    }

    /// Weekly delta percentage: weeklyResolved / total * 100
    var weeklyDeltaPct: Double {
        guard row.totalIssues > 0 else { return 0 }
        return Double(row.weeklyResolvedCount) / Double(row.totalIssues) * 100.0
    }

    /// Previous week's progress percentage (current minus this week's delta).
    var previousProgressPct: Double {
        guard row.totalIssues > 0 else { return 0 }
        let previousDone = max(0, row.doneIssues - row.weeklyResolvedCount)
        return Double(previousDone) / Double(row.totalIssues)
    }

    /// Status badge based on velocity and remaining work.
    var statusBadge: EpicStatus {
        // If done
        if row.doneIssues >= row.totalIssues { return .onTrack }

        // If no velocity at all in 28 days
        if row.monthlyResolvedCount == 0 && row.doneIssues < row.totalIssues {
            return .behind
        }

        // If weekly velocity dropped (week < monthly avg)
        let weeklyAvg = Double(row.monthlyResolvedCount) / 4.0
        if row.weeklyResolvedCount == 0 && weeklyAvg > 0 {
            return .atRisk
        }

        // Forecast > 12 weeks
        if let fw = forecastWeeks, fw > 12 {
            return .atRisk
        }

        return .onTrack
    }
}

enum EpicStatus: String {
    case onTrack = "on_track"
    case atRisk = "at_risk"
    case behind = "behind"

    var label: String {
        switch self {
        case .onTrack: "On Track"
        case .atRisk: "At Risk"
        case .behind: "Behind"
        }
    }
}

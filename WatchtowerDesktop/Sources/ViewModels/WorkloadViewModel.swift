import Foundation
import GRDB

@MainActor
@Observable
final class WorkloadViewModel {
    var entries: [WorkloadEntry] = []
    var isLoading = true
    var errorMessage: String?

    private let dbManager: DatabaseManager
    private var observationTask: Task<Void, Never>?

    // MARK: - Types

    struct WorkloadEntry: Identifiable {
        var id: String { slackUserID }
        var slackUserID: String
        var displayName: String
        var openIssues: Int
        var storyPoints: Double
        var overdueCount: Int
        var blockedCount: Int
        var avgCycleTimeDays: Double
        var slackMessageCount: Int
        var meetingHours: Double
        var signal: WorkloadSignal
    }

    enum WorkloadSignal: String {
        case normal, watch, overload, low

        var label: String {
            switch self {
            case .normal: "Normal"
            case .watch: "Watch"
            case .overload: "Overload"
            case .low: "Low"
            }
        }

        var emoji: String {
            switch self {
            case .normal: "✅"
            case .watch: "⚠️"
            case .overload: "🔴"
            case .low: "💤"
            }
        }

        /// Sort priority (overload first).
        var sortOrder: Int {
            switch self {
            case .overload: 0
            case .watch: 1
            case .low: 2
            case .normal: 3
            }
        }
    }

    // MARK: - Init

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    // MARK: - Observation

    func startObserving() {
        guard observationTask == nil else { return }
        load()
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jira_issues") ?? 0
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

    // MARK: - Load

    func load() {
        isLoading = true
        do {
            let rows = try dbManager.dbPool.read { db in
                try JiraQueries.fetchTeamWorkload(db)
            }

            let now = Date()
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now

            var result: [WorkloadEntry] = []
            for row in rows {
                let slackMsgs: Int
                let mtgHours: Double

                do {
                    slackMsgs = try dbManager.dbPool.read { db in
                        try JiraQueries.fetchSlackMessageCount(
                            db, userID: row.slackUserID, from: sevenDaysAgo, to: now
                        )
                    }
                } catch {
                    slackMsgs = 0
                }

                do {
                    mtgHours = try dbManager.dbPool.read { db in
                        try JiraQueries.fetchMeetingHours(
                            db, userID: row.slackUserID, from: sevenDaysAgo, to: now
                        )
                    }
                } catch {
                    mtgHours = 0
                }

                let signal = Self.computeSignal(
                    openIssues: row.openIssues,
                    overdueCount: row.overdueCount,
                    blockedCount: row.blockedCount,
                    slackMessages: slackMsgs
                )

                result.append(WorkloadEntry(
                    slackUserID: row.slackUserID,
                    displayName: row.displayName.isEmpty ? row.slackUserID : row.displayName,
                    openIssues: row.openIssues,
                    storyPoints: row.storyPoints,
                    overdueCount: row.overdueCount,
                    blockedCount: row.blockedCount,
                    avgCycleTimeDays: (row.avgCycleTimeDays * 100).rounded() / 100,
                    slackMessageCount: slackMsgs,
                    meetingHours: (mtgHours * 10).rounded() / 10,
                    signal: signal
                ))
            }

            // Sort: overload first, then watch, low, normal
            result.sort { $0.signal.sortOrder < $1.signal.sortOrder }
            entries = result
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Signal Logic (matches Go computeSignal)

    static func computeSignal(
        openIssues: Int,
        overdueCount: Int,
        blockedCount: Int,
        slackMessages: Int
    ) -> WorkloadSignal {
        if overdueCount > 2 || blockedCount > 3 || openIssues > 15 {
            return .overload
        }
        if overdueCount > 0 || blockedCount > 1 || openIssues > 10 {
            return .watch
        }
        if openIssues == 0 && slackMessages < 5 {
            return .low
        }
        return .normal
    }
}

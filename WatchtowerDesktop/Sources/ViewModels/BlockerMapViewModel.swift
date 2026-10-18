import Foundation
import GRDB
import SwiftUI
import WatchtowerCore

/// The Blockers tab: blocked and stale issues of Jira and Linear side by
/// side, read through the tracker-neutral views (`TrackerQueries`, spec §6).
@MainActor
@Observable
final class BlockerMapViewModel {
    var blockers: [BlockerEntry] = []
    var isLoading: Bool = true
    var errorMessage: String?

    struct BlockerEntry: Identifiable {
        var id: String { issueKey }
        let issueKey: String
        /// "Jira" or "Linear", for the card's "Open in …".
        let trackerName: String
        /// The issue's page in its tracker; nil when the view has no
        /// absolute link (a Jira site with no recorded URL).
        let issueURL: URL?
        let summary: String
        let status: String
        let assigneeName: String
        let blockedDays: Int
        let blockerType: String  // "blocked" or "stale"
        let blockingChain: [String]  // issue keys (immediate blocker first, root cause last)
        /// Links for the chain's keys, where the view has one.
        let chainURLs: [String: URL]
        let downstreamCount: Int
        let whoToPing: [PingTarget]
        let slackContext: String
        let urgency: BlockerUrgency
    }

    struct PingTarget: Identifiable {
        var id: String { slackUserID }
        let slackUserID: String
        let displayName: String
        let reason: String
    }

    enum BlockerUrgency: String {
        case red, yellow, gray

        var color: Color {
            switch self {
            case .red: .red
            case .yellow: .yellow
            case .gray: .gray
            }
        }
    }

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
            // Both trackers' tables: the view itself is not observable.
            let observation = ValueObservation.tracking { db in
                (
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jira_issues WHERE is_deleted = 0") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM linear_issues WHERE is_deleted = 0") ?? 0
                )
            }
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    // A released VM ends the loop, so its observer leaves the pool
                    // at the next change even if no view called stopObserving().
                    guard !Task.isCancelled, let self else { break }
                    self.load()
                }
            } catch {}
        }
    }

    /// Cancels the GRDB observation; the view calls it from onDisappear.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    func load() {
        isLoading = true
        do {
            let entries = try dbManager.dbPool.read { db -> [BlockerEntry] in
                let blockedIssues = try TrackerQueries.fetchBlockedIssues(db)
                let staleIssues = try TrackerQueries.fetchStaleIssues(db)
                let adjacency = try Self.buildAdjacency(
                    db: db, keys: Set(blockedIssues.map(\.key) + staleIssues.map(\.key))
                )

                var result = blockedIssues.map {
                    Self.makeEntry(issue: $0, type: "blocked", adjacency: adjacency, db: db)
                }
                let blockedKeys = Set(blockedIssues.map(\.key))
                result += staleIssues
                    .filter { !blockedKeys.contains($0.key) }
                    .map { Self.makeEntry(issue: $0, type: "stale", adjacency: adjacency, db: db) }

                result.sort { lhs, rhs in
                    if lhs.downstreamCount != rhs.downstreamCount {
                        return lhs.downstreamCount > rhs.downstreamCount
                    }
                    return lhs.blockedDays > rhs.blockedDays
                }
                return result
            }
            blockers = entries
            errorMessage = nil
        } catch {
            blockers = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private static func buildAdjacency(
        db: Database, keys: Set<String>
    ) throws -> (blockedBy: [String: [String]], blocks: [String: [String]]) {
        let links = try TrackerQueries.fetchBlockLinks(db, keys: Array(keys))
        var blockedBy: [String: [String]] = [:]
        var blocks: [String: [String]] = [:]
        for link in links {
            blockedBy[link.blocked, default: []].append(link.blocker)
            blocks[link.blocker, default: []].append(link.blocked)
        }
        return (blockedBy, blocks)
    }

    private static func makeEntry(
        issue: TrackerIssue,
        type: String,
        adjacency: (blockedBy: [String: [String]], blocks: [String: [String]]),
        db: Database
    ) -> BlockerEntry {
        let chain = buildChain(from: issue.key, blockedBy: adjacency.blockedBy, maxDepth: 5)
        let downstream = countDownstream(from: issue.key, blocks: adjacency.blocks, maxDepth: 5)
        let days = daysSince(issue.statusChangedAt)
        var chainURLs: [String: URL] = [:]
        for key in chain {
            if let url = try? TrackerQueries.fetchIssueByKey(db, key: key)?.browseURL { chainURLs[key] = url }
        }
        return BlockerEntry(
            issueKey: issue.key,
            trackerName: issue.trackerName,
            issueURL: issue.browseURL,
            summary: issue.title,
            status: issue.status,
            assigneeName: issue.assigneeDisplayName,
            blockedDays: days,
            blockerType: type,
            blockingChain: chain,
            chainURLs: chainURLs,
            downstreamCount: downstream,
            whoToPing: buildPingTargets(issue: issue, chain: chain, db: db),
            slackContext: (try? JiraQueries.fetchSlackContextForIssue(db, issueKey: issue.key)) ?? "",
            urgency: computeUrgency(blockedDays: days, downstreamCount: downstream)
        )
    }

    // MARK: - Chain Building

    /// Walk the "blocked by" graph from a starting key, returning chain keys
    /// from immediate blocker to root cause. Max depth prevents cycles.
    private static func buildChain(
        from key: String,
        blockedBy: [String: [String]],
        maxDepth: Int
    ) -> [String] {
        var chain: [String] = []
        var visited: Set<String> = [key]
        var current = key
        for _ in 0..<maxDepth {
            guard let parents = blockedBy[current], let next = parents.first,
                  !visited.contains(next) else {
                break
            }
            chain.append(next)
            visited.insert(next)
            current = next
        }
        return chain
    }

    /// Count issues transitively blocked by this key.
    private static func countDownstream(
        from key: String,
        blocks: [String: [String]],
        maxDepth: Int
    ) -> Int {
        var visited: Set<String> = [key]
        var queue = [key]
        var count = 0
        var depth = 0
        while !queue.isEmpty, depth < maxDepth {
            var nextLevel: [String] = []
            for current in queue {
                for child in blocks[current] ?? [] where !visited.contains(child) {
                    visited.insert(child)
                    nextLevel.append(child)
                    count += 1
                }
            }
            queue = nextLevel
            depth += 1
        }
        return count
    }

    // MARK: - Ping Targets

    private static func buildPingTargets(
        issue: TrackerIssue,
        chain: [String],
        db: Database
    ) -> [PingTarget] {
        var targets: [PingTarget] = []
        var seen: Set<String> = []

        // Root cause assignee (last in chain).
        if let rootKey = chain.last {
            if let rootIssue = try? TrackerQueries.fetchIssueByKey(db, key: rootKey),
               !rootIssue.assigneeSlackID.isEmpty,
               !seen.contains(rootIssue.assigneeSlackID) {
                seen.insert(rootIssue.assigneeSlackID)
                targets.append(PingTarget(
                    slackUserID: rootIssue.assigneeSlackID,
                    displayName: rootIssue.assigneeDisplayName,
                    reason: "root cause assignee (\(rootKey))"
                ))
            }
        }

        // Issue's own assignee.
        if !issue.assigneeSlackID.isEmpty,
           !seen.contains(issue.assigneeSlackID) {
            seen.insert(issue.assigneeSlackID)
            targets.append(PingTarget(
                slackUserID: issue.assigneeSlackID,
                displayName: issue.assigneeDisplayName,
                reason: "assignee"
            ))
        }

        // Reporter.
        if !issue.reporterSlackID.isEmpty,
           !seen.contains(issue.reporterSlackID) {
            seen.insert(issue.reporterSlackID)
            targets.append(PingTarget(
                slackUserID: issue.reporterSlackID,
                displayName: issue.reporterDisplayName,
                reason: "reporter"
            ))
        }

        return targets
    }

    // MARK: - Urgency

    private static func computeUrgency(
        blockedDays: Int,
        downstreamCount: Int
    ) -> BlockerUrgency {
        if blockedDays > 5 || downstreamCount > 2 {
            return .red
        } else if blockedDays > 2 {
            return .yellow
        }
        return .gray
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static func daysSince(_ dateStr: String) -> Int {
        guard !dateStr.isEmpty else { return 0 }
        guard let date = isoFormatter.date(from: dateStr)
                ?? ISO8601DateFormatter().date(from: dateStr) else {
            return 0
        }
        return max(
            0,
            Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        )
    }

    // MARK: - Computed

    var urgentBlockers: [BlockerEntry] {
        blockers.filter { $0.urgency == .red }
    }

    var watchBlockers: [BlockerEntry] {
        blockers.filter { $0.urgency != .red }
    }
}

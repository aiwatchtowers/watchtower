import Foundation
import GRDB
import SwiftUI
import WatchtowerCore

/// The Blockers tab: blocked and stale issues of Jira and Linear side by
/// side, read through the tracker-neutral views (`TrackerQueries`, spec §6).
/// An issue is identified by tracker, account and key everywhere — a bare
/// key can exist on both trackers or on two Jira sites.
@MainActor
@Observable
final class BlockerMapViewModel {
    var blockers: [BlockerEntry] = []
    var isLoading: Bool = true
    var errorMessage: String?

    struct BlockerEntry: Identifiable {
        var id: String { "\(tracker.rawValue):\(accountID):\(issueKey)" }
        let tracker: TrackerIssue.Tracker
        let accountID: Int64
        let issueKey: String
        /// The issue's page in its tracker; nil when the view has no
        /// absolute link (a Jira site with no recorded URL).
        let issueURL: URL?
        let summary: String
        let status: String
        let assigneeName: String
        let blockedDays: Int
        let blockerType: String  // "blocked" or "stale"
        let blockingChain: [String]  // issue keys (immediate blocker first, root cause last)
        /// Links for the chain's keys, where the view has one. The chain
        /// stays inside the issue's own tracker account, so its keys are unique.
        let chainURLs: [String: URL]
        let downstreamCount: Int
        let whoToPing: [PingTarget]
        let slackContext: String
        let urgency: BlockerUrgency

        /// "Jira" or "Linear", for the card's "Open in …".
        var trackerName: String {
            switch tracker {
            case .jira: "Jira"
            case .linear: "Linear"
            }
        }
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
            blockers = try dbManager.dbPool.read { db in try Self.entries(db) }
            errorMessage = nil
        } catch {
            blockers = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private typealias Adjacency = (blockedBy: [TrackerIssueRef: [TrackerIssueRef]], blocks: [TrackerIssueRef: [TrackerIssueRef]])

    /// Every blocker entry, most downstream impact first. Any read error is
    /// thrown to `load`, which shows it.
    static func entries(_ db: Database) throws -> [BlockerEntry] {
        let blockedIssues = try TrackerQueries.fetchBlockedIssues(db)
        let staleIssues = try TrackerQueries.fetchStaleIssues(db)
        let links = try TrackerQueries.fetchBlockLinks(db, issues: Set((blockedIssues + staleIssues).map(\.ref)))
        var adjacency: Adjacency = ([:], [:])
        for link in links {
            adjacency.blockedBy[link.blocked, default: []].append(link.blocker)
            adjacency.blocks[link.blocker, default: []].append(link.blocked)
        }
        let blockedRefs = Set(blockedIssues.map(\.ref))
        let listed = blockedIssues.map { ($0, "blocked") }
            + staleIssues.filter { !blockedRefs.contains($0.ref) }.map { ($0, "stale") }
        let chains = Dictionary(uniqueKeysWithValues: listed.map { issue, _ in
            (issue.ref, buildChain(from: issue.ref, blockedBy: adjacency.blockedBy, maxDepth: 5))
        })
        // One read for every chain member (links and root-cause assignees).
        let chainIssues = try TrackerQueries.fetchIssues(db, refs: Set(chains.values.flatMap { $0 }))

        var result = try listed.map { issue, type in
            try makeEntry(
                issue: issue, type: type, chain: chains[issue.ref] ?? [],
                chainIssues: chainIssues, blocks: adjacency.blocks, db: db)
        }
        result.sort { lhs, rhs in
            if lhs.downstreamCount != rhs.downstreamCount {
                return lhs.downstreamCount > rhs.downstreamCount
            }
            return lhs.blockedDays > rhs.blockedDays
        }
        return result
    }

    private static func makeEntry(
        issue: TrackerIssue,
        type: String,
        chain: [TrackerIssueRef],
        chainIssues: [TrackerIssueRef: TrackerIssue],
        blocks: [TrackerIssueRef: [TrackerIssueRef]],
        db: Database
    ) throws -> BlockerEntry {
        let downstream = countDownstream(from: issue.ref, blocks: blocks, maxDepth: 5)
        let days = daysSince(issue.statusChangedAt)
        var chainURLs: [String: URL] = [:]
        for ref in chain {
            if let url = chainIssues[ref]?.browseURL { chainURLs[ref.key] = url }
        }
        // Slack context reads Jira's links table; a Linear issue has none
        // there (its links move to `issue_slack_links`, lane 2).
        let slackContext = issue.tracker == .jira
            ? try JiraQueries.fetchSlackContextForIssue(db, issueKey: issue.key) ?? ""
            : ""
        return BlockerEntry(
            tracker: issue.tracker,
            accountID: issue.accountID,
            issueKey: issue.key,
            issueURL: issue.browseURL,
            summary: issue.title,
            status: issue.status,
            assigneeName: issue.assigneeDisplayName,
            blockedDays: days,
            blockerType: type,
            blockingChain: chain.map(\.key),
            chainURLs: chainURLs,
            downstreamCount: downstream,
            whoToPing: buildPingTargets(issue: issue, root: chain.last.flatMap { chainIssues[$0] }),
            slackContext: slackContext,
            urgency: computeUrgency(blockedDays: days, downstreamCount: downstream)
        )
    }

    // MARK: - Chain Building

    /// Walk the "blocked by" graph from a starting issue, returning the chain
    /// from immediate blocker to root cause. Max depth prevents cycles.
    private static func buildChain(
        from start: TrackerIssueRef,
        blockedBy: [TrackerIssueRef: [TrackerIssueRef]],
        maxDepth: Int
    ) -> [TrackerIssueRef] {
        var chain: [TrackerIssueRef] = []
        var visited: Set<TrackerIssueRef> = [start]
        var current = start
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

    /// Count issues transitively blocked by this one.
    private static func countDownstream(
        from start: TrackerIssueRef,
        blocks: [TrackerIssueRef: [TrackerIssueRef]],
        maxDepth: Int
    ) -> Int {
        var visited: Set<TrackerIssueRef> = [start]
        var queue = [start]
        var count = 0
        var depth = 0
        while !queue.isEmpty, depth < maxDepth {
            var nextLevel: [TrackerIssueRef] = []
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

    /// The root cause's assignee, then the issue's assignee and reporter,
    /// each Slack user once.
    private static func buildPingTargets(issue: TrackerIssue, root: TrackerIssue?) -> [PingTarget] {
        var targets: [PingTarget] = []
        var seen: Set<String> = []
        func add(_ slackID: String, _ name: String, _ reason: String) {
            guard !slackID.isEmpty, seen.insert(slackID).inserted else { return }
            targets.append(PingTarget(slackUserID: slackID, displayName: name, reason: reason))
        }
        if let root {
            add(root.assigneeSlackID, root.assigneeDisplayName, "root cause assignee (\(root.key))")
        }
        add(issue.assigneeSlackID, issue.assigneeDisplayName, "assignee")
        add(issue.reporterSlackID, issue.reporterDisplayName, "reporter")
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

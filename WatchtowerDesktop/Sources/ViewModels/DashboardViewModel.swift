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
    var isGenerating = false
    var errorMessage: String?

    /// Master-detail selection (left list ↔ review pane). Lives here — the VM
    /// is AppState-owned — so selection survives tab/sidebar navigation.
    var selectedSituationID: Int?

    /// Member signals per situation, loaded lazily on selection and cached so
    /// re-selecting doesn't re-hit the DB (was view-local state in the old
    /// in-feed expansion UI).
    private var memberSignalsCache: [Int: [InboxItem]] = [:]

    var selectedSituation: Situation? {
        guard let id = selectedSituationID else { return nil }
        return situations.first { $0.id == id }
    }

    func select(_ situationID: Int?) {
        selectedSituationID = situationID
        guard let id = situationID, memberSignalsCache[id] == nil else { return }
        memberSignalsCache[id] = loadMemberSignals(id)
    }

    func memberSignals(for situationID: Int) -> [InboxItem] {
        memberSignalsCache[situationID] ?? []
    }

    func memberSignalsLoaded(_ situationID: Int) -> Bool {
        memberSignalsCache[situationID] != nil
    }

    /// Page size for `fetchFeed`; overridable by tests to exercise pagination cheaply.
    var pageSize: Int = 50
    private var offset: Int = 0

    // Name caches for rendering member-signal originals (resolved lazily, on
    // `loadMemberSignals`, the same way InboxViewModel resolves conversation names).
    private(set) var senderNames: [String: String] = [:]
    private(set) var channelNames: [String: String] = [:]

    // Workspace identity, used to build `slack://` deep links — same fields/fetch
    // as the dead `InboxViewModel.load()` (workspaceDomain unused today but kept
    // alongside teamID for parity with the other view models' workspace cache).
    private(set) var workspaceDomain: String?
    private(set) var workspaceTeamID: String?

    private let dbManager: DatabaseManager
    private var observationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    /// Overrides CLI resolution for tests; production falls back to
    /// `ProcessCLIRunner.makeDefault()` (mirrors `TargetsViewModel.resolveCLIRunner`).
    private let cliRunner: CLIRunnerProtocol?

    /// Interval for the safety-net poll. GRDB ValueObservation cannot see writes
    /// from the Go daemon (separate process, separate SQLite update hooks), so
    /// the feed needs a periodic reload to surface daemon-composed situations.
    private let pollInterval: Duration = .seconds(30)

    init(dbManager: DatabaseManager, cliRunner: CLIRunnerProtocol? = nil) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
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

    /// Runs `watchtower inbox generate` on demand (toolbar/empty-state "Generate"
    /// action) so a user can pull a fresh feed without waiting for the daemon's
    /// next cycle, then reloads. Guards re-entry via `isGenerating` since the
    /// pipeline can take minutes to run.
    func generateNow() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        do {
            try await DashboardGenerateService(runner: runner).generate()
            load()
        } catch {
            errorMessage = "Failed to generate dashboard: \(error.localizedDescription)"
        }
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
                let ws = try WorkspaceQueries.fetchWorkspace(db)
                let feed = try SituationQueries.fetchFeed(db, limit: self.pageSize, offset: 0)
                let count = try SituationQueries.openCount(db)
                return (ws?.domain, ws?.id, feed, count)
            }
            workspaceDomain = result.0
            workspaceTeamID = result.1
            situations = result.2
            openCount = result.3
            offset = result.2.count
            errorMessage = nil
            reconcileSelection()
        } catch {
            situations = []
            openCount = 0
            selectedSituationID = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Keeps the selection valid across reloads: an id still in the feed is
    /// kept; a vanished or absent selection falls back to the first situation.
    private func reconcileSelection() {
        if let id = selectedSituationID, situations.contains(where: { $0.id == id }) { return }
        select(situations.first?.id)
    }

    /// Pre-computes which situation should be selected after `removed` leaves
    /// the open feed: the next row in list order, the previous when the last
    /// row was acted on, nil when the feed empties. Only applies when the
    /// removed situation IS the selected one — acting on an unselected row
    /// (context menu) leaves selection alone.
    private func advanceSelection(from removed: Situation) {
        guard selectedSituationID == removed.id else { return }
        guard let idx = situations.firstIndex(where: { $0.id == removed.id }) else { return }
        let remaining = situations.filter { $0.id != removed.id }
        guard !remaining.isEmpty else {
            selectedSituationID = nil
            return
        }
        select(remaining[min(idx, remaining.count - 1)].id)
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
        advanceSelection(from: situation)
        do {
            try dbManager.dbPool.write { db in try SituationQueries.done(db, id: situation.id) }
            load()
        } catch {
            errorMessage = "Failed to mark done: \(error.localizedDescription)"
        }
    }

    func dismiss(_ situation: Situation) {
        advanceSelection(from: situation)
        do {
            try dbManager.dbPool.write { db in try SituationQueries.dismiss(db, id: situation.id) }
            load()
        } catch {
            errorMessage = "Failed to dismiss: \(error.localizedDescription)"
        }
    }

    /// "Keep open" on a suggested resolution (DASH-07): clears the secretary's
    /// mark and nothing else.
    func keepOpen(_ situation: Situation) {
        do {
            try dbManager.dbPool.write { db in
                try SituationQueries.clearSuggestedResolution(db, id: situation.id)
            }
            load()
        } catch {
            errorMessage = "Failed to keep open: \(error.localizedDescription)"
        }
    }

    func snooze(_ situation: Situation, until: String) {
        advanceSelection(from: situation)
        do {
            try dbManager.dbPool.write { db in try SituationQueries.snooze(db, id: situation.id, until: until) }
            load()
        } catch {
            errorMessage = "Failed to snooze: \(error.localizedDescription)"
        }
    }

    /// Marks a situation converted into a target and/or track, recording the
    /// resulting id(s) so the link isn't lost (DASH-03), then reloads. Called
    /// once the create-target/create-track sheet has produced a real id.
    func markConverted(situationID: Int, targetID: Int?, trackID: Int?) {
        if let situation = situations.first(where: { $0.id == situationID }) {
            advanceSelection(from: situation)
        }
        do {
            try dbManager.dbPool.write { db in
                try SituationQueries.markConverted(db, id: situationID, targetID: targetID, trackID: trackID)
            }
            load()
        } catch {
            errorMessage = "Failed to record conversion: \(error.localizedDescription)"
        }
    }

    /// Records thumbs-up/down feedback for a situation. Comment-less feedback
    /// stays on the direct-write fast path: the raw rating lands in the
    /// feedback table (entity_type='situation') so the 👍/👎 control reflects
    /// it, and rating -1 additionally derives channel mute rules — see
    /// `SituationQueries.recordFeedback`. A non-empty comment routes through
    /// `watchtower inbox feedback`, which persists the rating row itself
    /// (Go `SubmitSituationFeedback`) before running the learning interpreter
    /// (same pattern as `CatchUpViewModel.submitFeedback`).
    func submitFeedback(_ situation: Situation, rating: Int, comment: String = "") async {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            do {
                try await dbManager.dbPool.write { db in
                    try FeedbackQueries.addFeedback(
                        db, entityType: "situation", entityID: String(situation.id), rating: rating)
                    try SituationQueries.recordFeedback(db, situationID: situation.id, rating: rating)
                }
                load()
            } catch {
                errorMessage = "Failed to submit feedback: \(error.localizedDescription)"
            }
            return
        }
        guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        do {
            _ = try await runner.run(args: [
                "inbox", "feedback", String(situation.id),
                "--rating", rating >= 0 ? "up" : "down",
                "--comment", trimmed
            ])
        } catch {
            errorMessage = "Failed to submit feedback: \(error.localizedDescription)"
        }
    }

    /// Returns the situation's most recent 👍/👎 rating (nil = never rated),
    /// so the review pane's feedback control can render its selected state.
    func feedbackRating(for situationID: Int) -> Int? {
        try? dbManager.dbPool.read { db in
            try FeedbackQueries.getFeedback(
                db, entityType: "situation", entityID: String(situationID))?.rating
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

    /// Builds a Slack deep link for a member signal — mirrors the dead
    /// `InboxViewModel.slackMessageURL(for:)`'s `channel + message_ts` construction
    /// (using the thread parent ts when the item is a thread reply). Falls back to
    /// the item's stored permalink when no workspace team id is known yet.
    func slackURL(for item: InboxItem) -> URL? {
        if let teamID = workspaceTeamID, !teamID.isEmpty {
            let ts = item.threadTS.isEmpty ? item.messageTS : item.threadTS
            return URL(string: "slack://channel?team=\(teamID)&id=\(item.channelID)&message=\(ts)")
        }
        guard !item.permalink.isEmpty else { return nil }
        return URL(string: item.permalink)
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

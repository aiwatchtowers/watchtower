import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class ChannelStatsViewModel {
    enum Filter: String, CaseIterable {
        case all = "All"
        case muted = "Muted"
        case favorites = "Favorites"
        case hasRecommendations = "Recommendations"
        case notSynced = "Not synced"
    }

    enum SortOrder: String, CaseIterable {
        case messageCount = "Messages"
        case name = "Name"
        case botRatio = "Bot %"
        case lastActivity = "Activity"
    }

    var stats: [ChannelStat] = []
    var recommendations: [ChannelRecommendation] = []
    var filter: Filter = .all
    var sortOrder: SortOrder = .messageCount
    var searchText = ""
    var minMessages: Int = 5
    var showAllChannels = false
    var isLoading = false
    var errorMessage: String?
    private(set) var slackLinks: SlackLinkResolver?

    private let dbManager: DatabaseManager
    /// Runs `watchtower channels exclude|include`: the CLI is the only
    /// writer of the Stop syncing columns (`db.SetSyncExcluded`).
    @ObservationIgnored private let cliRunner: (any CLIRunnerProtocol)?
    /// Every write of this view model, in order (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// One pending toggle per row (board #670).
    let pendingWrites = PendingWrites()
    private(set) var observationTask: Task<Void, Never>?

    init(dbManager: DatabaseManager, cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault()) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
    }

    func startObserving() {
        guard observationTask == nil else { return }
        // No load() here: the observation's first value is the load, so a
        // write between a load and the registration cannot be missed.
        isLoading = true
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM channels") ?? 0
            }
            do {
                for try await _ in observation.values(in: dbPool) {
                    // A released VM ends the loop, so its observer leaves the pool
                    // at the next change even if no view called stopObserving().
                    guard !Task.isCancelled, let self else { break }
                    self.load()
                }
            } catch {}
        }
    }

    func load() {
        isLoading = true
        let dbPool = dbManager.dbPool
        Task.detached { [weak self] in
            let result: ([ChannelStat], [ChannelRecommendation], SlackLinkResolver?)
            do {
                result = try await dbPool.read { db in
                    let uid = try ChannelStatsQueries.fetchCurrentUserID(db)
                    guard let uid, !uid.isEmpty else {
                        return ([ChannelStat](), [ChannelRecommendation](), SlackLinkResolver?.none)
                    }
                    let allStats = try ChannelStatsQueries.fetchAll(db, currentUserID: uid)
                    let signals = try ChannelStatsQueries.fetchValueSignals(db)
                    let recs = ChannelStatsQueries.computeRecommendations(from: allStats, signals: signals)
                    return (allStats, recs, try SlackLinkResolver.load(db))
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stats = []
                    self?.recommendations = []
                    self?.errorMessage = error.localizedDescription
                    self?.isLoading = false
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.stats = result.0
                self?.recommendations = result.1
                self?.slackLinks = result.2
                self?.errorMessage = nil
                self?.isLoading = false
            }
        }
    }

    var filteredStats: [ChannelStat] {
        var result = stats

        // Apply minimum messages filter unless showing all. Not synced
        // shows every excluded channel: they stop growing, so a small one
        // would otherwise vanish.
        if !showAllChannels && filter != .notSynced {
            result = result.filter { $0.totalMessages >= minMessages }
        }

        switch filter {
        case .all:
            break
        case .muted:
            result = result.filter(\.isMutedForLLM)
        case .favorites:
            result = result.filter(\.isFavorite)
        case .hasRecommendations:
            let recChannelIDs = Set(recommendations.map(\.channelID))
            result = result.filter { recChannelIDs.contains($0.id) }
        case .notSynced:
            result = result.filter(\.isSyncExcluded)
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(query) }
        }

        switch sortOrder {
        case .messageCount:
            result.sort { $0.totalMessages > $1.totalMessages }
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .botRatio:
            result.sort { $0.botRatio > $1.botRatio }
        case .lastActivity:
            result.sort { $0.lastActivity > $1.lastActivity }
        }

        return result
    }

    /// Whether any channel is not synced (the Not synced filter's empty
    /// state says "Every channel is synced" only when none is).
    var hasNotSyncedChannels: Bool { stats.contains(where: \.isSyncExcluded) }

    var recommendationCount: Int {
        recommendations.count
    }

    /// Number of channels hidden by min messages filter.
    var hiddenChannelCount: Int {
        guard !showAllChannels && filter != .notSynced else { return 0 }
        return stats.filter { $0.totalMessages < minMessages }.count
    }

    // MARK: - Summary stats

    var totalChannels: Int { stats.count }
    var activeChannels: Int { stats.filter { ($0.lastActivityDaysAgo ?? 999) <= 7 }.count }
    var mutedChannels: Int { stats.filter(\.isMutedForLLM).count }
    var favoriteChannels: Int { stats.filter(\.isFavorite).count }
    var totalMessages: Int { stats.reduce(0) { $0 + $1.totalMessages } }
    var digestedChannels: Int { stats.filter(\.hasDigests).count }
    var pendingDigestChannels: Int {
        stats.filter { if case .pending = $0.digestStatus { return true }; return false }.count
    }

    /// A toggle pressed again while its write waits does nothing (board #670):
    /// it would flip from the same stale row a second time.
    func toggleMute(channelID: String) async {
        await pendingWrites.run("mute:\(channelID)") {
            guard let stat = stats.first(where: { $0.id == channelID }) else { return }
            await setMuted(channelID: channelID, muted: !stat.isMutedForLLM)
        }
    }

    func toggleFavorite(channelID: String) async {
        await pendingWrites.run("favorite:\(channelID)") {
            guard let stat = stats.first(where: { $0.id == channelID }) else { return }
            await setFavorite(channelID: channelID, favorite: !stat.isFavorite)
        }
    }

    /// Stop syncing a synced channel, Sync again an excluded one.
    func toggleSyncExcluded(channelID: String) async {
        await pendingWrites.run("sync:\(channelID)") {
            guard let stat = stats.first(where: { $0.id == channelID }) else { return }
            await setSyncExcluded(channelID: channelID, excluded: !stat.isSyncExcluded)
        }
    }

    func isMutePending(_ channelID: String) -> Bool { pendingWrites.isPending("mute:\(channelID)") }
    func isFavoritePending(_ channelID: String) -> Bool { pendingWrites.isPending("favorite:\(channelID)") }
    func isSyncPending(_ channelID: String) -> Bool { pendingWrites.isPending("sync:\(channelID)") }

    /// The CLI's `--json` answer.
    private struct ExcludeAnswer: Decodable {
        let ok: Bool
    }

    /// Runs `channels exclude|include --id <id> --json` in this view model's
    /// write chain. No optimistic flip: a failure says why and leaves the
    /// row as the database has it.
    private func setSyncExcluded(channelID: String, excluded: Bool) async {
        do {
            guard let runner = cliRunner else { throw CLIRunnerError.binaryNotFound }
            let args = ["channels", excluded ? "exclude" : "include", "--id", channelID, "--json"]
            let data = try await writes.runThrowing { try await runner.run(args: args) }
            // The CLI answers ok or exits non-zero; an answer that does not
            // decode is a failure too.
            _ = try JSONDecoder().decode(ExcludeAnswer.self, from: data)
            load()
        } catch {
            errorMessage = ChannelStatsPresentation.actionFailed(excluding: excluded, error.localizedDescription)
        }
    }

    private func setMuted(channelID: String, muted: Bool) async {
        do {
            try await chained { db in
                try ChannelStatsQueries.toggleMuteForLLM(db, channelID: channelID, muted: muted)
            }
            load()
        } catch {
            errorMessage = "Failed to toggle mute: \(error.localizedDescription)"
        }
    }

    private func setFavorite(channelID: String, favorite: Bool) async {
        do {
            try await chained { db in
                try ChannelStatsQueries.toggleFavorite(db, channelID: channelID, favorite: favorite)
            }
            load()
        } catch {
            errorMessage = "Failed to toggle favorite: \(error.localizedDescription)"
        }
    }

    func slackURL(for channelID: String) -> URL? {
        slackLinks?.channelURL(channelID)
    }

    /// Sets the recommended state outright — never a toggle, so a stale or
    /// repeated apply is idempotent and can never un-mute (feeding the channel
    /// back into the AI pipelines) or un-favorite. "Leave" mutes: Watchtower
    /// cannot leave a Slack channel for the owner.
    func applyRecommendation(_ rec: ChannelRecommendation) async {
        switch rec.action {
        case .mute, .leave:
            await setMuted(channelID: rec.channelID, muted: true)
        case .favorite:
            await setFavorite(channelID: rec.channelID, favorite: true)
        case .exclude:
            await pendingWrites.run("sync:\(rec.channelID)") {
                await setSyncExcluded(channelID: rec.channelID, excluded: true)
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// A database write in this view model's chain (board #670): it starts
    /// only once every write asked for before it finished.
    private func chained<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writes.runThrowing { try await self.dbManager.dbPool.write(body) }
    }
}

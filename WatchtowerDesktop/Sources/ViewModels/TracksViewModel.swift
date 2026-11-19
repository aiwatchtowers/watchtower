import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

@MainActor
@Observable
final class TracksViewModel {
    var updatedTracks: [Track] = []
    var allTracks: [Track] = []
    /// User-authored custom tracks, shown in a pinned "Custom" section above the
    /// auto sections. Kept out of `updatedTracks`/`allTracks` so a custom track
    /// is never listed twice.
    var customTracks: [Track] = []
    var isLoading = false
    var errorMessage: String?
    var totalCount: Int = 0
    var updatedCount: Int = 0
    var trackTaskCounts: [Int: Int] = [:]

    // Jira data
    var isJiraConnected: Bool = false
    var jiraSiteURL: String?
    var trackJiraIssues: [Int: [JiraIssue]] = [:]

    private(set) var workspaceDomain: String?
    private(set) var slackLinks: SlackLinkResolver?
    private let dbManager: DatabaseManager
    /// The presses through the tower and each track row's state.
    let presses: TowerPresses
    /// The feedback writes, in order (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// One pending sub-item write per track (board #670).
    let pendingWrites = PendingWrites()

    // User name cache for resolving Slack user IDs
    private(set) var userNameCache: [String: String] = [:]
    // swiftlint:disable:next force_try
    private static let userIDPattern = try! NSRegularExpression(
        pattern: "U[A-Z0-9]{8,11}"
    )

    init(dbManager: DatabaseManager, tower: (any TowerSending)? = nil) {
        self.dbManager = dbManager
        presses = TowerPresses(tower: tower)
        presses.reread = { [weak self] in self?.load() }
        refreshJiraStatus()
    }

    func load() {
        isLoading = true
        do {
            let result = try dbManager.dbPool.read { db in
                let ws = try WorkspaceQueries.fetchWorkspace(db)
                let counts = try TrackQueries.fetchCounts(db)
                let all = try TrackQueries.fetchAll(db)
                let taskRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT CAST(source_id AS INTEGER) AS track_id, COUNT(*) AS cnt
                        FROM targets
                        WHERE source_type = 'track'
                          AND status NOT IN ('done', 'dismissed')
                          AND source_id != ''
                        GROUP BY source_id
                        """
                )
                let taskCounts = Dictionary(uniqueKeysWithValues: taskRows.compactMap { row -> (Int, Int)? in
                    guard let tid = row["track_id"] as Int?, let cnt = row["cnt"] as Int? else { return nil }
                    return (tid, cnt)
                })
                return (ws?.domain, try SlackLinkResolver.load(db), all, counts, taskCounts)
            }
            workspaceDomain = result.0
            slackLinks = result.1
            trackTaskCounts = result.4

            var tracks = result.2

            // Load Jira issues for all tracks in a single read
            if isJiraConnected {
                loadJiraData(trackIDs: tracks.map(\.id))
            }

            // Custom tracks are pinned in their own section — partition them out
            // of the auto sections so they aren't listed twice.
            customTracks = tracks.filter { $0.isCustom }
            let autoTracks = tracks.filter { !$0.isCustom }
            updatedTracks = autoTracks.filter { $0.hasUpdates }
            let rest = autoTracks.filter { !$0.hasUpdates }
            // Read tracks stay hidden
            allTracks = rest.filter { $0.isUnread }
            totalCount = result.3.total
            updatedCount = result.3.updated
            refreshUserNameCache(tracks: tracks)
            errorMessage = nil
        } catch {
            updatedTracks = []
            allTracks = []
            customTracks = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func taskCount(for trackID: Int) -> Int {
        trackTaskCounts[trackID] ?? 0
    }

    // Every write is a `tracks.*` tower command (#1170 Task 12): Go writes
    // the row, the track's row carries the press's state (`presses`), and
    // the screen re-reads after an answer.

    /// The row key of `id`'s presses.
    static func row(_ id: Int) -> String { "track:\(id)" }

    func markRead(_ track: Track) async {
        await press(.tracksRead, track.id, label: TowerPressText.marking) {
            ScreenIDsRequest(requestID: $0, iDs: [Int64(track.id)])
        }
    }

    func updatePriority(_ track: Track, to priority: String) async {
        await press(.tracksPriority, track.id, label: TowerPressText.updating, variant: priority) {
            TrackPriorityRequest(requestID: $0, id: Int64(track.id), priority: priority)
        }
    }

    func updateOwnership(_ track: Track, to ownership: String) async {
        await press(.tracksOwnership, track.id, label: TowerPressText.updating, variant: ownership) {
            TrackOwnershipRequest(requestID: $0, id: Int64(track.id), ownership: ownership)
        }
    }

    /// Sets the sub-item to the opposite of what the row showed (board #670).
    /// Go re-reads the row in its own transaction and changes only that
    /// item, so another item's change landing first is kept. A second press
    /// on the same item while its write waits does nothing.
    func toggleSubItem(_ track: Track, at index: Int) async {
        let shown = track.decodedSubItems
        guard index >= 0, index < shown.count else { return }
        let done = !shown[index].isDone
        let id = track.id
        await pendingWrites.run(Self.subItemKey(trackID: id, index: index)) {
            await press(.tracksSubItems, id, label: TowerPressText.updating, variant: "\(index)|\(done)") {
                TrackSubItemRequest(requestID: $0, id: Int64(id), index: index, done: done)
            }
        }
    }

    /// The `pendingWrites` key of one sub-item's toggle, for the view to
    /// disable its checkbox meanwhile.
    static func subItemKey(trackID: Int, index: Int) -> String {
        "subItem:\(trackID):\(index)"
    }

    /// Stop watching (TRACKS-07): `tracks.stop`, which also stops a custom
    /// track's collection.
    func dismissTrack(_ track: Track) async {
        await press(.tracksStop, track.id, label: TowerPressText.updating) {
            ScreenIDsRequest(requestID: $0, iDs: [Int64(track.id)])
        }
    }

    func restoreTrack(_ track: Track) async {
        await press(.tracksRestore, track.id, label: TowerPressText.updating) {
            ScreenIDRequest(requestID: $0, id: Int64(track.id))
        }
    }

    /// One press on track `id`'s row; its failure stays on the row and in
    /// `errorMessage` (the track pane's banner).
    private func press<Params: Encodable & Sendable>(
        _ command: TowerCommand,
        _ id: Int,
        label: String,
        variant: String = "",
        _ params: @escaping (String) -> Params
    ) async {
        let row = Self.row(id)
        let result: ActResult? = await presses.send(command, row: row, label: label, variant: variant, params: params)
        if result == nil, case .refused(let sentence) = presses.state(row) { errorMessage = sentence }
    }

    func fetchDigest(id: Int) -> Digest? {
        do {
            return try dbManager.dbPool.read { db in
                try DigestQueries.fetchByID(db, id: id)
            }
        } catch {
            return nil
        }
    }

    func channelName(for channelID: String) -> String? {
        guard !channelID.isEmpty else { return nil }
        do {
            return try dbManager.dbPool.read { db in
                try ChannelQueries.fetchByID(db, id: channelID)?.name
            }
        } catch {
            return nil
        }
    }

    func itemByID(_ id: Int) -> Track? {
        do {
            return try dbManager.dbPool.read { db in
                try TrackQueries.fetchByID(db, id: id)
            }
        } catch {
            return nil
        }
    }

    func slackChannelURL(channelID: String) -> URL? {
        slackLinks?.channelURL(channelID)
    }

    func slackMessageURL(channelID: String, messageTS: String, threadTS: String? = nil) -> URL? {
        // Use thread parent TS when available — Slack opens the thread context correctly.
        let ts = threadTS.flatMap { $0.isEmpty ? nil : $0 } ?? messageTS
        return slackLinks?.channelURL(channelID, messageTS: ts)
    }

    func submitFeedback(trackID: Int, rating: Int) async {
        do {
            try await chained { db in
                try FeedbackQueries.addFeedback(
                    db,
                    entityType: "track",
                    entityID: "\(trackID)",
                    rating: rating,
                    comment: ""
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Jira

    func refreshJiraStatus() {
        isJiraConnected = JiraQueries.isConnected()
        if isJiraConnected {
            jiraSiteURL = JiraConfigHelper.readSiteURL()
        } else {
            jiraSiteURL = nil
            trackJiraIssues = [:]
        }
    }

    func jiraIssues(for trackID: Int) -> [JiraIssue] {
        trackJiraIssues[trackID] ?? []
    }

    private func loadJiraData(trackIDs: [Int]) {
        do {
            let issueMap = try dbManager.dbPool.read { db in
                try JiraQueries.fetchIssuesForTracks(db, trackIDs: trackIDs)
            }
            trackJiraIssues = issueMap
        } catch {
            trackJiraIssues = [:]
        }
    }

    // MARK: - User name resolution

    func resolveUserIDs(_ text: String) -> String {
        guard !userNameCache.isEmpty else { return text }
        guard let pattern = try? NSRegularExpression(pattern: "\\(?(U[A-Z0-9]{8,11})\\)?") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = pattern.matches(in: text, range: range).reversed()
        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let idRange = Range(match.range(at: 1), in: result) else { continue }
            let userID = String(result[idRange])
            if let name = userNameCache[userID] {
                let fullMatch = String(result[fullRange])
                let hasParens = fullMatch.hasPrefix("(") && fullMatch.hasSuffix(")")
                result.replaceSubrange(
                    fullRange, with: hasParens ? "(\(name))" : name
                )
            }
        }
        return result
    }

    private func refreshUserNameCache(tracks: [Track]) {
        let allText = tracks.flatMap {
            [$0.text, $0.context, $0.blocking, $0.participants, $0.requesterName]
        }
        let joined = allText.joined(separator: " ")
        let range = NSRange(joined.startIndex..., in: joined)
        let matches = Self.userIDPattern.matches(in: joined, range: range)
        var userIDs = Set<String>()
        for match in matches {
            if let idRange = Range(match.range, in: joined) {
                userIDs.insert(String(joined[idRange]))
            }
        }
        let newIDs = userIDs.subtracting(userNameCache.keys)
        guard !newIDs.isEmpty else { return }

        do {
            let map = try dbManager.dbPool.read { db in
                var result: [String: String] = [:]
                for uid in newIDs {
                    let name = try UserQueries.fetchDisplayName(db, forID: uid)
                    if name != uid { result[uid] = name }
                }
                return result
            }
            userNameCache.merge(map) { _, new in new }
        } catch {}
    }

    /// A database write in this view model's chain (board #670): it starts
    /// only once every write asked for before it finished.
    private func chained<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writes.runThrowing { try await self.dbManager.dbPool.write(body) }
    }
}

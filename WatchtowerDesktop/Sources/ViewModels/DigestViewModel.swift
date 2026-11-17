import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// One row of the Digests segment's cross-source feed: a Slack channel/daily/
/// weekly digest, a Gmail/Jira stream digest (Task 9), or a meeting recording
/// — merged into a single date-sorted list. Day grouping is a view-layer
/// concern (`Calendar`-based, `DigestListView`); this type only carries what
/// the view needs to sort, identify, and route to a detail pane.
enum DigestFeedEntry: Identifiable, Equatable {
    case slack(Digest)
    case stream(StreamDigest)
    case meeting(RecordingListItem)

    var id: String {
        switch self {
        case .slack(let d): "slack-\(d.id)"
        case .stream(let d): "stream-\(d.id)"
        case .meeting(let r): "meeting-\(r.id)"
        }
    }

    var date: Date {
        switch self {
        case .slack(let d): TimeFormatting.parseISO(d.createdAt) ?? .distantPast
        case .stream(let d): TimeFormatting.parseISO(d.createdAt) ?? .distantPast
        case .meeting(let r): r.createdDate ?? .distantPast
        }
    }

    /// A meeting recording has no unread concept (nothing in
    /// `meeting_transcripts` tracks read state) — always read, so the
    /// "Unread" filter never hides a Slack/stream item behind it and never
    /// shows a meeting row there either.
    var isRead: Bool {
        switch self {
        case .slack(let d): d.isRead
        case .stream(let d): d.isRead
        case .meeting: true
        }
    }
}

@MainActor
@Observable
final class DigestViewModel {
    var digests: [Digest] = []
    /// Gmail/Jira stream digests (Task 9) feeding the cross-source feed.
    var streamDigests: [StreamDigest] = []
    /// Meeting recordings feeding the cross-source feed — filtered to
    /// `hasRecap` at load (see `load()`), always-read entries.
    var recordings: [RecordingListItem] = []
    var unreadStreamCount: Int = 0
    /// Slack digests + stream digests + meeting recordings, merged and sorted
    /// per `sortOrder`. Computed (not stored) so it always reflects the
    /// latest loaded state of the three source arrays.
    var feedEntries: [DigestFeedEntry] {
        let combined: [DigestFeedEntry] = digests.map(DigestFeedEntry.slack)
            + streamDigests.map(DigestFeedEntry.stream)
            + recordings.map(DigestFeedEntry.meeting)
        switch sortOrder {
        case .newestFirst: return combined.sorted { $0.date > $1.date }
        case .oldestFirst: return combined.sorted { $0.date < $1.date }
        }
    }
    /// The decisions ledger — `ideas WHERE kind = 'decision'`, ordered by
    /// `last_mention_at` (falling back to `updated_at`), newest first. Replaces
    /// the old digest-scanned `decisionEntries`/`DecisionEntry` machinery: a
    /// decision is a durable, cross-source, deduped row in the ideas registry
    /// now, not something rebuilt from raw digest JSON on every load.
    var ledgerDecisions: [Idea] = []
    /// Distinct mention sources per decision (idea id -> `["slack", "jira", ...]`),
    /// for the ledger row's compact source glyphs (spec B3).
    var decisionMentionSources: [Int: [String]] = [:]
    var selectedType: String?
    var isLoading = false
    var errorMessage: String?
    var unreadDigestCount: Int = 0
    var unreadDecisionCount: Int = 0
    var sortOrder: SortOrder = .newestFirst
    /// One pending star write per channel (board #670).
    let pendingWrites = PendingWrites()

    enum SortOrder: String, CaseIterable {
        case newestFirst = "Newest first"
        case oldestFirst = "Oldest first"

        var systemImage: String {
            self == .newestFirst ? "arrow.down" : "arrow.up"
        }
    }

    func setSortOrder(_ order: SortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        digests = applySort(digests)
        // fetchDecisionLedger always returns newest-mentioned-first; with only
        // two possible directions, reversing the current array always yields
        // the other one — no need to re-fetch or keep a separate raw copy.
        ledgerDecisions = Array(ledgerDecisions.reversed())
    }

    private func applySort(_ items: [Digest]) -> [Digest] {
        switch sortOrder {
        case .newestFirst: return items.sorted { $0.periodTo > $1.periodTo }
        case .oldestFirst: return items.sorted { $0.periodTo < $1.periodTo }
        }
    }

    /// `IdeaQueries.fetchDecisionLedger` always returns newest-mentioned-first;
    /// applied to a freshly fetched (always newest-first) batch.
    private func applyLedgerSort(_ items: [Idea]) -> [Idea] {
        sortOrder == .oldestFirst ? Array(items.reversed()) : items
    }

    // Pagination — digests
    private(set) var hasMoreDigests = true
    private var digestsOffset = 0
    var isLoadingMoreDigests = false
    private let digestsPageSize = 50

    // M9: pre-fetched caches (avoids DB read per row in view body)
    private var channelNameCache: [String: String] = [:]
    private(set) var workspaceDomain: String?
    private(set) var slackLinks: SlackLinkResolver?
    private(set) var starredChannelIDs: Set<String> = []
    private let dbManager: DatabaseManager
    /// Every write of this view model, in order (board #670).
    @ObservationIgnored private let writes = SerialWrites()
    /// The `stream_digests` observation delivered its baseline: a write from
    /// now on surfaces in the feed (tests wait on it); false again after
    /// `stopObserving()`.
    private(set) var streamsObserved = false
    private var observationTask: Task<Void, Never>?
    private var streamsObservationTask: Task<Void, Never>?
    private var decisionsObservationTask: Task<Void, Never>?
    private var decisionsPollTask: Task<Void, Never>?
    /// GRDB ValueObservation cannot see writes from the Go daemon (separate
    /// process, separate SQLite update hooks) — the ideas.consolidate pipeline
    /// mines decisions there, so the ledger needs the same periodic-reload
    /// safety net the Inbox poll is (`ActionStripViewModel`).
    private let decisionsPollInterval: Duration = .seconds(30)

    /// The presses through the tower and each row's state.
    let presses: TowerPresses

    init(dbManager: DatabaseManager, tower: (any TowerSending)? = nil) {
        self.dbManager = dbManager
        presses = TowerPresses(tower: tower)
        presses.reread = { [weak self] in self?.reloadLedger() }
    }

    /// Start observing the digests table for live updates.
    func startObserving() {
        guard observationTask == nil else { return }
        load()
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests") ?? 0
            }
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self?.load()
                }
            } catch {}
        }
        // D9: new stream digests (Gmail/Jira, mined by the Go daemon's
        // ideas.digest_email/ideas.digest_jira passes) must surface in an
        // already-open Digests tab the same way a new Slack digest does —
        // mirrors the `digests` observation above, wired to reloadStreams()
        // instead of the full load().
        streamsObservationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_digests") ?? 0
            }
            do {
                var baseline = true
                for try await _ in observation.values(in: dbPool) {
                    guard !Task.isCancelled else { break }
                    // The first value is the baseline (`load()` read it); from
                    // here on every change of the table reaches the feed.
                    if baseline {
                        baseline = false
                        self?.streamsObserved = true
                        continue
                    }
                    self?.reloadStreams()
                }
            } catch {}
        }
        decisionsObservationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM ideas WHERE kind = 'decision' AND \(IdeaQueries.knowledgeVisibleSQL)
                    """) ?? 0
            }
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self?.reloadLedger()
                }
            } catch {}
        }
        startDecisionsPolling()
    }

    /// Drops the observations and the ledger poll — called when the
    /// Digests screen goes away, so a backgrounded tab stops waking up every
    /// 30 s to re-read the ledger. Safe to pair with `startObserving()` in
    /// any order: both are idempotent and `startObserving` reloads on the way
    /// back in, so a view that disappears and reappears on the same `@State`
    /// VM resumes with fresh data rather than staying dead.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        streamsObservationTask?.cancel()
        streamsObservationTask = nil
        streamsObserved = false
        decisionsObservationTask?.cancel()
        decisionsObservationTask = nil
        decisionsPollTask?.cancel()
        decisionsPollTask = nil
    }

    private func startDecisionsPolling() {
        guard decisionsPollTask == nil else { return }
        let interval = decisionsPollInterval
        decisionsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self?.reloadLedger()
            }
        }
    }

    private struct LoadResult {
        let digests: [Digest]
        let channelNames: [String: String]
        let domain: String?
        let slackLinks: SlackLinkResolver
        let unreadDigests: Int
        let ledgerDecisions: [Idea]
        let unreadDecisions: Int
        let decisionMentionSources: [Int: [String]]
        let starredChannels: Set<String>
        let streamDigests: [StreamDigest]
        let recordings: [RecordingListItem]
        let unreadStream: Int
    }

    func load() {
        isLoading = true
        do {
            let result = try dbManager.dbPool.read { db -> LoadResult in
                let digests = try DigestQueries.fetchAll(db, type: selectedType)
                let ws = try WorkspaceQueries.fetchWorkspace(db)

                // Pre-fetch user names for DM resolution
                let users = try UserQueries.fetchAll(db, activeOnly: false)
                var userNames: [String: String] = [:]
                for user in users {
                    let name = user.displayName.isEmpty ? user.name : user.displayName
                    userNames[user.id] = name
                }

                // Pre-fetch channel names, resolving DMs to user names.
                let allChannelIDs = Set(digests.map(\.channelID).filter { !$0.isEmpty })
                var nameMap: [String: String] = [:]
                for cid in allChannelIDs {
                    if let ch = try ChannelQueries.fetchByID(db, id: cid) {
                        if ch.type == "dm" || ch.type == "im" {
                            // Try dm_user_id first, then fall back to name if it looks like a user ID
                            let resolvedUID = ch.dmUserID ?? (ch.name.hasPrefix("U") ? ch.name : nil)
                            if let uid = resolvedUID, let userName = userNames[uid] {
                                nameMap[cid] = "DM: \(userName)"
                            } else {
                                nameMap[cid] = ch.name
                            }
                        } else {
                            nameMap[cid] = ch.name
                        }
                    }
                }

                let unreadDigests = try DigestQueries.unreadDigestCount(db)
                let ledgerDecisions = try IdeaQueries.fetchDecisionLedger(db)
                let unreadDecisions = try IdeaQueries.unreadDecisionCount(db)
                let mentionSources = try IdeaQueries.mentionSourcesByIdea(db, ids: ledgerDecisions.map(\.id))

                let profile = try ProfileQueries.fetchCurrentProfile(db)
                let starred = Set(profile?.decodedStarredChannels ?? [])

                let streamDigests = try StreamDigestQueries.fetchAll(db)
                // Feed noise guard (spec B2): an in-progress/failed/unrecapped
                // recording has nothing worth surfacing in the digest feed —
                // only recordings with a recap (own summary_json or the
                // linked event's meeting_recaps row) show up here.
                let recordings = try MeetingTranscriptQueries.fetchRecordingList(db)
                    .filter(\.hasRecap)
                let unreadStream = try StreamDigestQueries.unreadCount(db)

                return LoadResult(
                    digests: digests,
                    channelNames: nameMap,
                    domain: ws?.domain,
                    slackLinks: try SlackLinkResolver.load(db),
                    unreadDigests: unreadDigests,
                    ledgerDecisions: ledgerDecisions,
                    unreadDecisions: unreadDecisions,
                    decisionMentionSources: mentionSources,
                    starredChannels: starred,
                    streamDigests: streamDigests,
                    recordings: recordings,
                    unreadStream: unreadStream
                )
            }
            digests = applySort(result.digests)
            digestsOffset = result.digests.count
            hasMoreDigests = result.digests.count >= digestsPageSize
            channelNameCache = result.channelNames
            workspaceDomain = result.domain
            slackLinks = result.slackLinks
            starredChannelIDs = result.starredChannels
            ledgerDecisions = applyLedgerSort(result.ledgerDecisions)
            decisionMentionSources = result.decisionMentionSources
            unreadDigestCount = result.unreadDigests
            unreadDecisionCount = result.unreadDecisions
            streamDigests = result.streamDigests
            recordings = result.recordings
            unreadStreamCount = result.unreadStream
            errorMessage = nil
        } catch {
            digests = []
            ledgerDecisions = []
            decisionMentionSources = [:]
            streamDigests = []
            recordings = []
            unreadStreamCount = 0
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Read tracking (digests)

    // Every read mark and ledger verdict is a tower command (#1170 Task 12):
    // Go writes it (a digest's read cascades to its decisions), the row
    // keeps the press's state (`presses`), and the screen re-reads the slice
    // after the answer.

    /// The row keys of the presses.
    static func digestRow(_ id: Int) -> String { "digest:\(id)" }
    static func streamRow(_ id: Int) -> String { "stream:\(id)" }
    static func decisionRow(_ id: Int) -> String { "decision:\(id)" }
    static let allDecisionsRow = "decisions"

    func markDigestRead(_ digestID: Int) async {
        await markDigestsRead([digestID])
    }

    // MARK: - Read tracking (stream digests)

    /// Marks one Gmail/Jira stream digest read (`StreamDigestDetailView`'s
    /// `.onAppear`, the `DigestDetailView`/`markDigestRead`-on-selection
    /// precedent) and reloads just the stream slice so the feed entry's
    /// `isRead` and the segment's unread count update immediately.
    func markStreamRead(id: Int) async {
        let result: ActResult? = await presses.send(.digestsStreamRead, row: Self.streamRow(id),
                                                    label: TowerPressText.marking) {
            ScreenIDRequest(requestID: $0, id: Int64(id))
        }
        if result != nil { reloadStreams() }
    }

    /// Re-reads just the stream digests — cheaper than a full `load()` after
    /// a read-marking write (the `reloadLedger` precedent).
    private func reloadStreams() {
        do {
            let result = try dbManager.dbPool.read { db -> ([StreamDigest], Int) in
                (try StreamDigestQueries.fetchAll(db), try StreamDigestQueries.unreadCount(db))
            }
            streamDigests = result.0
            unreadStreamCount = result.1
        } catch {
            errorMessage = "Failed to reload stream digests: \(error.localizedDescription)"
        }
    }

    // MARK: - Batch operations

    func markDigestsRead(_ ids: Set<Int>) async {
        let sorted = ids.sorted()
        guard !sorted.isEmpty else { return }
        let row = sorted.count == 1 ? Self.digestRow(sorted[0]) : "digests:" + sorted.map(String.init).joined(separator: ",")
        let result: ActResult? = await presses.send(.digestsRead, row: row, label: TowerPressText.marking) {
            ScreenIDsRequest(requestID: $0, iDs: sorted.map(Int64.init))
        }
        guard result != nil else { return }
        for id in sorted {
            if let idx = digests.firstIndex(where: { $0.id == id && !$0.isRead }) {
                if let updated = digestByID(id) {
                    digests[idx] = updated
                }
                unreadDigestCount = max(0, unreadDigestCount - 1)
            }
        }
    }

    func submitBatchFeedback(entityType: String, entityIDs: [String], rating: Int) async {
        do {
            try await chained { db in
                for entityID in entityIDs {
                    try FeedbackQueries.addFeedback(db, entityType: entityType, entityID: entityID, rating: rating)
                }
            }
        } catch {
            print("Failed to submit batch feedback: \(error)")
        }
    }

    // MARK: - Decisions ledger

    /// Marks a single decision seen and reloads the ledger, so the row state
    /// and unread badge update immediately.
    func markDecisionSeen(id: Int) async {
        await ledgerPress(.ideasDecisionSeen, row: Self.decisionRow(id), label: TowerPressText.marking) {
            ScreenIDRequest(requestID: $0, id: Int64(id))
        }
    }

    /// Stamps every not-yet-seen decision as seen.
    func markAllDecisionsSeen() async {
        await ledgerPress(.ideasDecisionsSeenAll, row: Self.allDecisionsRow, label: TowerPressText.marking) {
            DecisionsSeenAllRequest(requestID: $0)
        }
    }

    func supersede(id: Int, by newID: Int? = nil) async {
        await ledgerPress(.ideasSupersede, row: Self.decisionRow(id), label: TowerPressText.updating,
                          variant: newID.map(String.init) ?? "") {
            IdeaSupersedeRequest(requestID: $0, id: Int64(id), by: newID.map(Int64.init))
        }
    }

    func reverse(id: Int) async {
        await ledgerPress(.ideasStatus, row: Self.decisionRow(id), label: TowerPressText.updating, variant: "reversed") {
            IdeaStatusRequest(requestID: $0, id: Int64(id), status: "reversed")
        }
    }

    /// Returns whether the rating landed, so the caller can keep an
    /// owner-typed comment on screen when it did not (clear-only-on-success,
    /// the IdeaDetailPane precedent).
    @discardableResult
    func setRating(id: Int, rating: Int, comment: String = "") async -> Bool {
        await ledgerPress(.ideasRating, row: Self.decisionRow(id), label: TowerPressText.saving,
                          variant: "\(rating)|\(comment)") {
            IdeaRatingRequest(requestID: $0, id: Int64(id), rating: rating, comment: comment)
        }
    }

    /// One ledger press: the ledger re-reads after the answer (the presses'
    /// `reread`), and a refusal says why in `errorMessage` after it.
    @discardableResult
    private func ledgerPress<Params: Encodable & Sendable>(
        _ command: TowerCommand,
        row: String,
        label: String,
        variant: String = "",
        _ params: @escaping (String) -> Params
    ) async -> Bool {
        let result: ActResult? = await presses.send(command, row: row, label: label, variant: variant, params: params)
        if result == nil, case .refused(let sentence) = presses.state(row) { errorMessage = sentence }
        return result != nil
    }

    /// Re-reads just the decisions ledger — cheaper than a full `load()`
    /// (digests/channels/workspace untouched) after a ledger-only write, and
    /// what the ValueObservation/poll safety net above calls on a daemon-mined
    /// change it detects.
    private func reloadLedger() {
        do {
            let result = try dbManager.dbPool.read { db -> (decisions: [Idea], unread: Int, sources: [Int: [String]]) in
                let decisions = try IdeaQueries.fetchDecisionLedger(db)
                let unread = try IdeaQueries.unreadDecisionCount(db)
                let sources = try IdeaQueries.mentionSourcesByIdea(db, ids: decisions.map(\.id))
                return (decisions, unread, sources)
            }
            ledgerDecisions = applyLedgerSort(result.decisions)
            unreadDecisionCount = result.unread
            decisionMentionSources = result.sources
            errorMessage = nil
        } catch {
            errorMessage = "Failed to reload decisions: \(error.localizedDescription)"
        }
    }

    // MARK: - Pagination

    func loadMoreDigests() {
        guard hasMoreDigests, !isLoadingMoreDigests else { return }
        isLoadingMoreDigests = true
        do {
            let batch = try dbManager.dbPool.read { db in
                try DigestQueries.fetchAll(db, type: selectedType, limit: digestsPageSize, offset: digestsOffset)
            }
            // Update channel name cache for new channels
            let newChannelIDs = Set(batch.map(\.channelID).filter { !$0.isEmpty }) .subtracting(channelNameCache.keys)
            if !newChannelIDs.isEmpty {
                let names = try dbManager.dbPool.read { db -> [String: String] in
                    var map: [String: String] = [:]
                    for cid in newChannelIDs {
                        if let ch = try ChannelQueries.fetchByID(db, id: cid) {
                            map[cid] = ch.name
                        }
                    }
                    return map
                }
                channelNameCache.merge(names) { _, new in new }
            }
            digests = applySort(digests + batch)
            digestsOffset += batch.count
            hasMoreDigests = batch.count >= digestsPageSize
        } catch {
            print("Failed to load more digests: \(error)")
        }
        isLoadingMoreDigests = false
    }

    func digestByID(_ id: Int) -> Digest? {
        do {
            return try dbManager.dbPool.read { db in
                try DigestQueries.fetchByID(db, id: id)
            }
        } catch {
            return nil
        }
    }

    func channelName(for digest: Digest) -> String? {
        guard !digest.channelID.isEmpty else { return nil }
        return channelNameCache[digest.channelID]
    }

    /// Returns unique contributing channels for a cross-channel digest (daily/weekly),
    /// sorted alphabetically by channel name.
    func contributingChannels(for digest: Digest) -> [(name: String, channelID: String)] {
        guard digest.channelID.isEmpty, digest.type == "daily" || digest.type == "weekly" else {
            return []
        }
        do {
            let channels = try dbManager.dbPool.read { db in
                try DigestQueries.fetchAll(db, type: "channel")
                    .filter { $0.periodFrom >= digest.periodFrom && $0.periodTo <= digest.periodTo }
            }
            var seen = Set<String>()
            var unique: [(name: String, channelID: String)] = []
            for d in channels {
                let cid = d.channelID
                guard !cid.isEmpty, seen.insert(cid).inserted else { continue }
                let name = channelNameCache[cid] ?? cid
                unique.append((name: name, channelID: cid))
            }
            unique.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return unique
        } catch {
            return []
        }
    }

    /// Build Slack channel deep link (opens Slack app directly)
    func slackChannelURL(channelID: String) -> URL? {
        slackLinks?.channelURL(channelID)
    }

    /// Build Slack message deep link (opens Slack app directly). An empty
    /// messageTS yields nil, not a channel-only link — the digest pipeline
    /// blanks a message_ts it could not verify, so "" is a routine value.
    func slackMessageURL(channelID: String, messageTS: String) -> URL? {
        guard !messageTS.isEmpty else { return nil }
        return slackLinks?.channelURL(channelID, messageTS: messageTS)
    }

    // MARK: - Starred Channels Management

    /// Toggle a channel's starred status. The write resolves the owner's
    /// profile key in its own transaction (`ProfileQueries.ownerProfileWriteKey`),
    /// never a key remembered at load() that a later re-key may have moved.
    /// The star changes only once the write landed; a second press while it
    /// waits does nothing (board #670).
    func toggleStarredChannel(_ channelID: String) async {
        await pendingWrites.run("star:\(channelID)") {
            await writeStar(channelID)
        }
    }

    /// The star of `channelID` is being written: its button waits.
    func isStarPending(_ channelID: String) -> Bool {
        pendingWrites.isPending("star:\(channelID)")
    }

    private func writeStar(_ channelID: String) async {
        let wasStarred = starredChannelIDs.contains(channelID)
        do {
            if wasStarred {
                try await writes.runThrowing { try await self.dbManager.removeStarredChannel(channelID) }
                starredChannelIDs.remove(channelID)
            } else {
                try await writes.runThrowing { try await self.dbManager.addStarredChannel(channelID) }
                starredChannelIDs.insert(channelID)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to update starred channel: \(error.localizedDescription)"
        }
    }

    /// Check if a channel is starred
    func isChannelStarred(_ channelID: String) -> Bool {
        starredChannelIDs.contains(channelID)
    }

    /// A database write in this view model's chain (board #670): it starts
    /// only once every write asked for before it finished.
    private func chained<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writes.runThrowing { try await self.dbManager.dbPool.write(body) }
    }
}

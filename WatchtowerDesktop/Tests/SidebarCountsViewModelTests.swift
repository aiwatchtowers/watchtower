import XCTest
import GRDB
import os
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// A count other threads bump, with a wait for a count.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var value: Int { lock.withLock { count } }

    @discardableResult
    func bump() -> Int {
        let (now, ready) = lock.withLock {
            count += 1
            let now = count
            let ready = waiters.filter { now >= $0.count }.map(\.continuation)
            waiters.removeAll { now >= $0.count }
            return (now, ready)
        }
        ready.forEach { $0.resume() }
        return now
    }

    func until(_ target: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let met = lock.withLock {
                if count >= target { return true }
                waiters.append((target, continuation))
                return false
            }
            if met { continuation.resume() }
        }
    }
}

/// The table observation, handing out a value only when the view model asks
/// for one: the ask for value N + 1 means value N was applied.
private final class PulledChanges: @unchecked Sendable {
    let pulls = Tally()
    private var base: AsyncThrowingStream<Void, Error>.AsyncIterator?

    func changes(_ pool: DatabasePool) -> AsyncThrowingStream<Void, Error> {
        base = SidebarCountsViewModel.tableChanges(pool).makeAsyncIterator()
        return AsyncThrowingStream { [self] in
            pulls.bump()
            return try await base?.next()
        }
    }
}

@MainActor
final class SidebarCountsViewModelTests: XCTestCase {

    // MARK: - Catch-Up badge
    //
    // The badge is a single "there is a recap waiting for you" dot: one ready,
    // unacknowledged `catchup_recaps` row, never a count of unread sources.

    nonisolated private static func insertRecap(
        _ db: Database, status: String, acknowledgedAt: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO catchup_recaps (period_from, period_to, status, acknowledged_at)
                VALUES (1000, 2000, ?, ?)
                """,
            arguments: [status, acknowledgedAt]
        )
    }

    func testCatchUpBadgeIsOneWhenReadyUnacknowledgedRecapExists() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try Self.insertRecap(db, status: "ready")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()
        // Unread source counts must not contribute to the Catch-Up badge anymore.
        vm.unreadDigestCount = 99

        XCTAssertEqual(vm.unacknowledgedRecapCount, 1)
        XCTAssertEqual(vm.catchUpTotalCount, 1)
    }

    func testCatchUpBadgeIsZeroWhenAcknowledged() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try Self.insertRecap(db, status: "ready", acknowledgedAt: "2026-09-04T10:00:00Z")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.catchUpTotalCount, 0)
    }

    func testCatchUpBadgeIgnoresBuildingAndFailed() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try Self.insertRecap(db, status: "building")
            try Self.insertRecap(db, status: "failed")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.catchUpTotalCount, 0, "only a finished recap asks to be read")
    }

    /// The Inbox badge follows R1 (C1): proposals awaiting the owner (pending
    /// + failed), due reminders and unread open messages (`inbox_items`, the
    /// Messages cards since C1). The frozen situations backlog has no screen,
    /// so it is inserted here to prove it contributes zero; an applied
    /// proposal and a reminder not yet due count zero too.
    func testInboxBadgeCountsTheInboxCards() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            try TestDatabase.insertSituation(db, status: "open")
            try TestDatabase.insertInboxItem(db, channelID: "C001", messageTS: "1700000000.000100")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t1", status: "pending")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t2", status: "failed")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t3", status: "applied")
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','due','2000-01-01T00:00:00Z','pending')
                """)
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C2@2','x','2999-01-01T00:00:00Z','pending')
                """)
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.inboxStripCount, 4, "2 proposals awaiting the owner + 1 due reminder + 1 unread message")
    }

    /// A message written out of this pool's sight (another connection, as
    /// the daemon's writes are) reaches the badge through the Inbox read's
    /// `onFeedRefreshed`, the hook AppState wires to the counts' refresh.
    func testInboxBadgeFollowsAWriteTheObservationNeverSees() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let counts = SidebarCountsViewModel(dbPool: manager.dbPool)
        await counts.loadInitial()
        let strip = ActionStripViewModel(dbPool: manager.dbPool, cliRunner: FakeCLIRunner())
        strip.onFeedRefreshed = { await counts.refresh() }
        XCTAssertEqual(counts.inboxStripCount, 0)

        let other = try DatabaseQueue(path: manager.dbPool.path)
        try await other.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "C001", messageTS: "1700000000.000100")
        }
        try other.close()
        XCTAssertEqual(counts.inboxStripCount, 0, "no observation runs")

        await strip.refresh()
        XCTAssertEqual(counts.inboxStripCount, 1)
    }

    /// Attention detection turned off (the CLI's config write, which no
    /// observation sees) reaches the badge through `disabledFeatures`:
    /// neither Waiting for me nor the Messages stand-in counts, even on a
    /// row the daemon stopped earlier (the owner's off wins).
    func testInboxBadgeCountsNoWaitingForMeWhileAttentionDetectionIsOff() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try await manager.dbPool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "C001", messageTS: "1700000000.000100")
            try Self.insertWaitingForMe(db, enabled: false, disabledReason: "run would not end")
        }
        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()
        XCTAssertEqual(vm.inboxStripCount, 1, "stopped by the daemon: the Messages entry stands in")

        vm.disabledFeatures = [InboxFolderQueries.waitingForMeFeatureID]
        await vm.refresh()
        XCTAssertEqual(vm.inboxStripCount, 0, "turned off by the owner: nothing counts")
    }

    /// The `waiting-for-me` built-in's row as the indexer writes it.
    nonisolated private static func insertWaitingForMe(
        _ db: Database, enabled: Bool, disabledReason: String = ""
    ) throws {
        let id = try TestDatabase.insertAutomation(db, slug: "waiting-for-me", name: "Waiting for me")
        try db.execute(sql: """
            UPDATE automations SET origin = 'builtin', builtin_id = 'waiting-for-me', path = 'builtin:waiting-for-me',
                enabled = ?, disabled_reason = ? WHERE id = ?
            """, arguments: [enabled, disabledReason, id])
    }

    func testInboxBadgeIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.inboxStripCount, 0)
    }

    /// The Digests sidebar badge sums Slack + stream + decision unread — the
    /// same three sources the Digests screen's tab header shows, not Slack
    /// only (owner reversed the v1 Slack-only scoping).
    func testDigestsBadgeCountIncludesStreamAndDecisionUnread() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            // A workspace user (account #1) so fetch() runs its full path,
            // where unreadDigestCount is computed (the no-uid path leaves it 0).
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "U042")
            // 2 unread Slack digests (insertDigest leaves read_at NULL);
            // distinct channels to clear the (channel,type,period) UNIQUE key.
            try TestDatabase.insertDigest(db, channelID: "C001")
            try TestDatabase.insertDigest(db, channelID: "C002")
            // Stream digests: 1 unread, 1 read.
            _ = try TestDatabase.insertStreamDigest(db, readAt: nil)
            _ = try TestDatabase.insertStreamDigest(db, readAt: "2026-06-20T00:00:00Z")
            // Decisions: 1 never-seen (unread), 1 seen (read),
            // 1 seen-but-re-flagged (unread).
            _ = try TestDatabase.insertIdea(db, kind: "decision", seenAt: nil)
            _ = try TestDatabase.insertIdea(db, kind: "decision", seenAt: "2026-06-20T00:00:00Z")
            _ = try TestDatabase.insertIdea(
                db, kind: "decision", needsReview: true, seenAt: "2026-06-20T00:00:00Z"
            )
            // A non-decision idea must NOT contribute to the decision unread.
            _ = try TestDatabase.insertIdea(db, kind: "idea", status: "proposed")
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.unreadDigestCount, 2)
        XCTAssertEqual(vm.unreadStreamCount, 1)
        XCTAssertEqual(vm.unreadDecisionCount, 2)
        XCTAssertEqual(vm.digestsBadgeCount, 2 + 1 + 2)
        XCTAssertEqual(
            vm.digestsBadgeCount,
            vm.unreadDigestCount + vm.unreadStreamCount + vm.unreadDecisionCount
        )
    }

    func testDigestsBadgeCountIsZeroOnEmptyDB() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.digestsBadgeCount, 0)
    }

    // MARK: - Owner (OWNER-01)

    /// A Google-only install has an owner, so the owner-gated counts (tracks,
    /// targets) are real — before OWNER-01 they zeroed out without Slack.
    func testOwner01GoogleOnlyInstallCountsTracks() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@x.com")
            try TestDatabase.insertTrack(db, text: "Ship it", hasUpdates: true)
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.totalTrackCount, 1)
        XCTAssertEqual(vm.updatedTrackCount, 1)
        XCTAssertEqual(vm.recommendationCount, 0, "channel recommendations need a Slack owner")
    }

    /// BEHAVIOR PROJ-01 — the Targets sidebar badge (activeTaskCount /
    /// overdueTaskCount) never counts a project target.
    func testProj01_TargetsBadgeIgnoresProjectTargets() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        try await manager.dbPool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, currentUserID: "U042")
            try db.execute(sql: "INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')")
            let projectID = db.lastInsertedRowID
            _ = try TestDatabase.insertTarget(db, text: "Ordinary", dueDate: "2020-01-01T09:00")
            let boardTarget = try TestDatabase.insertTarget(db, text: "Board", dueDate: "2020-01-01T09:00", sourceType: "chat")
            try db.execute(sql: "UPDATE targets SET project_id = ? WHERE id = ?", arguments: [projectID, boardTarget])
        }

        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()

        XCTAssertEqual(vm.activeTaskCount, 1)
        XCTAssertEqual(vm.overdueTaskCount, 1)
    }

    // MARK: - Observation restart (board #526)

    /// One read error used to end the observation for good, freezing every
    /// badge until a relaunch. Now it starts again after the backoff pause
    /// and reloads the counts, so a change made meanwhile shows.
    func testAFailedObservationStartsAgainAndReloadsTheCounts() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let starts = Tally()
        let vm = SidebarCountsViewModel(
            dbPool: manager.dbPool,
            changes: { _ in
                let start = starts.bump()
                return AsyncThrowingStream { continuation in
                    // The first start fails at once; the restart delivers
                    // its start value and stays open.
                    if start == 1 {
                        continuation.finish(throwing: CocoaError(.fileReadUnknown))
                    } else {
                        continuation.yield()
                    }
                }
            },
            backoff: RestartBackoff(first: .milliseconds(10)),
            pause: { _ in } // swiftlint:disable:this trailing_closure
        )
        await vm.loadInitial()
        XCTAssertEqual(vm.catchUpTotalCount, 0)
        try await manager.dbPool.write { try Self.insertRecap($0, status: "ready") }

        vm.startObserving()
        defer { vm.stopObserving() }
        await untilObserved { vm.catchUpTotalCount == 1 } // the restart's first value reloads the counts
        XCTAssertEqual(starts.value, 2, "observing again after the pause, and only once")
    }

    /// The live observation follows this process's writes, one made right
    /// after the start included (it may land in the start's own value).
    func testTheTableObservationRefreshesOnAWrite() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()
        vm.startObserving()
        defer { vm.stopObserving() }
        try await manager.dbPool.write { try Self.insertRecap($0, status: "ready") }
        await untilObserved { vm.catchUpTotalCount == 1 }
    }

    /// A write to `automations` (Waiting for me turned off in this process)
    /// re-counts the badge: the observation tracks the table.
    func testTheTableObservationRefreshesOnAnAutomationsWrite() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try await manager.dbPool.write { db in
            try TestDatabase.insertInboxItem(db, channelID: "C001", messageTS: "1700000000.000100")
            try Self.insertWaitingForMe(db, enabled: true)
        }
        let changes = PulledChanges()
        let vm = SidebarCountsViewModel(dbPool: manager.dbPool) { changes.changes($0) }
        await vm.loadInitial()
        XCTAssertEqual(vm.inboxStripCount, 1, "no run yet: the Messages entry stands in")
        vm.startObserving()
        defer { vm.stopObserving() }
        // The start's own value lands first (the view model asks for the
        // next one once it applied it), so only the write can re-count.
        await changes.pulls.until(2)
        XCTAssertEqual(vm.inboxStripCount, 1)
        try await manager.dbPool.write { db in
            try db.execute(sql: "UPDATE automations SET enabled = 0 WHERE builtin_id = 'waiting-for-me'")
        }
        // Turned off: the badge re-counts without another table's write.
        await untilObserved { vm.inboxStripCount == 0 }
    }

    /// Every start delivers a value, so an error right after each start must
    /// keep doubling the pause; a delivered change resets it.
    func testTheBackoffDoublesWhenEachStartFailsAfterItsFirstValue() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let starts = Tally()
        let pauses = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let vm = SidebarCountsViewModel(
            dbPool: manager.dbPool,
            changes: { _ in
                let start = starts.bump()
                return AsyncThrowingStream { continuation in
                    continuation.yield()
                    // The fourth run delivers a change too, then fails.
                    if start == 4 { continuation.yield() }
                    if start <= 4 { continuation.finish(throwing: CocoaError(.fileReadUnknown)) }
                }
            },
            backoff: RestartBackoff(first: .seconds(2), max: .seconds(60)),
            // Labelled, like the `changes:` closure above it.
            pause: { duration in pauses.withLock { $0.append(duration) } } // swiftlint:disable:this trailing_closure
        )
        vm.startObserving()
        defer { vm.stopObserving() }
        // Each pause is taken before the start it leads to.
        await starts.until(5)

        XCTAssertEqual(pauses.withLock { $0 }, [.seconds(2), .seconds(4), .seconds(8), .seconds(2)])
    }
}

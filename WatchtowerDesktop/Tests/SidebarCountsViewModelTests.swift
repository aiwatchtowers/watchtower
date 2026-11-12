import AppKit
import XCTest
import GRDB
import os
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class SidebarCountsViewModelTests: XCTestCase {
    override func tearDown() async throws {
        IdeaBatchDefaults.clearStandard()
        try await super.tearDown()
    }

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

    /// The Inbox badge (redesign phase 1): Needs approval's open approvals
    /// (proposals awaiting the owner, pending + failed, and due reminders) +
    /// people waiting today (open `inbox_items` from today; the message is
    /// written now). The frozen situations backlog has no screen, so it is
    /// inserted here to prove it contributes zero; an applied proposal and a
    /// reminder not yet due count zero too.
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

        XCTAssertEqual(vm.inboxStripCount, 4, "2 proposals awaiting the owner + 1 due reminder + 1 person waiting today")
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

    // MARK: - "Today" moves with no database write

    /// One open message created at `createdAt`.
    nonisolated private static func insertOpenMessage(_ db: Database, createdAt: String) throws {
        let id = try TestDatabase.insertInboxItem(db)
        try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [createdAt, id])
    }

    nonisolated private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    nonisolated private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    /// The wall clock and zone a day test moves by hand.
    private final class FakeTime: Sendable {
        private let state: OSAllocatedUnfairLock<(now: Date, zone: String)>

        init(_ now: String, zone: String) {
            state = OSAllocatedUnfairLock(initialState: (SidebarCountsViewModelTests.date(now), zone))
        }

        var now: Date { state.withLock { $0.now } }
        var calendar: Calendar { SidebarCountsViewModelTests.calendar(state.withLock { $0.zone }) }
        func set(_ now: String) { state.withLock { $0.now = SidebarCountsViewModelTests.date(now) } }
        func set(zone: String) { state.withLock { $0.zone = zone } }
    }

    /// A sleeper that never waits in real time: each call is recorded and
    /// returns on `fire()` or when its task is cancelled.
    private final class FakeSleeper: Sendable {
        private struct State: Sendable {
            var calls: [Date] = []
            var pending: [Int: CheckedContinuation<Void, Never>] = [:]
            var cancelled: Set<Int> = []
            var nextID = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var calls: [Date] { state.withLock { $0.calls } }

        func sleep(until date: Date) async {
            let id = state.withLock { state -> Int in
                state.nextID += 1
                return state.nextID
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let cancelled = state.withLock { state -> Bool in
                        state.calls.append(date)
                        guard !state.cancelled.contains(id) else { return true }
                        state.pending[id] = continuation
                        return false
                    }
                    if cancelled { continuation.resume() }
                }
            } onCancel: {
                let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                    state.cancelled.insert(id)
                    return state.pending.removeValue(forKey: id)
                }
                continuation?.resume()
            }
        }

        /// Ends every pending sleep, as the moment it waited for arriving.
        func fire() {
            let all = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                defer { state.pending = [:] }
                return Array(state.pending.values)
            }
            for continuation in all { continuation.resume() }
        }
    }

    /// A view model on `time` and `sleeper` whose table observation stays
    /// quiet: only the day recounts re-read.
    private func dayViewModel(
        _ pool: DatabasePool,
        _ time: FakeTime,
        _ sleeper: FakeSleeper,
        center: NotificationCenter = NotificationCenter(),
        workspace: NotificationCenter = NotificationCenter()
    ) -> SidebarCountsViewModel {
        SidebarCountsViewModel(
            dbPool: pool,
            changes: { _ in AsyncThrowingStream { _ in } },
            clock: { time.now },
            calendar: { time.calendar },
            sleepUntil: { await sleeper.sleep(until: $0) },
            notificationCenter: center,
            workspaceNotificationCenter: workspace
        )
    }

    /// Waits (bounded) until the sleeper has `count` calls and `done` holds.
    private func waitFor(_ sleeper: FakeSleeper, calls count: Int, _ done: () -> Bool = { true }) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while sleeper.calls.count < count || !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testInboxBadgeRecountsAtMidnight() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try await manager.dbPool.write { try Self.insertOpenMessage($0, createdAt: "2026-11-11T20:00:00Z") }
        let time = FakeTime("2026-11-11T23:59:00Z", zone: "UTC")
        let sleeper = FakeSleeper()
        let vm = dayViewModel(manager.dbPool, time, sleeper)
        await vm.loadInitial()
        XCTAssertEqual(vm.inboxStripCount, 1)

        vm.startObserving()
        defer { vm.stopObserving() }
        try await waitFor(sleeper, calls: 1)
        XCTAssertEqual(sleeper.calls, [Self.date("2026-11-12T00:00:01Z")], "one second after the next midnight")

        time.set("2026-11-12T00:00:01Z")
        sleeper.fire()
        try await waitFor(sleeper, calls: 2) { vm.inboxStripCount == 0 }

        XCTAssertEqual(vm.inboxStripCount, 0, "yesterday evening's message is no longer today's, with no write")
        XCTAssertEqual(sleeper.calls.last, Self.date("2026-11-13T00:00:01Z"), "the next midnight is scheduled")
    }

    func testInboxBadgeRecountsAfterWakePastMidnight() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try await manager.dbPool.write { try Self.insertOpenMessage($0, createdAt: "2026-11-11T20:00:00Z") }
        let time = FakeTime("2026-11-11T23:00:00Z", zone: "UTC")
        let sleeper = FakeSleeper()
        let workspace = NotificationCenter()
        let vm = dayViewModel(manager.dbPool, time, sleeper, workspace: workspace)
        await vm.loadInitial()
        vm.startObserving()
        defer { vm.stopObserving() }
        try await waitFor(sleeper, calls: 1)
        XCTAssertEqual(vm.inboxStripCount, 1)

        // Asleep for 9 hours: the midnight timer never fired.
        time.set("2026-11-12T08:00:00Z")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitFor(sleeper, calls: 2) { vm.inboxStripCount == 0 }

        XCTAssertEqual(vm.inboxStripCount, 0)
        XCTAssertEqual(sleeper.calls.last, Self.date("2026-11-13T00:00:01Z"), "rescheduled from the clock after the wake")
    }

    func testInboxBadgeRecountsOnCalendarDayChange() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try await manager.dbPool.write { try Self.insertOpenMessage($0, createdAt: "2026-11-11T20:00:00Z") }
        let time = FakeTime("2026-11-11T23:00:00Z", zone: "UTC")
        let sleeper = FakeSleeper()
        let center = NotificationCenter()
        let vm = dayViewModel(manager.dbPool, time, sleeper, center: center)
        await vm.loadInitial()
        vm.startObserving()
        defer { vm.stopObserving() }
        try await waitFor(sleeper, calls: 1)
        XCTAssertEqual(vm.inboxStripCount, 1)

        time.set("2026-11-12T00:00:00Z")
        center.post(name: .NSCalendarDayChanged, object: nil)
        try await waitFor(sleeper, calls: 2) { vm.inboxStripCount == 0 }

        XCTAssertEqual(vm.inboxStripCount, 0)
    }

    /// A message from 23:30 in Kyiv (21:30 UTC), read at 00:30 in Kyiv: from
    /// today in UTC, from yesterday once the zone is Kyiv.
    func testInboxBadgeRecountsOnTimeZoneChange() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try await manager.dbPool.write { try Self.insertOpenMessage($0, createdAt: "2026-11-11T21:30:00Z") }
        let time = FakeTime("2026-11-11T22:30:00Z", zone: "UTC")
        let sleeper = FakeSleeper()
        let center = NotificationCenter()
        let vm = dayViewModel(manager.dbPool, time, sleeper, center: center)
        await vm.loadInitial()
        vm.startObserving()
        defer { vm.stopObserving() }
        try await waitFor(sleeper, calls: 1)
        XCTAssertEqual(vm.inboxStripCount, 1, "UTC: counted")

        time.set(zone: "Europe/Kyiv")
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await waitFor(sleeper, calls: 2) { vm.inboxStripCount == 0 }

        XCTAssertEqual(vm.inboxStripCount, 0, "Kyiv: not counted")
        XCTAssertEqual(sleeper.calls.last, Self.date("2026-11-12T22:00:01Z"), "the next midnight in Kyiv")
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
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let vm = SidebarCountsViewModel(
            dbPool: manager.dbPool,
            changes: { _ in
                let start = starts.withLock { count -> Int in
                    count += 1
                    return count
                }
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
            backoff: RestartBackoff(first: .milliseconds(10))
        )
        await vm.loadInitial()
        XCTAssertEqual(vm.catchUpTotalCount, 0)
        try await manager.dbPool.write { try Self.insertRecap($0, status: "ready") }

        vm.startObserving()
        defer { vm.stopObserving() }
        let deadline = ContinuousClock.now + .seconds(3)
        while vm.catchUpTotalCount == 0 || starts.withLock({ $0 }) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(vm.catchUpTotalCount, 1, "the restart's first value reloads the counts")
        XCTAssertEqual(starts.withLock { $0 }, 2, "observing again after the pause, and only once")
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
        let deadline = ContinuousClock.now + .seconds(3)
        while vm.catchUpTotalCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.catchUpTotalCount, 1)
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
        let vm = SidebarCountsViewModel(dbPool: manager.dbPool)
        await vm.loadInitial()
        XCTAssertEqual(vm.inboxStripCount, 1, "no run yet: the Messages entry stands in")
        vm.startObserving()
        defer { vm.stopObserving() }
        // Let the start's own value land first, so only the write can re-count.
        try await Task.sleep(for: .milliseconds(300))
        try await manager.dbPool.write { db in
            try db.execute(sql: "UPDATE automations SET enabled = 0 WHERE builtin_id = 'waiting-for-me'")
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while vm.inboxStripCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.inboxStripCount, 0, "turned off: the badge re-counts without another table's write")
    }

    /// Every start delivers a value, so an error right after each start must
    /// keep doubling the pause; a delivered change resets it.
    func testTheBackoffDoublesWhenEachStartFailsAfterItsFirstValue() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let pauses = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let vm = SidebarCountsViewModel(
            dbPool: manager.dbPool,
            changes: { _ in
                let start = starts.withLock { count -> Int in
                    count += 1
                    return count
                }
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
        let deadline = ContinuousClock.now + .seconds(3)
        while starts.withLock({ $0 }) < 5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(pauses.withLock { $0 }, [.seconds(2), .seconds(4), .seconds(8), .seconds(2)])
    }
}

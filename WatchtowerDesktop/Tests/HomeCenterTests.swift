import XCTest
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Home's inputs for tests: the owner known, every Today card allowed.
@MainActor
@Observable
final class FakeHomeEnvironment: HomeEnvironment {
    var now = Date()
    var calendar = Calendar.current
    var ownerKnown = true
    var ownerPendingSource: String?
    var firstSync: FirstSyncLine?
    var allowedTodayCards = Set(TodayCardKind.allCases)
}

@MainActor
final class HomeCenterTests: XCTestCase {
    private var poolPaths: [String] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
        suiteNames.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suiteNames = []
        super.tearDown()
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        return pool
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "HomeCenterTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func makeCenter(
        readiness: ReadinessCenter? = nil,
        environment: FakeHomeEnvironment? = nil,
        defaults: UserDefaults,
        tickInterval: Duration = .seconds(30)
    ) -> HomeCenter {
        HomeCenter(readiness: readiness ?? ReadinessCenter(environment: FakeReadinessEnvironment()),
                   environment: environment ?? FakeHomeEnvironment(),
                   store: GettingReadyStore(defaults: defaults), tickInterval: tickInterval)
    }

    /// Waits (bounded) until `condition` holds for the center's snapshot,
    /// re-checking on every change of it — no sleeping.
    private func waitUntil(
        _ center: HomeCenter,
        timeout: TimeInterval = 5,
        _ condition: @escaping (HomeSnapshot?) -> Bool
    ) async {
        let met = expectation(description: "snapshot condition")
        func check() {
            if condition(center.snapshot) {
                met.fulfill()
                return
            }
            withObservationTracking { _ = center.snapshot } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [met], timeout: timeout)
    }

    private func snapshotHas(_ kind: TodayCardKind) -> (HomeSnapshot?) -> Bool {
        { $0?.today.contains { $0.kind == kind } == true }
    }

    private func insertTargetDueToday(_ pool: DatabasePool, text: String = "Ship the feature") throws {
        let today = HomeTodayBuilder.dayString(Date(), calendar: .current)
        try pool.write { db in
            try TestDatabase.insertTarget(db, text: text, level: "day", periodStart: today, periodEnd: today,
                                          dueDate: today + "T15:00")
        }
    }

    private func cards(_ snapshot: HomeSnapshot?) -> [GettingReadyCard] {
        if case .shown(let cards, _)? = snapshot?.gettingReady { return cards }
        return []
    }

    /// Readiness with two cards in the zone — Slack sync and digests — and
    /// every other feature off or waiting on a source.
    private func zoneReadiness() -> FakeReadinessEnvironment {
        let environment = FakeReadinessEnvironment()
        environment.disabledFeatureIDs = Set(ReadinessFeature.allCases.compactMap(\.featureID))
            .subtracting(["slack-digests"])
        return environment
    }

    private func startRun(_ pool: DatabasePool, _ pipeline: String) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO pipeline_runs (pipeline) VALUES (?)", arguments: [pipeline])
        }
    }

    func testFirstReadPublishesSnapshot() async throws {
        let center = makeCenter(defaults: try makeDefaults())
        XCTAssertNil(center.snapshot)
        center.beginReading(pool: try makePool())
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.today, [])
        XCTAssertEqual(center.snapshot?.nothingNeedsYou, true)
    }

    func testInsertingATargetAddsMyTargets() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }

        try insertTargetDueToday(pool)
        await waitUntil(center, snapshotHas(.myTargets))
        XCTAssertEqual(center.snapshot?.today.first?.items.map(\.title), ["Ship the feature"])
    }

    /// The daemon writes from another process, which the ValueObservation
    /// never sees: a second pool on the same file stands in for it.
    func testASuggestionDecisionRereadsHomeAtOnce() async throws {
        let appState = AppState.isolated()
        appState.homeEnvironmentOverride = FakeHomeEnvironment()
        var decided: [(Int64, Bool)] = []
        appState.homeCenter.beginReading(pool: try makePool())
        defer { appState.homeCenter.endReading() }
        await waitUntil(appState.homeCenter) { $0 != nil }
        let reads = appState.homeCenter.todayReads

        let error = await appState.decideInstructionSuggestion(id: 7, add: true) { decided.append(($0, $1)) }

        XCTAssertNil(error)
        XCTAssertEqual(decided.map(\.0), [7])
        XCTAssertEqual(appState.homeCenter.todayReads, reads + 1, "a success re-reads Home")
    }

    func testAFailedSuggestionDecisionDoesNotReread() async throws {
        let appState = AppState.isolated()
        appState.homeEnvironmentOverride = FakeHomeEnvironment()
        appState.homeCenter.beginReading(pool: try makePool())
        defer { appState.homeCenter.endReading() }
        await waitUntil(appState.homeCenter) { $0 != nil }
        let reads = appState.homeCenter.todayReads

        let error = await appState.decideInstructionSuggestion(id: 7, add: true) { _, _ in
            throw OwnerInstructionsError(message: "session instructions: over")
        }

        XCTAssertEqual(error, "session instructions: over")
        XCTAssertEqual(appState.homeCenter.todayReads, reads)
    }

    func testTickPicksUpWritesTheObservationMisses() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults(), tickInterval: .milliseconds(50))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }

        let daemonPool = try DatabasePool(path: try XCTUnwrap(poolPaths.last))
        try await daemonPool.write { db in
            let workbench = try TestDatabase.insertWorkbench(db)
            try TestDatabase.insertOwnerAsk(db, projectID: workbench)
        }
        try daemonPool.close()
        await waitUntil(center, snapshotHas(.agentsWaiting))
    }

    func testReadinessChangeRebuildsWithoutDBRead() async throws {
        let pool = try makePool()
        try startRun(pool, "slack-sync")
        try startRun(pool, "digests")
        let readiness = ReadinessCenter(environment: zoneReadiness())
        readiness.start(pool: pool)
        defer { readiness.stop() }
        let center = makeCenter(readiness: readiness, defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { self.cards($0).first { $0.feature == .digests }?.tone == .preparing }
        let reads = center.todayReads

        // `digests` is not a Home table: only readiness sees this write.
        try await pool.write { db in try TestDatabase.insertDigest(db) }
        await waitUntil(center) { self.cards($0).first { $0.feature == .digests }?.tone == .ready }
        XCTAssertEqual(center.todayReads, reads)
    }

    /// A first-sync or allowed-cards change rebuilds from the last read
    /// without touching the DB.
    func testEnvironmentChangeRebuildsWithoutDBRead() async throws {
        let pool = try makePool()
        try insertTargetDueToday(pool)
        let environment = FakeHomeEnvironment()
        let center = makeCenter(environment: environment, defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, snapshotHas(.myTargets))
        let reads = center.todayReads

        let line = FirstSyncLine(title: "Syncing Slack", detail: "12 of 40 channels")
        environment.firstSync = line
        await waitUntil(center) { $0?.firstSync == line }
        environment.allowedTodayCards = [.agentsWaiting]
        await waitUntil(center) { $0?.today.isEmpty == true }
        XCTAssertEqual(center.todayReads, reads)
    }

    func testHideGettingReadyPersists() async throws {
        let pool = try makePool()
        try startRun(pool, "digests")
        let readiness = ReadinessCenter(environment: zoneReadiness())
        readiness.start(pool: pool)
        defer { readiness.stop() }
        let defaults = try makeDefaults()
        let center = makeCenter(readiness: readiness, defaults: defaults)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { !self.cards($0).isEmpty }
        XCTAssertNotNil(GettingReadyStore(defaults: defaults).memory.firstShownAt)

        center.hideGettingReady()
        XCTAssertEqual(center.snapshot?.gettingReady, .hidden)
        XCTAssertTrue(GettingReadyStore(defaults: defaults).memory.hiddenByOwner)
    }

    func testCompletedThisLaunchShowsAllReadyThenGoneOnRelaunch() async throws {
        let pool = try makePool()
        try await pool.write { db in try TestDatabase.insertMessage(db) }
        try startRun(pool, "digests")
        let readiness = ReadinessCenter(environment: zoneReadiness())
        readiness.start(pool: pool)
        defer { readiness.stop() }
        let defaults = try makeDefaults()
        let center = makeCenter(readiness: readiness, defaults: defaults)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { self.cards($0).first { $0.feature == .digests }?.tone == .preparing }

        try await pool.write { db in try TestDatabase.insertDigest(db) }
        await waitUntil(center) { $0?.gettingReady == .allReady }
        XCTAssertNotNil(GettingReadyStore(defaults: defaults).memory.completedAt)

        let relaunched = makeCenter(readiness: readiness, defaults: defaults)
        relaunched.beginReading(pool: pool)
        defer { relaunched.endReading() }
        await waitUntil(relaunched) { $0 != nil }
        XCTAssertEqual(relaunched.snapshot?.gettingReady, .hidden)
    }

    /// A `targets` table every read of it fails on (Review Focus 3).
    private func breakTargets(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE targets")
            try db.execute(sql: "CREATE TABLE targets (x INTEGER)")
        }
    }

    func testAllReadsFailedIsNotAllClear() async throws {
        let pool = try makePool()
        try breakTargets(pool)
        let environment = FakeHomeEnvironment()
        environment.allowedTodayCards = [.myTargets]
        let center = makeCenter(environment: environment, defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.todayReadFailed, true)
        XCTAssertEqual(center.snapshot?.nothingNeedsYou, false)
    }

    /// One allowed card's read fails and the rest are empty: the read error,
    /// not the all-clear.
    func testOneFailedReadIsNotAllClear() async throws {
        let pool = try makePool()
        try breakTargets(pool)
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.todayReadFailed, false)
        XCTAssertEqual(center.snapshot?.todayFailed, [.myTargets])
        XCTAssertEqual(center.snapshot?.showsReadError, true)
        XCTAssertEqual(center.snapshot?.nothingNeedsYou, false)
    }

    /// Every open ask unreadable and nothing else to show: the read error,
    /// never "Nothing needs you right now".
    func testOnlyUnreadableAsksIsNotAllClear() async throws {
        let pool = try makePool()
        try await pool.write { db in
            let workbench = try TestDatabase.insertWorkbench(db)
            // The column's CHECK refuses 'poll'; a newer Go could still widen it.
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: "INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'poll', 'Pick one')",
                           arguments: [workbench])
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.today, [])
        XCTAssertEqual(center.snapshot?.todayFailed, [.agentsWaiting])
        XCTAssertEqual(center.snapshot?.showsReadError, true)
        XCTAssertEqual(center.snapshot?.nothingNeedsYou, false)
    }

    /// A failed card the owner's tabs hide does not count.
    func testFailedReadOutsideAllowedIsIgnored() async throws {
        let pool = try makePool()
        try breakTargets(pool)
        let environment = FakeHomeEnvironment()
        environment.allowedTodayCards = [.agentsWaiting]
        let center = makeCenter(environment: environment, defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.todayFailed, [])
        XCTAssertEqual(center.snapshot?.nothingNeedsYou, true)
    }

    /// The pool itself failing before any good read: a snapshot with every
    /// card failed (the read error, Getting ready), not an endless spinner.
    func testFirstPoolFailurePublishesAllFailed() async throws {
        let pool = try makePool()
        try pool.close()
        let center = makeCenter(defaults: try makeDefaults(), tickInterval: .milliseconds(50))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.todayReadFailed, true)
        XCTAssertEqual(center.snapshot?.todayFailed, Set(TodayCardKind.allCases))
        XCTAssertEqual(center.snapshot?.showsReadError, true)
        XCTAssertEqual(center.snapshot?.nothingNeedsYou, false)
    }

    /// A good read, then the pool failing: the stale read is marked failed,
    /// never shown as the all-clear.
    func testPoolFailureAfterGoodReadIsNotAllClear() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults(), tickInterval: .milliseconds(50))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.nothingNeedsYou == true }

        try pool.close()
        await waitUntil(center) { $0?.showsReadError == true }
        XCTAssertEqual(center.snapshot?.nothingNeedsYou, false)
    }

    func testStopCancelsObservationAndTick() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults(), tickInterval: .milliseconds(50))
        center.beginReading(pool: pool)
        await waitUntil(center) { $0 != nil }
        center.endReading()
        let reads = center.todayReads

        try insertTargetDueToday(pool)
        // A second center seeing the write proves it was observable.
        let witness = makeCenter(defaults: try makeDefaults())
        witness.beginReading(pool: pool)
        defer { witness.endReading() }
        await waitUntil(witness, snapshotHas(.myTargets))
        XCTAssertFalse(snapshotHas(.myTargets)(center.snapshot))
        XCTAssertEqual(center.todayReads, reads)
    }

    func testStartTwiceKeepsOneObservation() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        let reads = center.todayReads

        try insertTargetDueToday(pool, text: "First")
        await waitUntil(center) { $0?.today.first?.items.count == 1 }
        try insertTargetDueToday(pool, text: "Second")
        await waitUntil(center) { $0?.today.first?.items.count == 2 }
        XCTAssertEqual(center.todayReads, reads + 2)
    }

    func testGarbageDefaultsReadAsEmpty() throws {
        let defaults = try makeDefaults()
        defaults.set("yesterday", forKey: "home.gettingReady.firstShownAt")
        defaults.set("never", forKey: "home.gettingReady.completedAt")
        defaults.set("maybe", forKey: "home.gettingReady.hidden")
        XCTAssertEqual(GettingReadyStore(defaults: defaults).memory, GettingReadyMemory())
    }

    func testStoreRoundTrips() throws {
        let defaults = try makeDefaults()
        let shown = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let store = GettingReadyStore(defaults: defaults)
        store.memory = GettingReadyMemory(hiddenByOwner: true, firstShownAt: shown, completedAt: nil)
        XCTAssertEqual(GettingReadyStore(defaults: defaults).memory,
                       GettingReadyMemory(hiddenByOwner: true, firstShownAt: shown, completedAt: nil))
    }

    /// Each tab-following card against its own tab's rule, one source or
    /// feature at a time.
    func testTodayCardsFollowTheirOwnTab() {
        let appState = AppState.isolated()
        let always: Set<TodayCardKind> = [.myTargets, .agentsWaiting, .instructionSuggestion]
        let rows: [(ConnectedSources, Set<String>, Set<TodayCardKind>)] = [
            // Briefings has no source gate; Inbox and Catch-Up need any source.
            (.none, [], always.union([.briefing])),
            // Calendar fills Calendar, and Inbox and Catch-Up (meeting items).
            (ConnectedSources(calendar: true), [],
             always.union([.briefing, .nextMeeting, .waitingOnYou, .sinceYouWereAway])),
            (ConnectedSources(slack: true), [], always.union([.briefing, .waitingOnYou, .sinceYouWereAway])),
            (ConnectedSources(jira: true), [], always.union([.briefing, .waitingOnYou, .sinceYouWereAway])),
            (.all, ["briefing"], Set(TodayCardKind.allCases).subtracting([.briefing])),
            // Catch-Up needs one of its three features; Inbox has no feature gate.
            (.all, ["secretary-inbox", "slack-digests", "stream-digests"],
             Set(TodayCardKind.allCases).subtracting([.sinceYouWereAway]))
        ]
        for (connected, disabled, expected) in rows {
            appState.featureVisibility.connectedSources = connected
            appState.featureVisibility.disabledFeatureIDs = disabled
            XCTAssertEqual(appState.homeTodayCardsAllowed, expected, "\(connected) disabled \(disabled)")
        }
    }

    /// Waiting on you, Next meeting, Briefing and Since you were away follow
    /// their tab; My targets and Agents waiting are always allowed.
    func testTodayCardsFollowTabVisibility() {
        let appState = AppState.isolated()
        appState.featureVisibility.connectedSources = .none
        appState.featureVisibility.disabledFeatureIDs = ["briefing"]
        XCTAssertEqual(appState.homeTodayCardsAllowed, [.myTargets, .agentsWaiting, .instructionSuggestion])

        appState.featureVisibility.connectedSources = .all
        appState.featureVisibility.disabledFeatureIDs = []
        XCTAssertEqual(appState.homeTodayCardsAllowed, Set(TodayCardKind.allCases))
    }
}

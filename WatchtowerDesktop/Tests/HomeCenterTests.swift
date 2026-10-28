import XCTest
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Home's inputs for tests: the owner known, every link and feed source
/// allowed, no live session.
@MainActor
@Observable
final class FakeHomeEnvironment: HomeEnvironment {
    var now = Date()
    var calendar = Calendar.current
    var ownerKnown = true
    var ownerPendingSource: String?
    var firstSync: FirstSyncLine?
    var linksAllowed = Set(HomeLinkKind.allCases)
    var feedSourcesAllowed = Set(FeedSource.allCases)
    var managedPolicy = ManagedPolicy.none
    var workbenchSessions: [SessionAgentStatus] = []
    var lastOpenedWorkbench: Int64?
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
                   store: GettingReadyStore(defaults: defaults), performer: FakeHomeFeedPerformer(),
                   tickInterval: tickInterval)
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

    /// Waits (bounded) until `condition` holds for the center, re-checking on
    /// every change of its snapshot or numbers read count.
    private func waitUntilCenter(
        _ center: HomeCenter,
        timeout: TimeInterval = 5,
        _ condition: @escaping (HomeCenter) -> Bool
    ) async {
        let met = expectation(description: "center condition")
        func check() {
            if condition(center) {
                met.fulfill()
                return
            }
            withObservationTracking {
                _ = center.snapshot
                _ = center.numbersReads
            } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [met], timeout: timeout)
    }

    private func session(
        _ id: Int64, workbench: Int64 = 1, _ kind: SessionSwitcherPresentation.State.Kind
    ) -> SessionAgentStatus {
        SessionAgentStatus(
            sessionID: id, workbenchID: workbench, workbenchName: "acme", title: "Session \(id)",
            state: SessionSwitcherPresentation.State(kind: kind, live: true), at: nil)
    }

    private func insertTargetDueToday(_ pool: DatabasePool, text: String = "Ship the feature") throws {
        let today = HomeFeedBuilder.dayString(Date(), calendar: .current)
        try pool.write { db in
            try TestDatabase.insertTarget(db, text: text, level: "day", periodStart: today, periodEnd: today,
                                          dueDate: today)
        }
    }

    /// A Slack mention a minute old: one feed row.
    private func insertMention(_ pool: DatabasePool) throws {
        try pool.write { db in
            try TestDatabase.insertInboxItem(db)
        }
    }

    private func insertAsk(_ pool: DatabasePool) throws {
        try pool.write { db in
            let workbench = try TestDatabase.insertWorkbench(db)
            try TestDatabase.insertOwnerAsk(db, projectID: workbench)
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
        XCTAssertEqual(center.snapshot?.workbench, [])
        XCTAssertNil(center.snapshot?.coach)
        XCTAssertEqual(center.snapshot?.workbenchFailed, false)
        XCTAssertEqual(center.snapshot?.links.map(\.kind), HomeLinkKind.allCases)
        XCTAssertEqual(center.snapshot?.linksFailed, false)
    }

    func testInsertingATargetAddsAFeedRow() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }

        try insertTargetDueToday(pool)
        await waitUntil(center) { $0?.feed.waiting.count == 1 }
        XCTAssertEqual(center.snapshot?.feed.waiting.first?.kind, .target)
    }

    func testFeedIsInTheSnapshot() async throws {
        let pool = try makePool()
        try insertMention(pool)
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 1)
        XCTAssertEqual(center.snapshot?.feed.waiting.first?.kind, .slack)
    }

    /// Attention detection off: no inbox row, and a failed inbox read is not
    /// named either; the other sources still show.
    func testInboxRowsFollowAttentionDetection() async throws {
        let pool = try makePool()
        try insertMention(pool)
        try insertTargetDueToday(pool)
        let environment = FakeHomeEnvironment()
        environment.feedSourcesAllowed = [.reminders, .proposals, .targets, .calendar]
        let center = makeCenter(environment: environment, defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.feed.waiting.map(\.kind), [.target])
        let reads = center.todayReads

        environment.feedSourcesAllowed.insert(.inbox)
        await waitUntil(center) { $0?.feed.waiting.count == 2 }
        XCTAssertEqual(center.todayReads, reads, "a source change rebuilds from the last read")
    }

    func testDisallowedSourceFailureIsNotNamed() async throws {
        let pool = try makePool()
        try await pool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE inbox_items")
            try db.execute(sql: "CREATE TABLE inbox_items (x INTEGER)")
        }
        let environment = FakeHomeEnvironment()
        let center = makeCenter(environment: environment, defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.feed.failed, [.inbox])

        environment.feedSourcesAllowed.remove(.inbox)
        await waitUntil(center) { $0?.feed.failed.isEmpty == true }
    }

    /// The coach CLI writes from another process, which the ValueObservation
    /// never sees: a success re-reads Home at once.
    func testHomeDecideRereadsAndCallsTheCoach() async throws {
        let appState = AppState.isolated()
        appState.homeEnvironmentOverride = FakeHomeEnvironment()
        appState.homeCenter.beginReading(pool: try makePool())
        defer { appState.homeCenter.endReading() }
        await waitUntil(appState.homeCenter) { $0 != nil }
        let reads = appState.homeCenter.todayReads
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true}"#.utf8))

        let accepted = await appState.decideCoachProposal(id: 7, accept: true, runner: runner)
        let declined = await appState.decideCoachProposal(id: 8, accept: false, runner: runner)

        XCTAssertNil(accepted)
        XCTAssertNil(declined)
        XCTAssertEqual(runner.invocations, [["coach", "accept", "7", "--json"], ["coach", "decline", "8", "--json"]])
        XCTAssertEqual(appState.homeCenter.todayReads, reads + 2, "a success re-reads Home")
    }

    func testHomeDecideStaleReloads() async throws {
        let appState = AppState.isolated()
        appState.homeEnvironmentOverride = FakeHomeEnvironment()
        appState.homeCenter.beginReading(pool: try makePool())
        defer { appState.homeCenter.endReading() }
        await waitUntil(appState.homeCenter) { $0 != nil }
        let reads = appState.homeCenter.todayReads
        for code in ["stale", "state_changed"] {
            let stderr = #"{"ok":false,"error":"x","code":"\#(code)"}"# + "\ncoach: x\n"
            let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))
            let line = await appState.decideCoachProposal(id: 7, accept: true, runner: runner)
            XCTAssertEqual(line, "That proposal changed — showing the next one")
        }
        XCTAssertEqual(appState.homeCenter.todayReads, reads + 2)
    }

    func testHomeDecideErrorKeepsRow() async throws {
        let appState = AppState.isolated()
        appState.homeEnvironmentOverride = FakeHomeEnvironment()
        appState.homeCenter.beginReading(pool: try makePool())
        defer { appState.homeCenter.endReading() }
        await waitUntil(appState.homeCenter) { $0 != nil }
        let reads = appState.homeCenter.todayReads
        let stderr = #"{"ok":false,"error":"destination is over its limit","code":"over_budget"}"# + "\ncoach: over\n"
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: stderr))

        let line = await appState.decideCoachProposal(id: 7, accept: true, runner: runner)

        XCTAssertEqual(line, "destination is over its limit")
        XCTAssertEqual(appState.homeCenter.todayReads, reads, "the row stays: no re-read")
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
        await waitUntil(center) { $0?.workbench.first?.asks.count == 1 }
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

    /// A first-sync, allowed-links or live-session change rebuilds from the
    /// last read without touching the DB.
    func testEnvironmentChangeRebuildsWithoutDBRead() async throws {
        let pool = try makePool()
        try insertAsk(pool)
        let environment = FakeHomeEnvironment()
        let center = makeCenter(environment: environment, defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.workbench.count == 1 }
        let reads = center.todayReads

        let line = FirstSyncLine(title: "Syncing Slack", detail: "12 of 40 channels")
        environment.firstSync = line
        await waitUntil(center) { $0?.firstSync == line }
        environment.linksAllowed = [.digests]
        await waitUntil(center) { $0?.links.map(\.kind) == [.digests] }
        environment.linksAllowed = []
        await waitUntil(center) { $0?.links.isEmpty == true }
        XCTAssertEqual(center.todayReads, reads)
    }

    /// A live session in a shown state joins its workbench's block, a
    /// finished one does not; no DB read either way.
    func testLiveSessionsFillTheWorkbenchZoneWithoutRead() async throws {
        let environment = FakeHomeEnvironment()
        let center = makeCenter(environment: environment, defaults: try makeDefaults())
        center.beginReading(pool: try makePool())
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        let reads = center.todayReads

        environment.workbenchSessions = [session(1, .working), session(2, .finished), session(3, .needsApproval)]
        await waitUntil(center) { $0?.workbench.count == 1 }
        XCTAssertEqual(center.snapshot?.workbench.first?.sessions.map(\.sessionID), [3, 1])
        environment.workbenchSessions = []
        await waitUntil(center) { $0?.workbench.isEmpty == true }
        XCTAssertEqual(center.todayReads, reads)
    }

    func testCoachProposalAndRecapReachTheirZones() async throws {
        let pool = try makePool()
        let now = Date()
        try await pool.write { db in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme")
            try db.execute(sql: "UPDATE projects SET agent_analytics = 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: """
                INSERT INTO coach_proposals (fingerprint, kind, destination, title, why, metric, after_text, sources, created_at)
                VALUES ('lint', 'add', 'session', 'run the linter', 'why', 'corrections', 'Run the linter.', 3, '2026-10-20T10:00:00Z')
                """)
            try db.execute(
                sql: "INSERT INTO catchup_recaps (period_from, period_to, status, tldr) VALUES (?, ?, 'ready', 'All quiet')",
                arguments: [now.timeIntervalSince1970 - 3600, now.timeIntervalSince1970])
        }
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.coach?.proposal.title, "run the linter")
        let catchUp = center.snapshot?.links.first { $0.kind == .catchUp }
        XCTAssertEqual(catchUp?.status, "new recap")
        XCTAssertEqual(catchUp?.highlighted, true)
    }

    /// Numbers have their own read and observation: a sync's `messages`
    /// write re-reads them, never the feed and the other zones.
    func testMessagesWriteRereadsNumbersNotTheFeed() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntilCenter(center) { $0.snapshot?.numbers != nil && $0.numbersReads > 0 }
        let reads = center.todayReads
        let numberReads = center.numbersReads

        try await pool.write { db in try TestDatabase.insertMessage(db) }
        await waitUntilCenter(center) { $0.numbersReads > numberReads }
        XCTAssertEqual(center.todayReads, reads, "a messages write never re-reads the feed")

        // A feed write re-reads the feed.
        try insertTargetDueToday(pool)
        await waitUntil(center) { $0?.feed.waiting.count == 1 }
        XCTAssertGreaterThan(center.todayReads, reads)
    }

    /// The tick re-reads the numbers too (the daemon writes from another process).
    func testTickRereadsNumbers() async throws {
        let center = makeCenter(defaults: try makeDefaults(), tickInterval: .milliseconds(50))
        center.beginReading(pool: try makePool())
        defer { center.endReading() }
        await waitUntilCenter(center) { $0.numbersReads > 2 }
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

    /// A `briefings` table every read of it fails on (Review Focus 3).
    private func breakBriefings(_ pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DROP TABLE briefings")
            try db.execute(sql: "CREATE TABLE briefings (x INTEGER)")
        }
    }

    /// A failed links read keeps the rows and says so; the other zones read.
    func testFailedLinksReadIsSaid() async throws {
        let pool = try makePool()
        try breakBriefings(pool)
        let center = makeCenter(defaults: try makeDefaults())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0 != nil }
        XCTAssertEqual(center.snapshot?.linksFailed, true)
        XCTAssertEqual(center.snapshot?.links.count, HomeLinkKind.allCases.count)
        XCTAssertEqual(center.snapshot?.workbenchFailed, false)
    }

    /// Every open ask unreadable: the Workbench zone's read error, never an
    /// empty zone.
    func testOnlyUnreadableAsksMarksWorkbenchFailed() async throws {
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
        XCTAssertEqual(center.snapshot?.workbench, [])
        XCTAssertEqual(center.snapshot?.workbenchFailed, true)
    }

    /// The pool itself failing before any good read: a snapshot with every
    /// zone failed (Getting ready, the read errors), not an endless spinner.
    func testFirstPoolFailurePublishesAllFailed() async throws {
        let pool = try makePool()
        try pool.close()
        let center = makeCenter(defaults: try makeDefaults(), tickInterval: .milliseconds(50))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.numbers != nil }
        XCTAssertEqual(center.snapshot?.workbenchFailed, true)
        XCTAssertEqual(center.snapshot?.linksFailed, true)
        XCTAssertEqual(center.snapshot?.feed.failed, Set(FeedSource.allCases))
        XCTAssertEqual(center.snapshot?.numbers?.failed, HomeNumbers.fieldNames)
    }

    /// A good read, then the pool failing: the stale read is marked failed,
    /// never shown as current.
    func testPoolFailureAfterGoodReadIsSaid() async throws {
        let pool = try makePool()
        let center = makeCenter(defaults: try makeDefaults(), tickInterval: .milliseconds(50))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.workbenchFailed == false && $0?.numbers?.failed.isEmpty == true }

        try pool.close()
        await waitUntil(center) { $0?.workbenchFailed == true && $0?.linksFailed == true }
        await waitUntil(center) { $0?.numbers?.failed == HomeNumbers.fieldNames }
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
        await waitUntil(witness) { $0?.feed.waiting.count == 1 }
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 0)
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
        await waitUntil(center) { $0?.feed.waiting.count == 1 }
        try insertTargetDueToday(pool, text: "Second")
        await waitUntil(center) { $0?.feed.waiting.count == 2 }
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

    /// Each link against its own tab's rule, one source or feature at a time.
    func testLinksFollowTheirOwnTab() {
        let appState = AppState.isolated()
        let all = Set(HomeLinkKind.allCases)
        let rows: [(ConnectedSources, Set<String>, Set<HomeLinkKind>)] = [
            // Digests has no source gate; Catch-Up needs any source; the
            // brief and the plan open Inbox day cards, and the Inbox has no gate.
            (.none, [], [.digests, .briefing, .dayPlan]),
            (ConnectedSources(calendar: true), [], all),
            (ConnectedSources(slack: true), [], all),
            (.all, ["briefing"], all.subtracting([.briefing])),
            (.all, ["day-plan"], all.subtracting([.dayPlan])),
            // Digests needs one of its three features.
            (.all, ["slack-digests", "stream-digests", "ideas"], all.subtracting([.digests])),
            // Catch-Up needs one of its three features.
            (.all, ["secretary-inbox", "slack-digests", "stream-digests"], all.subtracting([.catchUp]))
        ]
        for (connected, disabled, expected) in rows {
            appState.featureVisibility.connectedSources = connected
            appState.featureVisibility.disabledFeatureIDs = disabled
            XCTAssertEqual(appState.homeLinksAllowed, expected, "\(connected) disabled \(disabled)")
        }
    }

    /// Inbox rows only while attention detection is on, calendar rows only
    /// while the Calendar tab is visible; reminders, proposals, automation
    /// outputs and targets always.
    func testFeedSourcesFollowAttentionDetectionAndCalendar() {
        let appState = AppState.isolated()
        let always: Set<FeedSource> = [.reminders, .proposals, .automations, .targets]
        let rows: [(ConnectedSources, Set<String>, Set<FeedSource>)] = [
            (.all, [], always.union([.inbox, .calendar])),
            (.all, ["secretary-inbox"], always.union([.calendar])),
            (ConnectedSources(slack: true), [], always.union([.inbox])),
            (.none, ["secretary-inbox"], always)
        ]
        for (connected, disabled, expected) in rows {
            appState.featureVisibility.connectedSources = connected
            appState.featureVisibility.disabledFeatureIDs = disabled
            XCTAssertEqual(appState.homeFeedSourcesAllowed, expected, "\(connected) disabled \(disabled)")
        }
    }
}

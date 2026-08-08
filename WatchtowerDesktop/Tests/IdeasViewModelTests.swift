import XCTest
import GRDB
@testable import WatchtowerDesktop

// MARK: - IdeasViewModel Tests

@MainActor
final class IdeasViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do {
            (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        } catch {
            XCTFail("setUp failed: \(error)")
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - load()

    func testLoadSplitsReviewVsRegistry() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, title: "Proposed", status: "proposed")
            try TestDatabase.insertIdea(db, title: "Active, settled", status: "active")
            try TestDatabase.insertIdea(db, title: "Rejected but flagged", status: "rejected", needsReview: true)
        }

        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(Set(vm.reviewItems.map(\.title)), ["Proposed", "Rejected but flagged"])
        XCTAssertEqual(vm.registryItems.map(\.title), ["Active, settled"])
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadOnEmptyDBYieldsEmptyLists() throws {
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertTrue(vm.reviewItems.isEmpty)
        XCTAssertTrue(vm.registryItems.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - approve()

    func testApproveMovesItemOutOfReviewAndKeepsSelectionValid() throws {
        let id = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, title: "Proposed", status: "proposed")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.reviewItems.first)
        vm.select(idea.id)

        vm.approve(idea)

        XCTAssertTrue(vm.reviewItems.isEmpty)
        XCTAssertEqual(vm.registryItems.map(\.id), [Int(id)])
        XCTAssertEqual(vm.registryItems.first?.status, .active)
        XCTAssertEqual(vm.selectedID, Int(id))
        XCTAssertNil(vm.errorMessage)
    }

    func testApproveOnUnselectedItemLeavesSelectionAlone() throws {
        let (selectedIdeaID, otherID) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let selected = try TestDatabase.insertIdea(db, title: "Selected", status: "proposed")
            let other = try TestDatabase.insertIdea(db, title: "Other", status: "proposed")
            return (selected, other)
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        vm.select(Int(selectedIdeaID))
        let other = try XCTUnwrap(vm.reviewItems.first { $0.id == Int(otherID) })

        vm.approve(other)

        XCTAssertEqual(vm.selectedID, Int(selectedIdeaID))
        XCTAssertEqual(vm.reviewItems.map(\.id), [Int(selectedIdeaID)])
    }

    // MARK: - reject() / drop() / reverse()

    func testRejectSetsStatusRejected() throws {
        let id = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, status: "proposed")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.reviewItems.first)

        vm.reject(idea)

        let all = vm.registryItems + vm.reviewItems
        XCTAssertEqual(all.first { $0.id == Int(id) }?.status, .rejected)
    }

    func testDropSetsStatusDropped() throws {
        let id = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, status: "active")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.registryItems.first)

        vm.drop(idea)

        XCTAssertEqual(vm.registryItems.first { $0.id == Int(id) }?.status, .dropped)
    }

    // MARK: - createManual()

    func testCreateManualAddsAnActiveOwnerIdeaToTheRegistry() throws {
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()

        let newID = vm.createManual(kind: "decision", title: "Ship it", essence: "Because it's ready")

        XCTAssertNotNil(newID)
        XCTAssertEqual(vm.registryItems.map(\.title), ["Ship it"])
        XCTAssertEqual(vm.registryItems.first?.status, .active)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - convertToTarget()

    func testConvertToTargetCreatesTargetAndMarksIdeaConverted() throws {
        let ideaID = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, title: "Adopt the new onboarding flow", essence: "Cuts drop-off", status: "active")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let idea = try XCTUnwrap(vm.registryItems.first)

        let targetID = vm.convertToTarget(idea)

        let newTargetID = try XCTUnwrap(targetID)
        XCTAssertNil(vm.errorMessage)
        let target = try dbManager.dbPool.read { try TargetQueries.fetchByID($0, id: newTargetID) }
        XCTAssertEqual(target?.text, "Adopt the new onboarding flow")
        XCTAssertEqual(target?.sourceType, "idea")
        XCTAssertEqual(target?.sourceID, String(ideaID))

        let convertedIdea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(convertedIdea?.status, .converted)
        XCTAssertEqual(convertedIdea?.convertedTargetID, newTargetID)
    }

    // MARK: - IDEA-04 reachability

    /// A rejected idea the consolidator flagged `needs_review` shows up in the
    /// review queue. The owner must have an action that gets it back OUT —
    /// "Activate" is the one the detail pane offers for `rejected`/`dropped`.
    /// Without it the item is stuck in "For review" permanently.
    func testIdeas04_ResurfacedRejectedIdeaLeavesReviewQueueViaActivate() throws {
        let ideaID = try dbManager.dbPool.write {
            try TestDatabase.insertIdea($0, title: "Weekly metrics email", status: "rejected",
                                        needsReview: true, reviewReason: "brought up again: slack C1|1.1")
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()

        XCTAssertEqual(vm.reviewItems.map(\.title), ["Weekly metrics email"],
                       "a resurfaced rejected idea starts in the review queue")
        let flagged = try XCTUnwrap(vm.reviewItems.first)

        vm.activate(flagged)

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.reviewItems.isEmpty, "the owner's action must clear it out of the review queue")
        XCTAssertEqual(vm.registryItems.map(\.title), ["Weekly metrics email"])

        let idea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(ideaID)) }
        XCTAssertEqual(idea?.status, .active)
        XCTAssertEqual(idea?.needsReview, false)
    }

    /// The same reachability, via the other action `rejected`/`dropped` offers.
    func testIdeas04_ResurfacedDroppedIdeaLeavesReviewQueueViaMerge() throws {
        let (droppedID, survivorID) = try dbManager.dbPool.write { db -> (Int64, Int64) in
            let dropped = try TestDatabase.insertIdea(db, title: "Dropped idea", status: "dropped",
                                                      needsReview: true, reviewReason: "brought up again: jira WT-1")
            let survivor = try TestDatabase.insertIdea(db, title: "Canonical idea", status: "active")
            return (dropped, survivor)
        }
        let vm = IdeasViewModel(dbManager: dbManager)
        vm.load()
        let flagged = try XCTUnwrap(vm.reviewItems.first { $0.id == Int(droppedID) })

        vm.merge(flagged, into: Int(survivorID))

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.reviewItems.isEmpty)

        let idea = try dbManager.dbPool.read { try IdeaQueries.fetchOne($0, id: Int(droppedID)) }
        XCTAssertEqual(idea?.status, .merged)
        XCTAssertEqual(idea?.needsReview, false)
    }

    // MARK: - startBackfill()

    /// `watchtower ideas mine --from --to` writes new idea rows directly to
    /// the DB; GRDB's in-process observation can't see a separate process's
    /// writes, so a successful run must explicitly reload.
    func testStartBackfillSuccessSetsSummaryClearsFlagAndReloadsList() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"proposed":5,"cycles":2,"mentions_deduped":1}"#.utf8))
        let vm = IdeasViewModel(dbManager: dbManager, cliRunner: runner)
        XCTAssertTrue(vm.reviewItems.isEmpty)

        try await dbManager.dbPool.write { db in
            try TestDatabase.insertIdea(db, title: "Mined idea", status: "proposed")
        }

        await vm.startBackfill(from: Date(timeIntervalSince1970: 0), to: Date())

        XCTAssertFalse(vm.isBackfilling)
        XCTAssertEqual(vm.backfillSummary, "Proposed 5 ideas (2 cycles, 1 duplicates skipped)")
        XCTAssertNil(vm.backfillError)
        XCTAssertEqual(vm.reviewItems.map(\.title), ["Mined idea"], "success reloads the list")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first.map { Array($0.prefix(2)) }, ["ideas", "mine"])
    }

    func testStartBackfillFailureSetsErrorNotSummary() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        let vm = IdeasViewModel(dbManager: dbManager, cliRunner: runner)

        await vm.startBackfill(from: Date(timeIntervalSince1970: 0), to: Date())

        XCTAssertFalse(vm.isBackfilling)
        XCTAssertNil(vm.backfillSummary)
        XCTAssertEqual(vm.backfillError, "watchtower exited with error: boom")
    }

    /// SB5: GB9 on the Go side emits {"disabled":true} on the backfill path
    /// when ideas.enabled=false, instead of the usual proposed/cycles
    /// envelope. That must not read as an opaque parse failure.
    func testStartBackfillDisabledRegistrySetsActionableError() async {
        let runner = FakeCLIRunner(stdout: Data(#"{"disabled":true}"#.utf8))
        let vm = IdeasViewModel(dbManager: dbManager, cliRunner: runner)

        await vm.startBackfill(from: Date(timeIntervalSince1970: 0), to: Date())

        XCTAssertFalse(vm.isBackfilling)
        XCTAssertNil(vm.backfillSummary)
        XCTAssertEqual(vm.backfillError, "The ideas registry is disabled in Settings.")
    }

    func testStartBackfillMalformedOutputSetsErrorNotCrash() async {
        let runner = FakeCLIRunner(stdout: Data("not json at all".utf8))
        let vm = IdeasViewModel(dbManager: dbManager, cliRunner: runner)

        await vm.startBackfill(from: Date(timeIntervalSince1970: 0), to: Date())

        XCTAssertFalse(vm.isBackfilling)
        XCTAssertNil(vm.backfillSummary)
        XCTAssertNotNil(vm.backfillError)
    }

    /// A second `startBackfill` while one is already in flight must not
    /// invoke the CLI again — guarded synchronously before the first await,
    /// so the check can't race the in-flight run.
    func testStartBackfillDoubleStartIsGuarded() async {
        let blocking = FakeCLIRunner()
        blocking.blockUntilCancelled = true
        let vm = IdeasViewModel(dbManager: dbManager, cliRunner: blocking)

        let firstTask = Task { await vm.startBackfill(from: Date(timeIntervalSince1970: 0), to: Date()) }
        for _ in 0..<1000 where !vm.isBackfilling { await Task.yield() }
        XCTAssertTrue(vm.isBackfilling)

        await vm.startBackfill(from: Date(timeIntervalSince1970: 0), to: Date())
        XCTAssertEqual(blocking.invocations.count, 1, "the guarded call must not invoke the CLI a second time")

        firstTask.cancel()
        await firstTask.value
        XCTAssertFalse(vm.isBackfilling)
    }

    /// House rule: async ops need VM-owned state so they survive the sheet
    /// being dismissed / the tab switched away from and back — nothing here
    /// holds onto the started Task, mirroring how the sheet's Start button
    /// fires an unstructured Task rather than a view-scoped `.task`.
    func testStartBackfillStateSurvivesNavigationAwayAndBack() async {
        let runner = FakeCLIRunner(stdout: Data(#"{"proposed":4,"cycles":3,"mentions_deduped":2}"#.utf8))
        let vm = IdeasViewModel(dbManager: dbManager, cliRunner: runner)

        Task { await vm.startBackfill(from: Date(timeIntervalSince1970: 0), to: Date()) }

        for _ in 0..<1000 where vm.isBackfilling || vm.backfillSummary == nil {
            await Task.yield()
        }

        XCTAssertFalse(vm.isBackfilling)
        XCTAssertEqual(vm.backfillSummary, "Proposed 4 ideas (3 cycles, 2 duplicates skipped)")
        XCTAssertNil(vm.backfillError)
    }

    // MARK: - date formatting (SB1)

    /// SB1: the `--from`/`--to` formatter must render the UTC calendar day,
    /// not the machine's local day. 2026-01-01T23:30 UTC rolls to Jan 2nd
    /// local time in any zone east of UTC (this machine included), so an
    /// unpinned formatter would send the wrong date.
    func testStartBackfillFormatsDatesAsTheUTCCalendarDay() async {
        let runner = FakeCLIRunner(stdout: Data(#"{"proposed":0,"cycles":0,"mentions_deduped":0}"#.utf8))
        let vm = IdeasViewModel(dbManager: dbManager, cliRunner: runner)

        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = 2026
        comps.month = 1
        comps.day = 1
        comps.hour = 23
        comps.minute = 30
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        await vm.startBackfill(from: date, to: date)

        XCTAssertEqual(runner.invocations.first, ["ideas", "mine", "--from", "2026-01-01", "--to", "2026-01-01"])
    }

    // MARK: - parseBackfillEnvelope()

    func testParseBackfillEnvelopeIgnoresProgressLinesBeforeTheJSONLine() {
        let stdout = Data("""
        cycle=1
        cycle=2
        cycle=3
        {"proposed":7,"cycles":3,"mentions_deduped":4}
        """.utf8)

        let envelope = IdeasViewModel.parseBackfillEnvelope(stdout)

        XCTAssertEqual(envelope?.proposed, 7)
        XCTAssertEqual(envelope?.cycles, 3)
        XCTAssertEqual(envelope?.mentionsDeduped, 4)
    }

    func testParseBackfillEnvelopeReturnsNilOnMalformedOutput() {
        XCTAssertNil(IdeasViewModel.parseBackfillEnvelope(Data("not json at all".utf8)))
    }
}

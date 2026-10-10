import GRDB
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Workbench tab's list and menu (spec §4.2, §13 B2) over the demo seed.
@MainActor
final class WorkbenchWiringTests: XCTestCase {
    private let now = Date()

    private func card(_ id: Int64) throws -> WorkbenchCardModel {
        let snapshot = try demoSnapshot(now: now)
        return WorkbenchCardModel(try XCTUnwrap(snapshot.workbench(id)))
    }

    // MARK: - Level 1: the list

    func testTheListOrdersByLatestSessionActivity() throws {
        let snapshot = try demoSnapshot(now: now)
        XCTAssertEqual(snapshot.orderedWorkbenches.map(\.name), ["Acme", "Acme Website", "Notes"])
    }

    func testACardShowsFolderBranchWaitingCountsAndProgress() throws {
        let acme = try card(DemoSeed.acmeID)
        XCTAssertEqual(acme.folder, "~/Projects/acme")
        XCTAssertEqual(acme.branch, "main")
        XCTAssertEqual(acme.waitingCount, 3)
        XCTAssertEqual(acme.stateCounts.map(\.text), [
            "1 working", "1 waiting for you", "1 needs approval", "2 finished", "1 failed", "1 stopped"
        ])
        XCTAssertEqual(try XCTUnwrap(acme.progress), 1.0 / 8.0, accuracy: 0.0001)
        XCTAssertEqual(acme.countsLine, "3 in progress · 3 todo · 1 blocked · 1 done")
        XCTAssertEqual(acme.pills.map(\.text), ["3 waiting", "1 error"])
        XCTAssertEqual(try card(DemoSeed.websiteID).pills.map(\.text), [], "a working workbench is not idle")
    }

    func testAZeroOfZeroBoardHasNoProgressBar() throws {
        let notes = try card(DemoSeed.notesID)
        XCTAssertNil(notes.progress)
        XCTAssertEqual(notes.countsLine, "0 in progress · 0 todo · 0 done")
        XCTAssertTrue(notes.stateCounts.isEmpty)
        XCTAssertEqual(notes.pills.map(\.text), ["idle"])
    }

    /// The Workbench tab's badge is the open-ask count; the others have none.
    func testTheWorkbenchTabBadgeCountsOpenAsks() throws {
        XCTAssertEqual(try demoSnapshot(now: now).openAsks().count, 3)
        XCTAssertEqual(RootTabView.Tab.workbench.badge(openAskCount: 3), 3)
        XCTAssertEqual(RootTabView.Tab.now.badge(openAskCount: 3), 0)
        XCTAssertEqual(RootTabView.Tab.workbench.badge(openAskCount: 0), 0)
    }

    func testADetachedHeadReadsAsDetached() throws {
        let detached = WorkbenchCardModel(try mirror(Workbench.self, DemoSeed.JSON.workbench(9, ["branch": "", "detached": true])))
        XCTAssertEqual(detached.branch, "detached")
    }

    // MARK: - Level 2: the menu

    func testZeroSessionsShowNoSessionsYet() throws {
        let menu = try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.notesID, snapshot: try demoSnapshot(now: now), now: now))
        XCTAssertTrue(menu.sessions.isEmpty)
        XCTAssertEqual(menu.sessionsEmptyText, "No sessions yet")
        XCTAssertTrue(menu.waiting.isEmpty)
    }

    func testTheMenuSublineAndWaitingStack() throws {
        let menu = try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: try demoSnapshot(now: now), now: now))
        XCTAssertEqual(menu.title, "Acme")
        XCTAssertEqual(menu.subline, "main · 3 in progress · 3 todo · 1 blocked")
        XCTAssertNil(menu.sessionsEmptyText)
        XCTAssertEqual(menu.waitingHeader, "Waiting for you · 3")
        // Newest first.
        XCTAssertEqual(menu.waiting.map(\.id), [111, 109, 110])
        XCTAssertEqual(menu.waiting.map(\.kindLabel), ["CHECK", "ASK", "REVIEW"])
        XCTAssertEqual(menu.waiting.first?.subline, "Archive closed targets · #415 · 5m")
        XCTAssertEqual(menu.closedLabel, "▸ 3 closed")
        XCTAssertEqual(menu.closedAsks.map(\.id), [107, 106, 105])
    }

    func testSessionsListLiveFirstThenNewest() throws {
        let menu = try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: try demoSnapshot(now: now), now: now))
        XCTAssertEqual(menu.sessions.map(\.id), [10, 11, 12, 14, 13, 15, 16, 17])
    }

    func testAnUnknownWorkbenchHasNoMenu() throws {
        XCTAssertNil(WorkbenchMenuModel(workbenchID: 999, snapshot: try demoSnapshot(now: now), now: now))
    }

    // MARK: - Replica read

    /// The snapshot reads what the hydrator stored; an undecodable record is
    /// skipped, never a failed screen.
    func testTheSnapshotReadsTheHydratedDemoAndSkipsABadRecord() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: now)
        try await transport.save([
            CloudRecordFactory.record(for: SliceRecord(kind: .workbench, id: "99", modifiedAt: now, payload: Data("{}".utf8)))
        ])
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        let model = WorkbenchReplicaModel()
        model.start(store: store)
        try await poll { model.snapshot.workbenches.count == 3 }
        XCTAssertEqual(model.snapshot.sessions.count, 10)
        XCTAssertEqual(model.snapshot.asks.count, 6)
        XCTAssertEqual(model.snapshot.targets.count, 13)
        XCTAssertEqual(model.snapshot.comments.count, 3)
        XCTAssertEqual(model.snapshot.heartbeat?.macName, DemoSeed.macName)
        XCTAssertEqual(model.snapshot.skippedRecords, [.workbench: 1])
    }

    /// A replica write the Workbench slices do not read publishes no new
    /// snapshot, and the tab badge's count is set only when it changes, so
    /// the tab bar is not re-rendered on every write.
    func testTheModelPublishesOnlyRealChangesAndTheBadgeOnlyItsOwn() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        try await transport.save(try DemoSeed.workbenchRecords(now: now))
        _ = try await hydrator.hydrateOnce()
        let model = WorkbenchReplicaModel()
        model.start(store: store)
        try await poll { model.snapshot.workbenches.count == 3 }
        XCTAssertEqual(model.openAskCount, 3)
        var published = WorkbenchReplicaModel.observation(store: store).values(in: store.reader).makeAsyncIterator()
        let initial = try await published.next()
        XCTAssertEqual(initial?.workbenches.count, 3)
        let badgeSets = ObservedSetCounter { _ = model.openAskCount }
        // A sibling observation proves the unrelated write was seen.
        let sentinel = CalendarReplicaModel()
        sentinel.start(store: store)

        try await transport.save(try DemoSeed.calendarRecords(now: now))
        _ = try await hydrator.hydrateOnce()
        try await poll { !sentinel.snapshot.events.isEmpty }

        try await transport.save([try DemoSeed.record(kind: .workbench, id: 98, json: DemoSeed.JSON.workbench(98), modifiedAt: now)])
        _ = try await hydrator.hydrateOnce()
        let next = try await published.next()
        XCTAssertEqual(next?.workbenches.count, 4, "a calendar write must not republish the Workbench snapshot")
        try await poll { model.snapshot.workbenches.count == 4 }
        XCTAssertEqual(badgeSets.count, 0, "a new workbench leaves the open-ask count alone")

        try await transport.save([try DemoSeed.record(
            kind: .ownerAsk, id: 199, json: DemoSeed.JSON.ask(199, workbench: 98), modifiedAt: now
        )])
        _ = try await hydrator.hydrateOnce()
        try await poll { model.openAskCount == 4 }
        XCTAssertEqual(badgeSets.count, 1)
    }
}

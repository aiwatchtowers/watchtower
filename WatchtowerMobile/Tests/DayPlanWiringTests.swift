import GRDB
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// Wiring tests for the day plan on Today: the view model's observation over
/// the `day_plan`/`day_plan_item` slices, the desktop's item ordering, the
/// progress count, and the two quick actions — including WHICH items may be
/// acted on at all (a calendar-sourced block is read-only on the Mac, so the
/// phone must not offer an action the desktop would refuse).
@MainActor
final class DayPlanWiringTests: XCTestCase {

    // MARK: - Helpers

    private func makePoolStore() throws -> ReplicaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-dayplan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path)
    }

    private func poll(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        _ message: @autoclosure () -> String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    private func planRecord(hasConflicts: Bool = false, conflictSummary: String = "") throws -> SliceRecord {
        SliceRecord(
            kind: .dayPlan,
            id: "1",
            modifiedAt: Date(),
            payload: try RowPayloadCoder.payload(from: Row([
                "id": 1,
                "user_id": "U001",
                "plan_date": "2026-08-04",
                "status": "active",
                "has_conflicts": hasConflicts ? 1 : 0,
                "conflict_summary": conflictSummary,
                "generated_at": "2026-08-04T08:00:00Z",
            ]))
        )
    }

    private func itemRecord(
        id: Int,
        kind: String = "timeblock",
        sourceType: String = "manual",
        title: String = "Deep work",
        startTime: String = "",
        endTime: String = "",
        status: String = "pending",
        orderIndex: Int = 0
    ) throws -> SliceRecord {
        SliceRecord(
            kind: .dayPlanItem,
            id: String(id),
            modifiedAt: Date(),
            payload: try RowPayloadCoder.payload(from: Row([
                "id": id,
                "day_plan_id": 1,
                "kind": kind,
                "source_type": sourceType,
                "title": title,
                "start_time": startTime,
                "end_time": endTime,
                "status": status,
                "order_index": orderIndex,
            ]))
        )
    }

    private func startedModel(
        _ store: ReplicaStore,
        transport: InMemoryCloudTransport = InMemoryCloudTransport()
    ) -> DayPlanViewModel {
        let model = DayPlanViewModel()
        model.start(store: store, outbox: ActionOutbox(transport: transport, store: store))
        return model
    }

    private func apply(_ records: [SliceRecord], to store: ReplicaStore, token: Int = 1) throws {
        try store.apply(CloudChangeBatch(
            changed: records.map { CloudRecordFactory.record(for: $0) },
            deletedRecordNames: [],
            newToken: CloudChangeToken(value: token)
        ))
    }

    // MARK: - Observation + ordering

    /// The desktop's own order (DayPlanQueries.fetchItems): time blocks first,
    /// then backlog, each by order_index.
    func testItemsSplitIntoBlocksAndBacklogInDesktopOrder() async throws {
        let store = try makePoolStore()
        let model = startedModel(store)
        try apply([
            try planRecord(),
            try itemRecord(id: 1, kind: "backlog", title: "Answer in #ops", orderIndex: 1),
            try itemRecord(id: 2, title: "1:1", startTime: "2026-08-04T14:00:00Z",
                           endTime: "2026-08-04T14:30:00Z", orderIndex: 1),
            try itemRecord(id: 3, title: "Deep work", startTime: "2026-08-04T09:30:00Z",
                           endTime: "2026-08-04T11:00:00Z", orderIndex: 0),
            try itemRecord(id: 4, kind: "backlog", title: "Read the RFC", orderIndex: 0),
        ], to: store)

        try await poll { model.items.count == 4 }
        XCTAssertEqual(model.timeblocks.map(\.title), ["Deep work", "1:1"])
        XCTAssertEqual(model.backlog.map(\.title), ["Read the RFC", "Answer in #ops"])
        XCTAssertEqual(model.plan?.planDate, "2026-08-04")
    }

    func testProgressCountsDoneAgainstEveryItem() async throws {
        let store = try makePoolStore()
        let model = startedModel(store)
        try apply([
            try planRecord(),
            try itemRecord(id: 1, status: "done"),
            try itemRecord(id: 2, status: "skipped", orderIndex: 1),
            try itemRecord(id: 3, orderIndex: 2),
        ], to: store)

        try await poll { model.items.count == 3 }
        XCTAssertEqual(model.progress.done, 1, "skipped is not done")
        XCTAssertEqual(model.progress.total, 3)
    }

    /// Yesterday's plan leaving the publisher's window deletes it here — the
    /// section must disappear rather than keep yesterday on screen.
    func testPlanLeavingTheSliceClearsTheSection() async throws {
        let store = try makePoolStore()
        let model = startedModel(store)
        try apply([try planRecord(), try itemRecord(id: 1)], to: store)
        try await poll { model.plan != nil && model.items.count == 1 }

        try store.apply(CloudChangeBatch(
            changed: [],
            deletedRecordNames: [
                SliceKind.dayPlan.recordName(id: "1"),
                SliceKind.dayPlanItem.recordName(id: "1"),
            ],
            newToken: CloudChangeToken(value: 2)
        ))

        try await poll { model.plan == nil && model.items.isEmpty }
    }

    // MARK: - Quick actions

    func testMarkDoneAndSkipEnqueueTheirKindsAgainstTheItemRecord() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let model = startedModel(store, transport: transport)
        try apply([try planRecord(), try itemRecord(id: 7), try itemRecord(id: 8, orderIndex: 1)], to: store)
        try await poll { model.items.count == 2 }

        await model.markDone(try XCTUnwrap(model.items.first { $0.id == 7 }))
        await model.skip(try XCTUnwrap(model.items.first { $0.id == 8 }))

        let actions = try store.pendingActions().sorted { $0.action.kind.rawValue < $1.action.kind.rawValue }
        XCTAssertEqual(actions.map(\.action.kind), [.dayPlanItemDone, .dayPlanItemSkip])
        XCTAssertEqual(actions.map(\.action.entityID), ["7", "8"])
        XCTAssertEqual(actions.map(\.entityRecordName), ["day_plan_item-7", "day_plan_item-8"])
        // The wire got both, as pending action records.
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.filter { $0.kind == RelayRecordKind.action.rawValue }.count, 2)
    }

    /// The chip is the row's in-flight marker, and it disappears once the
    /// authoritative row shows the outcome (PendingOverlay's suppression).
    func testPendingChipAppearsThenYieldsToTheAppliedRow() async throws {
        let store = try makePoolStore()
        let model = startedModel(store)
        try apply([try planRecord(), try itemRecord(id: 7)], to: store)
        try await poll { model.items.count == 1 }
        let item = try XCTUnwrap(model.items.first)

        await model.markDone(item)
        try await poll { model.chip(for: item) != nil }

        // The desktop applied it: the slice row now says done.
        try apply([try itemRecord(id: 7, status: "done")], to: store, token: 2)
        try await poll { model.items.first?.status == .done }
        let applied = try XCTUnwrap(model.items.first)
        XCTAssertNil(model.chip(for: applied), "a done row must not still wear a pending chip")
    }

    /// Calendar-sourced blocks are read-only on the Mac; a done/skip swipe on
    /// one would come back as a failure, so the row must not offer it.
    func testCalendarBlocksAreReadOnly() async throws {
        let store = try makePoolStore()
        let model = startedModel(store)
        try apply([
            try planRecord(),
            try itemRecord(id: 1, sourceType: "calendar", title: "Standup"),
            try itemRecord(id: 2, sourceType: "task", title: "Ship it", orderIndex: 1),
        ], to: store)

        try await poll { model.items.count == 2 }
        XCTAssertTrue(try XCTUnwrap(model.items.first { $0.id == 1 }).isReadOnly)
        XCTAssertFalse(try XCTUnwrap(model.items.first { $0.id == 2 }).isReadOnly)
    }

    // MARK: - Model projections

    func testTimeRangeRendersOnlyForFullyScheduledBlocks() throws {
        let scheduled = DayPlanItem(row: Row([
            "id": 1, "day_plan_id": 1, "kind": "timeblock", "source_type": "manual",
            "title": "Deep work",
            "start_time": "2026-08-04T09:30:00Z", "end_time": "2026-08-04T11:00:00Z",
            "status": "pending", "order_index": 0,
        ]))
        XCTAssertNotNil(scheduled.timeRange)
        XCTAssertNotNil(scheduled.startDate)

        let backlog = DayPlanItem(row: Row([
            "id": 2, "day_plan_id": 1, "kind": "backlog", "source_type": "manual",
            "title": "Read the RFC", "start_time": "", "end_time": "",
            "status": "pending", "order_index": 0,
        ]))
        XCTAssertNil(backlog.timeRange, "a backlog entry has no time range to show")
        XCTAssertNil(backlog.startDate)
    }
}

import GRDB
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// Wiring tests for the Task 6 quick actions: VM swipe methods → `ActionOutbox`
/// enqueue (pending overlay row + relay record with the right kind/entityID),
/// the overlay join back into the VMs (chip / suppression / failed banner /
/// retry), the snooze wall-clock math, and `AppEnvironment`'s relay wiring
/// (applied echo → overlay cleared + hydrate nudge). The Kit's own suites
/// cover outbox/feed logic — here we prove the APP's glue over them.
@MainActor
final class ActionsWiringTests: XCTestCase {

    // MARK: - Fixtures

    /// One transport shared by seed, outbox, and assertions — the same
    /// single-transport shape `AppEnvironment` wires in production.
    private struct Fixture {
        let transport: InMemoryCloudTransport
        let store: ReplicaStore
        let outbox: ActionOutbox
    }

    private func makeFixture() async throws -> Fixture {
        let store = try ReplicaStore(path: makeReplicaPath())
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        return Fixture(
            transport: transport,
            store: store,
            outbox: ActionOutbox(transport: transport, store: store)
        )
    }

    /// Isolated on-disk pool path (the production DatabasePool mechanism).
    private func makeReplicaPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("replica.sqlite").path
    }

    /// Polls the main run loop until `condition` holds or the timeout elapses
    /// (observation callbacks arrive async on the main queue).
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

    /// All action records currently in the relay zone, wire-decoded.
    private func relayActions(in transport: InMemoryCloudTransport) async throws -> [ActionRequestPayload] {
        let batch = try await transport.changes(in: .relay, since: nil)
        return batch.changed
            .filter { $0.kind == "action" }
            .compactMap { try? RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: $0.payload) }
    }

    // MARK: - Enqueue through the VM (swipe path)

    /// Inbox swipe "Resolve": pending overlay row + relay record carry the
    /// right kind AND the right entityID for the row that was swiped —
    /// the typed-method pairing this VM exists to enforce.
    func testInboxResolveEnqueuesPendingRowRelayRecordAndChip() async throws {
        let fx = try await makeFixture()
        let vm = InboxViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.items.count == 2 }
        let item = try XCTUnwrap(vm.items.first) // seeded id 1, high priority

        await vm.resolve(item)

        let rows = try fx.store.pendingActions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.action.kind, .inboxResolve)
        XCTAssertEqual(rows.first?.entityRecordName, "inbox_item-1")
        XCTAssertEqual(rows.first?.state, .pending)

        let actions = try await relayActions(in: fx.transport)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.kind, .inboxResolve)
        XCTAssertEqual(actions.first?.entityID, "1")
        XCTAssertEqual(actions.first?.status, .pending)

        // The overlay observation re-fires and the row now carries the chip
        // (status is still "pending" ≠ "resolved", so no suppression).
        try await poll { vm.chip(for: item) != nil }
        XCTAssertEqual(vm.chip(for: item)?.action.kind, .inboxResolve)
    }

    /// Inbox swipe "Snooze": the wire `snooze_until` param is the plain UTC
    /// ISO8601 instant the desktop parser accepts, end-to-end from the VM.
    func testInboxSnoozeSendsPlainISO8601SnoozeUntil() async throws {
        let fx = try await makeFixture()
        let vm = InboxViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.items.count == 2 }
        let item = try XCTUnwrap(vm.items.first)

        let now = Date(timeIntervalSince1970: 1_783_000_000)
        await vm.snooze(item, option: .oneHour, now: now)

        let expected = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let actions = try await relayActions(in: fx.transport)
        XCTAssertEqual(actions.first?.kind, .inboxSnooze)
        XCTAssertEqual(actions.first?.params["snooze_until"], .string(expected))
    }

    /// Create sheet → `task_create`: entity-less (nil recordName, nil wire
    /// entityID), text carried in params.
    func testCreateTargetEnqueuesEntityLessTaskCreate() async throws {
        let fx = try await makeFixture()
        let vm = TasksViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.targets.count == 3 }

        await vm.createTarget(text: "Buy milk")

        let rows = try fx.store.pendingActions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.action.kind, .taskCreate)
        XCTAssertNil(rows.first?.entityRecordName)

        let actions = try await relayActions(in: fx.transport)
        XCTAssertEqual(actions.first?.kind, .taskCreate)
        XCTAssertNil(actions.first?.entityID)
        XCTAssertEqual(actions.first?.params["text"], .string("Buy milk"))
    }

    // MARK: - Overlay semantics

    /// Failed echo: the chip disappears (row restores its appearance) and the
    /// failure surfaces in the tab's banner list with the desktop's message.
    func testTargetDoneFailedEchoRestoresOverlayAndSurfacesError() async throws {
        let fx = try await makeFixture()
        let vm = TasksViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.targets.count == 3 }
        let target = try XCTUnwrap(vm.targets.first { $0.status == "in_progress" })

        await vm.markDone(target)
        try await poll { vm.chip(for: target)?.action.kind == .targetDone }

        let pendingID = try XCTUnwrap(fx.store.pendingActions().first?.id)
        var echo = ActionRequestPayload(id: pendingID, kind: .targetDone, entityID: "1", createdAt: Date())
        echo.status = .failed
        echo.errorMessage = "boom"
        try await fx.outbox.applyEcho(echo)

        try await poll { vm.chip(for: target) == nil && vm.failedActions.count == 1 }
        XCTAssertEqual(vm.failedActions.first?.errorMessage, "boom")
        XCTAssertEqual(vm.failedActions.first?.action.kind, .targetDone)
    }

    /// Suppress-chip-when-state-matches: a pending `target_done` on a target
    /// whose slice status is ALREADY "done" (hydration beat the echo) renders
    /// no chip, while the same action on an in-progress target does.
    func testPendingChipSuppressedWhenSliceStatusAlreadyMatches() async throws {
        let fx = try await makeFixture()
        let vm = TasksViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.targets.count == 3 }
        let doneTarget = try XCTUnwrap(vm.targets.first { $0.status == "done" })
        let activeTarget = try XCTUnwrap(vm.targets.first { $0.status == "in_progress" })

        await vm.markDone(doneTarget)
        await vm.markDone(activeTarget)
        try await poll { vm.pending.count == 2 }

        XCTAssertNil(vm.chip(for: doneTarget), "chip must be suppressed when the row already shows the outcome")
        XCTAssertNotNil(vm.chip(for: activeTarget))
    }

    /// Retry re-enqueues the failed action verbatim under a fresh id and
    /// drops the failed row; Dismiss just drops the row.
    func testRetryReenqueuesFreshActionAndDismissRemovesRow() async throws {
        let fx = try await makeFixture()
        let vm = InboxViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.items.count == 2 }
        let item = try XCTUnwrap(vm.items.first)

        await vm.resolve(item)
        let firstID = try XCTUnwrap(fx.store.pendingActions().first?.id)
        var echo = ActionRequestPayload(id: firstID, kind: .inboxResolve, entityID: "1", createdAt: Date())
        echo.status = .failed
        echo.errorMessage = "no such row"
        try await fx.outbox.applyEcho(echo)
        try await poll { vm.failedActions.count == 1 }

        let failedRow = try XCTUnwrap(vm.failedActions.first)
        await vm.retry(failedRow)
        try await poll { vm.failedActions.isEmpty && vm.pending.count == 1 }
        let retried = try XCTUnwrap(fx.store.pendingActions().first)
        XCTAssertEqual(retried.state, .pending)
        XCTAssertEqual(retried.action.kind, .inboxResolve)
        XCTAssertEqual(retried.entityRecordName, "inbox_item-1")
        XCTAssertNotEqual(retried.id, firstID, "retry must mint a fresh action id")

        var secondEcho = ActionRequestPayload(id: retried.id, kind: .inboxResolve, entityID: "1", createdAt: Date())
        secondEcho.status = .failed
        secondEcho.errorMessage = "still no"
        try await fx.outbox.applyEcho(secondEcho)
        try await poll { vm.failedActions.count == 1 }

        let dismissRow = try XCTUnwrap(vm.failedActions.first)
        vm.dismissFailure(dismissRow)
        try await poll { vm.pending.isEmpty }
        XCTAssertTrue(try fx.store.pendingActions().isEmpty)
    }

    /// Failed `task_create`: `PendingOverlay.taskCreateText` surfaces the
    /// typed text so the banner can show WHICH create failed — otherwise
    /// Dismiss discards it invisibly (review Fix 2).
    func testFailedTaskCreateExposesTypedTextViaPendingOverlay() async throws {
        let fx = try await makeFixture()
        let vm = TasksViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.targets.count == 3 }

        await vm.createTarget(text: "Buy milk")
        let pendingID = try XCTUnwrap(fx.store.pendingActions().first?.id)
        var echo = ActionRequestPayload(id: pendingID, kind: .taskCreate, entityID: nil, createdAt: Date())
        echo.status = .failed
        echo.errorMessage = "boom"
        try await fx.outbox.applyEcho(echo)

        try await poll { vm.failedActions.count == 1 }
        let failed = try XCTUnwrap(vm.failedActions.first)
        XCTAssertEqual(PendingOverlay.taskCreateText(of: failed), "Buy milk")
    }

    /// Non-`task_create` failures (e.g. `target_done`) have no typed text to
    /// show — the computed property must stay nil rather than guess.
    func testTaskCreateTextIsNilForOtherKinds() async throws {
        let fx = try await makeFixture()
        let vm = TasksViewModel()
        vm.start(store: fx.store, outbox: fx.outbox)
        try await poll { vm.targets.count == 3 }
        let target = try XCTUnwrap(vm.targets.first { $0.status == "in_progress" })

        await vm.markDone(target)
        let pendingID = try XCTUnwrap(fx.store.pendingActions().first?.id)
        var echo = ActionRequestPayload(id: pendingID, kind: .targetDone, entityID: "1", createdAt: Date())
        echo.status = .failed
        echo.errorMessage = "boom"
        try await fx.outbox.applyEcho(echo)

        try await poll { vm.failedActions.count == 1 }
        let failed = try XCTUnwrap(vm.failedActions.first)
        XCTAssertNil(PendingOverlay.taskCreateText(of: failed))
    }

    // MARK: - Snooze wall-clock math

    /// The menu instants are computed on the USER's local calendar and only
    /// rendered as UTC: pinned here against a fixed zone (America/New_York,
    /// UTC-4 in July) so the wall-clock semantics can't silently drift.
    func testSnoozeOptionsComputeLocalWallClockInstants() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let iso = ISO8601DateFormatter()
        // 2026-07-06 11:00 EDT — before 6 pm.
        let morning = try XCTUnwrap(iso.date(from: "2026-07-06T15:00:00Z"))

        XCTAssertEqual(
            SnoozeOption.oneHour.until(now: morning, calendar: calendar),
            try XCTUnwrap(iso.date(from: "2026-07-06T16:00:00Z"))
        )
        XCTAssertEqual(
            SnoozeOption.tonight.until(now: morning, calendar: calendar),
            try XCTUnwrap(iso.date(from: "2026-07-06T22:00:00Z")),
            "tonight before 6 pm = today 18:00 local"
        )
        XCTAssertEqual(
            SnoozeOption.tomorrow.until(now: morning, calendar: calendar),
            try XCTUnwrap(iso.date(from: "2026-07-07T04:00:00Z")),
            "tomorrow = next local midnight"
        )

        // 2026-07-06 19:30 EDT — past 6 pm: "tonight" rolls to tomorrow evening.
        let evening = try XCTUnwrap(iso.date(from: "2026-07-06T23:30:00Z"))
        XCTAssertEqual(
            SnoozeOption.tonight.until(now: evening, calendar: calendar),
            try XCTUnwrap(iso.date(from: "2026-07-07T22:00:00Z")),
            "tonight after 6 pm = tomorrow 18:00 local (never in the past)"
        )
        XCTAssertEqual(
            SnoozeOption.nextWeek.until(now: morning, calendar: calendar),
            try XCTUnwrap(iso.date(from: "2026-07-13T04:00:00Z")),
            "next week = local midnight 7 days out"
        )
    }

    /// Menu regression guard: the Tasks tab must offer ONLY day-granularity
    /// snooze options. `TargetQueries.snooze` (desktop) truncates to a bare
    /// `yyyy-MM-dd`, and Go's `UnsnoozeExpiredTargets` (internal/db/targets.go)
    /// compares that string lexicographically against `<= "now"` — a same-day
    /// bare date always sorts before any timestamp later that day, so
    /// `.oneHour`/`.tonight` would unsnooze the target IMMEDIATELY (a silent
    /// no-op the user has no way to notice). If this test ever needs
    /// loosening, the desktop storage/comparison must change FIRST.
    func testTargetSnoozeCasesAreDayGranularityOnly() {
        XCTAssertEqual(SnoozeOption.targetCases, [.tomorrow, .nextWeek])
    }

    // MARK: - AppEnvironment relay wiring

    /// The full app wiring: a VM action enqueued through `env.outbox`, an
    /// `applied` echo routed by `env.feed` → the overlay row disappears AND
    /// `onActionApplied` nudges an immediate hydration (observable because a
    /// fresh slice record lands in the store long before the hydrator's own
    /// 30 s poll could have delivered it).
    func testAppliedEchoThroughEnvironmentClearsOverlayAndNudgesHydration() async throws {
        let transport = InMemoryCloudTransport()
        let env = try AppEnvironment(transport: transport, replicaPath: makeReplicaPath())
        try await poll { env.lastHydrate != nil }

        let vm = TasksViewModel()
        vm.start(store: env.store, outbox: env.outbox)
        try await poll { vm.targets.count == 3 }
        let target = try XCTUnwrap(vm.targets.first { $0.status == "in_progress" })
        await vm.markDone(target)
        try await poll { vm.chip(for: target) != nil }
        let pendingID = try XCTUnwrap(env.store.pendingActions().first?.id)

        // The "desktop applied it" pair: the rewritten target slice row (done)
        // plus the applied action echo, in the same transport state.
        let payload = try RowPayloadCoder.payload(from: Row([
            "id": 1,
            "text": "Ship the mobile app skeleton",
            "level": "week",
            "status": "done",
            "priority": "high",
            "created_at": "2026-07-06T10:00:00Z",
        ]))
        let slice = SliceRecord(kind: .target, id: "1", modifiedAt: Date(), payload: payload)
        var echo = ActionRequestPayload(id: pendingID, kind: .targetDone, entityID: "1", createdAt: Date())
        echo.status = .applied
        try await transport.save([
            CloudRecordFactory.record(for: slice),
            try CloudRecordFactory.record(for: echo, modifiedAt: Date()),
        ])

        _ = try await env.feed.pollOnce()

        // Applied echo → overlay row removed (chip gone) …
        try await poll { env.store.hasNoPendingActions }
        // … and the hydrate nudge delivered the authoritative slice change.
        try await poll {
            (try? env.store.fetchAll(Target.self, kind: .target))?
                .first { $0.id == 1 }?.status == "done"
        }
        try await poll { vm.chip(for: target) == nil }
    }
}

private extension ReplicaStore {
    var hasNoPendingActions: Bool {
        (try? pendingActions().isEmpty) ?? false
    }
}

import GRDB
import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The content-free timing of an action (relay client Phase 4, Task 14): written at the start of the save that
/// landed, answered at the final `applied` echo, effect at the first slice of an effect kind. Only
/// `at`/`transport`/`answer_ms`/`result_ms` are kept; every other outcome leaves no sample.
final class ActionLatencyTests: XCTestCase {

    // Anchored to the real clock, per test: opening a replica sweeps with it, and XCTest builds every instance up front.
    private var base = Date(timeIntervalSince1970: 0)
    private var device: String { TestE2E.deviceID.uuidString }
    private var hubID: String { TestE2E.hubID.uuidString }

    override func setUp() {
        super.setUp()
        base = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
    }

    private struct Phone {
        let inner: InMemoryCloudTransport
        let store: ReplicaStore
        let outbox: ActionOutbox
        let clock: OSAllocatedUnfairLock<Date>

        func advance(by seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }
        var now: Date { clock.withLock { $0 } }
    }

    private func makePhone(ordered: Bool = true, route: HubRoute = .cloudKit(.private)) async throws -> Phone {
        let keys = try TestE2E.phoneStore()
        let inner = InMemoryCloudTransport()
        let recorder = RecordingConditionalTransport(inner: inner)
        let secure = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: recorder)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let clock = OSAllocatedUnfairLock(initialState: base)
        let outbox = ActionOutbox(transport: secure, store: store, deviceID: device, route: route) {
            clock.withLock { $0 }
        }
        if ordered { try await outbox.enableOrderedActions() }
        await outbox.setHubID(hubID)
        return Phone(inner: inner, store: store, outbox: outbox, clock: clock)
    }

    /// Enqueues one action and flushes it; returns its id and seq.
    private func send(_ phone: Phone, _ kind: ActionKind = .boardTargetStatus) async throws -> (id: String, seq: UInt64) {
        let id = try await phone.outbox.enqueue(kind: kind, entityRecordName: "target-42")
        _ = try await phone.outbox.flush()
        let row = try XCTUnwrap(phone.store.outboxRows([.queued, .sent, .settled, .undelivered]).first { $0.actionID == id })
        return (id, row.actionSeq)
    }

    private func echo(
        _ sent: (id: String, seq: UInt64), _ status: ActionStatus, kind: ActionKind = .boardTargetStatus
    ) -> ActionRequestPayload {
        var echo = ActionRequestPayload(
            id: sent.id, kind: kind, entityID: "42", createdAt: base, deviceID: device, hubID: hubID)
        echo.actionSeq = sent.seq
        echo.status = status
        return echo
    }

    private func pendingCount(_ store: ReplicaStore) throws -> Int {
        try store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM latency_pending") ?? 0 }
    }

    private func samples(_ store: ReplicaStore) throws -> [LatencySample] {
        try store.latencySamples(since: base.addingTimeInterval(-1_000_000))
    }

    // MARK: - The three stamps

    func testAnActionWithItsEchoAndSliceRecordsOneSample() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        phone.advance(by: 2)
        try await phone.outbox.applyEcho(echo(sent, .applied))
        XCTAssertEqual(try samples(phone.store), [], "the effect has not been seen yet")
        phone.advance(by: 1.5)
        try phone.store.latencyEffect(kind: "workbench", at: phone.now)

        XCTAssertEqual(try samples(phone.store), [
            LatencySample(at: phone.now, transport: .cloudKit, answerMs: 2000, resultMs: 3500)
        ])
        XCTAssertEqual(try pendingCount(phone.store), 0)
        // A second slice or a replayed echo records nothing more.
        try phone.store.latencyEffect(kind: "workbench", at: phone.now)
        try await phone.outbox.applyEcho(echo(sent, .applied))
        XCTAssertEqual(try samples(phone.store).count, 1)
    }

    func testASliceBeforeTheEchoCounts() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        phone.advance(by: 1)
        try phone.store.latencyEffect(kind: "workbench_target", at: phone.now)
        phone.advance(by: 2)
        try await phone.outbox.applyEcho(echo(sent, .applied))

        let sample = try XCTUnwrap(samples(phone.store).first)
        XCTAssertEqual(sample.answerMs, 3000)
        XCTAssertEqual(sample.resultMs, 3000, "result is the later of the echo and the slice")
    }

    func testAQueuedOfflineWaitIsNotCounted() async throws {
        let phone = try await makePhone()
        await phone.inner.refuseNext(.unreachable, count: 1)
        let id = try await phone.outbox.enqueue(kind: .boardTargetStatus, entityRecordName: "target-42")
        _ = try await phone.outbox.flush()
        XCTAssertEqual(try pendingCount(phone.store), 0, "a refused save stamps nothing")

        phone.advance(by: 600)
        _ = try await phone.outbox.flush()
        let row = try XCTUnwrap(phone.store.outboxRows([.sent]).first { $0.actionID == id })
        phone.advance(by: 1)
        try await phone.outbox.applyEcho(echo((id, row.actionSeq), .applied))
        try phone.store.latencyEffect(kind: "workbench", at: phone.now)

        let sample = try XCTUnwrap(samples(phone.store).first)
        XCTAssertEqual(sample.answerMs, 1000, "counted from the save that landed, not from the tap")
    }

    func testANonAppliedEchoDropsTheRow() async throws {
        for status in [ActionStatus.failed, .expired, .cancelled] {
            let phone = try await makePhone()
            let sent = try await send(phone)
            XCTAssertEqual(try pendingCount(phone.store), 1, "\(status)")
            phone.advance(by: 1)
            try await phone.outbox.applyEcho(echo(sent, status))
            XCTAssertEqual(try pendingCount(phone.store), 0, "\(status)")
            try phone.store.latencyEffect(kind: "workbench", at: phone.now)
            XCTAssertEqual(try samples(phone.store), [], "\(status)")
        }
    }

    func testAnUnrelatedSliceDoesNotStamp() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        phone.advance(by: 1)
        try phone.store.latencyEffect(kind: "inbox_item", at: phone.now)
        try phone.store.latencyEffect(kind: "terminal_session", at: phone.now)
        try await phone.outbox.applyEcho(echo(sent, .applied))
        XCTAssertEqual(try samples(phone.store), [], "no slice of an effect kind yet")
        XCTAssertEqual(try pendingCount(phone.store), 1)
    }

    func testAKindWithNoEffectLeavesNoRow() async throws {
        let phone = try await makePhone()
        _ = try await send(phone, .targetDone)
        XCTAssertEqual(try pendingCount(phone.store), 0)
    }

    func testALegacyActionLeavesNoRow() async throws {
        let phone = try await makePhone(ordered: false)
        _ = try await phone.outbox.enqueue(kind: .boardTargetStatus, entityRecordName: "target-42")
        _ = try await phone.outbox.flush()
        XCTAssertEqual(try pendingCount(phone.store), 0)
    }

    // MARK: - Dropped

    func testARouteChangeDropsThePendingRow() async throws {
        let phone = try await makePhone()
        try phone.store.adoptRoute("cloudkit")
        _ = try await send(phone)
        XCTAssertEqual(try pendingCount(phone.store), 1)
        XCTAssertTrue(try phone.store.adoptRoute("relay"))
        XCTAssertEqual(try pendingCount(phone.store), 0)
    }

    func testAResendDropsThePendingRow() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        XCTAssertEqual(try pendingCount(phone.store), 1)
        try await phone.outbox.resendFrom(sent.seq)
        XCTAssertEqual(try pendingCount(phone.store), 0, "the rewrite is not the first save")
        phone.advance(by: 1)
        try await phone.outbox.applyEcho(echo(sent, .applied))
        try phone.store.latencyEffect(kind: "workbench", at: phone.now)
        XCTAssertEqual(try samples(phone.store), [])
    }

    func testAnUnfinishedRowExpiresAfterSixtySeconds() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        phone.advance(by: ReplicaStore.latencyResultWait + 1)
        try await phone.outbox.applyEcho(echo(sent, .applied))
        try phone.store.latencyEffect(kind: "workbench", at: phone.now)
        XCTAssertEqual(try samples(phone.store), [])
        XCTAssertEqual(try pendingCount(phone.store), 0)
    }

    func testARelaunchMidwayFinishesOrExpires() throws {
        let path = NSTemporaryDirectory() + "latency-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let keys = try TestE2E.phoneStore()
        var store: ReplicaStore? = try ReplicaStore(path: path, opener: TestE2E.opener(store: keys))
        try store?.latencyWritten(actionID: "a", kind: "board_target_status", transport: .relay, at: base)
        try store?.latencyWritten(actionID: "b", kind: "board_target_status", transport: .relay, at: base)
        store = nil

        let reopened = try ReplicaStore(path: path, opener: TestE2E.opener(store: keys))
        XCTAssertEqual(try pendingCount(reopened), 2, "the rows live in the file")
        try reopened.latencyAnswered(actionID: "a", applied: true, at: base.addingTimeInterval(2))
        try reopened.latencyEffect(kind: "workbench", at: base.addingTimeInterval(3))
        XCTAssertEqual(try samples(reopened), [
            LatencySample(at: base.addingTimeInterval(3), transport: .relay, answerMs: 2000, resultMs: 3000)
        ])

        try reopened.latencySweep(now: base.addingTimeInterval(ReplicaStore.latencyResultWait + 1))
        XCTAssertEqual(try pendingCount(reopened), 0, "the other row expired")
    }

    func testABackwardClockDropsTheRow() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        phone.advance(by: -30)
        try await phone.outbox.applyEcho(echo(sent, .applied))
        try phone.store.latencyEffect(kind: "workbench", at: phone.now)
        XCTAssertEqual(try samples(phone.store), [])
        XCTAssertEqual(try pendingCount(phone.store), 0)
    }

    func testAResendThatDoesNotLandLeavesNoRow() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        await phone.inner.refuseNext(.unreachable, count: 1)
        try await phone.outbox.resendFrom(sent.seq)
        XCTAssertEqual(try pendingCount(phone.store), 0, "the resend stopped; its round trip must not count")
        phone.advance(by: 1)
        try await phone.outbox.applyEcho(echo(sent, .applied))
        try phone.store.latencyEffect(kind: "workbench", at: phone.now)
        XCTAssertEqual(try samples(phone.store), [])
    }

    func testAPermanentRefusalOfAResendDropsTheRow() async throws {
        let phone = try await makePhone()
        let sent = try await send(phone)
        await phone.inner.refuseNext(.permanent(code: "zoneNotFound"), count: 1)
        try await phone.outbox.resendFrom(sent.seq)
        XCTAssertEqual(try pendingCount(phone.store), 0)
    }

    func testListingUnechoedActionsDropsTheirRows() async throws {
        let phone = try await makePhone()
        _ = try await send(phone)
        XCTAssertEqual(try pendingCount(phone.store), 1)
        _ = try await phone.outbox.listUnechoedAsUndelivered(reason: .refused)
        XCTAssertEqual(try pendingCount(phone.store), 0)
    }

    func testTheLaunchSweepDropsAnExpiredRow() throws {
        let path = NSTemporaryDirectory() + "latency-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let keys = try TestE2E.phoneStore()
        var store: ReplicaStore? = try ReplicaStore(path: path, opener: TestE2E.opener(store: keys))
        let old = base.addingTimeInterval(-ReplicaStore.latencyResultWait - 10)
        // Fresh first: writing it would otherwise expire "old" in the same call, before the store closes.
        try store?.latencyWritten(actionID: "fresh", kind: "board_target_status", transport: .relay, at: base)
        try store?.latencyWritten(actionID: "old", kind: "board_target_status", transport: .relay, at: old)
        store = nil
        let reopened = try ReplicaStore(path: path, opener: TestE2E.opener(store: keys))
        XCTAssertEqual(try pendingCount(reopened), 1, "only the fresh row survives the launch")
    }

    func testRowsIndexedLaterStampTheEffectAtIndexTime() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: try TestE2E.phoneStore()))
        try store.latencyWritten(actionID: "a", kind: "board_target_status", transport: .relay, at: base)
        try store.latencyAnswered(actionID: "a", applied: true, at: base.addingTimeInterval(1))
        let record = AppliedSliceRecord(
            recordName: "workbench-1", kind: .workbench, notifyLevel: nil, modifiedAt: base)
        store.stampLatencyEffects(of: [record], at: base.addingTimeInterval(5))
        XCTAssertEqual(try samples(store), [
            LatencySample(at: base.addingTimeInterval(5), transport: .relay, answerMs: 1000, resultMs: 5000)
        ])
    }

    // MARK: - Storage

    func testPruneKeepsSevenDaysAndFiveThousandRows() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: try TestE2E.phoneStore()))
        let now = base
        try store.reader.asWriter.write { db in
            for i in 0..<5_100 {
                try db.execute(
                    sql: "INSERT INTO latency_samples (at, transport, answer_ms, result_ms) VALUES (?, 'relay', 10, 20)",
                    arguments: [now.addingTimeInterval(-Double(i)).timeIntervalSince1970])
            }
            for i in 0..<10 {
                try db.execute(
                    sql: "INSERT INTO latency_samples (at, transport, answer_ms, result_ms) VALUES (?, 'relay', 10, 20)",
                    arguments: [now.addingTimeInterval(-ReplicaStore.latencyWindow - 100 - Double(i)).timeIntervalSince1970])
            }
        }
        try store.latencySweep(now: now)
        let kept = try store.latencySamples(since: .distantPast)
        XCTAssertEqual(kept.count, ReplicaStore.latencyMaxRows)
        XCTAssertTrue(kept.allSatisfy { $0.at >= now.addingTimeInterval(-ReplicaStore.latencyWindow) })
        XCTAssertEqual(kept.map(\.at).min(), now.addingTimeInterval(-4_999), "the oldest rows went first")
    }

    func testASampleHoldsNoIDOrKind() throws {
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: try TestE2E.phoneStore()))
        let columns = try store.reader.read { db in try db.columns(in: "latency_samples").map(\.name) }
        XCTAssertEqual(columns, ["at", "transport", "answer_ms", "result_ms"])
    }

    func testAStampFailureDoesNotFailTheAction() async throws {
        let phone = try await makePhone()
        try await phone.store.reader.asWriter.write { db in try db.execute(sql: "DROP TABLE latency_pending") }
        let id = try await phone.outbox.enqueue(kind: .boardTargetStatus, entityRecordName: "target-42")
        let report = try await phone.outbox.flush()
        XCTAssertEqual(report.written, 1)
        let row = try XCTUnwrap(phone.store.outboxRows([.sent]).first { $0.actionID == id })
        phone.advance(by: 1)
        try await phone.outbox.applyEcho(echo((id, row.actionSeq), .applied))
        XCTAssertTrue(try phone.store.pendingActions().isEmpty, "the action settled")
    }

    // MARK: - The hydrator and the table

    func testASliceStoredByTheHydratorStampsTheEffect() async throws {
        let keys = try TestE2E.phoneStore()
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let transport = TestE2E.hubTransport()
        let clock = OSAllocatedUnfairLock(initialState: base.addingTimeInterval(4))
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        await hydrator.useClock { clock.withLock { $0 } }
        try store.latencyWritten(actionID: "a", kind: "board_target_status", transport: .cloudKit, at: base)
        try store.latencyAnswered(actionID: "a", applied: true, at: base.addingTimeInterval(1))

        try await transport.save([CloudRecord(
            recordName: SliceKind.target.recordName(id: "3"), zone: .data, kind: SliceKind.target.rawValue,
            modifiedAt: base, payload: Data("{\"id\":3}".utf8))])
        _ = try await hydrator.hydrateOnce()
        XCTAssertEqual(try samples(store), [], "a target slice is no effect of a board write")

        try await transport.save([CloudRecord(
            recordName: SliceKind.workbenchTarget.recordName(id: "3"), zone: .data,
            kind: SliceKind.workbenchTarget.rawValue, modifiedAt: base, payload: Data("{\"id\":3}".utf8))])
        _ = try await hydrator.hydrateOnce()
        XCTAssertEqual(try samples(store), [
            LatencySample(at: base.addingTimeInterval(4), transport: .cloudKit, answerMs: 1000, resultMs: 4000)
        ])
    }

    func testTheEffectTableMatchesTheSharedFixture() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("Fixtures/link/hub_contract_cases.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["action_effect_kinds"] as? [[String: Any]])
        var fixture: [String: [String]] = [:]
        for fixtureCase in cases {
            fixture[try XCTUnwrap(fixtureCase["action_kind"] as? String)] =
                try XCTUnwrap(fixtureCase["slice_kinds"] as? [String])
        }
        XCTAssertEqual(ActionEffectKinds.table, fixture)
        XCTAssertEqual(ActionEffectKinds.kinds(for: "ask_answer"), ["owner_ask", "ask_alert"])
        XCTAssertEqual(ActionEffectKinds.kinds(for: "kind_from_a_newer_build"), [])
    }
}

private extension DatabaseReader {
    var asWriter: any DatabaseWriter {
        guard let writer = self as? any DatabaseWriter else { fatalError("the replica reader is its writer") }
        return writer
    }
}

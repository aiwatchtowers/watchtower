import Foundation
import os
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync

/// The relay side of the hub (mobile POC spec §5.2): exactly-once handling,
/// age, the probe, the kinds the POC refuses, backlog batching and hygiene.
@MainActor
final class RelayProcessorTests: XCTestCase {
    private var transport: StubHubTransport!
    private var sidecar: HubSyncState!
    private var dispatcher: MobileHubCommandDispatcher!

    override func setUp() async throws {
        transport = StubHubTransport()
        sidecar = try HubSyncState.inMemory()
        // Every test action comes from this linked phone (the device gate
        // has its own tests in MobileLinkCenterTests).
        try sidecar.linkTestDevice("device-a")
        dispatcher = MobileHubCommandDispatcher()
    }

    override func tearDown() async throws {
        transport = nil
        sidecar = nil
        dispatcher = nil
    }

    private func makeProcessor(batchLimit: Int = RelayProcessor.defaultBatchLimit) -> RelayProcessor {
        RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: dispatcher,
            hubID: "hub-acme", batchLimit: batchLimit
        )
    }

    /// Every echo the hub wrote for `recordName`, in order.
    private func echoes(of recordName: String) throws -> [ActionRequestPayload] {
        try transport.saved
            .filter { $0.record.recordName == recordName }
            .map { try decodeAction($0.record) }
            .filter { $0.status != .pending }
    }

    // MARK: - Probe

    func testProbeDeliveredTwiceEchoesTheSameAppliedNonceAndHubID() async throws {
        let record = try pendingActionRecord(kind: .probe, params: ["nonce": .string("n-1")])
        try await transport.save([record])
        let processor = makeProcessor()

        _ = try await processor.processOnce()
        // The same pending record arrives again (the phone's save won over the echo).
        try await transport.save([record])
        _ = try await processor.processOnce()

        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.count, 2, "a done probe read pending again is re-echoed")
        XCTAssertEqual(echoes.map(\.status), [.applied, .applied])
        XCTAssertEqual(echoes.map(\.result), Array(repeating: ["nonce": .string("n-1"), "hub_id": .string("hub-acme")], count: 2))
        XCTAssertEqual(try sidecar.relayPhase(record.recordName), .done)
    }

    func testProbeWithoutNonceFailsInvalidParams() async throws {
        let record = try pendingActionRecord(kind: .probe)
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .invalidParams)
    }

    // MARK: - Exactly-once (§5.2 rule 1)

    func testNonIdempotentKindIsMarkedBegunBeforeItsHandlerRuns() async throws {
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        var phaseInHandler: HubSyncState.RelayPhase?
        var calls = 0
        dispatcher.register(.boardCommentAdd) { [sidecar] _ in
            calls += 1
            phaseInHandler = try sidecar?.relayPhase(record.recordName)
            return .applied(["comment_id": .integer(42)])
        }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1, "a non-idempotent kind is applied once")
        XCTAssertEqual(phaseInHandler, .begun, "`begun` is committed before the write")
        XCTAssertEqual(try sidecar.relayPhase(record.recordName), .done)
        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.status, .applied)
        XCTAssertEqual(echo.result, ["comment_id": .integer(42)])
    }

    func testIdempotentKindIsNotMarkedBegun() async throws {
        let record = try pendingActionRecord(kind: .boardTargetStatus, entityID: "7")
        var phaseInHandler: HubSyncState.RelayPhase?
        dispatcher.register(.boardTargetStatus) { [sidecar] _ in
            phaseInHandler = try sidecar?.relayPhase(record.recordName)
            return .applied(["status": .string("done")])
        }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertNil(phaseInHandler, "an idempotent kind simply re-runs, it is never `begun`")
        XCTAssertEqual(try sidecar.relayPhase(record.recordName), .done)
    }

    func testRecordFoundBegunAtStartFailsOutcomeUnknownAndIsNeverApplied() async throws {
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        try await transport.save([record])
        // The previous run crashed between `begun` and `done`.
        try sidecar.markRelayBegun(record.recordName, at: Date())

        _ = try await makeProcessor().processOnce()
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0, "an interrupted apply is never re-run")
        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.count, 2, "the second read re-echoes the stored outcome")
        XCTAssertEqual(echoes.map(\.status), [.failed, .failed])
        XCTAssertEqual(echoes.map(\.reason), [.outcomeUnknown, .outcomeUnknown])
        XCTAssertEqual(try sidecar.relayPhase(record.recordName), .done)
    }

    func testADoneActionReadPendingAgainIsReEchoedFromTheStoredOutcomeWithoutDispatching() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied(["comment_id": .integer(42)])
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        // A lost ack: the phone re-saved its pending copy and that save won.
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1, "a re-echo never dispatches again")
        let written = try echoes(of: record.recordName)
        XCTAssertEqual(written.map(\.status), [.applied, .applied])
        XCTAssertEqual(written.last?.result, ["comment_id": .integer(42)], "the same comment, not a second one")
        let stored = try await transport.changes(in: .relay, since: nil).changed.first { $0.recordName == record.recordName }
        XCTAssertEqual(try decodeAction(try XCTUnwrap(stored)).status, .applied, "the record reads applied again")

        // Its own echo read back is no work.
        _ = try await makeProcessor().processOnce()
        XCTAssertEqual(try echoes(of: record.recordName).count, 2)
    }

    /// CloudKit never buffers the hub's own echo: a re-read (a pass that
    /// left a backlog, a reset rewinding the cursor) still shows the phone's
    /// `pending` save of every action already done. Those stale copies are
    /// no work, so the backlog drains; a later phone save is re-echoed
    /// outside the batch budget.
    func testOwnStaleBufferedCopiesAreNotReEchoedAndNeverStallTheBacklog() async throws {
        let buffer = PhoneOnlyBuffer()
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied(["comment_id": .integer(42)])
        }
        let records = try (0..<2).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await buffer.phone.save(records)
        let processor = RelayProcessor(
            transport: buffer, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme", batchLimit: 1
        )

        var passes = [try await processor.processOnce()]
        while let last = passes.last, last.remaining > 0, passes.count < 5 {
            passes.append(try await processor.processOnce())
        }

        XCTAssertEqual(passes.map(\.remaining), [1, 0], "the second pass finishes the backlog")
        XCTAssertEqual(calls, 2)
        let echoed = await buffer.echoes.map(\.recordName)
        XCTAssertEqual(echoed.sorted(), records.map(\.recordName).sorted(), "one echo each")
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "the token advances")

        try sidecar.wipeSyncState(now: Date())  // an account reset rewinds the relay cursor
        _ = try await processor.processOnce()
        let afterReset = await buffer.echoes.count
        XCTAssertEqual(afterReset, 2, "a re-read from the start re-echoes nothing")

        // A lost ack: the phone saves its pending copy again.
        try await buffer.phone.save([records[0]])
        let pass = try await processor.processOnce()
        XCTAssertEqual(pass.remaining, 0, "a re-echo never takes the batch budget")
        let after = await buffer.echoes.map(\.recordName)
        XCTAssertEqual(after.filter { $0 == records[0].recordName }.count, 2, "the later phone save is re-echoed")
        XCTAssertEqual(calls, 2)
    }

    func testADoneActionStuckAtReceivedIsReEchoedWithItsFinalOutcome() async throws {
        var calls = 0
        dispatcher.register(.sessionStart) { _ in
            calls += 1
            return .applied(["stage": .string("starting")])
        }
        let record = try pendingActionRecord(kind: .sessionStart, entityID: "7")
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        // Only the `received` echo reached the server; the final one was lost.
        var received = try decodeAction(record)
        received.status = .received
        try await transport.save([try CloudRecordFactory.record(for: received, modifiedAt: Date())])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1)
        let last = try XCTUnwrap(try echoes(of: record.recordName).last)
        XCTAssertEqual(last.status, .applied)
        XCTAssertEqual(last.result, ["stage": .string("starting")])
    }

    func testADoneLedgerRowWithoutAStoredEchoIsSkipped() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        // A row written before the ledger kept echoes.
        try sidecar.markRelayDone(record.recordName, outcome: "applied", at: Date())
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try echoes(of: record.recordName).isEmpty, "nothing stored, nothing to re-echo")
    }

    func testASidecarWithoutTheEchoColumnGainsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayLedger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hubstate.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE relay_processed (
                    record_name TEXT PRIMARY KEY,
                    phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')),
                    outcome TEXT,
                    updated_at REAL NOT NULL DEFAULT 0
                );
                INSERT INTO relay_processed (record_name, phase, outcome, updated_at) VALUES ('action-old', 'done', 'applied', 1);
                """)
        }

        let reopened = try HubSyncState(path: path)

        XCTAssertEqual(try reopened.relayPhase("action-old"), .done)
        XCTAssertNil(try reopened.relayEcho("action-old"))
        try reopened.markRelayDone("action-new", outcome: "applied", echo: Data("{}".utf8), at: Date())
        XCTAssertEqual(try reopened.relayEcho("action-new"), Data("{}".utf8))
        // A second open over the migrated file is a no-op.
        XCTAssertEqual(try HubSyncState(path: path).relayEcho("action-new"), Data("{}".utf8))
    }

    /// Two instances opening an old file at once (a relaunch overlap) both
    /// open: the upgrade runs in an IMMEDIATE transaction.
    func testConcurrentOpensOfAnOldSidecarAllSucceed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RelayLedger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hubstate.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE relay_processed (
                    record_name TEXT PRIMARY KEY,
                    phase TEXT NOT NULL CHECK (phase IN ('begun', 'done')),
                    outcome TEXT,
                    updated_at REAL NOT NULL DEFAULT 0
                );
                INSERT INTO relay_processed (record_name, phase, outcome, updated_at) VALUES ('action-old', 'done', 'applied', 1);
                """)
        }
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                _ = try HubSyncState(path: path)
            } catch {
                failures.withLock { $0.append(error.localizedDescription) }
            }
        }

        XCTAssertEqual(failures.withLock { $0 }, [])
        let reopened = try HubSyncState(path: path)
        XCTAssertNil(try reopened.relayDoneSeq("action-old"), "an old row holds no buffer mark")
        try reopened.markRelayDone("action-new", outcome: "applied", doneSeq: 7, at: Date())
        XCTAssertEqual(try reopened.relayDoneSeq("action-new"), 7)
    }

    func testReceivedIsEchoedBeforeTheHandlerForStartLikeKinds() async throws {
        let record = try pendingActionRecord(kind: .sessionStart, entityID: "7")
        var echoesInHandler: [ActionStatus] = []
        dispatcher.register(.sessionStart) { [weak self] _ in
            echoesInHandler = try self?.echoes(of: record.recordName).map(\.status) ?? []
            return .applied(["stage": .string("starting")])
        }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(echoesInHandler, [.received], "the phone sees `received` before any work")
        XCTAssertEqual(try echoes(of: record.recordName).map(\.status), [.received, .applied])
    }

    func testThrowingHandlerFailsWriteFailed() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "disk on fire" } }
        let record = try pendingActionRecord(kind: .boardTargetPriority, entityID: "7")
        dispatcher.register(.boardTargetPriority) { _ in throw Boom() }
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        let echo = try XCTUnwrap(try echoes(of: record.recordName).first)
        XCTAssertEqual(echo.status, .failed)
        XCTAssertEqual(echo.reason, .writeFailed)
        XCTAssertEqual(echo.errorMessage, "disk on fire")
    }

    // MARK: - Age (§5.2 rule 5)

    func testActionOlderThanSevenDaysExpiresAndSixDaysOldIsApplied() async throws {
        let now = Date()
        let stale = try pendingActionRecord(
            kind: .probe, params: ["nonce": .string("old")], age: 7 * 86_400 + 1, now: now
        )
        let fresh = try pendingActionRecord(
            kind: .probe, params: ["nonce": .string("new")], age: 6 * 86_400, now: now
        )
        try await transport.save([stale, fresh])
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme"
        ) { now }

        _ = try await processor.processOnce()

        let staleEcho = try XCTUnwrap(try echoes(of: stale.recordName).first)
        XCTAssertEqual(staleEcho.status, .expired)
        XCTAssertEqual(staleEcho.reason, .expired)
        XCTAssertEqual(try echoes(of: fresh.recordName).first?.status, .applied)
    }

    func testSessionRequestsExpireAfterADay() async throws {
        let now = Date()
        let stale = try pendingActionRecord(kind: .sessionInput, entityID: "7", age: 86_400 + 1, now: now)
        var calls = 0
        dispatcher.register(.sessionInput) { _ in
            calls += 1
            return .applied()
        }
        try await transport.save([stale])
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme"
        ) { now }

        _ = try await processor.processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try echoes(of: stale.recordName).first?.status, .expired)
    }

    // MARK: - Kinds the POC refuses

    func testDKindsAndKindsWithoutAHandlerFailUnsupportedInPOC() async throws {
        let records = try [ActionKind.taskCreate, .targetDone, .targetSnooze, .askAnswer].map {
            try pendingActionRecord(kind: $0, entityID: "1")
        }
        try await transport.save(records)

        _ = try await makeProcessor().processOnce()

        for record in records {
            let echo = try XCTUnwrap(try echoes(of: record.recordName).first, record.recordName)
            XCTAssertEqual(echo.status, .failed, record.recordName)
            XCTAssertEqual(echo.reason, .unsupportedInPOC, record.recordName)
        }
    }

    func testDKindsAreRefusedEvenWithAHandler() async throws {
        var calls = 0
        dispatcher.register(.taskCreate) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(kind: .taskCreate)
        try await transport.save([record])

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try echoes(of: record.recordName).first?.reason, .unsupportedInPOC)
    }

    // MARK: - Backlog after a long sleep (Review focus 5)

    func testFiveHundredPendingRecordsAreProcessedInBatchesOfTwoHundred() async throws {
        let records = try (0..<500).map {
            try pendingActionRecord(kind: .probe, params: ["nonce": .string("n-\($0)")])
        }
        try await transport.save(records)
        let processor = makeProcessor()
        XCTAssertEqual(RelayProcessor.defaultBatchLimit, 200)

        var passes: [RelayProcessor.Pass] = []
        var backlogs: [Int] = []
        repeat {
            passes.append(try await processor.processOnce())
            backlogs.append(processor.relayBacklog)
        } while passes.last?.remaining ?? 0 > 0 && passes.count < 10

        XCTAssertEqual(passes.map(\.handled), [200, 200, 100])
        XCTAssertEqual(backlogs, [300, 100, 0], "relay_backlog counts down to 0")
        for record in records {
            let echoes = try echoes(of: record.recordName)
            XCTAssertEqual(echoes.map(\.status), [.applied], "\(record.recordName) is echoed exactly once")
        }
        // A further pass finds nothing: the token moved past the batch.
        let idle = try await processor.processOnce()
        XCTAssertEqual(idle.handled, 0)
        XCTAssertEqual(idle.remaining, 0)
    }

    // MARK: - Hygiene

    func testHygieneDeletesAgedEchoesAndKeepsPendingAndFresh() async throws {
        let now = Date()
        var applied = ActionRequestPayload(id: "old-echo", kind: .probe, entityID: nil, createdAt: now)
        applied.status = .applied
        let agedEcho = try CloudRecordFactory.record(for: applied, modifiedAt: now.addingTimeInterval(-8 * 86_400))
        let agedPending = try pendingActionRecord(id: "old-pending", kind: .probe, age: 8 * 86_400, now: now)
        let fresh = try pendingActionRecord(id: "fresh", kind: .probe, age: 60, now: now)
        try await transport.save([agedEcho, agedPending, fresh])
        try sidecar.markRelayDone("action-ancient", outcome: "applied", at: now.addingTimeInterval(-9 * 86_400))
        let processor = RelayProcessor(
            transport: transport, sidecar: sidecar, dispatcher: dispatcher, hubID: "hub-acme"
        ) { now }

        try await processor.runHygieneIfDue()

        let names = Set(try await transport.changes(in: .relay, since: nil).changed.map(\.recordName))
        XCTAssertFalse(names.contains(agedEcho.recordName), "an aged echo is deleted")
        XCTAssertTrue(names.contains(agedPending.recordName), "an unprocessed pending record waits for its echo")
        XCTAssertTrue(names.contains(fresh.recordName))
        XCTAssertNil(try sidecar.relayPhase("action-ancient"), "the processed set is pruned past the window")
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.hygieneStampKey))
    }

    // MARK: - One pass at a time (I-3)

    func testConcurrentPassesApplyEachNonIdempotentRecordOnce() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            return .applied()
        }
        let records = try (0..<3).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await transport.save(records)
        let processor = makeProcessor()

        let first = Task { try await processor.processOnce() }
        let second = Task { try await processor.processOnce() }
        await awaitHubCondition("a pass is inside the handler") { latch.entries == 1 }
        latch.release()
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(latch.calls.count, 3)
        XCTAssertTrue(latch.calls.values.allSatisfy { $0 == 1 }, "each record is applied once: \(latch.calls)")
    }

    func testTwoProcessorsSharingTheSidecarApplyEachRecordOnce() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            return .applied()
        }
        let records = try (0..<3).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await transport.save(records)
        let old = makeProcessor()
        let rebuilt = makeProcessor()

        let first = Task { try await old.processOnce() }
        let second = Task { try await rebuilt.processOnce() }
        await awaitHubCondition("a pass is inside the handler") { latch.entries == 1 }
        latch.release()
        _ = try await first.value
        _ = try await second.value

        XCTAssertTrue(latch.calls.values.allSatisfy { $0 == 1 }, "\(latch.calls)")
        XCTAssertEqual(latch.calls.count, 3)
    }

    func testClaimIsAtomic() throws {
        XCTAssertTrue(try sidecar.claimRelay("action-x", at: Date()))
        XCTAssertFalse(try sidecar.claimRelay("action-x", at: Date()), "a second claim of the same record fails")
        XCTAssertEqual(try sidecar.relayPhase("action-x"), .begun)
    }

    func testCancellationStopsThePassBetweenRecordsNeverMidApply() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { action in
            await latch.enter(action)
            // A cancellation-aware await inside the apply, as GRDB's async
            // write or a sleep would be.
            try Task.checkCancellation()
            return .applied(["comment_id": .integer(1)])
        }
        let records = try (0..<2).map { _ in try pendingActionRecord(kind: .boardCommentAdd, entityID: "7") }
        try await transport.save(records)
        let processor = makeProcessor()

        let pass = Task { try await processor.processOnce() }
        await awaitHubCondition("the first record is inside the handler") { latch.entries == 1 }
        pass.cancel()
        latch.release()

        do {
            _ = try await pass.value
            XCTFail("a cancelled pass throws")
        } catch is CancellationError {}
        XCTAssertEqual(latch.entries, 1, "the record being applied finishes; the next one is left")
        let done = try records.filter { try sidecar.relayPhase($0.recordName) == .done }
        XCTAssertEqual(done.count, 1, "the applied record is done; the other is untouched")
        let echo = try XCTUnwrap(try echoes(of: try XCTUnwrap(done.first).recordName).last)
        XCTAssertEqual(echo.status, .applied, "a stop never reaches into the apply")
        XCTAssertNil(echo.reason)

        // The next pass picks up the record that was left, once.
        _ = try await processor.processOnce()
        XCTAssertEqual(latch.calls.count, 2)
        XCTAssertTrue(latch.calls.values.allSatisfy { $0 == 1 })
    }

    // MARK: - Account reset (I-3, spec §9)

    func testAccountResetKeepsTheLedgerSoADoneRecordIsNotReapplied() async throws {
        var calls = 0
        dispatcher.register(.boardCommentAdd) { _ in
            calls += 1
            return .applied()
        }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7")
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        try sidecar.wipeSyncState(now: Date())
        // Same Apple ID back: the zone is re-fetched and the echo never landed.
        try await transport.save([record])
        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(calls, 1, "a reset never re-applies a done record")
        XCTAssertEqual(try sidecar.relayPhase(record.recordName), .done)
        XCTAssertEqual(try echoes(of: record.recordName).map(\.status), [.applied, .applied], "at most a re-echo")
    }
}

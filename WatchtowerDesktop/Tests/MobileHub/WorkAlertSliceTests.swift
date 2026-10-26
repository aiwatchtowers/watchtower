import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerE2ETesting
import WatchtowerSync
import WatchtowerTestSupport

/// The work alerts (spec 2026-10-25-mobile-workbench-remote §5.2): one sealed `ask_alert` per stop of work, pushed
/// only while the owner is away, a stop left unresolved at the Mac pushed once on leaving, never twice; deleted when
/// the stop resolves or 7 days after its push; nothing older than `enabled_at`; an account reset never alerts the
/// new zone for an alert pushed before.
final class WorkAlertSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    // A whole second, so a stamp 7 days later round-trips the sidecar's
    // seconds-since-1970 REAL exactly at the lifetime boundary.
    private let clock = OSAllocatedUnfairLock(
        initialState: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    )
    private let away = OSAllocatedUnfairLock(initialState: true)
    private let live = OSAllocatedUnfairLock(initialState: SessionLiveness())
    private let day: TimeInterval = 86_400
    private var enabledAt: Date!
    /// When the live sessions' runs started (the hook stamps are trusted after it).
    private var started: Date!

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        sidecar = try HubSyncState.inMemory()
        enabledAt = try HubIdentity(sidecar: sidecar).ensureEnabledAt(now.addingTimeInterval(-3600))
        started = now.addingTimeInterval(-600)
        // A hub whose work alerts have run since its enable (an upgraded one is tested on its own).
        try sidecar.setMetaValue(String(enabledAt.timeIntervalSince1970), forKey: WorkAlertSlice.startedAtKey)
    }

    override func tearDownWithError() throws {
        dbPool = nil
        sidecar = nil
        TestDatabase.cleanup(path: dbPath)
    }

    // MARK: - Helpers

    private var now: Date { clock.withLock { $0 } }

    private func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    private func setAway(_ value: Bool) {
        away.withLock { $0 = value }
    }

    private func setLive(_ ids: Set<Int64>) {
        let started: Date = started
        live.withLock { $0 = SessionLiveness(liveIDs: ids, startedAt: Dictionary(uniqueKeysWithValues: ids.map { ($0, started) })) }
    }

    private func slice() -> WorkAlertSlice {
        let clock = self.clock, away = self.away, live = self.live
        return WorkAlertSlice(
            sidecar: sidecar, isAway: { away.withLock { $0 } }, liveness: { live.withLock { $0 } }, now: { clock.withLock { $0 } }
        )
    }

    private func alerts() throws -> [WorkAlertPayload] {
        let slice = slice()
        return try dbPool.read { try slice.records($0) }.map { try JSONDecoder().decode(WorkAlertPayload.self, from: $0.payload) }
    }

    private func publisher(_ transport: StubHubTransport) -> SlicePublisher {
        let clock = self.clock
        // Labelled: a trailing closure would bind to `clock`, the first closure parameter.
        return SlicePublisher(
            dbPool: dbPool, state: sidecar, transport: transport.sealing(names: sidecar), sources: [slice()],
            now: { clock.withLock { $0 } } // swiftlint:disable:this trailing_closure
        )
    }

    /// The plain names of the alerts saved, opened by the paired phone.
    private func savedAlerts(_ transport: StubHubTransport) throws -> [String] {
        try transport.openedSaves().map(\.record.recordName).filter { $0.hasPrefix("ask_alert-") }
    }

    private func signals(_ transport: StubHubTransport) -> Int {
        transport.saved.map(\.record).filter { $0.kind == WireKind.signal }.count
    }

    private func wireName(_ plain: String) throws -> String {
        try testSecureTransport(InMemoryCloudTransport()).wireName(plain: plain, zone: .data)
    }

    private func workbench(name: String = "acme") throws -> Int64 {
        try dbPool.write { try TestDatabase.insertWorkbench($0, name: name) }
    }

    @discardableResult
    private func ask(
        in project: Int64,
        createdAt: Date? = nil,
        title: String = "Which way?",
        kind: String = "question",
        payload: String = "{}",
        sessionID: Int64? = nil
    ) throws -> Int64 {
        let created = dbStamp(createdAt ?? now)
        return try dbPool.write {
            try TestDatabase.insertOwnerAsk(
                $0, projectID: project, sessionID: sessionID, kind: kind, title: title, payload: payload, createdAt: created
            )
        }
    }

    private func session(in project: Int64) throws -> Int64 {
        try dbPool.write { try SliceSeed.insertSession($0, projectID: project) }
    }

    /// Go's hook stamp format (UTC, milliseconds).
    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// The session's hook state entered at `at`; `finished` also stamps `finished_at`, `failedError` a failed turn.
    private func setState(_ id: Int64, state: String?, at: Date, finished: Bool = false, failedError: String? = nil) throws {
        let at = stamp(at)
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?, finished_at = ?,
                        agent_failed_at = ?, agent_error = ? WHERE id = ?
                    """,
                arguments: [state, state == nil ? nil : at, finished ? at : nil, failedError == nil ? nil : at, failedError ?? "", id]
            )
        }
    }

    @discardableResult
    private func request(session: Int64, workbench: Int64, tool: String = "Bash") throws -> Int64 {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
                    VALUES (?, ?, ?, 'git push', 'pending', ?)
                    """,
                arguments: [session, workbench, tool, SessionAgentStatus.formatStamp(now)]
            )
            return db.lastInsertedRowID
        }
    }

    private func answer(_ askID: Int64) throws {
        try dbPool.write {
            try $0.execute(sql: "UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?", arguments: [askID])
        }
    }

    // MARK: - The away gate

    func testAtTheMacNothingIsPublished() throws {
        setAway(false)
        let id = try ask(in: try workbench())

        XCTAssertEqual(try alerts(), [])
        let mark = try XCTUnwrap(try sidecar.noteWorkAlerts([], at: now).marks[WorkAlertKey.ask(id)], "seen")
        XCTAssertNil(mark.pushedAt, "seen at the Mac, not pushed")
    }

    func testGoingAwayPublishesTheStillOpenAsk() async throws {
        setAway(false)
        let id = try ask(in: try workbench())
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()
        XCTAssertEqual(try savedAlerts(transport), [])

        advance(300)
        setAway(true)
        try await publisher.publishOnce()

        XCTAssertEqual(try savedAlerts(transport), ["ask_alert-ask-\(id)"])
        XCTAssertEqual(signals(transport), 1)
    }

    func testASecondAwayPeriodDoesNotRepushTheSameAsk() async throws {
        let id = try ask(in: try workbench())
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()
        setAway(false)
        advance(60)
        try await publisher.publishOnce()
        XCTAssertEqual(try alerts().map(\.key), ["ask-\(id)"], "a pushed alert stays while the ask is open")

        setAway(true)
        advance(60)
        try await publisher.publishOnce()

        XCTAssertEqual(try savedAlerts(transport), ["ask_alert-ask-\(id)"], "pushed once")
        XCTAssertEqual(signals(transport), 1)
    }

    func testAResolvedStopSeenAtTheMacNeverPushes() throws {
        setAway(false)
        let id = try ask(in: try workbench())
        XCTAssertEqual(try alerts(), [])
        try answer(id)

        setAway(true)
        XCTAssertEqual(try alerts(), [])
    }

    // MARK: - No push storm (spec §4)

    func testAnUpgradedHubDoesNotPushOldStops() throws {
        try sidecar.removeMetaValue(forKey: WorkAlertSlice.startedAtKey)
        let project = try workbench()
        let finished = try session(in: project)
        try setState(finished, state: nil, at: now.addingTimeInterval(-120), finished: true)
        let stopped = try session(in: project)
        setLive([stopped])
        try setState(stopped, state: "approval", at: now.addingTimeInterval(-60))
        try request(session: stopped, workbench: project)
        try dbPool.write { try $0.execute(sql: "UPDATE permission_requests SET created_at = ?", arguments: [dbStamp(now.addingTimeInterval(-60))]) }

        XCTAssertEqual(try alerts(), [], "work from before the first pass never alerts")

        // The positive control: a stop after the start still alerts.
        advance(30)
        try setState(finished, state: "waiting", at: now)
        setLive([stopped, finished])
        advance(30)
        XCTAssertEqual(try alerts().map(\.sessionID), [finished])
    }

    func testAStaleSuppressedStopDoesNotPushOnDeparture() throws {
        setAway(false)
        let session = try session(in: try workbench())
        try setState(session, state: nil, at: now.addingTimeInterval(-60), finished: true)
        XCTAssertEqual(try alerts(), [])

        advance(31 * 60 - 60)
        setAway(true)

        XCTAssertEqual(try alerts(), [])
        advance(3600)
        XCTAssertEqual(try alerts(), [], "nor later in the same away period")
    }

    func testARecentSuppressedStopPushesOnDeparture() throws {
        setAway(false)
        let session = try session(in: try workbench())
        try setState(session, state: nil, at: now.addingTimeInterval(-60), finished: true)
        XCTAssertEqual(try alerts(), [])

        advance(29 * 60 - 60)
        setAway(true)

        XCTAssertEqual(try alerts().map(\.body), ["Finished"])
    }

    func testAnOldOpenAskStillPushesOnDeparture() throws {
        setAway(false)
        let id = try ask(in: try workbench())
        XCTAssertEqual(try alerts(), [])

        advance(5 * 3600)
        setAway(true)

        XCTAssertEqual(try alerts().map(\.askID), [id])
    }

    func testTheDepartureIsTheFirstAwayPassAndClearsOnReturn() throws {
        setAway(false)
        XCTAssertEqual(try alerts(), [])
        XCTAssertNil(try sidecar.metaValue(forKey: WorkAlertSlice.awaySinceKey))
        setAway(true)
        let left = now
        _ = try alerts()
        advance(60)
        _ = try alerts()
        XCTAssertEqual(try sidecar.metaValue(forKey: WorkAlertSlice.awaySinceKey), String(left.timeIntervalSince1970))
        setAway(false)
        _ = try alerts()
        XCTAssertNil(try sidecar.metaValue(forKey: WorkAlertSlice.awaySinceKey))
    }

    // MARK: - One stop, one push

    func testAWaitingOnAskSessionPushesOnlyTheAsk() throws {
        let project = try workbench()
        let session = try session(in: project)
        let id = try ask(in: project, sessionID: session)

        let result = try alerts()

        XCTAssertEqual(result.map(\.event), [.ask])
        XCTAssertEqual(result.first?.askID, id)
        XCTAssertEqual(result.first?.title, "acme · Session")
        XCTAssertEqual(result.first?.body, "Which way?")
    }

    func testReadyToCheckPushesAsItsAsk() throws {
        let project = try workbench()
        let session = try session(in: project)
        try setState(session, state: nil, at: now.addingTimeInterval(-120), finished: true)
        let id = try ask(in: project, kind: "check", sessionID: session)

        XCTAssertEqual(try alerts().map(\.key), [WorkAlertKey.ask(id)])
    }

    /// One stop, one push: answering the check ask of a finished session (which does not resume it) leaves the
    /// session Finished at the same moment; that stop was the ask's and does not push again.
    func testAnAnsweredAsksStopDoesNotPushAgain() throws {
        let project = try workbench()
        let session = try session(in: project)
        try setState(session, state: nil, at: now.addingTimeInterval(-120), finished: true)
        let id = try ask(in: project, kind: "check", sessionID: session)
        XCTAssertEqual(try alerts().map(\.key), [WorkAlertKey.ask(id)])

        try answer(id)
        advance(60)

        XCTAssertEqual(try alerts(), [])
    }

    func testNeedsApprovalPushesOnlyTheRequest() throws {
        let project = try workbench()
        let session = try session(in: project)
        setLive([session])
        try setState(session, state: "approval", at: now.addingTimeInterval(-60))
        let id = try request(session: session, workbench: project)

        let result = try alerts()

        XCTAssertEqual(result.map(\.event), [.permission])
        XCTAssertEqual(result.first?.key, WorkAlertKey.permission(id))
        XCTAssertEqual(result.first?.requestID, id)
        XCTAssertEqual(result.first?.body, "Needs approval: Bash")
        XCTAssertEqual(result.first?.title, "acme · Session")
    }

    func testAStopUnder20sDoesNotPush() throws {
        let session = try session(in: try workbench())
        setLive([session])
        try setState(session, state: "waiting", at: now.addingTimeInterval(-19))

        XCTAssertEqual(try alerts(), [])
    }

    func testAStopHeld20sPushes() throws {
        let session = try session(in: try workbench())
        setLive([session])
        let stateAt = now.addingTimeInterval(-20)
        try setState(session, state: "waiting", at: stateAt)

        let result = try alerts()

        XCTAssertEqual(result.map(\.event), [.sessionStopped])
        XCTAssertEqual(result.first?.body, "Waiting for you")
        XCTAssertEqual(result.first?.sessionID, session)
        XCTAssertEqual(result.first?.key, WorkAlertKey.stop(session: session, stateAt: stateAt), "the Kit's key (dual path)")
    }

    func testFinishedSaysFinished() throws {
        let session = try session(in: try workbench())
        try setState(session, state: nil, at: now.addingTimeInterval(-120), finished: true)

        let result = try alerts()

        XCTAssertEqual(result.map(\.event), [.sessionStopped])
        XCTAssertEqual(result.first?.body, "Finished")
    }

    func testFailedPushesSessionFailed() throws {
        let session = try session(in: try workbench())
        setLive([session])
        try setState(session, state: "waiting", at: now.addingTimeInterval(-60), failedError: "rate_limit")

        let result = try alerts()

        XCTAssertEqual(result.map(\.event), [.sessionFailed])
        XCTAssertEqual(result.first?.body, "Failed")
    }

    func testAStopThatWorksAgainDropsItsRecord() async throws {
        let session = try session(in: try workbench())
        setLive([session])
        try setState(session, state: "waiting", at: now.addingTimeInterval(-60))
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()
        XCTAssertEqual(try savedAlerts(transport).count, 1)

        try setState(session, state: "working", at: now)
        let outcome = try await publisher.publishOnce()

        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(try alerts(), [])
    }

    func testNothingBeforeEnabledAt() throws {
        let project = try workbench()
        try ask(in: project, createdAt: enabledAt.addingTimeInterval(-60))
        let finished = try session(in: project)
        try setState(finished, state: nil, at: enabledAt.addingTimeInterval(-60), finished: true)

        XCTAssertEqual(try alerts(), [])
        XCTAssertEqual(try sidecar.noteWorkAlerts([], at: now).marks, [:], "old work is never remembered")
    }

    // MARK: - Restart, republish, deletion

    func testAHubRestartRepublishesWithoutNewSignals() async throws {
        let project = try workbench(name: "acme")
        let id = try ask(in: project)
        let transport = StubHubTransport()
        try await publisher(transport).publishOnce()

        // A rebuilt hub over the same sidecar: the alert is known as published.
        let rebuilt = publisher(transport)
        advance(30)
        try await rebuilt.publishOnce()
        XCTAssertEqual(try savedAlerts(transport), ["ask_alert-ask-\(id)"], "nothing new to save")

        // A changed payload is saved again under the same name, with no second signal.
        try await dbPool.write { try $0.execute(sql: "UPDATE projects SET name = 'beta' WHERE id = ?", arguments: [project]) }
        let outcome = try await rebuilt.publishOnce()

        XCTAssertEqual(outcome.pushed, 1)
        XCTAssertEqual(try savedAlerts(transport), ["ask_alert-ask-\(id)", "ask_alert-ask-\(id)"])
        XCTAssertEqual(signals(transport), 1, "the signal is written when the alert first reaches the zone")
    }

    func testAnsweredAskDropsItsRecord() async throws {
        let id = try ask(in: try workbench(), title: "Ship the acme release?")
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()

        let wire = try wireName(SliceKind.askAlert.recordName(id: WorkAlertKey.ask(id)))
        let zone = try await transport.changes(in: .data, since: nil).changed
        let alert = try XCTUnwrap(zone.first { $0.recordName == wire })
        XCTAssertEqual(alert.kind, WireKind.envelope)
        XCTAssertNil(alert.payload.range(of: Data("acme".utf8)), "no title in the clear")
        let context = EnvelopeContext(zone: .data, wireName: wire)
        let verifier = TestE2E.hubSigningKey.publicKey
        let opened = try EnvelopeSealer.openSymmetric(
            alert.payload, accepting: [.alert], context: context, verifier: verifier
        ) { _ in TestE2E.alertKey(epoch: 1) }
        XCTAssertEqual(opened.frame.kind, SliceKind.askAlert.rawValue)
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(
            alert.payload, accepting: [.alert], context: context, verifier: verifier
        ) { _ in TestE2E.dataKey(epoch: 1) }, "K_data does not open an alert")
        let signalName = AskAlertSignal.signalName(forAlertWireName: wire)
        XCTAssertNotNil(zone.first { $0.recordName == signalName }, "the signal record exists")

        try answer(id)
        let outcome = try await publisher.publishOnce()

        XCTAssertEqual(outcome.deleted, 1)
        let after = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(after.changed.isEmpty, "the alert and its signal are gone")
        XCTAssertEqual(Set(after.deletedRecordNames), [wire, signalName])
    }

    func testAnAlertOlderThan7DaysIsDeletedAndNeverRaisedAgain() async throws {
        let id = try ask(in: try workbench())
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()

        advance(7 * day)
        XCTAssertEqual(try alerts().map(\.askID), [id], "exactly 7 days after the push is kept")
        advance(1)
        let outcome = try await publisher.publishOnce()

        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(try alerts(), [], "still open, but pushed once already")
        XCTAssertEqual(try savedAlerts(transport), ["ask_alert-ask-\(id)"])
    }

    func testAResolvedStopsRowIsPrunedAfter7Days() throws {
        let project = try workbench()
        let id = try ask(in: project)
        _ = try alerts()
        try dbPool.write { try $0.execute(sql: "UPDATE owner_asks SET status = 'withdrawn' WHERE id = ?", arguments: [id]) }
        let open = try ask(in: project)
        _ = try alerts()

        advance(7 * day + 1)
        _ = try alerts()

        XCTAssertEqual(
            Set(try sidecar.noteWorkAlerts([], at: now).marks.keys), [WorkAlertKey.ask(open)],
            "an open ask stays remembered, a closed one is forgotten"
        )
    }

    // MARK: - Account reset

    func testAnAccountResetRaisesNoAlertForPushedWork() async throws {
        let project = try workbench()
        try ask(in: project)
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()

        try sidecar.wipeSyncState(now: now)
        let before = try savedAlerts(transport).count
        try await publisher.publishOnce()
        XCTAssertEqual(try savedAlerts(transport).count, before, "the new zone gets no alert for an old ask")

        // The positive control: an ask filed after the reset still alerts.
        advance(10)
        let fresh = try ask(in: project)
        try await publisher.publishOnce()
        XCTAssertEqual(try savedAlerts(transport).dropFirst(before), ["ask_alert-ask-\(fresh)"])
    }

    func testAnAlertNeverConfirmedPublishedIsRaisedAfterAReset() async throws {
        let id = try ask(in: try workbench())
        // Pushed, but no save ever recorded its hash.
        XCTAssertEqual(try alerts().map(\.askID), [id])
        XCTAssertEqual(try sidecar.hashes(forKind: .askAlert), [:])

        try sidecar.wipeSyncState(now: now)
        let transport = StubHubTransport()
        try await publisher(transport).publishOnce()

        XCTAssertEqual(try savedAlerts(transport), [SliceKind.askAlert.recordName(id: WorkAlertKey.ask(id))])
    }

    func testAResetDuringTheAlertsSaveStillAlertsInTheNewGeneration() async throws {
        let id = try ask(in: try workbench())
        let name = SliceKind.askAlert.recordName(id: WorkAlertKey.ask(id))
        let transport = StubHubTransport()
        let gate = SaveGate()
        defer { gate.release() }
        let wire = try wireName(name)
        transport.gateNextSave(on: gate) { $0.recordName == wire }
        let publisher = publisher(transport)

        let first = Task { try await publisher.publishOnce() }
        await fulfillment(of: [gate.arrived], timeout: 5)
        try sidecar.wipeSyncState(now: now)
        gate.release()
        _ = try await first.value
        XCTAssertNil(try sidecar.hashes(forKind: .askAlert)[name], "the reset aborts the cycle before it records the hash")

        let before = transport.saved.count
        advance(10)
        try await publisher.publishOnce()

        XCTAssertEqual(
            try transport.openedSaves().dropFirst(before).map(\.record.recordName).filter { $0.hasPrefix("ask_alert-") }, [name],
            "the next cycle publishes the alert into the new zone"
        )
    }

    func testAnExpiredAlertOfAnOpenAskIsNotRaisedAgainAfterAReset() async throws {
        let id = try ask(in: try workbench())
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()
        advance(7 * day + 1)
        try await publisher.publishOnce()
        XCTAssertEqual(try sidecar.hashes(forKind: .askAlert), [:], "the expired record left the zone")

        try sidecar.wipeSyncState(now: now)
        try await publisher.publishOnce()

        XCTAssertEqual(try savedAlerts(transport), [SliceKind.askAlert.recordName(id: WorkAlertKey.ask(id))], "alerted once, ever")
    }

    // MARK: - Payload

    func testThePayloadIsCappedAndTitled() throws {
        let project = try workbench(name: String(repeating: "w", count: 61))
        let session = try session(in: project)
        try dbPool.write {
            try $0.execute(sql: "UPDATE terminal_sessions SET title = ? WHERE id = ?", arguments: [String(repeating: "s", count: 61), session])
        }
        let options = #"[{"label": "A", "recommended": true}, {"label": "B"}]"#
        let quick = #"{"focus": [], "questions": [{"id": "q", "question": "Which?", "options": \#(options)}], "checklist": []}"#
        let id = try ask(in: project, title: String(repeating: "t", count: 121), payload: quick, sessionID: session)
        let slice = slice()
        let record = try XCTUnwrap(try dbPool.read { try slice.records($0) }.first)
        let raw = try SliceJSON.object(record.payload)
        let payload = try JSONDecoder().decode(WorkAlertPayload.self, from: record.payload)

        XCTAssertEqual(record.recordName, "ask_alert-ask-\(id)")
        XCTAssertEqual(
            Set(raw.keys), ["event", "key", "workbench_id", "workbench_name", "session_id", "ask_id", "title", "body", "quick"]
        )
        XCTAssertEqual(payload.workbenchName.count, 60)
        XCTAssertEqual(payload.title, "\(String(repeating: "w", count: 59))… · \(String(repeating: "s", count: 59))…")
        XCTAssertEqual(payload.body.count, 120)
        XCTAssertEqual(payload.body.last, "…")
        XCTAssertEqual(payload.workbenchID, project)
        XCTAssertEqual(payload.sessionID, session)
        XCTAssertTrue(payload.quick)
    }

    func testAWorkbenchAskIsTitledByTheWorkbenchAlone() throws {
        try ask(in: try workbench(name: "acme"), kind: "check")
        let payload = try XCTUnwrap(try alerts().first)

        XCTAssertEqual(payload.title, "acme")
        XCTAssertFalse(payload.quick)
        XCTAssertNil(payload.sessionID)
    }
}

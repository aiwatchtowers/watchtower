import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `ask_alert` push trigger (mobile POC spec §4.7, §8 B1 (h)): written
/// once per ask opened after `enabled_at`, never again on a re-hydrate or an
/// epoch reset, deleted when the ask leaves `open` or 7 days after it was
/// written.
final class AskAlertSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    // A whole second, so a stamp 7 days later round-trips the sidecar's
    // seconds-since-1970 REAL exactly at the lifetime boundary.
    private let clock = OSAllocatedUnfairLock(
        initialState: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    )
    private let day: TimeInterval = 86_400
    private var enabledAt: Date!

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        sidecar = try HubSyncState.inMemory()
        enabledAt = try HubIdentity(sidecar: sidecar).ensureEnabledAt(Date().addingTimeInterval(-3600))
    }

    override func tearDownWithError() throws {
        dbPool = nil
        sidecar = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private var now: Date { clock.withLock { $0 } }

    private func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    private func slice() -> AskAlertSlice {
        let clock = self.clock
        return AskAlertSlice(sidecar: sidecar) { clock.withLock { $0 } }
    }

    private func alertIDs() throws -> [Int64] {
        let slice = slice()
        return try SliceJSON.objects(try dbPool.read { try slice.records($0) }).compactMap {
            ($0["ask_id"] as? NSNumber)?.int64Value
        }
    }

    private func publisher(_ transport: StubHubTransport) -> SlicePublisher {
        let clock = self.clock
        // Labelled: a trailing closure would bind to `clock`, the first closure parameter.
        return SlicePublisher(
            dbPool: dbPool, state: sidecar, transport: transport, sources: [slice()],
            now: { clock.withLock { $0 } } // swiftlint:disable:this trailing_closure
        )
    }

    private func savedAlerts(_ transport: StubHubTransport) -> [String] {
        transport.saved.map(\.record.recordName).filter { $0.hasPrefix("ask_alert-") }
    }

    private func workbench(name: String = "acme") throws -> Int64 {
        try dbPool.write { try TestDatabase.insertWorkbench($0, name: name) }
    }

    @discardableResult
    private func ask(
        in project: Int64,
        createdAt: Date,
        title: String = "Which way?",
        payload: String = "{}",
        sessionID: Int64? = nil
    ) throws -> Int64 {
        try dbPool.write {
            try TestDatabase.insertOwnerAsk(
                $0, projectID: project, sessionID: sessionID, title: title, payload: payload, createdAt: dbStamp(createdAt)
            )
        }
    }

    // MARK: - Once, and only for new asks

    func testAnAskOpenBeforeTheHubWasEnabledRaisesNoAlert() throws {
        try ask(in: try workbench(), createdAt: enabledAt.addingTimeInterval(-60))

        XCTAssertEqual(try alertIDs(), [])
        XCTAssertEqual(try sidecar.alertedAsks(), [:], "an old ask is never remembered as alerted")
    }

    func testANewAskRaisesExactlyOneAlert() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        let transport = StubHubTransport()
        let publisher = publisher(transport)

        try await publisher.publishOnce()
        advance(30)
        try await publisher.publishOnce()

        XCTAssertEqual(savedAlerts(transport), ["ask_alert-\(id)"])
        XCTAssertEqual(try alertIDs(), [id], "the record stays while the ask is open")
    }

    func testAReHydrateRaisesNoSecondAlert() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        let first = StubHubTransport()
        try await publisher(first).publishOnce()
        XCTAssertEqual(savedAlerts(first), ["ask_alert-\(id)"])

        // A rebuilt hub over the same sidecar republishes its whole window.
        let rebuilt = StubHubTransport()
        try await publisher(rebuilt).publishOnce()

        XCTAssertEqual(savedAlerts(rebuilt), [])
    }

    func testAnEpochResetRaisesNoAlertForAlertedAsks() async throws {
        let project = try workbench()
        try ask(in: project, createdAt: now)
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()

        try sidecar.wipeSyncState(now: Date())
        let before = savedAlerts(transport).count
        try await publisher.publishOnce()
        XCTAssertEqual(savedAlerts(transport).count, before, "the new zone gets no alert for an old ask")

        // The positive control: an ask filed after the reset still alerts.
        advance(10)
        let fresh = try ask(in: project, createdAt: now)
        try await publisher.publishOnce()
        XCTAssertEqual(savedAlerts(transport).dropFirst(before), ["ask_alert-\(fresh)"])
    }

    func testMarkAlertedReturnsTheGenerationOfItsOwnTransaction() throws {
        XCTAssertEqual(try sidecar.markAlerted([], at: now).generation, 0)
        try sidecar.wipeSyncState(now: Date())

        let marked = try sidecar.markAlerted([7], at: now)

        XCTAssertEqual(marked.generation, 1, "the bumped generation")
        XCTAssertEqual(marked.alerted[7]?.generation, marked.generation, "a fresh ask carries the same value")
    }

    func testAnAlertNeverConfirmedPublishedIsRaisedAfterAReset() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        // Remembered as alerted, but no save ever recorded its hash.
        XCTAssertEqual(try alertIDs(), [id])
        XCTAssertEqual(try sidecar.hashes(forKind: .askAlert), [:])

        try sidecar.wipeSyncState(now: now)
        let transport = StubHubTransport()
        try await publisher(transport).publishOnce()

        XCTAssertEqual(savedAlerts(transport), [SliceKind.askAlert.recordName(id: String(id))])
    }

    func testAResetDuringTheAlertsSaveStillAlertsInTheNewGeneration() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        let name = SliceKind.askAlert.recordName(id: String(id))
        let transport = StubHubTransport()
        let gate = SaveGate()
        defer { gate.release() }
        transport.gateNextSave(on: gate) { $0.recordName == name }
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
            transport.saved.dropFirst(before).map(\.record.recordName).filter { $0.hasPrefix("ask_alert-") }, [name],
            "the next cycle publishes the alert into the new zone"
        )
    }

    func testAnExpiredAlertOfAnOpenAskIsNotRaisedAgainAfterAReset() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()
        advance(7 * day + 1)
        try await publisher.publishOnce()
        XCTAssertEqual(try sidecar.hashes(forKind: .askAlert), [:], "the expired record left the zone")

        try sidecar.wipeSyncState(now: now)
        try await publisher.publishOnce()

        XCTAssertEqual(savedAlerts(transport), [SliceKind.askAlert.recordName(id: String(id))], "alerted once, ever")
    }

    func testAResetKeepsAnOlderGenerationsAlertWithoutAHash() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()
        try sidecar.wipeSyncState(now: now)
        // Delivered to the first zone; the second has no hash for it.
        XCTAssertEqual(try sidecar.alertedAsks()[id]?.generation, 0)

        try sidecar.wipeSyncState(now: now)
        try await publisher.publishOnce()

        XCTAssertEqual(try sidecar.alertedAsks()[id]?.generation, 0, "the historic row survives the second reset")
        XCTAssertEqual(savedAlerts(transport), [SliceKind.askAlert.recordName(id: String(id))])
    }

    // MARK: - Deletion

    func testAnAnsweredAskLosesItsAlert() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()

        try await dbPool.write {
            try $0.execute(sql: "UPDATE owner_asks SET status = 'answered', answer = '{}' WHERE id = ?", arguments: [id])
        }
        let outcome = try await publisher.publishOnce()

        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(try alertIDs(), [])
    }

    func testAnAlertOlderThan7DaysIsDeletedAndNeverRaisedAgain() async throws {
        let id = try ask(in: try workbench(), createdAt: now)
        let transport = StubHubTransport()
        let publisher = publisher(transport)
        try await publisher.publishOnce()

        advance(7 * day)
        XCTAssertEqual(try alertIDs(), [id], "exactly 7 days old is kept")
        advance(1)
        let outcome = try await publisher.publishOnce()

        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(try alertIDs(), [], "still open, but alerted once already")
        XCTAssertEqual(savedAlerts(transport), ["ask_alert-\(id)"])
    }

    func testAClosedAsksAlertedRowIsPrunedAfter7Days() throws {
        let project = try workbench()
        let id = try ask(in: project, createdAt: now)
        _ = try alertIDs()
        try dbPool.write { try $0.execute(sql: "UPDATE owner_asks SET status = 'withdrawn' WHERE id = ?", arguments: [id]) }
        let open = try ask(in: project, createdAt: now)
        _ = try alertIDs()

        advance(7 * day + 1)
        _ = try alertIDs()

        XCTAssertEqual(Set(try sidecar.alertedAsks().keys), [open], "an open ask stays remembered, a closed one is forgotten")
    }

    // MARK: - Payload

    func testThePayloadIsCapped() throws {
        let project = try workbench(name: String(repeating: "w", count: 61))
        let session = try dbPool.write { try SliceSeed.insertSession($0, projectID: project) }
        let options = #"[{"label": "A", "recommended": true}, {"label": "B"}]"#
        let quick = #"{"focus": [], "questions": [{"id": "q", "question": "Which?", "options": \#(options)}], "checklist": []}"#
        try ask(in: project, createdAt: now, title: String(repeating: "t", count: 121), payload: quick, sessionID: session)
        let slice = slice()
        let payload = try XCTUnwrap(try SliceJSON.objects(try dbPool.read { try slice.records($0) }).first)

        XCTAssertEqual(
            Set(payload.keys), ["ask_id", "workbench_id", "workbench_name", "session_id", "kind", "title", "quick"]
        )
        XCTAssertEqual((payload["workbench_name"] as? String)?.count, 60)
        XCTAssertEqual((payload["title"] as? String)?.count, 120)
        XCTAssertEqual((payload["title"] as? String)?.last, "…")
        XCTAssertEqual((payload["workbench_id"] as? NSNumber)?.int64Value, project)
        XCTAssertEqual((payload["session_id"] as? NSNumber)?.int64Value, session)
        XCTAssertEqual(payload["kind"] as? String, "question")
        XCTAssertEqual(payload["quick"] as? Bool, true)
    }

    func testAnAskWithoutQuickOrSessionSaysSo() throws {
        try ask(in: try workbench(), createdAt: now)
        let slice = slice()
        let payload = try XCTUnwrap(try SliceJSON.objects(try dbPool.read { try slice.records($0) }).first)

        XCTAssertEqual(payload["quick"] as? Bool, false)
        XCTAssertNil(payload["session_id"])
    }
}

import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Permission answers and Interrupt through a real outbox (#517, spec
/// 2026-10-17 §5.3, §5.4, §6): what goes on the wire, how far the Mac got,
/// and the Mac's refusal with Dismiss.
@MainActor
final class PermissionAnswerWiringTests: XCTestCase {
    private let now = Date()

    private struct Fixture {
        let store: ReplicaStore
        let outbox: ActionOutbox
        let inputs: SessionInputSender
    }

    private func makeFixture() async throws -> Fixture {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let inputs = SessionInputSender.sending(through: outbox, store: store)
        let starter = SessionStarter.sending(through: outbox, store: store)
        let answerer = AskAnswerer.sending(through: outbox, store: store, drafts: AskDraftStore())
        await outbox.setAppliedObserver(
            HubSession.appliedObserver(askAnswerer: answerer, sessionStarts: starter, sessionInputs: inputs)
        )
        return Fixture(store: store, outbox: outbox, inputs: inputs)
    }

    private func grant() -> DeviceGrant {
        DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: true, startSessionsAllowed: true, permissionsAllowed: true
        )
    }

    private func snapshot(_ store: ReplicaStore) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        snapshot.permissionRequests = [try mirror(PermissionRequest.self, permissionRequestJSON(7, session: 12))]
        snapshot.pending = try store.pendingActions()
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: now, lastRelayAt: now, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "_user", sharing: .none
        )
        return snapshot
    }

    private func detail(_ fixture: Fixture, sessionID: Int64 = 12) throws -> SessionDetailModel {
        try XCTUnwrap(SessionDetailModel(
            sessionID: sessionID, snapshot: try snapshot(fixture.store), report: nil, timeline: nil, now: now,
            permissions: PermissionAccess(
                grant: grant(), requested: true, inFlight: fixture.inputs.inFlight,
                sentRequestID: fixture.inputs.answered[sessionID]
            )
        ))
    }

    private func echo(
        _ fixture: Fixture, _ status: ActionStatus, reason: ActionReason? = nil, message: String? = nil
    ) async throws {
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = status
        echo.reason = reason
        echo.errorMessage = message
        try await fixture.outbox.applyEcho(echo)
    }

    func testAllowQueuesPermissionAnswer() async throws {
        let fixture = try await makeFixture()

        let sent = try await fixture.inputs.answer(sessionID: 12, requestID: 7, behavior: .allow)

        XCTAssertTrue(sent)
        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .permissionAnswer)
        XCTAssertEqual(row.entityRecordName, "terminal_session-12")
        XCTAssertEqual(row.action.params, ["request_id": .integer(7), "behavior": .string("allow")])

        let detail = try detail(fixture)
        XCTAssertFalse(try XCTUnwrap(detail.permission).canAnswer, "an answer on its way holds the buttons")
        XCTAssertEqual(detail.answerRows.first?.state, .waiting("Allow once · Sending…"))
    }

    func testDenyQueuesPermissionAnswerAndTheAppliedEchoSaysSent() async throws {
        let fixture = try await makeFixture()
        try await fixture.inputs.answer(sessionID: 12, requestID: 7, behavior: .deny)
        XCTAssertEqual(try fixture.store.pendingActions().first?.action.params["behavior"], .string("deny"))

        try await echo(fixture, .received)
        XCTAssertEqual(try detail(fixture).answerRows.map(\.state), [.waiting("Deny · Mac picked it up")])

        try await echo(fixture, .applied)
        try await waitFor { fixture.inputs.answered[12] == 7 }

        let detail = try detail(fixture)
        XCTAssertTrue(detail.answerRows.isEmpty)
        XCTAssertEqual(detail.answerNotice, "Sent to the session", "never \"Denied\": the Mac may have answered first")
    }

    func testANotPendingEchoShowsAnsweredOnTheMac() async throws {
        let fixture = try await makeFixture()
        try await fixture.inputs.answer(sessionID: 12, requestID: 7, behavior: .allow)

        try await echo(fixture, .failed, reason: .notPending, message: "Answered on the Mac")

        let detail = try detail(fixture)
        let row = try XCTUnwrap(detail.answerRows.first)
        XCTAssertEqual(row.state, .failed("Answered on the Mac"))
        XCTAssertNil(detail.answerNotice)
        try fixture.inputs.dismiss(row.pending)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    /// A refused answer shows even after its request left the slice (the
    /// Mac answered it): the row is the session's, not the card's.
    func testARefusalOutlivesItsRequest() async throws {
        let fixture = try await makeFixture()
        try await fixture.inputs.answer(sessionID: 12, requestID: 7, behavior: .allow)
        try await echo(fixture, .failed, reason: .notPending, message: "Answered on the Mac")

        var replica = try snapshot(fixture.store)
        replica.permissionRequests = []
        let detail = try XCTUnwrap(SessionDetailModel(
            sessionID: 12, snapshot: replica, report: nil, timeline: nil, now: now,
            permissions: PermissionAccess(grant: grant(), requested: true)
        ))

        XCTAssertNil(detail.permission)
        XCTAssertEqual(detail.answerRows.map(\.state), [.failed("Answered on the Mac")])
    }

    func testInterruptQueuesSessionInterrupt() async throws {
        let fixture = try await makeFixture()

        let sent = try await fixture.inputs.interrupt(sessionID: 10)

        XCTAssertTrue(sent)
        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .sessionInterrupt)
        XCTAssertEqual(row.entityRecordName, "terminal_session-10")
        XCTAssertEqual(row.action.params, [:])

        try await echo(fixture, .failed, reason: .notWorking, message: "Needs approval — use Deny")
        let replica = try snapshot(fixture.store)
        let actions = SessionActionsModel(
            session: try XCTUnwrap(replica.session(10)), snapshot: replica, inFlight: [], now: now,
            grant: grant(), typingRequested: true
        )
        XCTAssertEqual(actions.interruptRows.map(\.state), [.failed("Needs approval — use Deny")])
        XCTAssertTrue(actions.canInterrupt, "a refused interrupt does not hold the next")
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in 5 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

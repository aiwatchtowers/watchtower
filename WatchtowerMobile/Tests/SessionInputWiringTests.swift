import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Session input from the phone (spec §5.2, §6.6, PROJ-16): the "Tell the
/// session…" bar and Finish follow the phone's toggle and the Mac's Allow,
/// a session at a permission prompt takes nothing, a held line shows why,
/// and the actions and the Mac's delivery go through a real outbox.
@MainActor
final class SessionInputWiringTests: XCTestCase {
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

    private func grant(typing: Bool) -> DeviceGrant {
        DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: typing, startSessionsAllowed: true
        )
    }

    private func snapshot(_ store: ReplicaStore? = nil) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        snapshot.pending = try store?.pendingActions() ?? []
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: now, lastRelayAt: now, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "_user", sharing: .none
        )
        return snapshot
    }

    private func session(_ overrides: [String: Any] = [:]) throws -> TerminalSessionState {
        try mirror(TerminalSessionState.self, DemoSeed.JSON.session(11, workbench: DemoSeed.acmeID, overrides))
    }

    private func model(
        _ session: TerminalSessionState,
        _ snapshot: WorkbenchReplicaSnapshot,
        typing: Bool = true,
        requested: Bool = true,
        delivered: SessionInputDelivery? = nil
    ) -> SessionInputModel {
        SessionInputModel(
            session: session, snapshot: snapshot, grant: grant(typing: typing), typingRequested: requested,
            delivered: delivered, now: now
        )
    }

    private func echo(
        _ fixture: Fixture, _ status: ActionStatus, reason: ActionReason? = nil, result: [String: JSONValue]? = nil
    ) async throws {
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = status
        echo.reason = reason
        echo.result = result
        try await fixture.outbox.applyEcho(echo)
    }

    // MARK: - The toggle

    /// The toggle off — on the phone, or not yet allowed on the Mac — hides
    /// the bar and Finish; both on shows them on a live session only.
    func testTheToggleOffHidesTheBarAndFinish() throws {
        let replica = try snapshot()
        let live = try session()

        for (typing, requested) in [(false, true), (true, false), (false, false)] {
            let input = model(live, replica, typing: typing, requested: requested)
            XCTAssertFalse(input.showsBar, "typing \(typing), requested \(requested)")
            XCTAssertFalse(input.showsFinish)
            let actions = SessionActionsModel(session: live, snapshot: replica, inFlight: [], now: now, showsFinish: input.showsFinish)
            XCTAssertFalse(actions.showsFinish)
        }

        let allowed = model(live, replica)
        XCTAssertTrue(allowed.showsBar)
        XCTAssertTrue(allowed.showsFinish)
        XCTAssertTrue(allowed.canSend)
        XCTAssertTrue(SessionActionsModel(session: live, snapshot: replica, inFlight: [], now: now, showsFinish: true).hasActions)
        let stopped = model(try session(["live": false, "state_kind": "stopped", "is_ring": true]), replica)
        XCTAssertFalse(stopped.showsBar, "a session that does not run takes no line")
    }

    /// The toggle's caption in Settings: the Mac's answer.
    func testTheToggleStatusFollowsTheMacsAnswer() {
        XCTAssertEqual(SettingsView.typingCaption(grant: grant(typing: false)), "Waiting for your Mac to confirm")
        XCTAssertEqual(SettingsView.typingCaption(grant: nil), "Waiting for your Mac to confirm")
        XCTAssertEqual(SettingsView.typingCaption(grant: grant(typing: true)), "Allowed")
    }

    // MARK: - Needs approval

    /// The phone never answers a permission prompt: the bar says so and
    /// offers no send.
    func testNeedsApprovalShowsTheNoticeAndNoSendButton() throws {
        let input = model(try session(["state_kind": "needs_approval", "state_tone": "orange"]), try snapshot())

        XCTAssertTrue(input.showsBar)
        XCTAssertEqual(input.approvalText, "Needs approval on the Mac")
        XCTAssertFalse(input.canSend)
    }

    // MARK: - Lines

    func testSendQueuesSessionInputWithTheTrimmedText() async throws {
        let fixture = try await makeFixture()

        let blank = try await fixture.inputs.send(sessionID: 11, text: "  \n ")
        let long = try await fixture.inputs.send(sessionID: 11, text: String(repeating: "a", count: 4001))
        let sent = try await fixture.inputs.send(sessionID: 11, text: "  Run the tests \n")

        XCTAssertFalse(blank)
        XCTAssertFalse(long)
        XCTAssertTrue(sent)
        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .sessionInput)
        XCTAssertEqual(row.entityRecordName, "terminal_session-11")
        XCTAssertEqual(row.action.params, ["text": .string("Run the tests")])
        let input = model(try session(), try snapshot(fixture.store))
        XCTAssertEqual(input.lines.map(\.text), ["Run the tests"])
        XCTAssertEqual(input.lines.map(\.state), [.waiting("Sending…")])
    }

    /// A held echo shows its reason, with Cancel; a reason change replaces
    /// it.
    func testAHeldEchoShowsItsReason() async throws {
        let fixture = try await makeFixture()
        try await fixture.inputs.send(sessionID: 11, text: "Also the changelog")

        try await echo(fixture, .held, reason: .agentBusy)
        var input = model(try session(), try snapshot(fixture.store))
        XCTAssertEqual(input.lines.map(\.state), [.held("Held — goes when the agent is idle")])

        try await echo(fixture, .held, reason: .needsApproval)
        input = model(try session(), try snapshot(fixture.store))
        XCTAssertEqual(input.lines.map(\.state), [.held("Held — Needs approval on the Mac")])

        try await echo(fixture, .held, reason: .promptHasText)
        input = model(try session(), try snapshot(fixture.store))
        XCTAssertEqual(input.lines.map(\.state), [.held("Held — text is typed in the session on the Mac")])
    }

    func testCancelSendsSessionInputCancelForTheOriginal() async throws {
        let fixture = try await makeFixture()
        try await fixture.inputs.send(sessionID: 11, text: "Never mind")
        try await echo(fixture, .held, reason: .agentBusy)
        let held = try XCTUnwrap(fixture.store.pendingActions().first)

        try await fixture.inputs.cancel(held)

        let cancel = try XCTUnwrap(fixture.store.pendingActions().first { $0.action.kind == .sessionInputCancel })
        XCTAssertEqual(cancel.action.entityID, held.action.id)
        XCTAssertEqual(cancel.action.params, [:])
    }

    /// Typed and not submitted on the Mac: the phone says to press Return
    /// there.
    func testATypedDeliverySaysToPressReturnOnTheMac() async throws {
        let fixture = try await makeFixture()
        try await fixture.inputs.send(sessionID: 11, text: "Go on")

        try await echo(fixture, .applied, result: ["delivery": .string("typed")])
        try await waitFor { fixture.inputs.delivered[11] == .typed }

        let input = model(try session(), try snapshot(fixture.store), delivered: fixture.inputs.delivered[11])
        XCTAssertTrue(input.lines.isEmpty)
        XCTAssertEqual(input.notice, "Typed into the session — press Return on the Mac")
    }

    func testARefusedLineShowsTheMacsMessage() async throws {
        let fixture = try await makeFixture()
        try await fixture.inputs.send(sessionID: 11, text: "Hello")
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = .failed
        echo.reason = .deviceNotAllowed
        echo.errorMessage = "This phone is not allowed to type into sessions"
        try await fixture.outbox.applyEcho(echo)

        let input = model(try session(), try snapshot(fixture.store))

        XCTAssertEqual(input.lines.map(\.state), [.failed("This phone is not allowed to type into sessions")])
        try fixture.inputs.dismiss(try XCTUnwrap(input.lines.first).pending)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    func testFinishQueuesTheFinishRequest() async throws {
        let fixture = try await makeFixture()

        let sent = try await fixture.inputs.finish(sessionID: 11)

        XCTAssertTrue(sent)
        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .sessionFinishRequest)
        XCTAssertEqual(row.entityRecordName, "terminal_session-11")
        XCTAssertEqual(row.action.params, [:])
        XCTAssertEqual(model(try session(), try snapshot(fixture.store)).lines.map(\.text), ["Finish"])
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in 5 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

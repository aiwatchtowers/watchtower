import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The workchat's what-next card (#1784): built from the session record, so
/// it is there before the chat; finished shows the summary, PR line and
/// Report; failed offers Continue (a line) where the phone may type and a
/// new session on the target; a session whose run ended offers a new
/// session; needs approval without a request on the phone says where to
/// answer; no card while the agent works, waits on an ask or is idle.
@MainActor
final class WorkchatStateCardTests: XCTestCase {
    private let now = Date()

    private func grant(typing: Bool = true) -> DeviceGrant {
        DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: typing, startSessionsAllowed: true, permissionsAllowed: true
        )
    }

    private func snapshot(requests: [[String: Any]] = [], pending: [PendingAction] = [], online: Bool = true) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        snapshot.permissionRequests = try requests.map { try mirror(PermissionRequest.self, $0) }
        snapshot.pending = pending
        let beat = online ? now : now.addingTimeInterval(-2_400)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: beat, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: beat, lastRelayAt: beat, relayBacklog: 0, accounts: [],
            enabledAt: beat, ownerUser: "_user", sharing: .none
        )
        return snapshot
    }

    private func session(_ id: Int64, _ overrides: [String: Any] = [:]) throws -> TerminalSessionState {
        try mirror(TerminalSessionState.self, DemoSeed.JSON.session(id, workbench: DemoSeed.acmeID, overrides))
    }

    private func card(_ session: TerminalSessionState, _ snapshot: WorkbenchReplicaSnapshot, typing: Bool = true) -> WorkchatStateCard? {
        let access = PermissionAccess(grant: grant(typing: typing), requested: true)
        let input = SessionInputModel(
            session: session, snapshot: snapshot, grant: grant(typing: typing), typingRequested: true, delivered: nil, now: now,
            answersPermission: PermissionCardModel.answerable(session, in: snapshot, access: access)
        )
        return WorkchatModel(
            session: session, chat: nil, snapshot: snapshot, input: input,
            permission: PermissionCardModel.card(for: session, in: snapshot, access: access, now: now),
            mac: .of(heartbeat: snapshot.heartbeat?.updatedAt, linked: true, now: now), now: now
        ).stateCard
    }

    private func failedLive() throws -> TerminalSessionState {
        try session(16, [
            "title": "Undo archive", "state_kind": "failed", "state_caption": "Error: rate limit", "state_tone": "red",
            "agent_error": "rate_limit", "target_id": 416
        ])
    }

    // MARK: - Finished

    func testFinishedShowsTheSummaryThePRLineAndReport() throws {
        let finished = try session(13, [
            "state_kind": "finished", "live": false, "is_ring": true, "target_id": 422,
            "finish_summary": "Folded done targets per lane.", "report_pr_line": "PR #180 merged"
        ])
        let card = try XCTUnwrap(card(finished, try snapshot()), "the card needs no chat: the chat is nil here")

        XCTAssertEqual(card.title, "Finished")
        XCTAssertEqual(card.summary, "Folded done targets per lane.")
        XCTAssertEqual(card.details, ["PR #180 merged"])
        XCTAssertEqual(card.actions, [.report])
        XCTAssertEqual(WorkchatStateCard.Action.report.title, "Report")
    }

    func testFinishedWithoutSummaryOrPRShowsOnlyReport() throws {
        let card = try XCTUnwrap(card(try session(13, ["state_kind": "finished", "live": false]), try snapshot()))

        XCTAssertNil(card.summary)
        XCTAssertEqual(card.details, [])
        XCTAssertEqual(card.actions, [.report])
    }

    // MARK: - Failed

    func testFailedOffersContinueAndANewSessionOnTheTarget() throws {
        let card = try XCTUnwrap(card(try failedLive(), try snapshot()))

        XCTAssertEqual(card.title, "Stopped on an error")
        XCTAssertEqual(card.details, ["It still runs on your Mac. Continue sends it “Continue”, or start a new session on #416 here."])
        XCTAssertEqual(card.actions, [.continueSession, .newSession(targetID: 416)])
        XCTAssertEqual(card.actions.map(\.title), ["Continue", "New session"])
        XCTAssertEqual(WorkchatStateCard.Action.continueSession.accessibilityHint, "Sends “Continue” to the session")
    }

    func testFailedWhileThePhoneMayNotTypeOffersANewSessionOnly() throws {
        let card = try XCTUnwrap(card(try failedLive(), try snapshot(), typing: false))

        XCTAssertEqual(card.details, ["It still runs on your Mac: continue it there, or start a new session on #416 here."])
        XCTAssertEqual(card.actions, [.newSession(targetID: 416)])
    }

    func testFailedWithoutTargetOffersAPlainNewSession() throws {
        let card = try XCTUnwrap(card(try session(16, ["state_kind": "failed", "live": false]), try snapshot()))

        XCTAssertEqual(card.title, "Not running")
        XCTAssertEqual(card.actions, [.newSession(targetID: nil)])
        XCTAssertEqual(card.details, ["Its run ended on your Mac. Start a new session to pick the work up."])
        XCTAssertEqual(WorkchatStateCard.Action.newSession(targetID: nil).accessibilityHint, "Starts a new session on your Mac")
    }

    /// Continue is a real line: once one is on its way, the card stops
    /// offering it (no second send).
    func testContinueGoesAsALineAndIsNotOfferedTwice() async throws {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let inputs = SessionInputSender.sending(through: outbox, store: store)

        _ = try await inputs.send(sessionID: 16, text: WorkchatStateCard.continueLine)
        let pending = try store.pendingActions()
        let line = try XCTUnwrap(pending.first { $0.action.kind == .sessionInput })
        XCTAssertEqual(line.action.params["text"], .string("Continue"))
        XCTAssertEqual(line.entityRecordName, SessionStarter.sessionRecordName(16))

        let card = try XCTUnwrap(card(try failedLive(), try snapshot(pending: pending)))
        XCTAssertEqual(card.actions, [.newSession(targetID: 416)])
    }

    // MARK: - Not running

    func testASessionWhoseRunEndedOffersANewSession() throws {
        for kind in ["stopped", "not_started"] {
            let ended = try session(15, ["state_kind": kind, "live": false, "is_ring": true, "target_id": 501])
            let card = try XCTUnwrap(card(ended, try snapshot()), kind)

            XCTAssertEqual(card.title, "Not running")
            XCTAssertEqual(card.details, ["Its run ended on your Mac. Start a new session on #501 to pick the work up."])
            XCTAssertEqual(card.actions, [.newSession(targetID: 501)])
            XCTAssertEqual(WorkchatStateCard.Action.newSession(targetID: 501).accessibilityHint, "Starts a new session on #501 on your Mac")
        }
    }

    // MARK: - Needs approval

    func testNeedsApprovalWithoutARequestSaysWhereToAnswer() throws {
        let waiting = try session(12, ["state_kind": "needs_approval"])
        XCTAssertEqual(card(waiting, try snapshot())?.details, ["The request is on its way from your Mac."])
        XCTAssertEqual(card(waiting, try snapshot(online: false))?.details, ["Your Mac sends the request when it wakes."])
        XCTAssertEqual(card(waiting, try snapshot())?.actions, [])

        let codex = try session(12, ["state_kind": "needs_approval", "agent": "codex_cli"])
        XCTAssertEqual(card(codex, try snapshot())?.details, ["Answer this prompt on the Mac."])
    }

    func testNeedsApprovalWithTheCardHasNoStateCard() throws {
        let waiting = try session(12, ["state_kind": "needs_approval"])
        XCTAssertNil(card(waiting, try snapshot(requests: [permissionRequestJSON(7, session: 12)])))
    }

    // MARK: - No card

    func testNoCardWhileTheAgentWorksWaitsOrIsIdle() throws {
        let kinds: [[String: Any]] = [
            ["state_kind": "working"], ["state_kind": "running"], ["state_kind": "waiting_on_ask", "open_asks": 1],
            ["state_kind": "ready_to_check", "open_asks": 1], ["state_kind": "stopped", "state_caption": "Idle"]
        ]
        for overrides in kinds {
            XCTAssertNil(card(try session(10, overrides), try snapshot()), "\(overrides)")
        }
    }
}

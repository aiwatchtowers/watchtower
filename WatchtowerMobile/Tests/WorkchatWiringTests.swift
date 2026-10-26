import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The session screen is the workchat (spec §5.3, §5.4; mockups 3, 4, 8):
/// the chat watch on open, the state line with its timer, the permission
/// card and open asks at the foot of the feed, the composer's states, the
/// queued caption of a line sent while the agent works, and the actions
/// menu that reaches the report.
@MainActor
final class WorkchatWiringTests: XCTestCase {
    private let now = Date()

    private func grant(typing: Bool = true, permissions: Bool = true) -> DeviceGrant {
        DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: typing, startSessionsAllowed: true, permissionsAllowed: permissions
        )
    }

    private func snapshot(requests: [[String: Any]] = [], heartbeatAt: Date? = nil) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        snapshot.permissionRequests = try requests.map { try mirror(PermissionRequest.self, $0) }
        let beat = heartbeatAt ?? now
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

    private func model(
        _ session: TerminalSessionState,
        _ snapshot: WorkbenchReplicaSnapshot,
        typing: Bool = true,
        chat: SessionChat? = nil
    ) -> WorkchatModel {
        let access = PermissionAccess(grant: grant(typing: typing), requested: true)
        let input = SessionInputModel(
            session: session, snapshot: snapshot, grant: grant(typing: typing), typingRequested: true, delivered: nil, now: now,
            answersPermission: PermissionCardModel.answerable(session, in: snapshot, access: access)
        )
        return WorkchatModel(
            session: session, chat: chat, snapshot: snapshot, input: input,
            permission: PermissionCardModel.card(for: session, in: snapshot, access: access, now: now),
            macOnline: MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline, now: now
        )
    }

    // MARK: - The chat watch

    func testOpeningTheSessionStartsTheChatWatch() async throws {
        var sent: [String] = []
        let requester = SessionChatRequester(ticks: { AsyncStream { _ in } }, send: { sent.append("\($0.sessionID)/\($0.agentID ?? "-")") })
        let chat = WorkchatView.chatModel(sessionID: 10, store: try TestPhone.replica(), requester: requester)

        XCTAssertNil(chat.agentID, "the workchat is the session's main chat")
        chat.appeared()
        try await poll({ sent == ["10/-"] }, "opening the session asked the Mac for its chat")
        chat.disappeared()
    }

    // MARK: - Header

    func testStateLineShowsTimerWhileWorking() throws {
        let working = try session(10, [
            "title": "Session report", "state_kind": "working", "state_caption": "Working",
            "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-194))
        ])
        let workchat = model(working, try snapshot())

        XCTAssertEqual(workchat.title, "Session report")
        XCTAssertEqual(workchat.workbenchName, "Acme")
        XCTAssertEqual(workchat.stateLine.visibleText, "Working · 3:14")
        XCTAssertFalse(workchat.stateLine.isWaiting)

        let asleep = model(working, try snapshot(heartbeatAt: now.addingTimeInterval(-3_600)))
        XCTAssertEqual(asleep.stateLine.visibleText, "Working · as of 1 h ago", "the Mac away stops the count")
        XCTAssertEqual(asleep.composer, .macAway("Waiting for your Mac"))
    }

    // MARK: - The foot of the feed

    func testPermissionCardSitsAboveTheComposer() throws {
        let replica = try snapshot(requests: [permissionRequestJSON(7, session: 12)])
        let waiting = model(try XCTUnwrap(replica.session(12)), replica)

        XCTAssertEqual(waiting.permission?.requestID, 7)
        XCTAssertEqual(waiting.stateLine.visibleText.hasPrefix("Needs approval"), true)
        XCTAssertTrue(waiting.stateLine.isWaiting)
        XCTAssertEqual(waiting.composer, .approval("Answer the request above"), "the composer points at the card")

        let codexLike = model(try XCTUnwrap(replica.session(12)), try snapshot())
        XCTAssertNil(codexLike.permission)
        XCTAssertEqual(codexLike.composer, .approval("Needs approval on the Mac"), "no card: the Mac answers it")
    }

    func testOpenAsksShowInline() throws {
        let replica = try snapshot()
        let workchat = model(try XCTUnwrap(replica.session(11)), replica)

        XCTAssertEqual(workchat.inlineAsks.map(\.destination), [.ask(111), .ask(109)], "the session's open asks, newest first")
        XCTAssertEqual(workchat.askOptions[109], [
            InlineAskOption(id: "Archive Closed Targets Now", label: "Archive Closed Targets Now", isRecommended: true),
            InlineAskOption(id: "Archive Now", label: "Archive Now")
        ], "a quick question answers in place")
        XCTAssertNil(workchat.askOptions[111], "a check opens its form")
    }

    // MARK: - The composer

    func testSentWhileBusyShowsQueuedCaption() async throws {
        let store = try TestPhone.replica()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let inputs = SessionInputSender.sending(through: outbox, store: store)
        let answerer = AskAnswerer.sending(through: outbox, store: store, drafts: AskDraftStore())
        await outbox.setAppliedObserver(HubSession.appliedObserver(
            askAnswerer: answerer, sessionStarts: SessionStarter.sending(through: outbox, store: store), sessionInputs: inputs
        ))
        try await inputs.send(sessionID: 10, text: "And keep the old header for sessions without a PR.")
        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .applied
        echo.result = ["delivery": .string("submitted"), "while_busy": .bool(true)]
        try await outbox.applyEcho(echo)

        try await poll({ inputs.lineDeliveries[echo.id] != nil }, "the applied echo arrived")
        XCTAssertEqual(inputs.lineDeliveries[echo.id]?.caption, "Queued · the agent reads it at its next step")
        XCTAssertEqual(SessionInputDelivery.submitted.caption, "Sent")
        XCTAssertEqual(SessionInputModel.heldText(.agentBusy), "Queued · sends when the agent stops")
    }

    func testCodexKeepsTheIdleFootnote() throws {
        let replica = try snapshot()
        let claude = model(try session(10, ["state_kind": "working"]), replica)
        let codex = model(try session(10, ["state_kind": "working", "agent": "codex_cli"]), replica)

        XCTAssertEqual(claude.composer, .ready(footnote: nil), "a Claude session takes a line while it works")
        XCTAssertEqual(codex.composer, .ready(footnote: "Delivered when the agent stops"))
        XCTAssertEqual(ComposerBarModel(text: "", mode: .message).placeholder, "Message the session…")
        XCTAssertEqual(model(try session(10), replica, typing: false).composer, .hidden(.waitingForMac))
        XCTAssertEqual(model(try session(15, ["live": false, "state_kind": "stopped"]), replica).composer, .hidden(nil))
    }

    func testSubagentScreenHasNoComposer() {
        XCTAssertTrue(WorkchatView.screen.hasComposer)
        XCTAssertFalse(SessionChatView.screen.hasComposer, "a subagent's chat is read-only")
    }

    // MARK: - The actions menu

    func testReportIsReachableFromTheMenu() throws {
        let replica = try snapshot()
        let live = try XCTUnwrap(replica.session(10))
        let actions = SessionActionsModel(
            session: live, snapshot: replica, inFlight: [], now: now, showsFinish: true, grant: grant(), typingRequested: true
        )
        XCTAssertEqual(WorkchatModel.menu(actions: actions, targetID: 430), [.stop, .finish, .interrupt, .report, .openTarget(430)])
        XCTAssertEqual(WorkchatMenuItem.report.title, "Report and timeline")

        let stopped = try XCTUnwrap(replica.session(15))
        let none = SessionActionsModel(session: stopped, snapshot: replica, inFlight: [], now: now)
        XCTAssertEqual(WorkchatModel.menu(actions: none, targetID: nil), [.report], "a stopped session still has its report")
    }
}

import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Starting and stopping a session from the phone (spec §5.2, §6.5, §13 B6):
/// the start sheet's fields and defaults, the grant, an existing session's
/// Open it / Start a new one, the progress stages that follow the Mac's
/// echoes, a refusal's Try again, and Stop in the session's actions menu,
/// over the demo board and a real outbox.
@MainActor
final class StartSheetWiringTests: XCTestCase {
    private let now = Date()

    private struct Fixture {
        let store: ReplicaStore
        let outbox: ActionOutbox
        let starter: SessionStarter
        let answerer: AskAnswerer
    }

    /// The app's wiring: `AppEnvironment.appliedObserver` hands the
    /// outbox's applied echoes to the starter and the ask answerer.
    private func makeFixture() async throws -> Fixture {
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store, deviceID: DemoSeed.device.deviceID)
        let starter = SessionStarter.sending(through: outbox, store: store)
        let answerer = AskAnswerer.sending(through: outbox, store: store, drafts: AskDraftStore())
        await outbox.setAppliedObserver(AppEnvironment.appliedObserver(askAnswerer: answerer, sessionStarts: starter))
        return Fixture(store: store, outbox: outbox, starter: starter, answerer: answerer)
    }

    /// The demo snapshot with the store's overlay rows and a heartbeat of
    /// the given age.
    private func snapshot(
        _ store: ReplicaStore, heartbeatAge: TimeInterval = 10, grant: DeviceGrant? = nil
    ) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        snapshot.pending = try store.pendingActions()
        let at = now.addingTimeInterval(-heartbeatAge)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
            enabledAt: at, ownerUser: "_user", sharing: .none
        )
        snapshot.grants = grant.map { [$0] } ?? []
        return snapshot
    }

    private func grant(typing: Bool, start: Bool) -> DeviceGrant {
        DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: typing, startSessionsAllowed: start
        )
    }

    private func form(
        _ targetID: Int64?, _ snapshot: WorkbenchReplicaSnapshot, _ starter: SessionStarter? = nil
    ) throws -> StartSessionFormModel {
        try XCTUnwrap(StartSessionFormModel(
            workbenchID: DemoSeed.acmeID,
            targetID: targetID,
            snapshot: snapshot,
            grant: snapshot.grant(for: DemoSeed.device.deviceID),
            attempt: targetID.flatMap { starter?.attempts[$0] },
            inFlight: starter?.inFlight ?? [],
            now: now
        ))
    }

    private func target(_ id: Int64) throws -> WorkbenchTarget {
        try XCTUnwrap(try demoSnapshot(now: now).targets.first { $0.id == id })
    }

    private func startParams(_ targetID: Int64, mode: SessionStartParams.Mode = .new) throws -> SessionStartParams {
        StartSessionDraft(target: try target(targetID)).params(workbenchID: DemoSeed.acmeID, mode: mode, grant: StartGrant(nil))
    }

    /// Rewrites the only overlay row's echo.
    private func echo(
        _ fixture: Fixture,
        _ status: ActionStatus,
        reason: ActionReason? = nil,
        result: [String: JSONValue]? = nil,
        message: String? = nil
    ) async throws {
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = status
        echo.reason = reason
        echo.result = result
        echo.errorMessage = message
        try await fixture.outbox.applyEcho(echo)
    }

    private func session(_ id: Int64, target: Int64, _ overrides: [String: Any]) throws -> TerminalSessionState {
        try mirror(TerminalSessionState.self, sessionJSON(id, target: target, overrides))
    }

    private func sessionJSON(_ id: Int64, target: Int64, _ overrides: [String: Any]) -> [String: Any] {
        var json = DemoSeed.JSON.session(id, workbench: DemoSeed.acmeID, overrides)
        json["target_id"] = target
        return json
    }

    /// Lands `records` in the store, as a hydrate does.
    private func hydrate(_ store: ReplicaStore, _ records: [CloudRecord]) async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save(records)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
    }

    // MARK: - Progress

    /// Spec §13 B6 (j): with a stale heartbeat no echo arrives, so the sheet
    /// stays on "Sent to your Mac" and says it waits for the Mac.
    func testAStaleHeartbeatKeepsTheSheetOnSentToYourMac() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))

        let stale = try XCTUnwrap(try form(400, try snapshot(fixture.store, heartbeatAge: 3_600), fixture.starter).progress)
        XCTAssertEqual(stale.stage, .sent)
        XCTAssertEqual(stale.current, "Sent to your Mac")
        XCTAssertEqual(stale.waitingLine, "Waiting for your Mac")
        XCTAssertEqual(stale.steps.map(\.state), [.current, .todo, .todo])
        XCTAssertNil(stale.openSessionID)

        let fresh = try XCTUnwrap(try form(400, try snapshot(fixture.store), fixture.starter).progress)
        XCTAssertEqual(fresh.current, "Sent to your Mac")
        XCTAssertNil(fresh.waitingLine, "an online Mac gets no waiting line")
    }

    /// The stages follow the echoes: received → picked up, applied with a
    /// session id → starting, the record live with a reported state → Open
    /// session.
    func testTheStagesFollowTheMacsEchoes() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))

        try await echo(fixture, .received)
        let picked = try XCTUnwrap(try form(400, try snapshot(fixture.store), fixture.starter).progress)
        XCTAssertEqual(picked.current, "Mac picked it up")
        XCTAssertEqual(picked.steps.map(\.state), [.done, .current, .todo])

        try await echo(fixture, .applied, result: ["session_id": .integer(90), "stage": .string("starting")])
        try await poll(timeout: 2, { fixture.starter.attempts[400]?.applied == true }, "the applied observer reached the starter")
        var replica = try snapshot(fixture.store)
        XCTAssertTrue(replica.pending.isEmpty, "applied removed the row")
        XCTAssertEqual(try form(400, replica, fixture.starter).progress?.stage, .starting(sessionID: 90))
        XCTAssertEqual(try form(400, replica, fixture.starter).progress?.current, "Starting Claude Code")

        replica.sessions.append(try session(90, target: 400, ["state_kind": "not_started", "live": true]))
        XCTAssertEqual(try form(400, replica, fixture.starter).progress?.stage, .starting(sessionID: 90), "not_started is not open yet")

        replica.sessions[replica.sessions.count - 1] = try session(90, target: 400, ["state_kind": "running", "live": true])
        let open = try XCTUnwrap(try form(400, replica, fixture.starter).progress)
        XCTAssertEqual(open.stage, .open(sessionID: 90))
        XCTAssertEqual(open.openSessionID, 90)
        XCTAssertEqual(open.current, "Open session")
        XCTAssertEqual(open.steps.map(\.state), [.done, .done, .done])

        // Open session ends the start: the target's sheet starts fresh.
        try fixture.starter.clear(targetID: 400)
        XCTAssertNil(try form(400, replica, fixture.starter).progress)
    }

    /// Review Important 1: a start is over once its session no longer runs.
    /// Applied → running (open) → stopped is `ended`, never `starting`
    /// again, and the sheet offers a new start once the owner is done.
    func testAStoppedSessionEndsTheStartAndTheSheetOffersANewOne() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))
        try await echo(fixture, .applied, result: ["session_id": .integer(90), "stage": .string("starting")])
        try await poll(timeout: 2, { fixture.starter.attempts[400]?.applied == true }, "the applied observer reached the starter")

        var replica = try snapshot(fixture.store)
        replica.sessions.append(try session(90, target: 400, ["state_kind": "running", "live": true]))
        XCTAssertEqual(try form(400, replica, fixture.starter).progress?.stage, .open(sessionID: 90))

        replica.sessions[replica.sessions.count - 1] = try session(90, target: 400, [
            "state_kind": "stopped", "state_caption": "Stopped", "state_tone": "secondary", "live": false, "is_ring": true
        ])
        let ended = try XCTUnwrap(try form(400, replica, fixture.starter).progress)
        XCTAssertEqual(ended.stage, .ended(sessionID: 90))
        XCTAssertTrue(ended.isEnded)
        XCTAssertEqual(ended.current, "The session ended")
        XCTAssertEqual(ended.caption, "The session ended", "the target's line no longer says Starting")
        XCTAssertNil(ended.openSessionID)
        XCTAssertTrue(try form(400, replica, fixture.starter).canStart, "Start a new one can send")

        // Dismiss (or Start a new one) clears it: the form is back, with the
        // ended session as the target's existing one.
        try fixture.starter.clear(targetID: 400)
        let fresh = try form(400, replica, fixture.starter)
        XCTAssertNil(fresh.progress)
        XCTAssertEqual(fresh.existing?.id, 90)
        XCTAssertEqual(fresh.openIt, .resume)
        XCTAssertTrue(fresh.canStart)
    }

    /// A new session whose record arrives already not live (it exited
    /// early) ends the start too. A resumed session's record that still
    /// reads stopped from before the start stays `starting`.
    func testARecordThatArrivesNotLiveEndsANewStartOnly() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))
        try await echo(fixture, .applied, result: ["session_id": .integer(92), "stage": .string("starting")])
        try await poll(timeout: 2, { fixture.starter.attempts[400]?.applied == true }, "the applied observer reached the starter")
        var replica = try snapshot(fixture.store)
        replica.sessions.append(try session(92, target: 400, ["state_kind": "stopped", "live": false, "is_ring": true]))
        XCTAssertEqual(try form(400, replica, fixture.starter).progress?.stage, .ended(sessionID: 92))

        try await hydrate(fixture.store, try DemoSeed.workbenchRecords(now: now))
        try await fixture.starter.start(targetID: 416, params: try startParams(416, mode: .openExisting))
        var resume = try XCTUnwrap(fixture.store.pendingActions().first { $0.entityRecordName == "workbench_target-416" }).action
        resume.status = .applied
        resume.result = ["session_id": .integer(16), "stage": .string("starting")]
        try await fixture.outbox.applyEcho(resume)
        try await poll(timeout: 2, { fixture.starter.attempts[416]?.applied == true }, "the applied observer reached the starter")
        replica = try snapshot(fixture.store)
        XCTAssertEqual(
            try form(416, replica, fixture.starter).progress?.stage, .starting(sessionID: 16),
            "#16 last ran hours before the resume: its record is stale, not the end"
        )
    }

    /// Final-review iii-M4: a resumed start's end is read off the Mac's own
    /// record, never by comparing the Mac's clock with the phone's. The
    /// record the phone held when the applied echo came is the one from
    /// before the start, even stamped by a Mac clock ahead of the phone's;
    /// a not-live record the Mac wrote after it ends the start, even
    /// stamped by a Mac clock behind.
    func testAResumedStartEndsOnANotLiveRecordWrittenAfterTheEcho() async throws {
        let fixture = try await makeFixture()
        let staleJSON = sessionJSON(16, target: 416, [
            "state_kind": "stopped", "state_caption": "Stopped", "live": false, "is_ring": true,
            "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(600))
        ])
        try await hydrate(fixture.store, [try DemoSeed.record(kind: .terminalSession, id: 16, json: staleJSON, modifiedAt: now)])
        try await fixture.starter.start(targetID: 416, params: try startParams(416, mode: .openExisting))
        try await echo(fixture, .applied, result: ["session_id": .integer(16), "stage": .string("starting")])
        try await poll(timeout: 2, { fixture.starter.attempts[416]?.applied == true }, "the applied observer reached the starter")

        var replica = try snapshot(fixture.store)
        replica.sessions.removeAll { $0.id == 16 }
        replica.sessions.append(try mirror(TerminalSessionState.self, staleJSON))
        XCTAssertEqual(
            try form(416, replica, fixture.starter).progress?.stage, .starting(sessionID: 16),
            "the record from before the resume is not its end, whatever the Mac's clock says"
        )

        replica.sessions[replica.sessions.count - 1] = try session(16, target: 416, [
            "state_kind": "stopped", "state_caption": "Exited", "live": false, "is_ring": true,
            "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-600))
        ])
        XCTAssertEqual(
            try form(416, replica, fixture.starter).progress?.stage, .ended(sessionID: 16),
            "a not-live record written after the echo ends the start, whatever the Mac's clock says"
        )
    }

    /// Review Minor 1: the app's one applied observer feeds both consumers.
    func testTheAppsAppliedObserverReachesTheAnswererAndTheStarter() async throws {
        let fixture = try await makeFixture()
        try await fixture.outbox.enqueue(kind: .askAnswer, entityRecordName: "owner_ask-109")
        try await fixture.starter.start(targetID: 400, params: try startParams(400))
        for var action in try fixture.store.pendingActions().map(\.action) {
            action.status = .applied
            action.result = action.kind == .askAnswer
                ? ["delivery": .string("submitted")]
                : ["session_id": .integer(93), "stage": .string("starting")]
            try await fixture.outbox.applyEcho(action)
        }
        try await poll(timeout: 2, {
            fixture.answerer.applied[109] != nil && fixture.starter.attempts[400]?.applied == true
        }, "both consumers saw their echo")
        XCTAssertEqual(fixture.answerer.applied[109], AppliedAnswer(delivery: .submitted))
        XCTAssertEqual(fixture.starter.attempts[400]?.sessionID, 93)
    }

    /// The progress lives in the app-owned starter: a sheet built again
    /// (left and reopened) shows the same stage; after a relaunch the
    /// overlay row still gives it, and an applied echo of a start sent
    /// before the relaunch is followed.
    func testTheProgressSurvivesLeavingTheSheetAndARelaunch() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))
        try await echo(fixture, .received)
        XCTAssertEqual(try form(400, try snapshot(fixture.store), fixture.starter).progress?.current, "Mac picked it up")
        XCTAssertEqual(try form(400, try snapshot(fixture.store), fixture.starter).progress?.current, "Mac picked it up")

        let relaunched = SessionStarter.sending(through: fixture.outbox, store: fixture.store)
        XCTAssertEqual(try form(400, try snapshot(fixture.store), relaunched).progress?.current, "Mac picked it up")

        let applied = try XCTUnwrap(fixture.store.pendingActions().first).action
        var echo = applied
        echo.status = .applied
        echo.result = ["session_id": .integer(91), "stage": .string("starting")]
        relaunched.receiveApplied(echo)
        XCTAssertEqual(relaunched.attempts[400]?.sessionID, 91)
        XCTAssertEqual(relaunched.attempts[400]?.actionID, applied.id)
    }

    // MARK: - Existing session

    /// Ruling 4: a target with a session offers Open it or Start a new one.
    /// Open it on a live session opens it on the phone and sends nothing;
    /// on one that does not run it resumes it on the Mac (`open_existing`).
    func testATargetWithASessionOffersOpenItOrStartANewOne() async throws {
        let fixture = try await makeFixture()
        let replica = try snapshot(fixture.store)

        let live = try form(415, replica)
        XCTAssertEqual(live.existing?.id, 11)
        XCTAssertEqual(live.existing?.isLive, true)
        XCTAssertEqual(live.openIt, .show(sessionID: 11))

        let withBoth = try form(421, replica)
        XCTAssertEqual(withBoth.existing?.id, 12, "a live session first, over the stopped #15")

        let stopped = try form(416, replica)
        XCTAssertEqual(stopped.existing?.id, 16)
        XCTAssertEqual(stopped.existing?.isLive, false)
        XCTAssertEqual(stopped.openIt, .resume)

        let none = try form(400, replica)
        XCTAssertNil(none.existing)
        XCTAssertNil(none.openIt)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty, "building the sheet sends nothing")

        try await fixture.starter.start(targetID: 416, params: try startParams(416, mode: .openExisting))
        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .sessionStart)
        XCTAssertEqual(row.entityRecordName, "workbench_target-416")
        XCTAssertEqual(row.action.entityID, "416")
        XCTAssertEqual(try SessionStartParams(wireParams: row.action.params).mode, .openExisting)

        try await fixture.starter.start(targetID: 415, params: try startParams(415, mode: .new))
        let new = try XCTUnwrap(fixture.store.pendingActions().last)
        XCTAssertEqual(try SessionStartParams(wireParams: new.action.params).mode, .new, "Start a new one")
    }

    // MARK: - Fields, defaults and the grant

    /// Ruling 7 and the pinned wire: Bring forward off, Plan first on, the
    /// agent Claude Code, the brief from the work-on prompt; snake_case keys.
    func testTheDefaultsGoOnTheWireWithoutABrief() async throws {
        let fixture = try await makeFixture()
        let model = try form(415, try snapshot(fixture.store))
        XCTAssertEqual(model.agent, "Claude Code")
        XCTAssertEqual(model.workbenchName, "Acme")
        XCTAssertEqual(model.targetLabel, "#415 Archive Closed Targets Now")

        let draft = StartSessionDraft(target: try target(415))
        XCTAssertEqual(draft.brief, "Work on target #415.", "prefilled from work_on_prompt")
        XCTAssertFalse(draft.bringForward)
        XCTAssertTrue(draft.planFirst)

        try await fixture.starter.start(targetID: 415, params: draft.params(workbenchID: DemoSeed.acmeID, mode: .new, grant: model.grant))
        let wire = try XCTUnwrap(fixture.store.pendingActions().first).action.params
        XCTAssertEqual(wire, [
            "workbench_id": .integer(DemoSeed.acmeID), "mode": .string("new"),
            "plan_first": .bool(true), "bring_forward": .bool(false)
        ])
    }

    /// The brief is editable and sent only from a phone allowed to type,
    /// and only when edited; without a grant record the spec's defaults
    /// hold (typing off, starts on).
    func testTheBriefFollowsTheTypingGrant() throws {
        let store = try ReplicaStore.inMemory()
        let defaults = try form(415, try snapshot(store))
        XCTAssertEqual(defaults.grant, StartGrant(nil))
        XCTAssertFalse(defaults.grant.typingAllowed)
        XCTAssertEqual(defaults.briefCaption, "The Mac uses this brief. To edit it here, allow typing for this phone on the Mac.")
        XCTAssertTrue(defaults.canStart)

        var draft = StartSessionDraft(target: try target(415))
        draft.brief = "Fix the archive menu first."
        XCTAssertNil(draft.params(workbenchID: DemoSeed.acmeID, mode: .new, grant: defaults.grant).brief, "typing off sends no brief")

        let typing = try form(415, try snapshot(store, grant: grant(typing: true, start: true)))
        XCTAssertNil(typing.briefCaption)
        XCTAssertEqual(draft.params(workbenchID: DemoSeed.acmeID, mode: .new, grant: typing.grant).brief, "Fix the archive menu first.")
        let unedited = StartSessionDraft(target: try target(415))
        XCTAssertNil(unedited.params(workbenchID: DemoSeed.acmeID, mode: .new, grant: typing.grant).brief, "an unedited prompt is the Mac's own")
        var blank = unedited
        blank.brief = "  \n"
        XCTAssertNil(blank.params(workbenchID: DemoSeed.acmeID, mode: .new, grant: typing.grant).brief)
    }

    /// Review Minor 2: a clipped work-on prompt says so when the brief is
    /// editable, since an edit replaces the Mac's full prompt.
    func testAClippedPromptSaysAnEditReplacesTheMacsPrompt() throws {
        var replica = try snapshot(try ReplicaStore.inMemory(), grant: grant(typing: true, start: true))
        replica.targets.append(try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(480, workbench: DemoSeed.acmeID, [
            "work_on_prompt": "Work on target #480 with a long brief…", "work_on_prompt_clipped": true
        ])))
        XCTAssertEqual(
            try form(480, replica).briefCaption,
            "The brief is shortened on the phone. Editing it replaces the Mac's full prompt."
        )
        XCTAssertNil(try form(415, replica).briefCaption, "an unclipped prompt needs no caption")
        replica.grants = []
        XCTAssertEqual(
            try form(480, replica).briefCaption,
            "The Mac uses this brief. To edit it here, allow typing for this phone on the Mac."
        )
    }

    /// A phone the Mac does not allow to start sessions gets Start off with
    /// the reason (the hub would refuse `device_not_allowed`).
    func testAPhoneNotAllowedToStartCannotStart() throws {
        let model = try form(400, try snapshot(try ReplicaStore.inMemory(), grant: grant(typing: false, start: false)))
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.startCaption, "This phone is not allowed to start sessions on the Mac")
    }

    /// From the Workbench header no target is set: Start waits for one, and
    /// picking one fills the brief from its work-on prompt. Archived
    /// targets are not offered.
    func testTheHeadersNewSessionPicksATarget() throws {
        let model = try form(nil, try snapshot(try ReplicaStore.inMemory()))
        XCTAssertNil(model.target)
        XCTAssertFalse(model.canStart)
        XCTAssertNil(model.progress)
        XCTAssertTrue(model.targetOptions.contains { $0.id == 415 })
        XCTAssertFalse(model.targetOptions.contains { $0.id == 417 || $0.id == 390 }, "archived targets stay off")
        XCTAssertFalse(model.targetOptions.contains { $0.id == 500 }, "another workbench's targets stay off")

        var draft = StartSessionDraft(target: nil)
        draft.pick(try target(430))
        XCTAssertEqual(draft.targetID, 430)
        XCTAssertEqual(draft.brief, "Work on target #430.")
    }

    // MARK: - Refusals

    /// Ruling 5: a refusal shows the hub's message and stays; only Try
    /// again sends, as a new action with the same params.
    func testARefusalShowsTheMacsMessageAndOnlyTryAgainSendsAgain() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))
        let firstID = try XCTUnwrap(fixture.store.pendingActions().first).id
        try await echo(fixture, .failed, reason: .claudeNotFound, message: "Claude Code was not found on the Mac")

        let failed = try XCTUnwrap(try form(400, try snapshot(fixture.store), fixture.starter).progress)
        XCTAssertEqual(failed.failure, "Claude Code was not found on the Mac")
        XCTAssertEqual(failed.caption, "Claude Code was not found on the Mac")
        XCTAssertEqual(failed.steps.map(\.state), [.todo, .todo, .todo])
        XCTAssertEqual(try fixture.store.pendingActions().count, 1, "nothing retried on its own")

        let row = try XCTUnwrap(failed.failedRow)
        let retried = try await fixture.starter.retry(row)
        XCTAssertTrue(retried)
        let rows = try fixture.store.pendingActions()
        XCTAssertEqual(rows.count, 1, "the refused row goes once the retry is queued")
        XCTAssertNotEqual(rows.first?.id, firstID)
        XCTAssertEqual(rows.first?.action.params, row.action.params)
        XCTAssertEqual(try form(400, try snapshot(fixture.store), fixture.starter).progress?.stage, .sent)
    }

    /// A hub restart mid-start says so when the echo carries no message;
    /// Dismiss clears the start.
    func testAnUnknownOutcomeSaysTheMacRestarted() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))
        try await echo(fixture, .failed, reason: .outcomeUnknown)

        XCTAssertEqual(
            try form(400, try snapshot(fixture.store), fixture.starter).progress?.failure,
            "Your Mac restarted while applying this — check it on the Mac"
        )
        try fixture.starter.clear(targetID: 400)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
        XCTAssertNil(try form(400, try snapshot(fixture.store), fixture.starter).progress)
    }

    /// Ruling 8: a second start while the first is still saving sends
    /// nothing, and the sheet's Start is off meanwhile.
    func testASecondStartWhileTheFirstIsSavingSendsNothing() async throws {
        let gate = Gate()
        let sent = Counter()
        let starter = SessionStarter(
            enqueue: { _, _, _ in
                sent.count += 1
                await gate.wait()
                return "action-\(sent.count)"
            },
            remove: { _ in }
        )
        let params = try startParams(400)

        let first = Task { try await starter.start(targetID: 400, params: params) }
        // Released on every path, so a failing assertion leaks no waiter.
        defer { Task { await gate.release() } }
        try await poll(timeout: 2) { sent.count == 1 }
        XCTAssertFalse(try form(400, try snapshot(try ReplicaStore.inMemory()), starter).canStart, "Start is off while saving")

        let secondDone = expectation(description: "the second start returns")
        let secondSent = Counter(-1)
        Task {
            secondSent.count = try await starter.start(targetID: 400, params: params) ? 1 : 0
            secondDone.fulfill()
        }
        await fulfillment(of: [secondDone], timeout: 2)
        XCTAssertEqual(secondSent.count, 0, "the second start sent nothing")
        XCTAssertEqual(sent.count, 1)

        await gate.release()
        let firstSent = try await first.value
        XCTAssertTrue(firstSent)
        XCTAssertEqual(starter.attempts[400]?.actionID, "action-1")
    }

    // MARK: - Stop

    /// Ruling 6: Stop is offered on a live session only; it sends
    /// `session_stop` with `{}` and shows in place until the Mac applies
    /// it. Finish stays hidden.
    func testStopSendsSessionStopForALiveSessionOnly() async throws {
        let fixture = try await makeFixture()
        var replica = try snapshot(fixture.store)
        let live = try XCTUnwrap(replica.session(11))
        let actions = SessionActionsModel(session: live, snapshot: replica, inFlight: [], now: now)
        XCTAssertTrue(actions.canStop)
        XCTAssertFalse(actions.showsFinish)

        let notLive = SessionActionsModel(session: try XCTUnwrap(replica.session(13)), snapshot: replica, inFlight: [], now: now)
        XCTAssertFalse(notLive.canStop)
        XCTAssertFalse(notLive.hasActions, "no menu on a session that does not run")

        let stopped = try await fixture.starter.stop(sessionID: 11)
        XCTAssertTrue(stopped)
        let row = try XCTUnwrap(fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .sessionStop)
        XCTAssertEqual(row.entityRecordName, "terminal_session-11")
        XCTAssertEqual(row.action.params, [:])

        replica = try snapshot(fixture.store)
        let pending = SessionActionsModel(session: live, snapshot: replica, inFlight: [], now: now)
        XCTAssertFalse(pending.canStop, "one stop at a time")
        XCTAssertEqual(pending.stopRows.map(\.state), [.sending("Stopping…")])
        let asleep = SessionActionsModel(session: live, snapshot: try snapshot(fixture.store, heartbeatAge: 3_600), inFlight: [], now: now)
        XCTAssertEqual(asleep.stopRows.map(\.state), [.sending("Waiting for your Mac")])

        try await echo(fixture, .failed, reason: .notFound, message: "This session no longer exists on the Mac")
        let refused = SessionActionsModel(session: live, snapshot: try snapshot(fixture.store), inFlight: [], now: now)
        XCTAssertEqual(refused.stopRows.map(\.state), [.failed("This session no longer exists on the Mac")])
        XCTAssertTrue(refused.canStop, "a refusal does not lock Stop")
        try fixture.starter.dismiss(try XCTUnwrap(refused.stopRows.first).pending)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    func testTheStartScreensDrawNoOrange() async throws {
        let fixture = try await makeFixture()
        try await fixture.starter.start(targetID: 400, params: try startParams(400))
        var uses = try form(400, try snapshot(fixture.store, heartbeatAge: 3_600), fixture.starter).toneUses
        try await echo(fixture, .failed, reason: .claudeNotFound, message: "Claude Code was not found on the Mac")
        uses += try form(400, try snapshot(fixture.store), fixture.starter).toneUses
        XCTAssertFalse(uses.isEmpty)
        XCTAssertFalse(uses.contains { $0.tone == .orange }, "progress stages are not orange")
    }
}

/// A gate the first enqueue waits on; releasing is sticky, so any later
/// waiter passes at once.
private actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class Counter {
    var count: Int

    init(_ count: Int = 0) {
        self.count = count
    }
}

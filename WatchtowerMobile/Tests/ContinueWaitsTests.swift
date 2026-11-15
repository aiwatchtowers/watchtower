import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A failed session the owner can continue from this phone waits for them
/// (#1785 follow-up): one rule (`SessionInputModel.waitsToContinue`) — live,
/// takes lines from the phone, typing on, no line on its way — puts it under
/// Now's and the Sessions tab's Waiting for you, into the badges' count and
/// gives the workchat's card its Continue. Not live, or typing off, it stays
/// Ended.
@MainActor
final class ContinueWaitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private let typingOn = PhoneTyping(grant: grant(typing: true), requested: true)

    private static func grant(typing: Bool, deviceID: String = DemoSeed.device.deviceID) -> DeviceGrant {
        DeviceGrant(
            deviceID: deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: typing, startSessionsAllowed: true, permissionsAllowed: false
        )
    }

    /// The seed with "Undo archive" (16) failed: live unless `live` is false.
    private func snapshot(live: Bool = true, overrides: [String: Any] = [:], pending: [PendingAction] = []) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        let at = DemoSeed.JSON.stamp(now.addingTimeInterval(-600))
        let failed = try mirror(TerminalSessionState.self, DemoSeed.JSON.session(16, workbench: DemoSeed.acmeID, [
            "title": "Undo archive", "state_kind": "failed", "state_caption": "Error: rate limit", "state_tone": "red",
            "state_glyph": "exclamationmark", "agent_error": "rate_limit", "target_id": 416, "live": live,
            "last_active_at": at, "state_at": at
        ].merging(overrides) { $1 }))
        snapshot.sessions = snapshot.sessions.filter { $0.id != 16 } + [failed]
        snapshot.grants = [Self.grant(typing: true)]
        snapshot.pending = pending
        return snapshot
    }

    private func waits(_ snapshot: WorkbenchReplicaSnapshot, typing: PhoneTyping? = nil) throws -> Bool {
        SessionInputModel.waitsToContinue(try XCTUnwrap(snapshot.session(16)), in: snapshot, typing: typing ?? typingOn)
    }

    private func lineRow(_ id: String) -> PendingAction {
        PendingAction(
            id: id,
            action: ActionRequestPayload(
                id: id, kind: .sessionInput, entityID: "16", params: ["text": .string("Continue")], createdAt: now,
                deviceID: "phone", hubID: "hub"),
            entityRecordName: SessionStarter.sessionRecordName(16), createdAt: now, state: .pending, errorMessage: nil,
            reason: nil, result: nil, echoStatus: nil, actionSeq: nil, epoch: nil, delivery: nil, undeliveredReason: nil)
    }

    // MARK: - The rule

    func testALiveFailedSessionThePhoneMayTypeIntoWaits() throws {
        XCTAssertTrue(try waits(try snapshot()))
    }

    func testANotLiveFailedSessionIsEnded() throws {
        XCTAssertFalse(try waits(try snapshot(live: false)))
    }

    func testTypingOffKeepsItEnded() throws {
        let snapshot = try snapshot()
        XCTAssertFalse(try waits(snapshot, typing: PhoneTyping(grant: Self.grant(typing: true), requested: false)), "the phone's toggle off")
        XCTAssertFalse(try waits(snapshot, typing: PhoneTyping(grant: Self.grant(typing: false), requested: true)), "the Mac never allowed it")
        XCTAssertFalse(try waits(snapshot, typing: .off))
    }

    func testASessionThatTakesNoLinesFromThePhoneIsEnded() throws {
        XCTAssertFalse(try waits(try snapshot(overrides: ["agent": "codex_cli"])), "an older Mac's Codex session")
    }

    func testALineOnItsWayTakesItOutOfWaiting() throws {
        XCTAssertFalse(try waits(try snapshot(pending: [lineRow("l1")])))
    }

    func testOnlyAFailedSessionWaitsToContinue() throws {
        XCTAssertFalse(try waits(try snapshot(overrides: ["state_kind": "stopped", "state_tone": "secondary"])), "Idle: the composer continues it")
    }

    /// The card's Continue is the same rule.
    func testTheCardOffersContinueExactlyWhenTheSessionWaits() throws {
        for (snapshot, typing) in [
            (try snapshot(), true), (try snapshot(), false), (try snapshot(pending: [lineRow("l1")]), true)
        ] {
            let session = try XCTUnwrap(snapshot.session(16))
            let input = SessionInputModel(
                session: session, snapshot: snapshot, grant: Self.grant(typing: true), typingRequested: typing, delivered: nil, now: now)
            let card = try XCTUnwrap(WorkchatStateCard(session: session, input: input, permission: nil, macOnline: true))
            let phoneTyping = PhoneTyping(grant: Self.grant(typing: true), requested: typing)
            XCTAssertEqual(card.actions.contains(.continueSession), try waits(snapshot, typing: phoneTyping))
            XCTAssertEqual(input.continues, try waits(snapshot, typing: phoneTyping))
        }
    }

    // MARK: - Now, the Sessions tab, the badges

    func testNowListsItUnderWaitingInItsRedLook() throws {
        let model = NowModel(snapshot: try snapshot(), linked: true, now: now, typing: typingOn)
        let row = try XCTUnwrap(model.waitingForYou.first { $0.id == .session(16) })
        XCTAssertEqual(row.title, "Undo archive — failed")
        XCTAssertEqual(row.tone, .red)
        XCTAssertEqual(row.glyph, "exclamationmark")
        XCTAssertEqual(row.destination, .session(16))
        XCTAssertEqual(row.meta, "Acme · Error: rate limit")
        XCTAssertFalse(model.ended.contains { $0.id == .session(16) }, "one row per thing")
        XCTAssertEqual(model.waitingCount, 4, "three asks and the failed session")
    }

    func testNowKeepsItEndedWhenNotLiveOrTypingIsOff() throws {
        for (snapshot, typing) in [(try snapshot(live: false), typingOn), (try snapshot(), PhoneTyping.off)] {
            let model = NowModel(snapshot: snapshot, linked: true, now: now, typing: typing)
            XCTAssertFalse(model.waitingForYou.contains { $0.id == .session(16) })
            XCTAssertTrue(model.ended.contains { $0.id == .session(16) })
            XCTAssertEqual(model.waitingCount, 3)
        }
    }

    /// An open ask of the failed session already waits: the session is not
    /// a second row, nor a second count.
    func testAFailedSessionWithAnOpenAskShowsOnceAsTheAsk() throws {
        var snapshot = try snapshot()
        snapshot.asks.append(try mirror(OwnerAsk.self, DemoSeed.JSON.ask(150, workbench: DemoSeed.acmeID, ["session_id": 16])))
        let model = NowModel(snapshot: snapshot, linked: true, now: now, typing: typingOn)
        XCTAssertTrue(model.waitingForYou.contains { $0.id == .ask(150) })
        XCTAssertFalse(model.waitingForYou.contains { $0.id == .session(16) })
        XCTAssertEqual(model.waitingCount, snapshot.waitingCount(typing: typingOn))
        XCTAssertEqual(snapshot.waitingCount(typing: typingOn), 4)
    }

    func testTheSessionsTabListsItUnderWaiting() throws {
        let waiting = try menu(try snapshot(), typing: typingOn)
        XCTAssertTrue(try XCTUnwrap(waiting.sections.first { $0.title == "Waiting for you" }).rows.contains { $0.id == 16 })
        XCTAssertFalse(waiting.sections.first { $0.title == "Ended" }?.rows.contains { $0.id == 16 } ?? false)
        let row = try XCTUnwrap(waiting.sections.flatMap(\.rows).first { $0.id == 16 })
        XCTAssertEqual(row.tone, .red, "the failed look stays")

        for (snapshot, typing) in [(try snapshot(live: false), typingOn), (try snapshot(), PhoneTyping.off)] {
            let menu = try menu(snapshot, typing: typing)
            XCTAssertTrue(try XCTUnwrap(menu.sections.first { $0.title == "Ended" }).rows.contains { $0.id == 16 })
        }
    }

    /// Now's rows, its header count, the snapshot's badge count and the
    /// Sessions tab agree in every case.
    func testNowTheSessionsTabAndTheBadgeAgree() throws {
        for (snapshot, typing) in [
            (try snapshot(), typingOn), (try snapshot(), .off), (try snapshot(live: false), typingOn),
            (try snapshot(pending: [lineRow("l1")]), typingOn)
        ] {
            let now = NowModel(snapshot: snapshot, linked: true, now: self.now, typing: typing)
            let badge = snapshot.waitingCount(typing: typing)
            XCTAssertEqual(now.waitingCount ?? 0, badge)
            XCTAssertEqual(NowModel.waitingCount(in: snapshot, typing: typing), badge)
            XCTAssertEqual(RootTabView.Tab.now.badge(waitingCount: badge), badge)
            let nowWaits = now.waitingForYou.contains { $0.id == .session(16) }
            let tabWaits = try XCTUnwrap(try menu(snapshot, typing: typing).sections.first).rows.contains { $0.id == 16 }
            XCTAssertEqual(nowWaits, tabWaits)
        }
    }

    /// The replica model's badge follows the phone's typing as the hub
    /// session feeds it, and publishes only on a change.
    func testTheReplicaBadgeFollowsTyping() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let hub = TestPhone.hub(over: transport)
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        let at = DemoSeed.JSON.stamp(now.addingTimeInterval(-600))
        try await hub.save(try DemoSeed.workbenchRecords(now: now) + [
            try DemoSeed.record(kind: .terminalSession, id: 16, json: DemoSeed.JSON.session(16, workbench: DemoSeed.acmeID, [
                "title": "Undo archive", "state_kind": "failed", "state_caption": "Error: rate limit", "state_tone": "red",
                "last_active_at": at, "state_at": at
            ]), modifiedAt: now),
            try TestPhone.grantRecord(Self.grant(typing: true, deviceID: TestPhone.deviceID()), keys: TestPhone.keyboxKeys(), modifiedAt: now)
        ])
        _ = try await hydrator.hydrateOnce()
        let model = WorkbenchReplicaModel()
        model.start(store: store)
        try await poll { model.snapshot.session(16)?.live == true && !model.snapshot.grants.isEmpty }
        XCTAssertEqual(model.waitingCount, 3, "typing off by default")

        model.typing = PhoneTypingSource(deviceID: TestPhone.deviceID(), requested: true)
        XCTAssertEqual(model.waitingCount, 4)
        model.typing.requested = false
        XCTAssertEqual(model.waitingCount, 3)
    }

    private func menu(_ snapshot: WorkbenchReplicaSnapshot, typing: PhoneTyping) throws -> WorkbenchMenuModel {
        try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, now: now, asOf: nil, typing: typing))
    }
}

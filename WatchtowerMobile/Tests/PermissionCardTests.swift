import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A Claude Code permission prompt on the phone (#517, spec 2026-10-17
/// §5.4, §6): the card in place of "Needs approval on the Mac", read-only
/// without the grant, Bash's confirmation, the clipped summary, Codex's
/// notice, Interrupt's gate, and the request in Now and the badge.
final class PermissionCardTests: XCTestCase {
    private let now = Date()

    private func grant(permissions: Bool = true, typing: Bool = true) -> DeviceGrant {
        DeviceGrant(
            deviceID: DemoSeed.device.deviceID, hubID: "hub", name: "Demo iPhone", scope: .private, linked: true,
            typingAllowed: typing, startSessionsAllowed: true, permissionsAllowed: permissions
        )
    }

    /// The demo snapshot with session 12 ("Board lanes", Needs approval)
    /// waiting on `request`.
    private func snapshot(_ requests: [[String: Any]] = [permissionRequestJSON(7, session: 12)]) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        snapshot.permissionRequests = try requests.map { try mirror(PermissionRequest.self, $0) }
        return snapshot
    }

    private func detail(
        _ snapshot: WorkbenchReplicaSnapshot,
        session sessionID: Int64 = 12,
        grant: DeviceGrant? = nil,
        requested: Bool = true
    ) throws -> SessionDetailModel {
        try XCTUnwrap(SessionDetailModel(
            sessionID: sessionID, snapshot: snapshot, report: nil, timeline: nil, now: now,
            permissions: PermissionAccess(grant: grant ?? self.grant(), requested: requested)
        ))
    }

    func testAPendingRequestReplacesTheApprovalNotice() throws {
        let card = try XCTUnwrap(try detail(try snapshot()).permission)

        XCTAssertNil(try detail(try snapshot()).approvalNotice, "the card stands in for the notice")
        XCTAssertEqual(card.requestID, 7)
        XCTAssertEqual(card.tool, "Bash")
        XCTAssertEqual(card.summary, "go test ./...\nRun the tests")
        XCTAssertNil(card.clippedNote)
        XCTAssertTrue(card.canAnswer)
        XCTAssertNil(card.hint)

        let none = try detail(try snapshot([]))
        XCTAssertNil(none.permission)
        XCTAssertEqual(none.approvalNotice, "Needs approval on the Mac", "no request: the old notice")
    }

    func testWithoutTheGrantTheCardIsReadOnlyWithAHint() throws {
        let off = try XCTUnwrap(try detail(try snapshot(), grant: grant(), requested: false).permission)
        XCTAssertFalse(off.canAnswer)
        XCTAssertEqual(off.hint, .turnOn)

        let waiting = try XCTUnwrap(try detail(try snapshot(), grant: grant(permissions: false), requested: true).permission)
        XCTAssertFalse(waiting.canAnswer)
        XCTAssertEqual(waiting.hint, .waitingForMac)
        XCTAssertEqual(
            PermissionHint.waitingForMac.text,
            "Allow answering permission prompts on the Mac: Watchtower → Settings → Mobile → Allow…"
        )

        let typingOnly = try XCTUnwrap(
            try detail(try snapshot(), grant: grant(permissions: false, typing: true), requested: true).permission
        )
        XCTAssertFalse(typingOnly.canAnswer, "the typing grant never implies answers")

        let noGrant = try XCTUnwrap(SessionDetailModel(
            sessionID: 12, snapshot: try snapshot(), report: nil, timeline: nil, now: now,
            permissions: PermissionAccess(grant: nil, requested: true)
        )?.permission)
        XCTAssertEqual(noGrant.hint, .waitingForMac)
    }

    /// The bar's footer points at a card this phone may answer; with no
    /// card, or a read-only one, it keeps "Needs approval on the Mac".
    func testTheBarFooterPointsAtAnAnswerableCard() throws {
        let replica = try snapshot()
        let session = try XCTUnwrap(replica.session(12))
        func footer(_ access: PermissionAccess, in snapshot: WorkbenchReplicaSnapshot) -> String? {
            SessionInputModel(
                session: session, snapshot: snapshot, grant: grant(), typingRequested: true, delivered: nil, now: now,
                answersPermission: PermissionCardModel.answerable(session, in: snapshot, access: access)
            ).approvalText
        }

        XCTAssertEqual(footer(PermissionAccess(grant: grant(), requested: true), in: replica), "Answer the request above")
        XCTAssertEqual(
            footer(PermissionAccess(grant: grant(permissions: false), requested: true), in: replica),
            "Needs approval on the Mac", "a read-only card"
        )
        XCTAssertEqual(footer(PermissionAccess(grant: grant(), requested: false), in: replica), "Needs approval on the Mac")
        XCTAssertEqual(footer(PermissionAccess(grant: grant(), requested: true), in: try snapshot([])), "Needs approval on the Mac", "no card")
        XCTAssertFalse(
            SessionInputModel(
                session: session, snapshot: replica, grant: grant(), typingRequested: true, delivered: nil, now: now,
                answersPermission: true
            ).canSend,
            "still no send at a prompt"
        )
    }

    func testBashAllowAsksForConfirmation() throws {
        let bash = try XCTUnwrap(try detail(try snapshot()).permission)
        XCTAssertTrue(bash.confirmsAllow)
        XCTAssertEqual(bash.allowConfirmTitle, "Allow this command once?")

        let edit = try XCTUnwrap(try detail(try snapshot([
            permissionRequestJSON(8, session: 12, ["tool_name": "Edit", "summary": "/tmp/acme/main.go"])
        ])).permission)
        XCTAssertFalse(edit.confirmsAllow)
    }

    func testAClippedSummarySaysSo() throws {
        let clipped = try XCTUnwrap(try detail(try snapshot([
            permissionRequestJSON(9, session: 12, ["summary": String(repeating: "a", count: 2000), "summary_clipped": true])
        ])).permission)
        XCTAssertEqual(clipped.clippedNote, "Shortened on the phone — the full text is on the Mac")
    }

    /// The hub never publishes a Codex request; even a stray one leaves a
    /// Codex session with the old notice.
    func testCodexSessionKeepsTheNotice() throws {
        var snapshot = try snapshot([permissionRequestJSON(7, session: 30)])
        snapshot.sessions.append(try mirror(TerminalSessionState.self, DemoSeed.JSON.session(30, workbench: DemoSeed.acmeID, [
            "agent": "codex_cli", "state_kind": "needs_approval", "state_caption": "Needs approval", "state_tone": "orange"
        ])))

        let codex = try detail(snapshot, session: 30)

        XCTAssertNil(codex.permission)
        XCTAssertEqual(codex.approvalNotice, "Needs approval on the Mac")
    }

    func testInterruptOnlyWhileWorkingAndAllowedToType() throws {
        let replica = try snapshot([])
        let working = try XCTUnwrap(replica.session(10), "the demo's working session")
        func actions(
            _ session: TerminalSessionState,
            typing: Bool = true,
            requested: Bool = true,
            in snapshot: WorkbenchReplicaSnapshot? = nil
        ) -> SessionActionsModel {
            SessionActionsModel(
                session: session, snapshot: snapshot ?? replica, inFlight: [], now: now,
                grant: grant(typing: typing), typingRequested: requested
            )
        }

        XCTAssertTrue(actions(working).canInterrupt)
        XCTAssertTrue(actions(working).hasActions)
        XCTAssertFalse(actions(working, typing: false).canInterrupt, "the Mac has not allowed typing")
        XCTAssertFalse(actions(working, requested: false).canInterrupt, "the phone's typing toggle is off")
        for id: Int64 in [11, 12, 13, 20] {
            let session = try XCTUnwrap(replica.session(id))
            XCTAssertFalse(actions(session).canInterrupt, "session \(id) is \(session.stateKind.rawValue)")
        }
        let atPrompt = try snapshot([permissionRequestJSON(7, session: 10)])
        XCTAssertFalse(actions(working, in: atPrompt).canInterrupt, "at a prompt the phone offers Deny, never Esc")
        XCTAssertFalse(
            SessionActionsModel(
                session: working, snapshot: replica, inFlight: [SessionInputSender.interruptKey(10)], now: now,
                grant: grant(), typingRequested: true
            ).canInterrupt,
            "one interrupt at a time"
        )
    }

    func testAPendingRequestShowsInNowAndTheBadge() throws {
        let replica = try snapshot([permissionRequestJSON(7, session: 12, [
            "summary": "rm -rf build\nClean the build", "created_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
        ])])

        let model = NowModel(snapshot: replica, now: now)

        let card = try XCTUnwrap(model.waiting.first)
        XCTAssertEqual(card.kindLabel, "Needs approval")
        XCTAssertEqual(card.title, "Bash")
        XCTAssertEqual(card.subline, "rm -rf build")
        XCTAssertEqual(card.destination, .session(12), "it opens the session's card")
        XCTAssertEqual(model.waiting.count, 4, "with the three open asks")
        XCTAssertEqual(replica.openAskCount, 4, "the Workbench badge counts it")
        XCTAssertEqual(try snapshot([]).openAskCount, 3)
        XCTAssertEqual(replica.pendingPermission(for: 12)?.id, 7)
        XCTAssertNil(replica.pendingPermission(for: 11))
    }
}

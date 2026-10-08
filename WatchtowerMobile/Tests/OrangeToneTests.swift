import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Spec §14: orange appears only on waiting-for-you and ask elements. The
/// project has no snapshot library, so this runs at the tone level: every
/// screen model the demo seed produces lists each colour it draws
/// (`ToneUse`) with a role decided from its data, and the views paint only
/// model tones. SwiftLint's `orange_outside_phone_tone` keeps views and
/// models from naming orange anywhere but `PhoneTone.swift`.
final class OrangeToneTests: XCTestCase {
    func testOrangeOnlyOnWaitingAndAskElementsAcrossTheDemoScreens() throws {
        let now = Date()
        let snapshot = try demoSnapshot(now: now)
        var uses: [ToneUse] = NowModel(snapshot: snapshot, now: now).toneUses
        for workbench in snapshot.workbenches {
            uses += WorkbenchCardModel(workbench).toneUses
            uses += try XCTUnwrap(WorkbenchMenuModel(workbenchID: workbench.id, snapshot: snapshot, now: now)).toneUses
            for filter in BoardFilter.allCases {
                uses += BoardModel(workbenchID: workbench.id, snapshot: snapshot, filter: filter).toneUses
            }
        }
        for target in snapshot.targets {
            uses += try XCTUnwrap(BoardTargetDetailModel(targetID: target.id, snapshot: snapshot, now: now)).toneUses
        }

        let orange = uses.filter { $0.tone == .orange }
        XCTAssertFalse(orange.isEmpty, "the demo must draw orange somewhere, or this test proves nothing")
        for use in orange {
            XCTAssertTrue(use.isWaitingOrAsk, "orange on a non-waiting element: \(use.element)")
        }
        XCTAssertTrue(uses.contains { $0.tone != .orange }, "the demo draws other tones too")
    }

    /// A session's orange counts as waiting only when the record is in one
    /// of the orange states; a mislabelled record would fail the test above.
    func testASessionDotIsWaitingOnlyInTheOrangeStates() throws {
        let waiting = try mirror(TerminalSessionState.self, DemoSeed.JSON.session(1, workbench: 1, [
            "state_kind": "needs_approval", "state_tone": "orange"
        ]))
        XCTAssertTrue(SessionRowModel(waiting, now: Date()).toneUses.allSatisfy(\.isWaitingOrAsk))
        let mislabelled = try mirror(TerminalSessionState.self, DemoSeed.JSON.session(2, workbench: 1, [
            "state_kind": "working", "state_tone": "orange"
        ]))
        XCTAssertFalse(SessionRowModel(mislabelled, now: Date()).toneUses.contains { $0.tone == .orange && $0.isWaitingOrAsk })
    }

    /// The tones the phone computes from data (target status, priority, the
    /// Mac chip) are never orange, for every known value and an unknown one.
    func testDataDrivenTonesAreNeverOrange() throws {
        let statuses = WorkbenchTargetStatus.knownValues + [WorkbenchTargetStatus(rawValue: "newer")]
        for status in statuses {
            XCTAssertNotEqual(BoardRowModel.status(status).tone, .orange, "status \(status.rawValue)")
        }
        let priorities = WorkbenchTargetPriority.knownValues + [WorkbenchTargetPriority(rawValue: "newer")]
        for priority in priorities {
            let target = try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(1, workbench: 1, ["priority": priority.rawValue]))
            let row = BoardRowModel(target, snapshot: WorkbenchReplicaSnapshot())
            XCTAssertTrue(row.toneUses.allSatisfy { $0.tone != .orange }, "priority \(priority.rawValue)")
        }
        var snapshot = WorkbenchReplicaSnapshot()
        let now = Date()
        XCTAssertNotEqual(NowModel(snapshot: snapshot, now: now).macChipTone, .orange)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: now, lastRelayAt: now, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "_user", sharing: .none
        )
        XCTAssertNotEqual(NowModel(snapshot: snapshot, now: now).macChipTone, .orange)
        XCTAssertNotEqual(NowModel(snapshot: snapshot, now: now.addingTimeInterval(800)).macChipTone, .orange)
    }
}

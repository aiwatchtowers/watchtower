import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// Spec §14: orange appears only on waiting-for-you and ask elements. The
/// project has no snapshot library, so this runs at the tone level: every
/// screen model the demo seed produces lists each colour it draws
/// (`ToneUse`), and the views paint only those tones.
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
}

import XCTest
@testable import WatchtowerCore

@MainActor
final class ArtifactNoticeGateTests: XCTestCase {
    func testALateNoticeReachesThePanelWhileTheSameArtifactIsShown() {
        let gate = ArtifactNoticeGate()
        var shown: [String] = []
        let deliver = gate.guarded { shown.append($0) }
        deliver("Export failed: disk full")
        XCTAssertEqual(shown, ["Export failed: disk full"])
    }

    /// The panel switched to artifact B before A's export failed: A's
    /// failure is not shown next to B.
    func testALateNoticeIsDroppedAfterThePanelMovedOn() {
        let gate = ArtifactNoticeGate()
        var shown: [String] = []
        let fromA = gate.guarded { shown.append($0) }
        gate.advance()
        fromA("Print failed: the page did not finish loading.")
        XCTAssertEqual(shown, [], "A's failure must not land on B")
        let fromB = gate.guarded { shown.append($0) }
        fromB("Export failed: disk full")
        XCTAssertEqual(shown, ["Export failed: disk full"], "B's own failure still shows")
    }

    /// Moving away and back is still a move: the notice belonged to the
    /// earlier showing.
    func testAdvancingTwiceStillDropsTheEarlierNotice() {
        let gate = ArtifactNoticeGate()
        var shown: [String] = []
        let early = gate.guarded { shown.append($0) }
        gate.advance()
        gate.advance()
        early("late")
        XCTAssertEqual(shown, [])
    }
}

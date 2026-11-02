import SwiftUI
import DesignKit
import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class WorkchatLiveLineTests: XCTestCase {
    func testTheExistingCaptionSlotHasOneStableHeightInEveryState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let agent = SessionLiveAgent(ref: SessionFeedSubagent(toolUseID: "a", status: "running"))
        let busy = SessionFeedLive(observedAt: now, current: SessionLiveAction(tool: "Bash", summary: "go test", startedAt: now - 2), agents: [agent])
        for (working, loaded, snapshot, error) in [
            (false, false, nil as SessionFeedLive?, nil as String?),
            (true, false, nil, nil),
            (true, true, busy, nil),
            (true, true, busy, "Activity unavailable")
        ] {
            let line = WorkchatLiveLine(snapshot: snapshot, error: error, loaded: loaded, working: working,
                                        stateAt: nil, onRetry: {}, onOpenAgent: { _ in }, referenceDate: now)
            XCTAssertEqual(ViewRenderProbe.fittingHeight(line, width: 340), ListLayout.lineMinHeight)
        }
    }
}

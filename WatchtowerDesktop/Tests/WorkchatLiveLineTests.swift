import SwiftUI
import DesignKit
import XCTest
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerChatText

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
                                        stateAt: nil, paneKey: "session-1", memory: WorkchatPaneMemory(),
                                        onRetry: {}, onOpenAgent: { _ in }, referenceDate: now)
            XCTAssertEqual(ViewRenderProbe.fittingHeight(line, width: 340), ListLayout.lineMinHeight)
        }
    }
    func testIdleAndEndedRowKeepsTheSlotHeightWithDone() {
        let done = [SessionFeedSubagent(toolUseID: "d1", type: "Explore", status: "finished")]
        let line = WorkchatLiveLine(snapshot: nil, error: nil, loaded: false, working: false, stateAt: nil, done: done,
                                    paneKey: "session-1", memory: WorkchatPaneMemory(), onRetry: {}, onOpenAgent: { _ in })
        XCTAssertEqual(ViewRenderProbe.fittingHeight(line, width: 340), ListLayout.lineMinHeight)
    }

    func testUnknownEmptyPopoverRendersUnknownInsteadOfNone() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unknown = SessionFeedLive(observedAt: now, agentsState: "unknown")
        let list = WorkchatLivePresentation.agentsList(snapshot: unknown, error: nil, feedLoaded: true, feedError: nil,
                                                       done: [], idle: false, now: now)
        let popover = WorkchatAgentsPopover(list: list, paneKey: "p", memory: WorkchatPaneMemory()) { _ in }
        let texts = try popover.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(texts.contains("Agents"))
        XCTAssertTrue(texts.contains("WORKING"))
        XCTAssertTrue(texts.contains("Agent status unavailable"))
        XCTAssertFalse(texts.contains("No agents working"))
    }

    func testDoneSectionFollowsPaneMemory() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let done = [SessionFeedSubagent(toolUseID: "d1", type: "Explore", description: "Read the filter", status: "finished")]
        let list = WorkchatLivePresentation.agentsList(snapshot: SessionFeedLive(observedAt: now), error: nil, feedLoaded: true,
                                                       feedError: nil, done: done, idle: true, now: now)
        let memory = WorkchatPaneMemory()
        var opened: [String] = []
        let open = WorkchatAgentsPopover(list: list, paneKey: "p", memory: memory) { opened.append($0.toolUseID) }
        XCTAssertNoThrow(try open.inspect().find(text: "Done · 1"))
        XCTAssertNoThrow(try open.inspect().find(text: "Read the filter"), "nothing works: Done opens by itself")
        try open.inspect().find(ViewType.Button.self) { (try? $0.find(text: "Read the filter")) != nil }.tap()
        XCTAssertEqual(opened, ["d1"])
        memory.setDoneOpen("p", false)
        let closed = WorkchatAgentsPopover(list: list, paneKey: "p", memory: memory) { _ in }
        XCTAssertThrowsError(try closed.inspect().find(text: "Read the filter"), "the owner's toggle wins")
    }

}

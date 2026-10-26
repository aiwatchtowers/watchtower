import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// A workbench opens on its sessions in the Desktop sessions panel's order
/// (spec §5.5, mockup 2): Waiting for you, Working, Ready to check, then
/// "▸ N finished" folded.
final class WorkbenchSessionsOrderTests: XCTestCase {
    private let now = Date()

    private func menu(extra: [[String: Any]] = []) throws -> WorkbenchMenuModel {
        var snapshot = try demoSnapshot(now: now)
        snapshot.sessions += try extra.map { try mirror(TerminalSessionState.self, $0) }
        return try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, now: now, asOf: nil))
    }

    func testSessionsFollowTheDesktopPanelOrder() throws {
        let menu = try menu(extra: [DemoSeed.JSON.session(18, workbench: DemoSeed.acmeID, [
            "title": "Diff reviewer polish", "state_kind": "ready_to_check", "state_caption": "Ready for review · ask #112",
            "state_tone": "purple", "state_glyph": "checklist", "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-2_400))
        ])])
        XCTAssertEqual(menu.sections.map(\.title), ["Waiting for you", "Working", "Ready to check", "Not running"])
        XCTAssertEqual(menu.sections.map { $0.rows.map(\.id) }, [[11, 12, 14, 15, 16], [10], [18], [17]])
        XCTAssertEqual(menu.sections.first?.tone, .waitingForYou)
        XCTAssertEqual(menu.finished.map(\.id), [13], "finished with no open ask folds")
        XCTAssertEqual(menu.finishedLabel, "1 finished")
    }

    func testEmptySectionsAreLeftOut() throws {
        let menu = try menu()
        XCTAssertEqual(menu.sections.map(\.title), ["Waiting for you", "Working", "Not running"])
    }

    func testARowShowsTheCaptionAndATrailingTime() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.heartbeat = nil
        let menu = try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, now: now, asOf: nil))
        let working = try XCTUnwrap(menu.sections.first { $0.title == "Working" }?.rows.first)
        XCTAssertEqual(working.panelMetaItems.first?.text, "Working · running tests")
        XCTAssertEqual(working.time, "3:14", "a working session counts up")
        let waiting = try XCTUnwrap(menu.sections.first?.rows.first)
        XCTAssertEqual(waiting.icon, .state(glyph: "questionmark", tone: .waitingForYou))
        XCTAssertEqual(waiting.time, "2m", "a waiting one shows its age")
    }

    func testAsleepMacStopsTheWorkingTimer() throws {
        let snapshot = try demoSnapshot(now: now)
        let lastSeen = now.addingTimeInterval(-2_400)
        let menu = try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, now: now, asOf: lastSeen))
        let working = try XCTUnwrap(menu.sections.first { $0.title == "Working" }?.rows.first)
        XCTAssertEqual(working.time, "as of 40 min ago", "a stale Mac's session does not look live")
        let stopped = try XCTUnwrap(menu.sections.first?.rows.first { $0.id == 15 })
        XCTAssertEqual(stopped.time, "3h", "a session that is not live keeps its age")
    }

    func testOpenAsksShowInTheRowUnlessTheCaptionSaysSo() throws {
        let menu = try menu(extra: [DemoSeed.JSON.session(18, workbench: DemoSeed.acmeID, [
            "title": "Diff reviewer polish", "state_kind": "ready_to_check", "state_caption": "Ready to check · ask #112",
            "state_tone": "purple", "state_glyph": "checklist", "open_asks": 2
        ])])
        let ready = try XCTUnwrap(menu.sections.first { $0.title == "Ready to check" }?.rows.first)
        XCTAssertEqual(Array(ready.panelMetaItems.map(\.text).prefix(2)), ["Ready to check · ask #112", "2 asks open"])
        XCTAssertEqual(ready.panelMetaItems[1].tone, .waitingForYou)
        let finished = try XCTUnwrap(menu.sections.first?.rows.first { $0.id == 14 })
        XCTAssertFalse(finished.panelMetaItems.dropFirst().contains { $0.text == "1 ask open" }, "the caption already says it")
    }
}

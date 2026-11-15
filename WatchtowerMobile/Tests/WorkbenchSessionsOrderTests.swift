import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// A workbench opens on its sessions split as Now splits them (#1788):
/// Waiting for you (asks, approvals, verdicts), Working, Ended in the last
/// day, then "▸ N older" folded.
final class WorkbenchSessionsOrderTests: XCTestCase {
    /// Whole seconds: the payload stamps are Unix seconds, so the 24 h edge is exact.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func menu(extra: [[String: Any]] = []) throws -> WorkbenchMenuModel {
        var snapshot = try demoSnapshot(now: now)
        snapshot.sessions += try extra.map { try mirror(TerminalSessionState.self, $0) }
        return try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, now: now, asOf: nil))
    }

    func testSessionsSplitLikeNow() throws {
        let menu = try menu(extra: [DemoSeed.JSON.session(18, workbench: DemoSeed.acmeID, [
            "title": "Diff reviewer polish", "state_kind": "ready_to_check", "state_caption": "Ready for review · ask #112",
            "state_tone": "purple", "state_glyph": "checklist", "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-2_400))
        ])])
        XCTAssertEqual(menu.sections.map(\.title), ["Waiting for you", "Working", "Ended"])
        // 11 ask, 12 approval, 18 a verdict, 14 finished with an ask open; 13 finished, 15 stopped, 16 failed.
        XCTAssertEqual(menu.sections.map { $0.rows.map(\.id) }, [[11, 12, 18, 14], [10], [13, 15, 16]])
        XCTAssertEqual(menu.sections.map(\.tone), [.waitingForYou, .secondary, .secondary])
        XCTAssertEqual(menu.older.map(\.id), [17], "ended more than a day ago folds")
        XCTAssertEqual(menu.olderLabel, "1 older")
    }

    /// A failed or stopped session waits only while something of it is
    /// open; with nothing the phone can do it is Ended, its caption red.
    func testAFailedSessionWaitsOnlyWithAnOpenAsk() throws {
        let menu = try menu(extra: [DemoSeed.JSON.session(19, workbench: DemoSeed.acmeID, [
            "title": "Retry migration", "state_kind": "failed", "state_caption": "Error: crashed", "state_tone": "red",
            "live": false, "is_ring": true, "open_asks": 1, "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
        ])])
        XCTAssertTrue(try XCTUnwrap(menu.sections.first).rows.contains { $0.id == 19 })
        let ended = try XCTUnwrap(menu.sections.first { $0.title == "Ended" })
        let failed = try XCTUnwrap(ended.rows.first { $0.id == 16 })
        XCTAssertEqual(failed.tone, .red)
    }

    /// The window and the order use when the session ended (`state_at`,
    /// Now's time), not its last activity: a long session that ended an
    /// hour ago is Ended; exactly 24 h still is, a second more is older.
    func testEndedUsesTheStateTime() throws {
        func ended(_ id: Int64, lastActive: TimeInterval, state: TimeInterval) -> [String: Any] {
            DemoSeed.JSON.session(id, workbench: DemoSeed.acmeID, [
                "title": "Ended \(id)", "state_kind": "finished", "live": false, "is_ring": true,
                "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-lastActive)),
                "state_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-state))
            ])
        }
        let menu = try menu(extra: [
            ended(40, lastActive: 3 * 86_400, state: 3_600),
            ended(41, lastActive: 600, state: 86_400),
            ended(42, lastActive: 600, state: 86_401)
        ])
        let rows = try XCTUnwrap(menu.sections.first { $0.title == "Ended" }).rows.map(\.id)
        XCTAssertEqual(rows.first, 40, "ended an hour ago, though active 3 days ago")
        XCTAssertEqual(rows.last, 41, "exactly 24 h is still Ended, and the oldest end reads last")
        XCTAssertTrue(menu.older.contains { $0.id == 42 })
        XCTAssertFalse(rows.contains(42))
    }

    /// An unknown state from a newer Mac: working while live, else ended.
    func testAnUnknownStateFallsBackOnLive() throws {
        let menu = try menu(extra: [
            DemoSeed.JSON.session(30, workbench: DemoSeed.acmeID, ["title": "Live new", "state_kind": "paused_new", "live": true]),
            DemoSeed.JSON.session(31, workbench: DemoSeed.acmeID, [
                "title": "Gone new", "state_kind": "paused_new", "live": false,
                "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-60))
            ])
        ])
        XCTAssertTrue(try XCTUnwrap(menu.sections.first { $0.title == "Working" }).rows.contains { $0.id == 30 })
        XCTAssertTrue(try XCTUnwrap(menu.sections.first { $0.title == "Ended" }).rows.contains { $0.id == 31 })
    }

    func testEmptySectionsAreLeftOut() throws {
        var snapshot = try demoSnapshot(now: now)
        snapshot.sessions.removeAll { $0.workbenchID == DemoSeed.acmeID && $0.id != 10 }
        let menu = try XCTUnwrap(WorkbenchMenuModel(workbenchID: DemoSeed.acmeID, snapshot: snapshot, now: now, asOf: nil))
        XCTAssertEqual(menu.sections.map(\.title), ["Working"])
        XCTAssertNil(menu.olderLabel, "no fold with nothing older")
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
        let stopped = try XCTUnwrap(menu.sections.first { $0.title == "Ended" }?.rows.first { $0.id == 15 })
        XCTAssertEqual(stopped.time, "3h", "a session that is not live keeps its age")
    }

    func testOpenAsksShowInTheRowUnlessTheCaptionSaysSo() throws {
        let menu = try menu(extra: [DemoSeed.JSON.session(18, workbench: DemoSeed.acmeID, [
            "title": "Diff reviewer polish", "state_kind": "ready_to_check", "state_caption": "Ready to check · ask #112",
            "state_tone": "purple", "state_glyph": "checklist", "open_asks": 2
        ])])
        let ready = try XCTUnwrap(menu.sections.first?.rows.first { $0.id == 18 })
        XCTAssertEqual(Array(ready.panelMetaItems.map(\.text).prefix(2)), ["Ready to check · ask #112", "2 asks open"])
        XCTAssertEqual(ready.panelMetaItems[1].tone, .waitingForYou)
        let finished = try XCTUnwrap(menu.sections.first?.rows.first { $0.id == 14 })
        XCTAssertFalse(finished.panelMetaItems.dropFirst().contains { $0.text == "1 ask open" }, "the caption already says it")
    }
}

import SwiftUI
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// One SESSIONS row (spec §4.5, §13 B2): the Mac's resolved dot, label and
/// glyph drawn as given, the report line, the open-ask pill and "▸ N closed".
final class SessionRowTests: XCTestCase {
    private func session(_ overrides: [String: Any]) throws -> TerminalSessionState {
        try mirror(TerminalSessionState.self, DemoSeed.JSON.session(31, workbench: 7, overrides))
    }

    /// The Kit fixture's report fields (`terminal_session.json`).
    func testTheReportLineRendersTheFixtureValues() throws {
        let row = SessionRowModel(try session([
            "report_target_id": 415, "report_done": 1, "report_total": 2, "report_pr_line": "PR #175 open"
        ]), now: Date())
        XCTAssertEqual(row.metaItems.dropFirst().map(\.text), ["#415 · 1/2", "PR #175 open"])
    }

    func testARecordWithoutAReportTargetHasNoReportLine() throws {
        let row = SessionRowModel(try session(["report_done": 1, "report_total": 2, "report_pr_line": "PR #175 open"]), now: Date())
        XCTAssertEqual(row.metaItems.map(\.text), [row.caption], "the caption alone")
    }

    func testAReportWithoutAPRLineOrTotalsStaysShort() throws {
        let noPR = SessionRowModel(try session(["report_target_id": 415, "report_done": 0, "report_total": 3]), now: Date())
        XCTAssertEqual(noPR.metaItems.dropFirst().map(\.text), ["#415 · 0/3"])
        let noTotals = SessionRowModel(try session(["report_target_id": 415, "report_pr_line": ""]), now: Date())
        XCTAssertEqual(noTotals.metaItems.dropFirst().map(\.text), ["#415"])
    }

    /// Every published tone maps to exactly the system colour of spec §14;
    /// a tone from a newer Mac falls back to secondary.
    func testEveryStateToneMapsToItsSystemColour() {
        let expected: [TerminalSessionState.Tone: Color] = [
            .green: .green, .orange: .orange, .blue: .blue, .red: .red, .secondary: .secondary
        ]
        XCTAssertEqual(Set(expected.keys), Set(TerminalSessionState.Tone.knownValues))
        for (tone, color) in expected {
            XCTAssertEqual(PhoneTone(tone).color, color, "tone \(tone.rawValue)")
        }
        XCTAssertEqual(PhoneTone(TerminalSessionState.Tone(rawValue: "purple")), .secondary)
    }

    func testANonLiveSessionDrawsARingAndALiveOneAFill() throws {
        let stopped = SessionRowModel(try session([
            "live": false, "is_ring": true, "state_kind": "stopped", "state_caption": "Stopped", "state_tone": "secondary"
        ]), now: Date())
        XCTAssertTrue(stopped.isRing)
        let working = SessionRowModel(try session(["state_kind": "working", "state_caption": "Working"]), now: Date())
        XCTAssertFalse(working.isRing)
    }

    func testTheLabelIsTheMacCaptionAndANonLiveRowAddsItsAge() throws {
        let now = Date()
        let waiting = SessionRowModel(try session([
            "state_kind": "waiting_on_ask", "state_caption": "Waiting for you · ask #109", "state_tone": "orange",
            "state_glyph": "questionmark", "open_asks": 1
        ]), now: now)
        XCTAssertEqual(waiting.caption, "Waiting for you · ask #109")
        XCTAssertEqual(waiting.tone, .orange)
        XCTAssertEqual(waiting.glyph, "questionmark")

        let stopped = SessionRowModel(try session([
            "live": false, "is_ring": true, "state_kind": "stopped", "state_caption": "Stopped", "state_tone": "secondary",
            "last_active_at": DemoSeed.JSON.stamp(now.addingTimeInterval(-3 * 3_600 - 60))
        ]), now: now)
        XCTAssertEqual(stopped.caption, "Stopped · 3h")
        XCTAssertNil(stopped.glyph, "an empty glyph draws none")
    }

    func testOpenAndClosedAskCounts() throws {
        let row = SessionRowModel(try session(["open_asks": 2, "closed_asks": 3]), now: Date())
        XCTAssertEqual(row.openAsks, 2)
        XCTAssertEqual(row.metaItems.last?.text, "3 closed")
        let none = SessionRowModel(try session([:]), now: Date())
        XCTAssertFalse(none.metaItems.contains { $0.text.hasSuffix("closed") })
    }

    /// Review focus 2 (design pass S3, §9.4): the caption in the session's
    /// tone first, then the report, the PR line and "N closed" last, so it
    /// is the first to truncate; no mini progress bar.
    func testTheMetaLineIsCaptionThenReportThenPRThenClosed() throws {
        let row = SessionRowModel(try session([
            "state_kind": "waiting_on_ask", "state_caption": "Waiting for you · ask #109 · 2 asks", "state_tone": "orange",
            "open_asks": 2, "closed_asks": 2, "report_target_id": 415, "report_done": 1, "report_total": 2,
            "report_pr_line": "PR #175 open"
        ]), now: Date())
        XCTAssertEqual(row.metaItems.map(\.text), ["Waiting for you · ask #109 · 2 asks", "#415 · 1/2", "PR #175 open", "2 closed"])
        XCTAssertEqual(row.metaItems.first?.tone, .orange)
        XCTAssertEqual(row.metaItems.first?.role, .session(isWaiting: true))
        XCTAssertTrue(row.metaItems.dropFirst().allSatisfy { $0.tone == .secondary })
        XCTAssertFalse(row.toneUses.contains { $0.role == .progress }, "the mini progress bar is gone")
    }
}

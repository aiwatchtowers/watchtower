import XCTest
import WatchtowerCore

/// `SessionReport`/`SessionReportSummary` decode Go's `session-report --json`
/// (spec 2026-10-03-workbench-session-report Part 6). The two goldens are
/// Go's own `cmd/testdata` files, read in place, so a Go shape change breaks
/// this suite too.
final class SessionReportTests: XCTestCase {
    static func golden(_ name: String) throws -> SessionReport {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("cmd/testdata/\(name).json")
        return try JSONDecoder().decode(SessionReport.self, from: Data(contentsOf: url))
    }

    private func decode(_ json: String) throws -> SessionReport {
        try JSONDecoder().decode(SessionReport.self, from: Data(json.utf8))
    }

    func testDecodesTheRunningGolden() throws {
        let r = try Self.golden("session_report_314")
        XCTAssertEqual(r.session.id, 1)
        XCTAssertEqual(r.session.title, "Session report")
        XCTAssertEqual(r.session.targetID, 314)
        XCTAssertEqual(r.session.kind, "claude")
        XCTAssertEqual(r.session.createdAt, "2026-09-28T07:00:00Z")
        XCTAssertEqual(r.session.agentState, "waiting")
        XCTAssertEqual(r.session.agentStateAt, "2026-10-02T15:00:01.000Z")
        XCTAssertEqual(r.session.finishedAt, "", "not finished")
        XCTAssertEqual(r.session.finishSummary, "")
        XCTAssertEqual(r.progress, .init(done: 14, total: 15))
        XCTAssertEqual(r.onYou, [], "the empty wire shape is [] and decodes")
        XCTAssertEqual(r.next, [])
        XCTAssertEqual(r.now.map(\.id), [342])
        XCTAssertEqual(r.now.first?.status, "blocked")
        XCTAssertEqual(r.now.first?.branch, "feature/session-report-ui")
        XCTAssertEqual(r.now.first?.since, "2026-10-02T15:00:00Z")
        XCTAssertEqual(r.phases.map(\.targetID), [320, 330, 340])
        XCTAssertEqual(r.phases.map(\.total), [7, 5, 2])
        XCTAssertEqual(r.phases[2].finishedAt, "", "a phase with a leaf left has no end")
        XCTAssertEqual(r.phases[2].items.map(\.id), [342, 341], "items keep board order")
        XCTAssertEqual(r.phases[2].items.first?.status, "blocked")
        XCTAssertEqual(r.prs.map(\.ref), ["pr:147", "branch:feature/session-report", "branch:feature/session-report-ui"])
        XCTAssertEqual(r.prs[0].prNumber, 147)
        XCTAssertEqual(r.prs[0].additions, 1200)
        XCTAssertEqual(r.prs[0].deletions, 80)
        XCTAssertEqual(r.prs[0].branch, nil)
        XCTAssertEqual(r.prs[1].prNumber, nil, "null pr_number decodes as nil")
        XCTAssertEqual(r.prs[1].additions, nil)
        XCTAssertEqual(r.prs[1].state, "unknown")
        XCTAssertEqual(r.prs[1].branch, "feature/session-report")
        XCTAssertEqual(r.prs[2].targets, [342])
        XCTAssertEqual(r.prNote, "the folder is not a git work tree; branch and pull request states not checked")
    }

    func testDecodesTheFinishedGolden() throws {
        let r = try Self.golden("session_report_finished")
        XCTAssertEqual(r.session.id, 3)
        XCTAssertEqual(r.session.targetID, 400)
        XCTAssertEqual(r.session.finishedAt, "2026-10-02T15:59:30.000Z")
        XCTAssertEqual(
            r.session.finishSummary,
            "Exporter merged in PR #150.\nThe progress sheet is open in PR #151 and waits on your answer about the file name."
        )
        XCTAssertEqual(r.progress, .init(done: 3, total: 5))
        XCTAssertEqual(r.onYou.map(\.id), [7])
        XCTAssertEqual(r.onYou.first?.kind, "question")
        XCTAssertEqual(r.onYou.first?.title, "Which default file name should the export use?")
        XCTAssertEqual(r.onYou.first?.targetID, 422)
        XCTAssertEqual(r.onYou.first?.createdAt, "2026-10-02T15:58:00Z")
        XCTAssertEqual(r.next, [.init(id: 423, text: "Document the export", status: "todo")])
        XCTAssertEqual(r.phases.map(\.targetID), [420, 410], "board order: the phase in progress comes first")
        XCTAssertEqual(r.phases[0].items.map(\.status), ["in_progress", "todo", "done"])
        XCTAssertEqual(r.phases[1].startedAt, "2026-10-01T09:00:00Z")
        XCTAssertEqual(r.phases[1].finishedAt, "2026-10-01T12:30:00Z")
        XCTAssertEqual(r.prs.map(\.ref), ["pr:151", "pr:150"], "board order, not number order")
        XCTAssertEqual(r.prs[1].state, "merged")
        XCTAssertEqual(r.prs[1].mergedAt, "2026-10-02T12:00:00Z")
        XCTAssertEqual(r.prs[1].checkedAt, "2026-10-02T15:00:00Z")
        XCTAssertEqual(r.prs[1].targets, [421, 411, 412])
    }

    func testMissingKeysDecodeWithDefaults() throws {
        let r = try decode(#"{"session": {"id": 5}, "prs": [{"ref": "pr:9"}], "phases": [{"target_id": 2}]}"#)
        XCTAssertEqual(r.session, .init(id: 5))
        XCTAssertEqual(r.session.targetID, nil)
        XCTAssertEqual(r.progress, .init(done: 0, total: 0))
        XCTAssertEqual(r.onYou, [])
        XCTAssertEqual(r.now, [])
        XCTAssertEqual(r.next, [])
        XCTAssertEqual(r.prNote, "")
        XCTAssertEqual(r.prs, [.init(ref: "pr:9")])
        XCTAssertEqual(r.prs.first?.state, "unknown", "a PR never checked is unknown")
        XCTAssertEqual(r.phases, [.init(targetID: 2, text: "", done: 0, total: 0)])

        XCTAssertEqual(try decode("{}"), SessionReport(session: .init()), "an empty object is an empty report")
    }

    func testNullsAndExtraKeysDecode() throws {
        let r = try decode("""
            {"session": {"id": 1, "target_id": null, "finish_summary": null, "mood": "calm"},
             "on_you": null, "pr_note": null, "progress": {"done": 1, "total": 2, "dismissed": 4},
             "future_section": [1, 2, 3]}
            """)
        XCTAssertEqual(r.session, .init(id: 1))
        XCTAssertEqual(r.onYou, [])
        XCTAssertEqual(r.prNote, "")
        XCTAssertEqual(r.progress, .init(done: 1, total: 2))
    }

    func testAPresentValueOfTheWrongTypeStillThrows() {
        XCTAssertThrowsError(try decode(#"{"progress": {"done": "three"}}"#))
    }

    func testSummaryRowsDecode() throws {
        let json = """
            [{"session_id": 1, "target_id": 314, "done": 14, "total": 15, "pr_line": "PR #147 open", "finished_at": ""},
             {"session_id": 2, "target_id": null, "done": 0, "total": 0, "pr_line": "",
              "finished_at": "2026-10-02T15:59:30.000Z", "extra": 1},
             {"session_id": 3}]
            """
        let rows = try JSONDecoder().decode([SessionReportSummary].self, from: Data(json.utf8))
        XCTAssertEqual(rows, [
            .init(sessionID: 1, targetID: 314, done: 14, total: 15, prLine: "PR #147 open"),
            .init(sessionID: 2, finishedAt: "2026-10-02T15:59:30.000Z"),
            .init(sessionID: 3)
        ])
        XCTAssertEqual(rows.map(\.id), [1, 2, 3])
    }
}

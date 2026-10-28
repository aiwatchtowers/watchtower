import XCTest
@testable import WatchtowerCore

final class CoachPresentationTests: XCTestCase {
    private func metric(_ v: Double?, n: Int = 5, known: Bool = true, prev: Double?) -> CoachMetric {
        CoachMetric(value: v, n: n, known: known, previous: prev)
    }

    private func proposal(
        id: Int64 = 1,
        destination: String = "session",
        workbench: Int64 = 1,
        status: String = "open",
        created: String = "2026-10-20T00:00:00Z",
        decided: String? = nil,
        before: String = "",
        after: String = "",
        budget: Int = 0,
        verdict: String = "",
        baseline: Double? = nil,
        verdictValue: Double? = nil,
        metricName: String = "corrections",
        promptID: String = ""
    ) -> CoachProposal {
        var obj: [String: Any] = [
            "id": id, "title": "t", "why": "w", "destination": destination, "workbench_id": workbench,
            "prompt_id": promptID, "kind": "add", "metric": metricName, "before": before, "after": after,
            "evidence": [], "sources": 3, "status": status, "created_at": created, "verdict": verdict,
            "reverts_id": 0, "budget": budget
        ]
        obj["decided_at"] = decided ?? NSNull()
        obj["baseline"] = baseline ?? NSNull()
        obj["verdict_value"] = verdictValue ?? NSNull()
        obj["verdict_at"] = NSNull()
        let data = try! JSONSerialization.data(withJSONObject: obj)  // swiftlint:disable:this force_try
        return try! JSONDecoder().decode(CoachProposal.self, from: data)  // swiftlint:disable:this force_try
    }

    func testTrendTable() {
        XCTAssertEqual(CoachTrend.of(metric(2.1, prev: 3.0), points: false), .better("↓ 30% · was 3.0"))
        XCTAssertEqual(CoachTrend.of(metric(7.4, prev: 7.6), points: false), .same)
        XCTAssertEqual(CoachTrend.of(metric(2.1, n: 2, prev: 3.0), points: false), .fewData)
        XCTAssertEqual(CoachTrend.of(metric(2.1, known: false, prev: 3.0), points: false), .fewData)
        XCTAssertEqual(CoachTrend.of(metric(2.1, prev: nil), points: false), .noTrend)
        XCTAssertEqual(CoachTrend.of(metric(0.22, prev: 0.31), points: true), .better("↓ 9 pts · was 31%"))
        XCTAssertEqual(CoachTrend.of(metric(3.9, prev: 3.0), points: false), .worse("↑ 30% · was 3.0"))
        XCTAssertEqual(CoachTrend.of(metric(0.4, prev: 0.31), points: true), .worse("↑ 9 pts · was 31%"))
    }

    func testForPane() {
        let all = [
            proposal(id: 1, workbench: 1, created: "2026-10-20T00:00:00Z"),
            proposal(id: 2, workbench: 2),
            proposal(id: 3, workbench: 0, created: "2026-10-22T00:00:00Z"),
            proposal(id: 4, workbench: 1, status: "accepted", decided: "2026-10-23T00:00:00Z"),
            proposal(id: 5, workbench: 0, status: "rolled_back", decided: "2026-10-24T00:00:00Z"),
            proposal(id: 6, workbench: 1, status: "declined")
        ]
        let pane = CoachProposal.forPane(all, workbench: 1)
        XCTAssertEqual(pane.open.map(\.id), [3, 1])
        XCTAssertEqual(pane.accepted.map(\.id), [5, 4])
    }

    func testVerdictLines() {
        let now = Date()
        XCTAssertEqual(
            proposal(status: "accepted", verdict: "works", baseline: 3, verdictValue: 2.1).verdictLine(hasCut: false, now: now),
            "works · corrections 3 → 2.1 since this edit")
        XCTAssertEqual(proposal(status: "accepted", verdict: "no_effect").verdictLine(hasCut: false, now: now), "no effect")
        XCTAssertEqual(proposal(status: "accepted", verdict: "no_effect").verdictLine(hasCut: true, now: now),
                       "no effect · a cut is proposed")
        XCTAssertEqual(proposal(status: "accepted", verdict: "too_little_data").verdictLine(hasCut: false, now: now),
                       "too little data")
        XCTAssertEqual(proposal(status: "accepted", decided: "2026-10-11T09:00:00Z").verdictLine(hasCut: false, now: now),
                       "measuring · verdict on Oct 25")
        XCTAssertEqual(proposal(status: "rolled_back", decided: "2026-10-11T09:00:00Z").verdictLine(hasCut: false, now: now),
                       "rolled back")
    }

    func testSizeLine() {
        XCTAssertEqual(proposal(before: String(repeating: "a", count: 812), after: String(repeating: "b", count: 905), budget: 1000).sizeLine,
                       "812 → 905 of 1000")
        XCTAssertNil(proposal(before: "a", after: "b", budget: 0).sizeLine)
    }

    func testSizeLineCountsUnicodeScalars() {
        let family = "👨‍👩‍👧"            // 5 scalars, 1 grapheme
        let combined = "e\u{301}"       // 2 scalars, 1 grapheme
        XCTAssertEqual(proposal(before: family, after: combined, budget: 10).sizeLine, "5 → 2 of 10")
    }

    func testDestinationLabel() {
        XCTAssertEqual(proposal(destination: "session", workbench: 1).destinationLabel, "Session instructions")
        XCTAssertEqual(proposal(destination: "procedure", workbench: 1).destinationLabel, "Target procedure")
        XCTAssertEqual(proposal(destination: "chat", workbench: 0).destinationLabel, "Chat instructions · all workbenches")
        XCTAssertEqual(proposal(destination: "prompt_addition", workbench: 1, promptID: "briefing").destinationLabel,
                       "Watchtower prompt · briefing")
        XCTAssertEqual(proposal(destination: "claude_settings_allow", workbench: 1).destinationLabel,
                       "Claude Code settings · allow rules")
        XCTAssertEqual(proposal(destination: "claude_md_user", workbench: 0).destinationLabel,
                       "~/.claude/CLAUDE.md · all workbenches")
    }

    func testDiffLines() {
        let p = proposal(before: "a\nb\nc", after: "a\nB\nc\nd")
        XCTAssertEqual(p.diffLines, [.kept("a"), .removed("b"), .added("B"), .kept("c"), .added("d")])
        XCTAssertEqual(proposal(before: "", after: "x").diffLines, [.added("x")])
    }

    func testHomeFourLineRule() {
        let five = proposal(before: "k", after: "k\n1\n2\n3\n4\n5")
        let r = CoachHomeRow.lines(five)
        XCTAssertEqual(r.shown, [.added("1"), .added("2"), .added("3"), .added("4")])
        XCTAssertTrue(r.truncated)
        let one = CoachHomeRow.lines(proposal(before: "k", after: "k\nx"))
        XCTAssertEqual(one.shown, [.added("x")])
        XCTAssertFalse(one.truncated)
    }

    func testTargetWorkbench() {
        XCTAssertEqual(CoachHomeRow.targetWorkbench(proposalWorkbench: 3, analyticsOn: [1, 3], lastOpened: 1), 3)
        XCTAssertNil(CoachHomeRow.targetWorkbench(proposalWorkbench: 3, analyticsOn: [1], lastOpened: 1))
        XCTAssertEqual(CoachHomeRow.targetWorkbench(proposalWorkbench: 0, analyticsOn: [2, 4], lastOpened: 4), 4)
        XCTAssertEqual(CoachHomeRow.targetWorkbench(proposalWorkbench: 0, analyticsOn: [4, 2], lastOpened: 9), 2)
        XCTAssertEqual(CoachHomeRow.targetWorkbench(proposalWorkbench: 0, analyticsOn: [4, 2], lastOpened: nil), 2)
        XCTAssertNil(CoachHomeRow.targetWorkbench(proposalWorkbench: 0, analyticsOn: [], lastOpened: 4))
    }
}

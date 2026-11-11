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
        promptID: String = "",
        origin: String? = nil,
        conversation: Int64? = nil,
        extra: [String: Any] = [:]
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
        if let origin { obj["origin"] = origin }
        if let conversation { obj["conversation_id"] = conversation }
        obj.merge(extra) { $1 }
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

    func testForChatKeepsOnlyThisConversation() {
        let all = [
            proposal(id: 4, origin: "chat", conversation: 12),
            proposal(id: 2, origin: "chat", conversation: 13),
            proposal(id: 3, origin: "weekly", conversation: 12),
            proposal(id: 5),
            proposal(id: 1, origin: "chat", conversation: 12)
        ]
        XCTAssertEqual(CoachProposal.forChat(all, conversationID: 12).map(\.id), [1, 4])
        XCTAssertEqual(CoachProposal.forChat(all, conversationID: 99).map(\.id), [])
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

    func testDestinationLabelTuningDestinations() throws {
        func decoded(_ destination: String, skill: String?) throws -> CoachProposal {
            var obj: [String: Any] = [
                "id": 1, "title": "t", "why": "w", "destination": destination, "workbench_id": 0,
                "prompt_id": "", "kind": "replace", "metric": "corrections", "before": "", "after": "",
                "evidence": [], "sources": 1, "status": "open", "created_at": "2026-11-03T00:00:00Z",
                "verdict": "", "reverts_id": 0, "budget": 0
            ]
            if let skill { obj["skill"] = skill }
            return try JSONDecoder().decode(CoachProposal.self, from: JSONSerialization.data(withJSONObject: obj))
        }
        XCTAssertEqual(try decoded("claude_skill_user", skill: "review-pr").destinationLabel, "Claude skill · review-pr")
        XCTAssertEqual(try decoded("codex_skill_user", skill: "lint").destinationLabel, "Codex skill · lint")
        XCTAssertEqual(try decoded("pack_overlay", skill: "watchtower-flow").destinationLabel,
                       "Watchtower skill · watchtower-flow")
        XCTAssertEqual(try decoded("claude_skill_user", skill: nil).destinationLabel, "Claude skill")
        XCTAssertEqual(try decoded("codex_agents_md_user", skill: nil).destinationLabel, "Codex AGENTS.md")
        XCTAssertEqual(try decoded("codex_rules_allow", skill: nil).destinationLabel, "Codex rules")
        XCTAssertNil(try decoded("session", skill: nil).skill)
    }

    func testRepoLabelsAndPaths() {
        let rows: [(String, String?, String, String?)] = [
            ("repo_claude_md", nil, "Workbench CLAUDE.md", "CLAUDE.md"),
            ("repo_agents_md", nil, "Workbench AGENTS.md", "AGENTS.md"),
            ("repo_claude_skill", "review-pr", "Workbench Claude skill · review-pr", ".claude/skills/review-pr/SKILL.md"),
            ("repo_codex_skill", "review-pr", "Workbench Codex skill · review-pr", ".agents/skills/review-pr/SKILL.md"),
            ("repo_workflow", nil, "Workbench workflow.md", ".watchtower/workflow.md"),
            ("repo_claude_skill", nil, "Workbench Claude skill", nil)
        ]
        for (dest, skill, label, path) in rows {
            let p = proposal(destination: dest, workbench: 3, extra: skill.map { ["skill": $0] } ?? [:])
            XCTAssertEqual(p.destinationLabel, label, dest)
            XCTAssertEqual(p.repoRelativePath, path, dest)
        }
        XCTAssertNil(proposal(destination: "claude_md_user", workbench: 0).repoRelativePath)
    }

    /// The table Go's `coach.RepoRelPath` reads too.
    func testRepoRelativePathSharedTable() throws {
        struct Case: Decodable { let destination: String; let skill: String; let path: String? }
        struct Table: Decodable { let cases: [Case] }
        // Tests/Core/<file> → the repository root.
        let root = (0..<4).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = root.appendingPathComponent("internal/coach/testdata/repo_rel_paths.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        XCTAssertFalse(table.cases.isEmpty)
        for c in table.cases {
            let p = proposal(destination: c.destination, workbench: 3, extra: ["skill": c.skill])
            XCTAssertEqual(p.repoRelativePath, c.path, "\(c.destination) \(c.skill)")
        }
    }

    func testOpenRepoCardCaptionNamesTheBranch() {
        func caption(_ branch: Any?) -> String {
            proposal(destination: "repo_claude_md", workbench: 3, extra: branch.map { ["folder_branch": $0] } ?? [:])
                .diffCaption
        }
        XCTAssertEqual(caption("main"), "CLAUDE.md · on branch main")
        XCTAssertEqual(caption("main"), TuningChatTexts.repoCardCaption(path: "CLAUDE.md", branch: "main"))
        XCTAssertEqual(caption("detached:abc1234"), "CLAUDE.md · on a detached HEAD (abc1234)")
        XCTAssertEqual(caption(""), "CLAUDE.md")
        XCTAssertEqual(caption(nil), "CLAUDE.md")
        XCTAssertEqual(proposal(destination: "repo_claude_md", workbench: 3, before: "a", after: "ab", budget: 2002,
                                extra: ["folder_branch": "main"]).diffCaption,
                       "CLAUDE.md · on branch main · 1 → 2 of 2002")
        XCTAssertEqual(proposal(destination: "session", workbench: 1).diffCaption, "Session instructions")
    }

    func testRepoAcceptedRowLines() {
        let now = Date()
        let waiting = proposal(destination: "repo_claude_md", status: "accepted", decided: "2026-11-01T09:00:00Z")
        XCTAssertEqual(waiting.verdictLine(hasCut: false, now: now), TuningChatTexts.awaitingCommit)
        let lapsed = proposal(destination: "repo_claude_md", status: "accepted", decided: "2026-10-01T09:00:00Z",
                              verdict: "too_little_data")
        XCTAssertEqual(lapsed.verdictLine(hasCut: false, now: now), TuningChatTexts.notCommitted)
        let committed = proposal(destination: "repo_claude_md", status: "accepted", decided: "2026-11-01T09:00:00Z",
                                 extra: ["measure_from": "2026-11-05T09:00:00Z"])
        XCTAssertEqual(committed.verdictLine(hasCut: false, now: now), "measuring · verdict on Nov 19",
                       "the 14 days start at the commit")
        let measured = proposal(destination: "repo_claude_md", status: "accepted", verdict: "too_little_data",
                                extra: ["measure_from": "2026-11-05T09:00:00Z"])
        XCTAssertEqual(measured.verdictLine(hasCut: false, now: now), "too little data")
        let skill = proposal(destination: "repo_claude_skill", status: "rolled_back", extra: ["skill": "review-pr"])
        XCTAssertEqual(skill.verdictLine(hasCut: false, now: now),
                       "Rolled back · restored .claude/skills/review-pr/SKILL.md — commit it yourself")
        let agents = proposal(destination: "repo_agents_md", status: "rolled_back")
        XCTAssertEqual(agents.verdictLine(hasCut: false, now: now, writtenPath: "AGENTS.md"),
                       TuningChatTexts.rolledBackRepoFile(path: "AGENTS.md"))
        XCTAssertEqual(proposal(destination: "session", status: "rolled_back").verdictLine(hasCut: false, now: now),
                       "rolled back")
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

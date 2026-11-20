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

    /// The card's error lines match Go's `coach.RepoDirtyLine` / `RepoNotGitLine` through one fixture.
    func testRepoRefusalLinesSharedFixture() throws {
        struct Lines: Decodable { let dirty_path: String; let dirty: String; let not_git: String }
        let root = (0..<4).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = root.appendingPathComponent("internal/coach/testdata/repo_lines.json")
        let lines = try JSONDecoder().decode(Lines.self, from: Data(contentsOf: url))
        XCTAssertEqual(TuningChatTexts.repoDirty(path: lines.dirty_path), lines.dirty)
        XCTAssertEqual(TuningChatTexts.repoNotGit, lines.not_git)
    }

    /// No branch: before Accept the Desktop cannot tell a pull request from a working-copy write.
    func testOpenRepoCardCaptionIsTheFile() {
        func caption(_ branch: Any?) -> String {
            proposal(destination: "repo_claude_md", workbench: 3, extra: branch.map { ["folder_branch": $0] } ?? [:])
                .diffCaption
        }
        XCTAssertEqual(caption("main"), "CLAUDE.md")
        XCTAssertEqual(caption("detached:abc1234"), "CLAUDE.md")
        XCTAssertEqual(caption(""), "CLAUDE.md")
        XCTAssertEqual(caption(nil), "CLAUDE.md")
        XCTAssertEqual(proposal(destination: "repo_claude_md", workbench: 3, before: "a", after: "ab", budget: 2002,
                                extra: ["folder_branch": "main"]).diffCaption,
                       "CLAUDE.md · 1 → 2 of 2002")
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

    // MARK: Pull-request edits (spec 2026-11-19 §4.4–§4.6)

    private let prURL = "https://github.com/acme/repo/pull/12"
    private let revertURL = "https://github.com/acme/repo/pull/13"

    func testPRNumberAndLabel() {
        XCTAssertEqual(CoachPRTexts.number(prURL), "#12")
        XCTAssertEqual(CoachPRTexts.number(prURL + "/"), "#12")
        XCTAssertEqual(CoachPRTexts.number("https://ghe.example.com/acme/repo/pull/7"), "#7")
        XCTAssertNil(CoachPRTexts.number("https://github.com/acme/repo"))
        XCTAssertNil(CoachPRTexts.number("https://github.com/acme/repo/pull/"))
        XCTAssertNil(CoachPRTexts.number("https://github.com/acme/repo/pull/12/files"))
        XCTAssertEqual(CoachPRTexts.label(prURL), "PR #12")
        XCTAssertEqual(CoachPRTexts.label("not a url"), "PR")
        XCTAssertEqual(proposal(extra: ["pr_url": prURL]).prLabel, "PR #12")
    }

    func testPRAcceptedRowLines() {
        let now = Date()
        func pr(_ status: String = "accepted", verdict: String = "", extra: [String: Any] = [:]) -> CoachProposal {
            proposal(destination: "repo_claude_md", status: status, decided: "2026-11-01T09:00:00Z", verdict: verdict,
                     extra: extra.merging(["pr_url": prURL]) { $1 })
        }
        // The "PR #12" link sits beside the line: the line does not name the PR again.
        XCTAssertEqual(pr().verdictLine(hasCut: false, now: now), "Waiting for the merge")
        XCTAssertEqual(pr().verdictLine(hasCut: false, now: now, writtenPath: "CLAUDE.md"), "Waiting for the merge",
                       "a PR row never says to commit it yourself")
        XCTAssertEqual(pr(verdict: "too_little_data").verdictLine(hasCut: false, now: now),
                       "Not merged in 30 days — not measured")
        let merged = pr(extra: ["measure_from": "2026-11-05T09:00:00Z"])
        XCTAssertEqual(merged.verdictLine(hasCut: false, now: now), "measuring · verdict on Nov 19",
                       "the 14 days start at the merge")
        let works = pr(verdict: "works", extra: ["measure_from": "2026-11-05T09:00:00Z"])
        XCTAssertEqual(proposal(status: "accepted", verdict: "works", baseline: 3, verdictValue: 2.1,
                                extra: ["pr_url": prURL, "measure_from": "2026-11-05T09:00:00Z"])
                        .verdictLine(hasCut: false, now: now),
                       "works · corrections 3 → 2.1 since this edit")
        XCTAssertEqual(works.verdictLine(hasCut: false, now: now), "works · corrections ? → ? since this edit")
        XCTAssertNil(pr().revertLine)

        let closed = pr("rolled_back")
        XCTAssertEqual(closed.verdictLine(hasCut: false, now: now), "Rolled back · PR closed")
        XCTAssertNil(closed.revertLine)
        let reverted = pr("rolled_back", extra: ["revert_pr_url": revertURL])
        XCTAssertEqual(reverted.verdictLine(hasCut: false, now: now), "Rolled back")
        XCTAssertEqual(reverted.revertLine, "Revert: PR #13 — merge it to remove the edit.")
        XCTAssertEqual(CoachPRTexts.revertLine("PR #13"),
                       [CoachPRTexts.revertLead, "PR #13", CoachPRTexts.revertTail].joined(separator: " "),
                       "the view draws the lead, the link and the tail")
    }

    /// The Desktop's sentences are Go's `coach.*Line` (internal/coach/repopr.go), word for word.
    func testPRRefusalLines() {
        func line(_ code: String, _ cli: String = "", path: String? = "CLAUDE.md", url: String? = nil) -> String? {
            CoachPRTexts.refusal(code: code, cliError: cli, path: path, prURL: url ?? prURL)
        }
        XCTAssertEqual(line("no_gh"), "Log in with `gh auth login` to let Watchtower open the pull request.")
        XCTAssertEqual(line("base_differs"),
                       "CLAUDE.md on the default branch differs from the one the chat read — pull, then ask the chat again.")
        XCTAssertNil(line("base_differs", path: nil), "no file to name: the CLI's own line")
        XCTAssertEqual(line("push_failed"), "GitHub refused the branch, or the push needed a password prompt.")
        XCTAssertEqual(line("pr_failed"),
                       "GitHub did not open or close the pull request — press the button again to retry.")
        XCTAssertEqual(line("timeout"), "GitHub did not answer in time; nothing changed — try again.")
        XCTAssertEqual(line("pr_unreadable"), "Could not read pull request #12 from GitHub — try again.")
        XCTAssertNil(line("pr_unreadable", url: ""))
        XCTAssertEqual(line("origin_moved"),
                       "This folder's origin is no longer the repository the pull request is in; nothing changed.")
        XCTAssertEqual(line("github_unreachable"),
                       "Could not reach GitHub to check your gh login; nothing changed — try again.")
        XCTAssertEqual(line("in_progress"),
                       "This proposal is already being accepted, declined or rolled back — wait for it to finish.")
        XCTAssertNil(line("dirty"))
        XCTAssertNil(line("failed"))

        // git's or gh's words after the sentence stay where they say what went wrong; the id prefix goes.
        let push = "coach proposal 9 (repo_claude_md): " + CoachPRTexts.pushFailed
            + " (workbenchgit: push failed: remote: Permission to acme/repo.git denied)"
        XCTAssertEqual(line("push_failed", push),
                       CoachPRTexts.pushFailed + " (workbenchgit: push failed: remote: Permission to acme/repo.git denied)")
        let noGH = "coach proposal 9 (repo_claude_md): " + CoachPRTexts.noGH + " (workbenchgit: gh: not logged in)"
        XCTAssertEqual(line("no_gh", noGH), CoachPRTexts.noGH, "the login line needs no gh words")
        XCTAssertEqual(line("pr_failed", "something else entirely"), CoachPRTexts.prFailed)

        XCTAssertTrue(CoachPRTexts.retryable("push_failed"))
        XCTAssertTrue(CoachPRTexts.retryable("pr_failed"))
        XCTAssertTrue(CoachPRTexts.retryable("timeout"))
        XCTAssertTrue(CoachPRTexts.retryable("pr_unreadable"))
        XCTAssertTrue(CoachPRTexts.retryable("github_unreachable"), "offline: nothing changed, Retry")
        XCTAssertFalse(CoachPRTexts.retryable("in_progress"), "the other decision moves the proposal on")
        XCTAssertFalse(CoachPRTexts.retryable("no_gh"))
        XCTAssertFalse(CoachPRTexts.retryable("base_differs"))
        XCTAssertFalse(CoachPRTexts.retryable(nil))
        XCTAssertEqual(CoachPRTexts.retry, "Retry")
        XCTAssertEqual(CoachPRTexts.syncLine(code: "no_gh"), CoachPRTexts.noGH)
        XCTAssertEqual(CoachPRTexts.syncLine(code: "timeout"), CoachPRTexts.timeout)
        XCTAssertEqual(CoachPRTexts.syncLine(code: "pr_unreadable"),
                       "Couldn't check the pull requests on GitHub — they are checked again next time you open this list.")
        XCTAssertEqual(CoachPRTexts.syncLine(code: ""), CoachPRTexts.syncFailed)
    }

    /// The Roll Back sheet after `changed_since`: a working-copy edit may be
    /// forced; a pull-request edit cannot (its revert needs the merged text on
    /// the default branch), so it names the file, says to revert by hand and
    /// only closes.
    func testRollbackSheetTexts() {
        let local = CoachRollbackTexts(proposal(destination: "repo_claude_md", status: "accepted"))
        XCTAssertEqual(local.title, "The text changed since you accepted")
        XCTAssertEqual(local.body, "Workbench CLAUDE.md was edited after “t”. Rolling back overwrites those edits.")
        XCTAssertTrue(local.offersForce)
        XCTAssertEqual(local.dismiss, "Cancel")

        let pr = CoachRollbackTexts(proposal(destination: "repo_claude_md", status: "accepted", extra: ["pr_url": prURL]))
        XCTAssertEqual(pr.title, "The file changed since the merge")
        XCTAssertEqual(pr.body,
                       "CLAUDE.md on the default branch changed since the merge — revert it by hand in a pull request.")
        XCTAssertFalse(pr.offersForce, "no Roll Back Anyway: --force does not apply to a pull request")
        XCTAssertEqual(pr.dismiss, "Close")
        XCTAssertEqual(CoachRollbackTexts.rollBackAnyway, "Roll Back Anyway")
        XCTAssertEqual(CoachRollbackTexts.noDiff, "No diff available.")
    }

    func testStyledMakesBacktickSpansCode() {
        let styled = CoachPRTexts.styled(CoachPRTexts.noGH)
        XCTAssertEqual(String(styled.characters), "Log in with gh auth login to let Watchtower open the pull request.")
        let code = styled.runs.filter { $0.inlinePresentationIntent == .code }
            .map { String(styled[$0.range].characters) }
        XCTAssertEqual(code, ["gh auth login"])
        XCTAssertEqual(String(CoachPRTexts.styled("a ` b").characters), "a ` b", "an odd backtick stays")
        XCTAssertTrue(CoachPRTexts.styled("plain").runs.allSatisfy { $0.inlinePresentationIntent == nil })
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

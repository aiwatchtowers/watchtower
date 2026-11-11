import XCTest
@testable import WatchtowerCore

final class TuningChatTextsTests: XCTestCase {
    func testFigures() {
        XCTAssertEqual(TuningChatTexts.figures(.init(days: 7, sessions: 23, tasks: 7, costUSD: 41.2, perTaskUSD: 2.94, previousPerTaskUSD: 2.31)),
                       "7 days · 23 sessions · 7 tasks · $41.20 · $2.94 per task (was $2.31)")
        XCTAssertEqual(TuningChatTexts.figures(.init(days: 1, sessions: 1, tasks: 1, costUSD: 0.4)), "1 day · 1 session · 1 task · $0.40")
        XCTAssertEqual(TuningChatTexts.figures(.init(days: 7, sessions: 2, tasks: 2, costUSD: 1, perTaskUSD: 0.5)),
                       "7 days · 2 sessions · 2 tasks · $1.00 · $0.50 per task")
    }

    func testStarters() {
        let finding = "Sessions re-read the same files: 41 times in 9 sessions"
        let all = TuningChatTexts.starters(.init(costPerTaskGrew: true, topHintFinding: finding))
        XCTAssertEqual(all.map(\.title), ["Why did cost per task grow?", finding, "Which prompt costs the most?", "Tune a skill"])
        XCTAssertEqual(all[1].text, "How do I fix this? \(finding)")
        XCTAssertEqual(all[3].text, "Which of my skills should I tune first, and how?")
        let plain = TuningChatTexts.starters(.init(costPerTaskGrew: false, topHintFinding: nil))
        XCTAssertEqual(plain.map(\.title), ["Which prompt costs the most?", "Tune a skill"])
        XCTAssertTrue((all + plain).allSatisfy(\.sendsImmediately))
    }

    func testToolLines() {
        let cases: [(String, String, String?)] = [
            ("get_agent_report", #"{"days":7}"#, "Read the 7-day report"),
            ("get_agent_report", "{}", "Read the agent report"),
            ("get_agent_report", #"{"days":1e30}"#, "Read the agent report"),
            ("get_agent_report", #"{"days":-3}"#, "Read the agent report"),
            ("get_agent_report", #"{"days":2.5}"#, "Read the agent report"),
            ("get_agent_report", #"{"days":7.0}"#, "Read the 7-day report"),
            ("list_agent_sessions", "{}", "Listed sessions"),
            ("get_agent_session", "{}", "Read a session"),
            ("get_llm_usage", #"{"days":7}"#, "Read the 7-day LLM usage"),
            ("list_prompts", "{}", "Listed prompts"),
            ("get_prompt", #"{"prompt_id":"digest.channel"}"#, "Read prompt digest.channel"),
            ("list_skills", "{}", "Listed skills"),
            ("get_skill", #"{"name":"review-pr"}"#, "Read skill review-pr"),
            ("get_agent_instructions", "{}", "Read your agent instructions"),
            ("list_coach_proposals", "{}", "Read the coach's proposals"),
            ("propose_tuning_edit", #"{"skill":"review-pr"}"#, "Proposed an edit to review-pr"),
            ("propose_tuning_edit", #"{"prompt_id":"digest.channel"}"#, "Proposed an edit to digest.channel"),
            ("propose_tuning_edit", "not json", "Proposed an edit"),
            ("search_knowledge", "{}", nil)
        ]
        for (name, args, line) in cases {
            XCTAssertEqual(TuningChatTexts.toolLine(name: name, args: args), line, "\(name) \(args)")
        }
    }

    func testLoadErrors() {
        XCTAssertEqual(TuningChatTexts.newChatFailed("disk full"), "Couldn't start a new tuning chat: disk full")
        XCTAssertEqual(TuningChatTexts.cardsReadFailed("database is locked"),
                       "Couldn't read the tuning chat's proposals: database is locked")
    }

    func testFoldedProposal() {
        XCTAssertEqual(TuningChatTexts.foldedProposal(status: "accepted", title: "x"), "Accepted · measuring for 14 days")
        XCTAssertEqual(TuningChatTexts.foldedProposal(status: "declined", title: "x"), "Declined · x")
        XCTAssertEqual(TuningChatTexts.foldedProposal(status: "superseded", title: "Removed with its source data"),
                       "Withdrawn · Removed with its source data")
        XCTAssertEqual(TuningChatTexts.foldedProposal(status: "rolled_back", title: "x"), "Rolled back · x")
        XCTAssertNil(TuningChatTexts.foldedProposal(status: "open", title: "x"))
    }

    func testRepoFileLines() {
        XCTAssertEqual(TuningChatTexts.repoCardCaption(path: "CLAUDE.md", branch: "main"), "CLAUDE.md · on branch main")
        XCTAssertEqual(TuningChatTexts.repoCardCaption(path: "CLAUDE.md", branch: "detached:abc1234"),
                       "CLAUDE.md · on a detached HEAD (abc1234)")
        XCTAssertEqual(TuningChatTexts.repoCardCaption(path: "CLAUDE.md", branch: ""), "CLAUDE.md")
        XCTAssertEqual(TuningChatTexts.acceptedRepoFile(path: "CLAUDE.md", branch: "main"),
                       "Accepted · wrote CLAUDE.md on main — commit it yourself")
        XCTAssertEqual(TuningChatTexts.acceptedRepoFile(path: "CLAUDE.md", branch: "detached:abc1234"),
                       "Accepted · wrote CLAUDE.md on a detached HEAD (abc1234) — commit it yourself")
        XCTAssertEqual(TuningChatTexts.acceptedRepoFile(path: "AGENTS.md", branch: ""),
                       "Accepted · wrote AGENTS.md — commit it yourself")
        XCTAssertEqual(TuningChatTexts.committedRepoFile, "Accepted · committed · measuring for 14 days")
        XCTAssertEqual(TuningChatTexts.awaitingCommit, "Accepted · waiting for your commit")
        XCTAssertEqual(TuningChatTexts.notCommitted, "Not committed in 30 days — not measured")
        XCTAssertEqual(TuningChatTexts.rolledBackRepoFile(path: ".claude/skills/review-pr/SKILL.md"),
                       "Rolled back · restored .claude/skills/review-pr/SKILL.md — commit it yourself")
        XCTAssertEqual(TuningChatTexts.repoDirty(path: "CLAUDE.md"),
                       "CLAUDE.md has uncommitted changes — commit or discard them, then press Accept again.")
        XCTAssertEqual(TuningChatTexts.repoNotGit,
                       "This workbench folder is not a git repository: Watchtower changes files here only where you "
                       + "can review and commit the change.")
    }

    func testFoldedRepoLine() throws {
        func repo(_ extra: String) throws -> CoachProposal {
            let json = #"{"id":9,"title":"Tests","why":"w","destination":"repo_claude_md","workbench_id":3,"prompt_id":"","#
                + #""kind":"add","metric":"corrections","before":"","after":"x","evidence":[],"sources":1,"#
                + #""status":"accepted","created_at":"2026-11-01T09:00:00Z","decided_at":"2026-11-01T09:00:00Z","#
                + #""verdict":"","reverts_id":0,"budget":0"# + extra + "}"
            return try JSONDecoder().decode(CoachProposal.self, from: Data(json.utf8))
        }
        XCTAssertEqual(TuningChatTexts.folded(try repo(#","written_branch":"main""#)),
                       "Accepted · wrote CLAUDE.md on main — commit it yourself")
        XCTAssertEqual(TuningChatTexts.folded(try repo(""), written: CoachWrittenFile(path: "CLAUDE.md", branch: "dev")),
                       "Accepted · wrote CLAUDE.md on dev — commit it yourself")
        XCTAssertEqual(TuningChatTexts.folded(try repo(#","written_branch":"main","measure_from":"2026-11-02T09:00:00Z""#)),
                       TuningChatTexts.committedRepoFile)
    }

    func testWrittenFileFromTheAcceptResult() {
        let ok = #"{"ok":true,"id":9,"status":"accepted","pack_copies_updated":0,"pack_copies_drifted":0,"#
            + #""written_path":"CLAUDE.md","written_branch":"main"}"#
        XCTAssertEqual(CoachWrittenFile.parse(acceptResult: Data(ok.utf8)), CoachWrittenFile(path: "CLAUDE.md", branch: "main"))
        let other = #"{"ok":true,"id":9,"status":"accepted","written_path":"","written_branch":""}"#
        XCTAssertNil(CoachWrittenFile.parse(acceptResult: Data(other.utf8)))
        XCTAssertNil(CoachWrittenFile.parse(acceptResult: Data(#"{"ok":true}"#.utf8)))
    }
}

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

    func testFoldedProposal() {
        XCTAssertEqual(TuningChatTexts.foldedProposal(status: "accepted", title: "x"), "Accepted · measuring for 14 days")
        XCTAssertEqual(TuningChatTexts.foldedProposal(status: "declined", title: "x"), "Declined · x")
        XCTAssertEqual(TuningChatTexts.foldedProposal(status: "superseded", title: "Removed with its source data"),
                       "Withdrawn · Removed with its source data")
        XCTAssertNil(TuningChatTexts.foldedProposal(status: "open", title: "x"))
    }
}

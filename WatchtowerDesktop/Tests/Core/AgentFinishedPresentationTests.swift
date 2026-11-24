import Foundation
@testable import WatchtowerCore
import XCTest

/// The quiet "agent finished" row of the Workchat (spec 2026-11-24-workchat-polish §3, D4): its title, meta line,
/// tone, result and ids.
final class AgentFinishedPresentationTests: XCTestCase {
    private func agent(
        status: String = "completed",
        summary: String = #"Agent "Claude verify review #2188" finished"#,
        result: String = "No blockers.",
        tokens: Int = 43545,
        toolUses: Int = 9,
        durationMS: Int = 88925
    ) -> SessionFeedTask {
        SessionFeedTask(taskID: "aaea0001bcde77f", toolUseID: "toolu_01abcdefgh", status: status, summary: summary,
                        result: result, outputFile: "/tmp/x.output", tokens: tokens, toolUses: toolUses,
                        durationMS: durationMS, kind: "agent")
    }

    func testFinishedAgent() {
        let p = AgentFinishedPresentation(task: agent(), fallbackTitle: "Notice")
        XCTAssertEqual(p.title, "Claude verify review #2188")
        XCTAssertEqual(p.meta, "finished · 9 tools · 43.5k tokens · 1m 29s")
        XCTAssertEqual(p.glyph, "checkmark")
        XCTAssertEqual(p.tone, .success)
        XCTAssertFalse(p.isCommand)
        XCTAssertEqual(p.result, "No blockers.")
    }

    func testFailedAgent() {
        let p = AgentFinishedPresentation(task: agent(status: "failed", summary: #"Agent "Codex verify round 3" failed"#,
                                                      tokens: 1200, toolUses: 2, durationMS: 12000),
                                          fallbackTitle: "")
        XCTAssertEqual(p.title, "Codex verify round 3")
        XCTAssertEqual(p.meta, "failed · 2 tools · 1.2k tokens · 12s")
        XCTAssertEqual(p.glyph, "xmark")
        XCTAssertEqual(p.tone, .failure)
    }

    func testStoppedAgentIsNeutral() {
        let p = AgentFinishedPresentation(task: agent(status: "killed", tokens: 0, toolUses: 0, durationMS: 0),
                                          fallbackTitle: "")
        XCTAssertEqual(p.meta, "stopped")
        XCTAssertEqual(p.tone, .neutral)
        XCTAssertEqual(p.glyph, "stop")
    }

    func testCommand() {
        let task = SessionFeedTask(taskID: "b1", status: "completed",
                                   summary: #"Background command "Run full Go test suite" completed (exit code 0)"#,
                                   durationMS: 214_000, kind: "command", exitCode: 0)
        let p = AgentFinishedPresentation(task: task, fallbackTitle: "")
        XCTAssertEqual(p.title, "Background command · Run full Go test suite")
        XCTAssertEqual(p.meta, "exit 0 · 3m 34s")
        XCTAssertTrue(p.isCommand)
        XCTAssertEqual(p.tone, .success)
        XCTAssertEqual(p.glyph, "checkmark")
    }

    func testCommandNonZeroExitFails() {
        let task = SessionFeedTask(taskID: "b1", status: "completed",
                                   summary: #"Background command "echo (exit code 9)" completed (exit code 3)"#,
                                   kind: "command", exitCode: 3)
        let p = AgentFinishedPresentation(task: task, fallbackTitle: "")
        XCTAssertEqual(p.title, "Background command · echo (exit code 9)")
        XCTAssertEqual(p.meta, "exit 3")
        XCTAssertEqual(p.tone, .failure)
        XCTAssertEqual(p.glyph, "xmark")
    }

    func testCommandWithoutExitCodeShowsStatus() {
        let task = SessionFeedTask(status: "completed", summary: "Background command", kind: "command")
        let p = AgentFinishedPresentation(task: task, fallbackTitle: "")
        XCTAssertEqual(p.title, "Background command")
        XCTAssertEqual(p.meta, "finished")
    }

    func testNoUsage() {
        let p = AgentFinishedPresentation(task: agent(tokens: 0, toolUses: 0, durationMS: 0), fallbackTitle: "")
        XCTAssertEqual(p.meta, "finished")
    }

    func testSingularToolAndSmallNumbers() {
        let p = AgentFinishedPresentation(task: agent(tokens: 850, toolUses: 1, durationMS: 400), fallbackTitle: "")
        XCTAssertEqual(p.meta, "finished · 1 tool · 850 tokens · <1s")
        let big = AgentFinishedPresentation(task: agent(tokens: 1_000, durationMS: 3_725_000), fallbackTitle: "")
        XCTAssertEqual(big.meta, "finished · 9 tools · 1k tokens · 1h 2m")
        let huge = AgentFinishedPresentation(task: agent(tokens: 1_260_000), fallbackTitle: "")
        XCTAssertEqual(huge.meta, "finished · 9 tools · 1.3M tokens · 1m 29s")
    }

    func testEmptyResultAndDetails() {
        let p = AgentFinishedPresentation(task: agent(result: "  \n"), fallbackTitle: "")
        XCTAssertNil(p.result)
        XCTAssertEqual(p.details, "task aaea0001bcde… · toolu_01abcd…")
        let short = AgentFinishedPresentation(task: SessionFeedTask(taskID: "t1", kind: "agent"), fallbackTitle: "")
        XCTAssertEqual(short.details, "task t1")
    }

    func testTitleFallsBack() {
        let unquoted = AgentFinishedPresentation(task: agent(summary: "Agent finished"), fallbackTitle: "Task done")
        XCTAssertEqual(unquoted.title, "Task done")
        let bare = AgentFinishedPresentation(task: agent(summary: ""), fallbackTitle: "")
        XCTAssertEqual(bare.title, AgentFinishedPresentation.untitled)
    }

    func testCopy() {
        XCTAssertEqual(AgentFinishedPresentation.resultLabel, "RESULT")
        XCTAssertEqual(AgentFinishedPresentation.openOutputTitle, "Open output")
        XCTAssertEqual(AgentFinishedPresentation.detailsTitle, "Details")
        XCTAssertEqual(AgentFinishedPresentation.untitled, "Agent")
    }

    func testUnknownOutcomeIsNeutral() {
        let p = AgentFinishedPresentation(task: SessionFeedTask(summary: #"Agent "X" ended"#, kind: "agent"),
                                          fallbackTitle: "")
        XCTAssertEqual(p.meta, "ended")
        XCTAssertEqual(p.tone, .neutral)
        XCTAssertEqual(p.glyph, "minus")
        let command = AgentFinishedPresentation(task: SessionFeedTask(kind: "command"), fallbackTitle: "")
        XCTAssertEqual(command.meta, "ended")
        XCTAssertEqual(command.tone, .neutral)
        let exited = AgentFinishedPresentation(task: SessionFeedTask(kind: "command", exitCode: 0), fallbackTitle: "")
        XCTAssertEqual(exited.tone, .success)
    }

    // MARK: - Decoding

    func testDecodesTask() throws {
        let json = #"{"id":"n1","kind":"event","event_type":"task","title":"t","task":{"task_id":"a1","#
            + #""tool_use_id":"tu1","status":"completed","summary":"Agent \"X\" finished","result":"","#
            + #""output_file":"/tmp/x.output","tokens":43545,"tool_uses":9,"duration_ms":88925,"kind":"agent"}}"#
        let e = try JSONDecoder().decode(SessionFeedEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.task, SessionFeedTask(taskID: "a1", toolUseID: "tu1", status: "completed",
                                               summary: #"Agent "X" finished"#, outputFile: "/tmp/x.output",
                                               tokens: 43545, toolUses: 9, durationMS: 88925, kind: "agent"))
        XCTAssertNil(e.task?.exitCode)
    }

    func testDecodesCommandExitCode() throws {
        let json = #"{"id":"n1","kind":"event","task":{"task_id":"b1","kind":"command","exit_code":3}}"#
        let e = try JSONDecoder().decode(SessionFeedEntry.self, from: Data(json.utf8))
        XCTAssertEqual(e.task?.exitCode, 3)
        XCTAssertEqual(e.task?.kind, "command")
        XCTAssertEqual(e.task?.status, "")
    }

    func testDecodesEntryWithoutTask() throws {
        let json = #"{"id":"n1","kind":"event","event_type":"teammate","title":"t","text":"b"}"#
        let e = try JSONDecoder().decode(SessionFeedEntry.self, from: Data(json.utf8))
        XCTAssertNil(e.task)
    }
}

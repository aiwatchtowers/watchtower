import XCTest
@testable import WatchtowerCore

final class ChatEventTests: XCTestCase {
    func testParsesEveryV2Event() {
        XCTAssertEqual(ChatEvent.parse(#"{"type":"session_ready","session_id":"s1","provider":"claude","model":"m"}"#),
                       .sessionReady(sessionID: "s1", provider: "claude", model: "m"))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"session_ready","provider":"codex","model":""}"#),
                       .sessionReady(sessionID: nil, provider: "codex", model: ""))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"turn_start","turn_id":"t"}"#), .turnStart(turnID: "t"))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"text_delta","turn_id":"t","text":"Hi\n"}"#),
                       .textDelta(turnID: "t", text: "Hi\n"))
        XCTAssertEqual(
            ChatEvent.parse(#"{"type":"tool_start","turn_id":"t","id":"a","name":"get_jira_issue","args":{"z":1,"key":"P-1"}}"#),
            .toolStart(ChatToolStart(turnID: "t", id: "a", name: "get_jira_issue", argsJSON: #"{"key":"P-1","z":1}"#)))
        XCTAssertEqual(
            ChatEvent.parse(#"{"type":"tool_end","turn_id":"t","id":"a","ok":true,"summary":"s","#
                            + #""sources":[{"kind":"jira","title":"P-1","url":"https://x","ref":"P-1"}]}"#),
            .toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "s",
                                 sources: [ChatSource(kind: "jira", title: "P-1", url: "https://x", ref: "P-1")])))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"usage","turn_id":"t","tokens_in":5,"tokens_out":7,"model":"m"}"#),
                       .usage(ChatUsage(turnID: "t", tokensIn: 5, tokensOut: 7, model: "m")))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"turn_done","turn_id":"t","status":"interrupted","session_id":"s2"}"#),
                       .turnDone(turnID: "t", status: .interrupted, sessionID: "s2"))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"error","code":"rate_limit","message":"slow","retryable":true}"#),
                       .error(ChatSessionError(turnID: nil, code: .rateLimit, message: "slow", retryable: true)))
    }

    /// Every wire error code (Go `internal/chat/events.go`) maps to its own case.
    /// Go's optional group/snippet/date ride tool_end; empty strings read as nil.
    func testToolEndSourcePresentationFields() {
        let line = #"{"type":"tool_end","turn_id":"t","id":"a","ok":true,"summary":"s","sources":["#
            + ##"{"kind":"slack","title":"#pay · Ann","url":"","ref":"r","group":"#pay","snippet":"hi","date":"2026-05-13"},"##
            + #"{"kind":"jira","title":"P-1","ref":"jira:P-1","group":""}]}"#
        XCTAssertEqual(ChatEvent.parse(line), .toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "s", sources: [
            ChatSource(kind: "slack", title: "#pay · Ann", url: nil, ref: "r", group: "#pay", snippet: "hi", date: "2026-05-13"),
            ChatSource(kind: "jira", title: "P-1", url: nil, ref: "jira:P-1")
        ])))
    }

    func testEveryWireErrorCodeRoundTrips() {
        let codes = ["auth", "rate_limit", "provider_unavailable", "session_lost",
                     "attachment_unsupported", "interrupted", "internal", "workdir_unsafe"]
        for code in codes {
            XCTAssertEqual(ChatErrorCode(rawValue: code)?.rawValue, code, code)
        }
    }

    /// Degenerate inputs: garbage, unknown types, a missing `sources` array,
    /// an unknown error code — none may crash or invent data.
    func testDegenerateLines() {
        XCTAssertNil(ChatEvent.parse("not json"))
        XCTAssertNil(ChatEvent.parse(""))
        XCTAssertNil(ChatEvent.parse(#"{"type":"reset"}"#), "v2 has no reset")
        XCTAssertNil(ChatEvent.parse(#"{"text":"no type"}"#))
        XCTAssertNil(ChatEvent.parse(#"[1,2]"#))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"tool_end","turn_id":"t","id":"a","ok":false}"#),
                       .toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: false, summary: "", sources: [])))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"error","code":"weird","message":"m"}"#),
                       .error(ChatSessionError(turnID: nil, code: .internalError, message: "m", retryable: false)))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"tool_start","turn_id":"t","id":"a","name":"x"}"#),
                       .toolStart(ChatToolStart(turnID: "t", id: "a", name: "x", argsJSON: "{}")))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"turn_done","turn_id":"t","status":"??"}"#),
                       .turnDone(turnID: "t", status: .interrupted, sessionID: nil),
                       "an unknown status keeps the text as partial, never claims completion")
    }

    /// Go's own golden (`internal/chat/testdata/events_v2_tool_wait.jsonl`,
    /// spec §3.1), read in place so a Go shape change breaks this suite too.
    func testChatEventParsesToolWait() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/testdata/events_v2_tool_wait.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(ChatEvent.parse(lines[0]), .toolWait(ChatToolWait(
            turnID: "u7", id: "toolu_012DAzxzTcKsUABYq7nUo3Hn", actionID: 42, message: "Waiting for your approval")))
    }

    /// A `tool_wait` missing `turn_id`, `id`, `message` or a positive integer
    /// `action_id` is ignored (spec §3.1) — never a waiting step without the
    /// row the owner answers.
    func testToolWaitMissingAFieldIsIgnored() {
        let valid = #"{"type":"tool_wait","turn_id":"t","id":"a","message":"Waiting for your approval","action_id":7}"#
        XCTAssertEqual(ChatEvent.parse(valid),
                       .toolWait(ChatToolWait(turnID: "t", id: "a", actionID: 7, message: "Waiting for your approval")))
        let broken = [
            #"{"type":"tool_wait","id":"a","message":"m","action_id":7}"#,
            #"{"type":"tool_wait","turn_id":"","id":"a","message":"m","action_id":7}"#,
            #"{"type":"tool_wait","turn_id":"t","message":"m","action_id":7}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"","message":"m","action_id":7}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","action_id":7}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"","action_id":7}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"m"}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"m","action_id":0}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"m","action_id":-3}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"m","action_id":4.5}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"m","action_id":"7"}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"m","action_id":true}"#,
            #"{"type":"tool_wait","turn_id":"t","id":"a","message":"m","action_id":1e30}"#,
            #"{"type":"tool_wait","turn_id":7,"id":"a","message":"m","action_id":7}"#
        ]
        for line in broken {
            XCTAssertNil(ChatEvent.parse(line), line)
        }
    }

    /// An event type this build does not know is still dropped (an older
    /// Desktop ignores `tool_wait` the same way).
    func testChatEventUnknownTypeStillNil() {
        XCTAssertNil(ChatEvent.parse(#"{"type":"tool_paused","turn_id":"t","id":"a","action_id":1}"#))
        XCTAssertNil(ChatEvent.parse(#"{"type":"TOOL_WAIT","turn_id":"t","id":"a","message":"m","action_id":1}"#))
    }
}

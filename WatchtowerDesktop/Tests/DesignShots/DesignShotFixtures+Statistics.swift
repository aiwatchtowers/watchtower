import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Analytics pane's Statistics stack (board #1120, Plan 2, Task 7) on
/// fixture data: totals, the main thing, a Context card with a baseline bar
/// and growth rows (a sub-percent source, MCP tool names, a folded rest),
/// Skills, Trouble and the other hints.
@MainActor
enum StatisticsShotFixtures {
    static func screen() -> AnyView {
        do {
            let overview = try decode()
            return AnyView(AgentAnalyticsOverviewView(
                state: .overview(overview, staleError: nil), period: .constant(.week),
                actions: AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in },
                                               openFile: { _ in }, openAsks: {}, discuss: { _ in },
                                               asksWaiting: true)
            ).detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    static func decode() throws -> AgentReportOverview {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let base = tests.appendingPathComponent("Core/Fixtures/agent-report-overview.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: base)) as? [String: Any])
        json["totals"] = [
            "sessions": 42, "active_ms": 1_357_680_000, "away_ms": 0, "cost_usd": 3042.0, "cost_estimated_calls": 12,
            "tokens": ["input": 9000, "output": 5000, "cache_read": 290_000, "cache_write_5m": 1000, "cache_write_1h": 0]
        ]
        json["subagents"] = [
            "count": 40, "foreground": 10, "background": 30, "peak": 20, "serial": 0,
            "busy_ms": 1, "union_ms": 1, "blocked_ms": 0, "avg_parallel": 2.2
        ]
        let blocks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.blocks.utf8)) as? [String: Any])
        for (key, value) in blocks where key != "extra_hints" { json[key] = value }
        json["hints"] = try XCTUnwrap(json["hints"] as? [Any]) + XCTUnwrap(blocks["extra_hints"] as? [Any])
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static let blocks = #"""
    {"context":{"lead":"Every session starts with 80.4k tokens; a third of that is tool schemas, another third your CLAUDE.md and rules.",
      "facts_sessions":40,"sessions":42,
      "baseline":{"tokens":80400,"parts":[
        {"part":"tools","tokens":28600,"share":0.36},{"part":"instructions","tokens":25600,"share":0.32},
        {"part":"skills","tokens":10100,"share":0.13},{"part":"system","tokens":5000,"share":0.06},
        {"part":"hooks","tokens":3400,"share":0.04},{"part":"deferred_tools","tokens":3000,"share":0.04},
        {"part":"agents","tokens":2600,"share":0.03},{"part":"mcp","tokens":1500,"share":0.02},
        {"part":"other","tokens":600,"share":0.0}]},
      "subagent_baseline":{"tokens":100,"parts":[]},
      "growth":[
        {"source":"Bash","tokens":45600000,"share":0.46},{"source":"reminders","tokens":33700000,"share":0.34},
        {"source":"model","tokens":11200000,"share":0.11},{"source":"Read","tokens":7200000,"share":0.07},
        {"source":"Agent","tokens":494000,"share":0.005},{"source":"mcp__watchtower-workbench__get_ask","tokens":94800,"share":0.001},
        {"source":"Grep","tokens":400000,"share":0.004},{"source":"mcp__github__get_issue","tokens":300000,"share":0.003},
        {"source":"Edit","tokens":200000,"share":0.002}],
      "top_sources":[{"tool":"Read","target":"a.go","tokens":70000,"calls":4,"sessions":2}],
      "repeated_reads":[{"target":"b.go","reads":5,"session_uuid":"11111111-aaaa-bbbb-cccc-000000000001","tokens":40000}],
      "compactions":{"count":3,"median_pre_tokens":150000,"median_post_tokens":20000,"sessions":2},
      "disk":{"claude_md_bytes":6144,"claude_md_lines":160,"rules_bytes":2048}},
     "skills":{"lead":"The skill list costs 10.1k tokens in every session; 14 of 38 skills were not called in this period.",
      "facts_sessions":40,"listed":38,"used":24,"listing_tokens":10100,
      "rows":[{"name":"brainstorming","invocations":9,"by_trigger":{"slash":9},"cost_usd":12.5,"sessions":6}],
      "never_used":[{"name":"deploy","listing_tokens":260},{"name":"release","listing_tokens":300}]},
     "trouble":{"lead":"63 failed calls and 12 permission denials; most often go test.",
      "classes":[{"class":"exit_code","tool":"Bash","count":41,
        "sessions":[{"session_uuid":"22222222-aaaa-bbbb-cccc-000000000002","count":9}]},
        {"class":"not_found","tool":"mcp__watchtower-workbench__get_ask","count":3,"sessions":[]}],
      "denials":[{"kind":"permission-rule","tool":"Bash","target":"make","count":12}],
      "interrupts":4,"rejections":1,"interrupt_sessions":[],"unfinished_subagents":0,"rate_limited":2,"facts_sessions":40},
     "extra_hints":[
       {"id":"H2","finding":"Permission prompts held cheap commands","action":"Allow them",
        "fix":{"kind":"copy_allow_rules","rules":["Bash(make:*)"]},
        "estimate_ms":3600000,"estimate_usd":0,"estimate_tokens":0,"evidence":[],"more_evidence":0}]}
    """#
}

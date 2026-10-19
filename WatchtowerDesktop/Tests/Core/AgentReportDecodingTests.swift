import XCTest
@testable import WatchtowerCore

/// The fixtures are written by the Go builders over a seeded placeholder
/// database (`internal/agentreport` `TestDesktopReportFixtures`, `-update`
/// regenerates them); a renamed key on either side fails a test.
final class AgentReportDecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/Core/<this file>
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    func testOverviewDecodes() throws {
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
        XCTAssertEqual(ov.workbenchID, 1)
        XCTAssertTrue(ov.enabled)
        XCTAssertEqual(ov.totals.sessions, 2)
        XCTAssertEqual(ov.totals.tokens.cacheRead, 400)
        XCTAssertEqual(ov.time.tools.buildTest, 360_000)
        XCTAssertEqual(ov.time.backgroundMS, 785_000)
        XCTAssertEqual(ov.time.wallMS, 3_630_000)
        XCTAssertEqual(ov.subagents.background, 1)
        XCTAssertEqual(ov.subagents.avgParallel, 1)
        XCTAssertEqual(ov.commands.first?.class, "build_test")
        XCTAssertEqual(ov.commands.first?.avgMS, 120_000)
        XCTAssertEqual(ov.models.first?.cacheReadShare ?? 0, 0.0540, accuracy: 0.0001)
        XCTAssertEqual(ov.hints.map(\.id), ["H4", "H1", "H6"])
        XCTAssertEqual(ov.hints[1].evidence.map(\.kind), ["command", "target"])
        XCTAssertEqual(ov.hints[2].estimateUSD, 15)
        XCTAssertEqual(ov.tasks.first?.targetID, 1)
        XCTAssertEqual(ov.tasks.first?.phases["in_review"], 567_000_000)
        XCTAssertEqual(ov.tasks.first?.shared, true)
        XCTAssertEqual(ov.sessions.map(\.oldFormat), [true, false])
        XCTAssertEqual(ov.sessions[1].prs, ["https://example.com/acme/app/pull/1"])
        XCTAssertEqual(ov.oldFormatSessions, 1)
        XCTAssertEqual(ov.importState?.state, "loading")
        XCTAssertEqual(ov.importState?.filesStored, 2)
    }

    /// The fixture with `import` set to `value`, or without the key for nil.
    private func overview(import value: String?) throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        json["import"] = nil
        if let value {
            json["import"] = try JSONSerialization.jsonObject(with: Data(value.utf8))
        }
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testOverviewDecodesTheImportState() throws {
        let ov = try overview(import: #"{"state": "loading", "files_stored": 1234, "updated_at": "2026-10-18T17:00:00Z"}"#)
        XCTAssertEqual(ov.importState, AgentImportState(state: "loading", filesStored: 1234, updatedAt: "2026-10-18T17:00:00Z"))
        let notStarted = try overview(import: #"{"state": "not_started", "files_stored": 0}"#)
        XCTAssertEqual(notStarted.importState?.state, "not_started")
        XCTAssertNil(notStarted.importState?.updatedAt)
    }

    func testOverviewWithoutImportDecodes() throws {
        XCTAssertNil(try overview(import: nil).importState)
    }

    func testOverviewDecodesTasksMore() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        json["tasks_more"] = nil
        func decode() throws -> AgentReportOverview {
            try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let absent = try decode()
        XCTAssertNil(absent.tasksMore)
        json["tasks_more"] = 7
        let present = try decode()
        XCTAssertEqual(present.tasksMore, 7)
        XCTAssertFalse(absent.sameReport(as: present))
    }

    func testOverviewDecodesV2Blocks() throws {
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
        XCTAssertEqual(ov.hints[0].action?.isEmpty, false)
        XCTAssertEqual(ov.hints[0].fix, AgentHintFix(kind: "open_asks", ref: nil, rules: nil))
        XCTAssertEqual(ov.hints[0].moreEvidence, 0)
        XCTAssertEqual(ov.hints[0].estimateTokens, 0)
        // The Go fixture has one session with the v3 facts: the row-level keys
        // decode from what the Go builders write.
        let ctx = try XCTUnwrap(ov.context)
        XCTAssertEqual(ctx.factsSessions, 1)
        XCTAssertEqual(ctx.sessions, 2)
        XCTAssertEqual(ctx.baseline?.tokens, 140)
        XCTAssertEqual(ctx.baseline?.parts?.first?.part, "mcp")
        XCTAssertEqual(ctx.baseline?.parts?.first?.tokens, 47)
        XCTAssertEqual(ctx.baseline?.parts?.first?.share ?? 0, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(ctx.subagentBaseline?.parts?.count, 5)
        XCTAssertEqual(ctx.growth?.map(\.source), ["owner", "Read", "model"])
        XCTAssertEqual(ctx.topSources?.first, AgentSourceRow(tool: "Read", target: "main.go", tokens: 112, calls: 3, sessions: 1))
        XCTAssertEqual(ctx.repeatedReads?.first,
                       AgentRepeatRow(target: "main.go", reads: 3, sessionUUID: "11111111-aaaa-bbbb-cccc-000000000001", tokens: 112))
        XCTAssertNotNil(ctx.disk)
        let skills = try XCTUnwrap(ov.skills)
        XCTAssertEqual(skills.factsSessions, 1)
        XCTAssertEqual(skills.listed, 3)
        XCTAssertEqual(skills.used, 1)
        XCTAssertEqual(skills.rows?.first?.name, "review")
        XCTAssertEqual(skills.rows?.first?.sessions, 1)
        XCTAssertEqual(skills.neverUsed, [AgentUnusedSkill(name: "brainstorming", listingTokens: 3),
                                          AgentUnusedSkill(name: "pdf", listingTokens: 3)])
        let trouble = try XCTUnwrap(ov.trouble)
        XCTAssertEqual(trouble.factsSessions, 1)
        XCTAssertEqual(trouble.classes?.map(\.class), ["exit_code", "too_large"])
        XCTAssertEqual(trouble.classes?.first?.tool, "Bash")
        XCTAssertEqual(trouble.classes?.first?.sessions,
                       [AgentSessionCount(sessionUUID: "11111111-aaaa-bbbb-cccc-000000000001", count: 1)])
        XCTAssertEqual(trouble.unfinishedSubagents, 1)
        XCTAssertEqual(trouble.denials, [])
        XCTAssertEqual(trouble.interruptSessions, [])
        XCTAssertNotNil(trouble.interrupts)
        XCTAssertNotNil(trouble.rejections)
        XCTAssertNotNil(trouble.unfinishedSubagents)
        XCTAssertNotNil(trouble.rateLimited)
    }

    func testSameReportIgnoresOnlyTheStamps() throws {
        func variant(_ changes: [String: Any]) throws -> AgentReportOverview {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
            json.merge(changes) { $1 }
            return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let base = try variant([:])
        XCTAssertTrue(base.sameReport(as: try variant(["since": "2026-10-02T00:00:00Z", "until": "2026-10-09T00:00:00Z"])))
        XCTAssertFalse(base.sameReport(as: try variant(["old_format_sessions": 9])))
        XCTAssertFalse(base.sameReport(as: try variant(["enabled": false])))
        XCTAssertFalse(base.sameReport(as: try variant(["hints": []])))
    }

    func testContextSkillsAndTroubleFieldsDecode() throws {
        let json = #"""
        {"workbench_id":1,"enabled":true,"since":"a","until":"b",
         "totals":{"sessions":0,"active_ms":0,"away_ms":0,"cost_usd":0,"cost_estimated_calls":0,
                   "tokens":{"input":0,"output":0,"cache_read":0,"cache_write_5m":0,"cache_write_1h":0}},
         "time":{"model_ms":0,"tools":{"build_test":0,"git":0,"read_search":0,"edit":0,"mcp":0,"subagents_fg":0,"other":0},
                 "background_ms":0,"owner_ms":0,"away_ms":0,"active_ms":0,"wall_ms":0},
         "subagents":{"count":0,"foreground":0,"background":0,"peak":0,"serial":0,"busy_ms":0,"union_ms":0,"blocked_ms":0,"avg_parallel":0},
         "commands":[],"models":[],
         "hints":[{"id":"S1","finding":"f","action":"a","fix":{"kind":"allow_rule","ref":"make","rules":["Bash(make:*)"]},
                   "estimate_ms":0,"estimate_usd":0,"estimate_tokens":1200,"evidence":[],"more_evidence":3}],
         "tasks":[],"sessions":[],"old_format_sessions":0,
         "context":{"facts_sessions":2,"sessions":3,
           "baseline":{"tokens":9000,"parts":[{"part":"skills","tokens":900,"share":0.1}]},
           "subagent_baseline":{"tokens":100,"parts":[]},
           "growth":[{"source":"Bash","tokens":50,"share":0.5}],
           "top_sources":[{"tool":"Read","target":"a.go","tokens":70,"calls":4,"sessions":2}],
           "repeated_reads":[{"target":"a.go","reads":5,"session_uuid":"s1","tokens":40}],
           "compactions":{"count":1,"median_pre_tokens":800,"median_post_tokens":100,"sessions":1},
           "disk":{"claude_md_bytes":2048,"claude_md_lines":60,"rules_bytes":10}},
         "skills":{"facts_sessions":2,"listed":5,"used":1,"listing_tokens":300,
           "rows":[{"name":"x","invocations":2,"by_trigger":{"slash":2},"cost_usd":1.5,"sessions":1}],
           "never_used":[{"name":"y","listing_tokens":60}]},
         "trouble":{"classes":[{"class":"timeout","tool":"Bash","count":3,"sessions":[{"session_uuid":"s1","count":3}]}],
           "denials":[{"kind":"permission-rule","tool":"Bash","target":"make","count":2}],
           "interrupts":4,"rejections":1,"interrupt_sessions":[{"session_uuid":"s2","count":4}],
           "unfinished_subagents":1,"rate_limited":2,"facts_sessions":2}}
        """#
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: Data(json.utf8))
        XCTAssertEqual(ov.hints[0].fix, AgentHintFix(kind: "allow_rule", ref: "make", rules: ["Bash(make:*)"]))
        XCTAssertEqual(ov.hints[0].moreEvidence, 3)
        XCTAssertEqual(ov.hints[0].estimateTokens, 1200)
        let ctx = try XCTUnwrap(ov.context)
        XCTAssertEqual(ctx.factsSessions, 2)
        XCTAssertEqual(ctx.sessions, 3)
        XCTAssertEqual(ctx.baseline?.tokens, 9000)
        XCTAssertEqual(ctx.baseline?.parts?.first, AgentPartShare(part: "skills", tokens: 900, share: 0.1))
        XCTAssertEqual(ctx.subagentBaseline?.parts, [])
        XCTAssertEqual(ctx.growth?.first, AgentGrowthRow(source: "Bash", tokens: 50, share: 0.5))
        XCTAssertEqual(ctx.topSources?.first, AgentSourceRow(tool: "Read", target: "a.go", tokens: 70, calls: 4, sessions: 2))
        XCTAssertEqual(ctx.repeatedReads?.first, AgentRepeatRow(target: "a.go", reads: 5, sessionUUID: "s1", tokens: 40))
        XCTAssertEqual(ctx.compactions, AgentCompactionStats(count: 1, medianPreTokens: 800, medianPostTokens: 100, sessions: 1))
        XCTAssertEqual(ctx.disk, AgentDiskSizes(claudeMDBytes: 2048, claudeMDLines: 60, rulesBytes: 10))
        let sk = try XCTUnwrap(ov.skills)
        XCTAssertEqual(sk.listed, 5)
        XCTAssertEqual(sk.listingTokens, 300)
        XCTAssertEqual(sk.rows?.first, AgentSkillRow(name: "x", invocations: 2, byTrigger: ["slash": 2], costUSD: 1.5, sessions: 1))
        XCTAssertEqual(sk.neverUsed?.first, AgentUnusedSkill(name: "y", listingTokens: 60))
        let tr = try XCTUnwrap(ov.trouble)
        XCTAssertEqual(tr.classes?.first,
                       AgentErrorClassRow(class: "timeout", tool: "Bash", count: 3,
                                          sessions: [AgentSessionCount(sessionUUID: "s1", count: 3)]))
        XCTAssertEqual(tr.denials?.first, AgentDenialRow(kind: "permission-rule", tool: "Bash", target: "make", count: 2))
        XCTAssertEqual(tr.interrupts, 4)
        XCTAssertEqual(tr.rejections, 1)
        XCTAssertEqual(tr.interruptSessions?.first?.sessionUUID, "s2")
        XCTAssertEqual(tr.unfinishedSubagents, 1)
        XCTAssertEqual(tr.rateLimited, 2)
        XCTAssertEqual(tr.factsSessions, 2)
    }

    func testOverviewWithoutV2BlocksStillDecodes() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        for k in ["context", "skills", "trouble"] { json[k] = nil }
        json["hints"] = [["id": "H4", "finding": "f", "estimate_ms": 1, "estimate_usd": 0, "evidence": []]]
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(ov.context)
        XCTAssertNil(ov.skills)
        XCTAssertNil(ov.trouble)
        XCTAssertNil(ov.hints[0].action)
        XCTAssertNil(ov.hints[0].fix)
        XCTAssertNil(ov.hints[0].moreEvidence)
        XCTAssertNil(ov.hints[0].estimateTokens)
    }

    func testSessionDetailDecodes() throws {
        let d = try JSONDecoder().decode(AgentSessionDetail.self, from: fixture("agent-report-session"))
        XCTAssertEqual(d.session.uuid, "11111111-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(d.lanes.count, 2)
        XCTAssertEqual(d.lanes[0].agentID, "")
        XCTAssertTrue(d.lanes[1].background)
        XCTAssertEqual(Set(d.lanes[0].segments.compactMap(\.timeCategory)), [.model, .tool, .background, .owner, .away])
        XCTAssertEqual(d.lanes[0].segments[5].toolClass, "build_test")
        XCTAssertEqual(d.lanes[0].segments[5].verb, "make test")
        XCTAssertEqual(d.lanes[1].agentID, "agent-1")
        XCTAssertEqual(d.lanes[1].subagentType, "general-purpose")
        XCTAssertEqual(d.lanes[1].segments.map(\.timeCategory), [.model, .tool, .model])
        XCTAssertEqual(d.hints.map(\.id), ["H4", "H1", "H6"])
    }

    func testUnknownCategoryDoesNotFailTheDecode() throws {
        let json = #"{"start":"a","end":"b","category":"future","tool_class":"","verb":""}"#
        let seg = try JSONDecoder().decode(AgentSegment.self, from: Data(json.utf8))
        XCTAssertNil(seg.timeCategory)
    }
}

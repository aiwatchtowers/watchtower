import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Analytics Context block with its ready actions (context actions,
/// spec 2026-11-12 part 4) on fixture data: Do these with all three tags,
/// a working repository row, a PR-ready row, two done rows and the open
/// What's in it fold.
@MainActor
enum ContextActionsShotFixtures {
    private static var center: CoachCenter?

    static func cleanUp() {
        center?.stop()
        center = nil
    }

    static func block() -> AnyView {
        do {
            let coach = try loaded()
            let inputs = ContextActionsInputs(
                coach: coach, workbench: 3, sessionKinds: [41: .working], liveSessions: [41], repository: nil,
                startSession: { _, _, _ in nil }, openSession: { _ in }
            )
            let actions = AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in },
                                                openFile: { _ in }, openAsks: {}, tune: {}, asksWaiting: false)
            return AnyView(AgentAnalyticsContextView(context: try context(), actions: actions,
                                                     contextActions: inputs, sourcesExpanded: true)
                .frame(maxWidth: 900, alignment: .leading)
                .padding(Spacing.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static func loaded() throws -> CoachCenter {
        if let center { return center }
        let defaults = UserDefaults(suiteName: DesignShotFixtures.defaultsSuite) ?? .standard
        let coach = CoachCenter(runner: Runner(proposals: proposals()), interval: .seconds(3600), defaults: defaults)
        coach.refreshProposals()
        let deadline = Date().addingTimeInterval(5)
        while coach.proposals?.value == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(coach.proposals?.value, "the coach proposals loaded")
        center = coach
        return coach
    }

    /// The report's Context with a 60.0k start and its sources.
    private static func context() throws -> AgentContextReport {
        let json = """
        {"lead":"Every session starts with 60.0k tokens; tool schemas are 33%, the skill list 13%.",
         "facts_sessions":10,
         "baseline":{"tokens":60000,"parts":[
           {"part":"instructions","tokens":25000,"share":0.42},{"part":"tools","tokens":20000,"share":0.33},
           {"part":"skills","tokens":8000,"share":0.13},{"part":"agents","tokens":3000,"share":0.05},
           {"part":"mcp","tokens":2000,"share":0.03},{"part":"system","tokens":2000,"share":0.03}]},
         "sources":[
           {"part":"tools","group":"acme-board","group_kind":"mcp_server","tokens":10000,"calls":1000,"measured_sessions":10},
           {"part":"tools","group":"","group_kind":"builtin","tokens":6000,"calls":2000,"measured_sessions":10},
           {"part":"tools","group":"claude.ai","group_kind":"claude_ai_connectors","tokens":2000,"calls":0,"measured_sessions":10},
           {"part":"tools","group":"example-server","group_kind":"mcp_server","tokens":2000,"calls":0,"measured_sessions":10},
           {"part":"skills","group":"acme-skills","group_kind":"plugin","tokens":2500,"calls":50,"measured_sessions":10},
           {"part":"skills","group":"acme-tools","group_kind":"plugin","tokens":1500,"calls":0,"measured_sessions":10},
           {"part":"skills","group":"","group_kind":"user","tokens":500,"calls":5,"measured_sessions":10},
           {"part":"agents","group":"acme-tools","group_kind":"plugin","tokens":2000,"calls":0,"measured_sessions":10},
           {"part":"agents","group":"","group_kind":"builtin","tokens":0,"calls":10,"measured_sessions":0},
           {"part":"mcp","group":"acme-board","group_kind":"mcp_server","tokens":1500,"calls":0,"measured_sessions":10},
           {"part":"mcp","group":"claude.ai","group_kind":"claude_ai_connectors","tokens":500,"calls":0,"measured_sessions":10}]}
        """
        return try JSONDecoder().decode(AgentContextReport.self, from: Data(json.utf8))
    }

    private struct Row {
        var id: Int
        var title: String
        var destination: String
        var workbench = 3
        var status = "open"
        var source = ""
        var evidence = "[]"
        var decidedDaysAgo: Double?
        var verdict = ""
        var verdictValue = "null"
        var extra = ""

        func json(_ stamp: (Double) -> String) -> String {
            let decided = decidedDaysAgo.map { "\"\(stamp($0))\"" } ?? "null"
            let verdictAt = verdict.isEmpty ? "null" : "\"\(stamp(1))\""
            return """
            {"id":\(id),"title":"\(title)","why":"w","destination":"\(destination)","workbench_id":\(workbench),\
            "prompt_id":"","kind":"cut","metric":"start_tokens","before":"","after":"","evidence":\(evidence),\
            "sources":6,"status":"\(status)","created_at":"\(stamp(3))","decided_at":\(decided),"baseline":60000,\
            "verdict":"\(verdict)","verdict_value":\(verdictValue),"verdict_at":\(verdictAt),"reverts_id":0,\
            "budget":0,"origin":"context","source_key":"\(source)"\(extra)}
            """
        }
    }

    /// Go's evidence for a CLAUDE.md move: the file, the section, and the
    /// estimate (`round(section bytes / 2.6)`). The file (60 KB ≈ 23.6k
    /// tokens) fits inside the bar's "CLAUDE.md & rules" part (25.0k); its
    /// three sections (30 + 9 + 8 KB) fit inside the file.
    private static func claudeMD(section: String, saving: Int) -> String {
        #"[{"kind":"file","ref":"CLAUDE.md · 60.0 KB"},{"kind":"section","ref":""# + section
            + #""},{"kind":"saving_tokens","ref":""# + String(saving) + #""}]"#
    }

    /// Stamps relative to now: the done rows stay inside their 14 days.
    private static func proposals() -> String {
        let formatter = ISO8601DateFormatter()
        let stamp = { (days: Double) in formatter.string(from: Date().addingTimeInterval(-days * 24 * 3600)) }
        let rows = [
            Row(id: 11, title: "Turn off the acme-tools plugin", destination: "claude_plugin_off", workbench: 0,
                source: "acme-tools@example-market", evidence: #"[{"kind":"elsewhere","ref":"on in: app-one"}]"#),
            Row(id: 12, title: "Turn off claude.ai connectors in Claude Code", destination: "claude_connectors_off",
                workbench: 0, source: "claude.ai"),
            Row(id: 13, title: "Archive shipped-feature lines in memory", destination: "claude_memory_index",
                evidence: #"[{"kind":"file","ref":"MEMORY.md · 20.0 KB"}]"#),
            Row(id: 17, title: "Move the setup section out of CLAUDE.md", destination: "repo_claude_md",
                evidence: Self.claudeMD(section: "Setup · 9.0 KB", saving: 3545)),
            Row(id: 14, title: "Move feature summaries out of CLAUDE.md", destination: "repo_claude_md",
                status: "accepted", evidence: Self.claudeMD(section: "Feature Notes · 30.0 KB", saving: 11815),
                decidedDaysAgo: 0, extra: #","session_id":41,"via_session":true,"session_branch":"wt/slim""#),
            Row(id: 15, title: "Move the review rules out of CLAUDE.md", destination: "repo_claude_md",
                status: "accepted", evidence: Self.claudeMD(section: "Review rules · 8.0 KB", saving: 3151),
                decidedDaysAgo: 1, extra: #","session_id":42,"via_session":true,"session_branch":"wt/rules","pr":12,"#
                    + #""pr_state":"open","pr_url":"https://github.com/acme/app/pull/12""#),
            Row(id: 18, title: "Turn off the example-server MCP server", destination: "claude_mcp_server_off",
                workbench: 0, status: "accepted", source: "example-server", decidedDaysAgo: 0),
            Row(id: 19, title: "Turn off the sample-helper plugin", destination: "claude_plugin_off", workbench: 0,
                status: "accepted", source: "sample-helper@example-market", decidedDaysAgo: 15, verdict: "works",
                verdictValue: "54000", extra: #","verdict_sessions":10"#)
        ]
        return #"{"ok":true,"proposals":["# + rows.map { $0.json(stamp) }.joined(separator: ",") + "]}"
    }

    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        let proposals: String
        init(proposals: String) { self.proposals = proposals }

        func run(args: [String]) async throws -> Data { Data(proposals.utf8) }
        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
    }
}

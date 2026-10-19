import XCTest
import AppKit
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Records what the Analytics pane's links asked for.
@MainActor
private final class AnalyticsActionLog {
    var turnOns = 0
    var sessions: [String] = []
    var targets: [Int64] = []
    var files: [String] = []
    var askOpens = 0
    var discussed: [String] = []
    var asksWaiting = true

    var actions: AgentAnalyticsActions {
        AgentAnalyticsActions(
            turnOn: { self.turnOns += 1 },
            openSession: { self.sessions.append($0) },
            openTarget: { self.targets.append($0) },
            openFile: { self.files.append($0) },
            openAsks: { self.askOpens += 1 },
            discuss: { self.discussed.append($0) },
            asksWaiting: asksWaiting
        )
    }
}

/// The Analytics pane (#298): what each state shows and where its links
/// go. View inspection over the decoded fixtures, plus the view model's
/// navigation and a light/dark render of the category colours.
@MainActor
final class AgentAnalyticsPaneViewTests: XCTestCase {
    private typealias OverviewSnapshot = SessionReportCenter.Snapshot<AgentReportOverview>
    private typealias DetailSnapshot = SessionReportCenter.Snapshot<AgentSessionDetail>

    nonisolated private static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/\(name).json")
        return (try? Data(contentsOf: url)) ?? Data()
    }

    private static func overview() throws -> AgentReportOverview {
        try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
    }

    private static func detail() throws -> AgentSessionDetail {
        try JSONDecoder().decode(AgentSessionDetail.self, from: fixture("agent-report-session"))
    }

    /// The fixture with `enabled` flipped off.
    private static func offOverview() throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        json["enabled"] = false
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The fixture with `import` replaced by `state`/`files`, or removed for nil.
    private static func importOverview(state: String?, files: Int = 0) throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        json["import"] = state.map { ["state": $0, "files_stored": files, "updated_at": "2026-10-18T17:00:00Z"] }
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func overviewView(
        _ state: AgentAnalyticsPaneState, period: AgentAnalyticsCenter.Period = .week, log: AnalyticsActionLog? = nil
    ) -> AgentAnalyticsOverviewView {
        AgentAnalyticsOverviewView(state: state, period: .constant(period), actions: (log ?? AnalyticsActionLog()).actions)
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: - State

    func testStateFollowsTheSnapshotAndEnabling() throws {
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: nil, enabling: false), .loading)
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(error: "boom"), enabling: false), .failed("boom"))
        let off = try Self.offOverview()
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: off), enabling: false),
                       .off(enabling: false, error: nil))
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: off), enabling: true),
                       .off(enabling: true, error: nil))
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: off, error: "enable failed"), enabling: false),
                       .off(enabling: false, error: "enable failed"))
        let on = try Self.overview()
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: on, error: "stale"), enabling: false),
                       .overview(on, staleError: "stale"))
    }

    // MARK: - Off

    func testOffShowsTurnOnAndCallsIt() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.off(enabling: false, error: nil), log: log)
        try view.inspect().find(button: "Turn On").tap()
        XCTAssertEqual(log.turnOns, 1)
        XCTAssertThrowsError(try view.inspect().find(ViewType.ProgressView.self))
    }

    func testEnablingShowsProgressWithoutTurnOn() throws {
        let view = overviewView(.off(enabling: true, error: nil))
        XCTAssertNoThrow(try view.inspect().find(ViewType.ProgressView.self))
        XCTAssertThrowsError(try view.inspect().find(button: "Turn On"))
    }

    func testOffShowsTheEnableError() throws {
        let view = overviewView(.off(enabling: false, error: "agents enable failed"))
        XCTAssertNoThrow(try view.inspect().find(text: "agents enable failed"))
        XCTAssertNoThrow(try view.inspect().find(button: "Turn On"))
    }

    // MARK: - Overview

    func testTilesShowActiveCostSessionsAndParallelism() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        XCTAssertTrue(all.contains("50m"), "active 3 030 000 ms: \(all)")
        XCTAssertTrue(all.contains("28%"), "cache hit: 400 of 1 410 input tokens")
        XCTAssertTrue(all.contains("$15.50"))
        XCTAssertTrue(all.contains("2"), "sessions")
        XCTAssertTrue(all.contains("Subagents: 1.0 at once on average · peak 1"), "\(all)")
        XCTAssertTrue(all.contains("1 call priced by estimate"), "\(all)")
    }

    func testTimeBreakdownLegendAndFootnote() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        // Shares of active time (3 030 000): tools 363 000, model 82 000, background 785 000, you 1 800 000.
        XCTAssertTrue(all.contains("Tools 12%"), "\(all)")
        XCTAssertTrue(all.contains("Model 3%"))
        XCTAssertTrue(all.contains("Background agents 26%"))
        XCTAssertTrue(all.contains("You 59%"))
        XCTAssertTrue(all.contains("build & test 12% · MCP 0% · other 0%"), "\(all)")
        XCTAssertTrue(all.contains("Tool time includes permission prompts."))
    }

    func testHintsKeepTheirOrderAndEachItsOwnEstimate() throws {
        let ov = try Self.overview()
        let all = try texts(overviewView(.overview(ov, staleError: nil)))
        let findings = all.filter { text in ov.hints.contains { $0.finding == text } }
        XCTAssertEqual(findings, ov.hints.map(\.finding))
        XCTAssertTrue(all.contains("4m"), "H1's time estimate")
        XCTAssertTrue(all.contains("$15.00"), "H6's money estimate")
        XCTAssertFalse(all.contains { $0.localizedCaseInsensitiveContains("total") && $0.contains("sav") },
                       "no summed savings")
    }

    func testHintEvidenceLinksOpenTheTargetAndTheSession() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(try Self.overview(), staleError: nil), log: log)
        try view.inspect().find(button: "#1 Add widget").tap()
        try view.inspect().find(button: "Session 11111111").tap()
        XCTAssertEqual(log.targets, [1])
        XCTAssertEqual(log.sessions, ["11111111-aaaa-bbbb-cccc-000000000001"])
    }

    func testOldFormatSessionsAreCounted() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        XCTAssertTrue(all.contains("Older sessions — time not analysed: 1"))
    }

    func testSharedTaskRowSaysSoAndOpensTheTarget() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(try Self.overview(), staleError: nil), log: log)
        let all = try texts(view)
        XCTAssertTrue(all.contains("shared"))
        try view.inspect().find(button: "#2 Fix login").tap()
        XCTAssertEqual(log.targets, [2])
    }

    func testSessionRowOpensItsDetail() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(try Self.overview(), staleError: nil), log: log)
        try view.inspect().find(button: "11111111").tap()
        XCTAssertEqual(log.sessions, ["11111111-aaaa-bbbb-cccc-000000000001"])
    }

    func testCommandsAndModelsSections() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        XCTAssertTrue(all.contains("make test"))
        XCTAssertTrue(all.contains("claude-opus-5-5"))
        XCTAssertTrue(all.contains("28%"), "cache read share")
    }

    func testThePeriodLabelComesFromTheReportAndAChangedPickerSaysUpdating() throws {
        let ov = try Self.overview()
        XCTAssertEqual(AgentAnalyticsFormat.period(of: ov), .week)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(AgentAnalyticsFormat.periodLabel(ov, timeZone: utc), "Oct 1 – Oct 8")

        XCTAssertThrowsError(try overviewView(.overview(ov, staleError: nil), period: .week).inspect().find(text: "Updating…"))
        XCTAssertNoThrow(try overviewView(.overview(ov, staleError: nil), period: .month).inspect().find(text: "Updating…"))
    }

    func testAllHistoryPeriod() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("agent-report-overview")) as? [String: Any])
        json["since"] = ""
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(AgentAnalyticsFormat.period(of: ov), .all)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(AgentAnalyticsFormat.periodLabel(ov, timeZone: utc), "All history to Oct 8")
    }

    func testDurations() {
        XCTAssertEqual(AgentAnalyticsFormat.duration(0), "0s")
        XCTAssertEqual(AgentAnalyticsFormat.duration(45000), "45s")
        XCTAssertEqual(AgentAnalyticsFormat.duration(1_650_000), "27m")
        XCTAssertEqual(AgentAnalyticsFormat.duration(51_600_000), "14h 20m")
        XCTAssertEqual(AgentAnalyticsFormat.duration(111_600_000), "31h")
    }

    // MARK: - v2: main thing, fixes, blocks

    /// The fixture with filled context, skills and trouble blocks and two
    /// more hints (copy rules, open a file).
    private static func filledOverview() throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        let blocks = #"""
        {"context":{"facts_sessions":2,"sessions":3,
           "baseline":{"tokens":9000,"parts":[{"part":"skills","tokens":900,"share":0.1},
                                              {"part":"instructions","tokens":8100,"share":0.9}]},
           "subagent_baseline":{"tokens":100,"parts":[]},
           "growth":[{"source":"Bash","tokens":50,"share":0.5}],
           "top_sources":[{"tool":"Read","target":"a.go","tokens":70,"calls":4,"sessions":2}],
           "repeated_reads":[{"target":"b.go","reads":5,"session_uuid":"11111111-aaaa-bbbb-cccc-000000000001","tokens":40}],
           "compactions":{"count":1,"median_pre_tokens":800,"median_post_tokens":100,"sessions":1},
           "disk":{"claude_md_bytes":2048,"claude_md_lines":60,"rules_bytes":10}},
         "skills":{"facts_sessions":2,"listed":5,"used":1,"listing_tokens":300,
           "rows":[{"name":"brainstorm","invocations":2,"by_trigger":{"slash":2},"cost_usd":1.5,"sessions":1}],
           "never_used":[{"name":"deploy","listing_tokens":60}]},
         "trouble":{"classes":[{"class":"timeout","tool":"Bash","count":3,
                                "sessions":[{"session_uuid":"22222222-aaaa-bbbb-cccc-000000000002","count":3}]}],
           "denials":[{"kind":"permission-rule","tool":"Bash","target":"make","count":2}],
           "interrupts":4,"rejections":1,"interrupt_sessions":[{"session_uuid":"s2","count":4}],
           "unfinished_subagents":1,"rate_limited":2,"facts_sessions":2},
         "extra_hints":[
           {"id":"H2","finding":"Permission prompts held cheap commands","action":"Allow them",
            "fix":{"kind":"copy_allow_rules","rules":["Bash(make:*)"]},
            "estimate_ms":60000,"estimate_usd":0,"estimate_tokens":0,"evidence":[],"more_evidence":4},
           {"id":"C1","finding":"CLAUDE.md is long","action":"Trim it",
            "fix":{"kind":"open_file","ref":"CLAUDE.md"},
            "estimate_ms":0,"estimate_usd":0,"estimate_tokens":12300,"evidence":[],"more_evidence":0}]}
        """#
        let filled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(blocks.utf8)) as? [String: Any])
        for key in ["context", "skills", "trouble"] { json[key] = filled[key] }
        json["hints"] = try XCTUnwrap(json["hints"] as? [Any]) + XCTUnwrap(filled["extra_hints"] as? [Any])
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A fix as the report sends it (the Core models have no public init).
    private static func fix(_ json: String) throws -> AgentHintFix {
        try JSONDecoder().decode(AgentHintFix.self, from: Data(json.utf8))
    }

    func testFixActionMapping() throws {
        XCTAssertNil(AgentHintFixAction.make(nil))
        XCTAssertNil(AgentHintFixAction.make(try Self.fix(#"{"kind":"launch_rockets","ref":"x"}"#)), "unknown kind")
        XCTAssertEqual(AgentHintFixAction.make(try Self.fix(#"{"kind":"open_asks"}"#)), .openAsks)
        XCTAssertEqual(AgentHintFixAction.make(try Self.fix(#"{"kind":"open_session","ref":"u-1"}"#)), .openSession("u-1"))
        XCTAssertNil(AgentHintFixAction.make(try Self.fix(#"{"kind":"open_session"}"#)), "no session to open")
        XCTAssertEqual(AgentHintFixAction.make(try Self.fix(#"{"kind":"open_file","ref":"CLAUDE.md"}"#)), .openFile("CLAUDE.md"))
        XCTAssertNil(AgentHintFixAction.make(try Self.fix(#"{"kind":"open_file","ref":""}"#)), "no file to open")
        let rules = ["Bash(make:*)", #"Bash(go test "./x":*)"#]
        XCTAssertEqual(AgentHintFixAction.make(try Self.fix(#"{"kind":"copy_allow_rules","rules":["Bash(make:*)","Bash(go test \"./x\":*)"]}"#)),
                       .copyRules(rules))
        XCTAssertNil(AgentHintFixAction.make(try Self.fix(#"{"kind":"copy_allow_rules","rules":[]}"#)), "nothing to copy")
        XCTAssertEqual(AgentHintFixAction.copyText(rules), #"""
        "Bash(make:*)",
        "Bash(go test \"./x\":*)"
        """#)
    }

    func testPaneStateShowsNotMeasuredWithoutFacts() throws {
        XCTAssertEqual(AgentAnalyticsBlockState.make(factsSessions: nil, hasFindings: true), .notMeasured)
        XCTAssertEqual(AgentAnalyticsBlockState.make(factsSessions: 0, hasFindings: true), .notMeasured)
        XCTAssertEqual(AgentAnalyticsBlockState.make(factsSessions: 2, hasFindings: false), .nothingFound)
        XCTAssertEqual(AgentAnalyticsBlockState.make(factsSessions: 2, hasFindings: true), .measured)

        // The Go fixture predates the facts: every v2 block says so.
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        XCTAssertEqual(all.filter { $0 == AgentAnalyticsBlockState.notMeasuredLine }.count, 3, "\(all)")
        XCTAssertEqual(AgentAnalyticsBlockState.notMeasuredLine,
                       "Not measured for sessions before this update — they fill in as new sessions run.")
    }

    func testCacheHitShare() throws {
        func tokens(_ json: String) throws -> AgentTokens {
            try JSONDecoder().decode(AgentTokens.self, from: Data(json.utf8))
        }
        let mixed = try tokens(#"{"input":1010,"output":505,"cache_read":400,"cache_write_5m":50,"cache_write_1h":40}"#)
        XCTAssertEqual(AgentAnalyticsFormat.cacheHit(mixed), "27%", "400 of 1 500, output left out")
        let none = try tokens(#"{"input":0,"output":9,"cache_read":0,"cache_write_5m":0,"cache_write_1h":0}"#)
        XCTAssertEqual(AgentAnalyticsFormat.cacheHit(none), "—", "no input at all")
    }

    func testEnumLabels() {
        let cases: [(String, String, String)] = [
            ("part", "instructions", "CLAUDE.md & rules"), ("part", "deferred_tools", "Deferred tools"),
            ("part", "hooks", "Hooks"), ("part", "brand_new", "brand_new"),
            ("class", "exit_code", "Command failed"), ("class", "isolation_block", "Blocked by worktree isolation"),
            ("class", "429", "Rate limited"), ("class", "brand_new", "brand_new"),
            ("denial", "permission-rule", "Permission rule"), ("denial", "user-rejected", "You declined"),
            ("denial", "automode-blocked", "Blocked in auto mode"), ("denial", "brand_new", "brand_new")
        ]
        for (kind, raw, want) in cases {
            let got = switch kind {
            case "part": AgentAnalyticsFormat.label(part: raw)
            case "class": AgentAnalyticsFormat.label(errorClass: raw)
            default: AgentAnalyticsFormat.label(denial: raw)
            }
            XCTAssertEqual(got, want, "\(kind) \(raw)")
        }
    }

    func testOpenWaitingForYouIsOffWithoutAnAsk() throws {
        let log = AnalyticsActionLog()
        log.asksWaiting = false
        let view = overviewView(.overview(try Self.overview(), staleError: nil), log: log)
        XCTAssertTrue(try view.inspect().find(button: "Open Waiting for You").isDisabled())
    }

    func testTokenCounts() {
        XCTAssertEqual(AgentAnalyticsFormat.tokens(950), "950")
        XCTAssertEqual(AgentAnalyticsFormat.tokens(12_300), "12.3k")
        XCTAssertEqual(AgentAnalyticsFormat.tokens(2_500_000), "2.5M")
    }

    func testMainThingIsTheFirstHintAndTheRestFollow() throws {
        let ov = try Self.filledOverview()
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(ov, staleError: nil), log: log)
        let all = try texts(view)
        let main = try XCTUnwrap(all.firstIndex(of: "The main thing"))
        let rest = try XCTUnwrap(all.firstIndex(of: "What else would save"))
        XCTAssertEqual(all.firstIndex(of: ov.hints[0].finding).map { $0 > main && $0 < rest }, true, "\(all)")
        for hint in ov.hints.dropFirst() {
            XCTAssertEqual(all.firstIndex(of: hint.finding).map { $0 > rest }, true, hint.id)
            XCTAssertTrue(all.contains(try XCTUnwrap(hint.action)), "the action line shows without a click")
        }
        XCTAssertTrue(all.contains("and 4 more"), "\(all)")
        XCTAssertTrue(all.contains("≈ 12.3k tokens"), "a tokens-only estimate")

        try view.inspect().find(button: "Open Waiting for You").tap()
        XCTAssertEqual(log.askOpens, 1)
        try view.inspect().find(button: "Open Session").tap()
        XCTAssertEqual(log.sessions, ["11111111-aaaa-bbbb-cccc-000000000001"])
        try view.inspect().find(button: "Open CLAUDE.md").tap()
        XCTAssertEqual(log.files, ["CLAUDE.md"])
        XCTAssertNoThrow(try view.inspect().find(button: "Copy Allow Rules"))
    }

    func testDiscussInChatSendsTheTopHints() throws {
        let ov = try Self.filledOverview()
        let log = AnalyticsActionLog()
        try overviewView(.overview(ov, staleError: nil), log: log).inspect().find(button: "Discuss in Chat").tap()
        let text = try XCTUnwrap(log.discussed.first)
        XCTAssertEqual(text, AgentAnalyticsFormat.discussText(ov))
        XCTAssertTrue(text.contains(ov.hints[0].finding))
        XCTAssertTrue(text.contains(try XCTUnwrap(ov.hints[0].action)))
        XCTAssertTrue(text.contains(ov.hints[2].finding))
        XCTAssertFalse(text.contains(ov.hints[3].finding), "the top three only")
    }

    func testFilledBlocks() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(try Self.filledOverview(), staleError: nil), log: log)
        let all = try texts(view)
        XCTAssertFalse(all.contains(AgentAnalyticsBlockState.notMeasuredLine))
        for line in ["Baseline: 9.0k tokens at session start", "CLAUDE.md & rules 8.1k · 90%", "Bash 50 · 50%",
                     "Compactions: 1 in 1 session · median 800 → 100 tokens",
                     "CLAUDE.md: 60 lines, 2 KB · rules 10 bytes",
                     "Used 1 of 5 listed skills · the listing costs 300 tokens per session",
                     "brainstorm", "Never used: deploy (60)",
                     "Interrupts: 4 · rejections: 1", "Unfinished subagents: 1", "Rate limited: 2"] {
            XCTAssertTrue(all.contains(line), "\(line): \(all)")
        }
        XCTAssertTrue(all.contains("b.go — 5 reads, 40 tokens"), "\(all)")
        XCTAssertTrue(all.contains("Timed out · Bash — 3"), "\(all)")
        XCTAssertTrue(all.contains("Permission rule · Bash make — 2"), "\(all)")
        try view.inspect().find(button: "22222222").tap()
        XCTAssertEqual(log.sessions, ["22222222-aaaa-bbbb-cccc-000000000002"], "the class's top session")
    }

    /// Compactions and the files on disk need no new facts: they show even
    /// in a block that is not measured yet.
    func testCompactionsAndDiskShowInAnyState() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("agent-report-overview")) as? [String: Any])
        var context = try XCTUnwrap(json["context"] as? [String: Any])
        context["compactions"] = ["count": 2, "median_pre_tokens": 800, "median_post_tokens": 100, "sessions": 1]
        context["disk"] = ["claude_md_bytes": 2048, "claude_md_lines": 60, "rules_bytes": 0]
        json["context"] = context
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
        let all = try texts(overviewView(.overview(ov, staleError: nil)))
        XCTAssertTrue(all.contains("Compactions: 2 in 1 session · median 800 → 100 tokens"), "\(all)")
        XCTAssertTrue(all.contains("CLAUDE.md: 60 lines, 2 KB"), "\(all)")
        XCTAssertEqual(all.filter { $0 == AgentAnalyticsBlockState.notMeasuredLine }.count, 3)
    }

    func testBlocksWithFactsButNothingFound() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("agent-report-overview")) as? [String: Any])
        for key in ["skills", "trouble"] {
            var block = try XCTUnwrap(json[key] as? [String: Any])
            block["facts_sessions"] = 2
            json[key] = block
        }
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
        let all = try texts(overviewView(.overview(ov, staleError: nil)))
        XCTAssertEqual(all.filter { $0 == "Nothing to fix here" }.count, 2, "\(all)")
        XCTAssertEqual(all.filter { $0 == AgentAnalyticsBlockState.notMeasuredLine }.count, 1, "context still not measured")
    }

    // MARK: - Session detail

    func testSessionDetailHasOneLanePerSubagentPlusMain() throws {
        let det = try Self.detail()
        let view = AgentSessionAnalyticsView(
            snapshot: DetailSnapshot(value: det), onBack: {}, actions: AnalyticsActionLog().actions)
        let all = try texts(view)
        let lanes = det.lanes.map(AgentSessionTimelineView.laneTitle)
        XCTAssertEqual(lanes, ["Main agent", "general-purpose · background"])
        XCTAssertEqual(all.filter(lanes.contains), lanes)
        XCTAssertTrue(all.contains(det.hints[0].finding))
        XCTAssertTrue(all.contains("Tool time includes permission prompts."))
    }

    func testSessionDetailBackAndLoading() throws {
        var backs = 0
        let loading = AgentSessionAnalyticsView(snapshot: nil, onBack: { backs += 1 }, actions: AnalyticsActionLog().actions)
        XCTAssertNoThrow(try loading.inspect().find(ViewType.ProgressView.self))
        try loading.inspect().find(button: "Back").tap()
        XCTAssertEqual(backs, 1)
        let failed = AgentSessionAnalyticsView(snapshot: DetailSnapshot(error: "no such session"), onBack: {},
                                               actions: AnalyticsActionLog().actions)
        XCTAssertNoThrow(try failed.inspect().find(text: "no such session"))
    }

    func testSegmentDescription() throws {
        let det = try Self.detail()
        XCTAssertEqual(AgentSessionTimelineView.describe(det.lanes[0].segments[5]), "Tools · build & test · make test · 2m")
        XCTAssertEqual(AgentSessionTimelineView.describe(det.lanes[0].segments[0]), "Model · 10s")
    }

    // MARK: - Session report line

    func testReportLineOnlyForAMatchingSession() throws {
        let ov = try Self.overview()
        XCTAssertNil(SessionReportAnalyticsLine.row(in: ov, claudeSessionID: "nope"))
        XCTAssertNil(SessionReportAnalyticsLine.row(in: ov, claudeSessionID: nil))
        XCTAssertNil(SessionReportAnalyticsLine.row(in: nil, claudeSessionID: "11111111-aaaa-bbbb-cccc-000000000001"))
        let row = try XCTUnwrap(SessionReportAnalyticsLine.row(in: ov, claudeSessionID: "11111111-aaaa-bbbb-cccc-000000000001"))
        var opened = 0
        let line = SessionReportAnalyticsLine(row: row) { opened += 1 }
        XCTAssertNoThrow(try line.inspect().find(text: "Agent time 50m · $15.00 ·"))
        try line.inspect().find(button: "Analytics").tap()
        XCTAssertEqual(opened, 1)
    }

    func testShowSessionAnalyticsOpensThePaneOnTheSession() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentAnalyticsPaneViewTests-\(UUID().uuidString)"))
        let projectID = try await pool.write { d in try TestDatabase.insertWorkbench(d, folder: "/tmp/acme") }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: nil)
        vm.showSessionAnalytics("u-1", projectID: projectID)
        XCTAssertEqual(vm.analyticsSession[projectID], "u-1")
        XCTAssertTrue(vm.layout(projectID: projectID).visiblePanes.contains(.analytics))
    }

    /// Opening a session's detail and going back keeps the pane shown: the
    /// center is not hidden and the overview does not run again.
    func testSwitchingToADetailAndBackKeepsTheOverviewShown() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentAnalyticsPaneViewTests-\(UUID().uuidString)"))
        let projectID = try await pool.write { d in try TestDatabase.insertWorkbench(d, folder: "/tmp/acme") }
        let project = try await pool.read { d in
            try XCTUnwrap(Workbench.fetchOne(d, sql: "SELECT * FROM projects WHERE id = ?", arguments: [projectID]))
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: nil)
        let runner = FakeCLIRunner(stdout: Self.fixture("agent-report-overview"))
        let center = AgentAnalyticsCenter(runner: runner, interval: .seconds(3600))
        defer { center.stop() }
        vm.agentAnalytics = center

        let host = NSHostingView(rootView: AgentAnalyticsPaneView(vm: vm, project: project))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() async {   // lay the view out, then let the center's runs finish
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(for: .milliseconds(100))
        }
        func overviewRuns() -> Int { runner.invocations.filter { !$0.contains("--session") }.count }
        await settle()
        XCTAssertEqual(overviewRuns(), 1)
        XCTAssertTrue(center.isPolling)

        vm.analyticsSession[projectID] = "11111111-aaaa-bbbb-cccc-000000000001"
        await settle()
        XCTAssertTrue(center.isPolling, "the detail does not hide the pane")
        vm.analyticsSession[projectID] = nil
        await settle()
        XCTAssertEqual(overviewRuns(), 1, "back to the overview reruns nothing")
        XCTAssertTrue(center.isPolling)
        XCTAssertEqual(runner.invocations.filter { $0.contains("--session") }.count, 1)
    }

    // MARK: - History import (#849)

    func testImportLine() throws {
        func line(_ state: String, _ files: Int, _ locale: String = "en_US") throws -> String? {
            let importState = try XCTUnwrap(Self.importOverview(state: state, files: files).importState)
            return AgentAnalyticsFormat.importLine(importState, locale: Locale(identifier: locale))
        }
        XCTAssertNil(try line("done", 1234))
        XCTAssertEqual(try line("loading", 1234), "Loading history — 1,234 files so far")
        XCTAssertEqual(try line("not_started", 0), "Loading history — 0 files so far")
        XCTAssertEqual(try line("loading", 1234, "de_DE"), "Loading history — 1.234 files so far")
        XCTAssertEqual(try line("waiting_for_move", 0),
                       "History not moved yet — restart the daemon or run watchtower agents scan")
    }

    /// Before the move the pane shows a warning, not a loading line that never moves.
    func testOverviewShowsTheMoveWarning() throws {
        let all = try texts(overviewView(.overview(Self.importOverview(state: "waiting_for_move"), staleError: nil)))
        XCTAssertTrue(all.contains("History not moved yet — restart the daemon or run watchtower agents scan"), "\(all)")
        XCTAssertFalse(all.contains { $0.hasPrefix("Loading history") }, "\(all)")
        let state = try XCTUnwrap(Self.importOverview(state: "waiting_for_move").importState)
        XCTAssertTrue(AgentAnalyticsFormat.isImportWarning(state))
        XCTAssertFalse(AgentAnalyticsFormat.isImportWarning(try XCTUnwrap(Self.importOverview(state: "loading").importState)))
    }

    /// The loading line sits above the overview until the import is done;
    /// an older binary that sends no `import` shows none.
    func testOverviewShowsTheLoadingLineUntilDone() throws {
        func lines(_ overview: AgentReportOverview) throws -> [String] {
            try texts(overviewView(.overview(overview, staleError: nil)))
        }
        XCTAssertTrue(try lines(Self.overview()).contains("Loading history — 2 files so far"))   // the Go fixture
        XCTAssertTrue(try lines(Self.importOverview(state: "loading", files: 1234))
            .contains("Loading history — \(1234.formatted()) files so far"))
        XCTAssertTrue(try lines(Self.importOverview(state: "not_started")).contains("Loading history — 0 files so far"))
        for state in ["done", nil] as [String?] {
            let all = try lines(Self.importOverview(state: state, files: 1234))
            XCTAssertFalse(all.contains { $0.hasPrefix("Loading history") }, "\(String(describing: state)): \(all)")
        }
    }

    // MARK: - Colours

    /// "You" has its own colour, not the orange of the pane's error lines,
    /// and no two categories share one.
    func testOwnerColourIsNotTheErrorOrange() {
        XCTAssertNotEqual(AgentTimeCategory.owner.color, .orange)
        let colours = [AgentTimeCategory.model, .tool, .background, .owner, .away].map(\.color)
        XCTAssertEqual(Set(colours.map(\.description)).count, colours.count)
    }

    /// The time bar draws its colours in both appearances (not the window's
    /// background, not transparent).
    func testTimeBarRendersInLightAndDark() throws {
        let probe = ViewRenderProbe(size: NSSize(width: 200, height: 20))
        let bar = AgentAnalyticsTimeBar(time: try Self.overview().time)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let bitmap = try probe.render(bar, appearance)
            let pixel = try probe.pixel(bitmap, x: 10, y: 10)
            XCTAssertEqual(pixel.alpha, 255, "\(name.rawValue): \(pixel)")
            let background = appearance.name == .darkAqua ? 30 : 236
            XCTAssertFalse(pixel.red == pixel.green && pixel.green == pixel.blue && abs(pixel.red - background) < 20,
                           "\(name.rawValue): \(pixel) looks like the background")
        }
    }
}

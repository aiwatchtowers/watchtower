import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The coach sections on the Analytics pane (board #1120, Plan 2) on
/// fixture data: two proposals, four accepted edits, and the Edit and
/// Roll Back sheets.
@MainActor
enum CoachShotFixtures {
    private static var center: CoachCenter?

    static func cleanUp() {
        center?.stop()
        center = nil
    }

    enum Frame { case sections, editSheet, rollbackSheet }

    static func screen(_ frame: Frame) -> AnyView {
        do {
            let coach = try loaded()
            switch frame {
            case .sections:
                let overview = try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
                return AnyView(AgentAnalyticsOverviewView(
                    state: .overview(overview, staleError: nil), period: .constant(.week),
                    actions: AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in },
                                                   openFile: { _ in }, openAsks: {}, discuss: { _ in },
                                                   asksWaiting: false),
                    coach: coach, workbench: 3
                ).detailBackground())
            case .editSheet:
                let proposal = try XCTUnwrap(coach.proposals?.value?.first { $0.id == 7 })
                return AnyView(CoachEditSheet(proposal: proposal, coach: coach)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .panelBackground())
            case .rollbackSheet:
                let proposal = try XCTUnwrap(coach.proposals?.value?.first { $0.id == 5 })
                let diff = "- Bash(go test:*)\n+ Bash(go test:*)\n+ Bash(go vet:*)"
                return AnyView(CoachRollbackSheet(proposal: proposal, diff: diff, coach: coach)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .panelBackground())
            }
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static func loaded() throws -> CoachCenter {
        if let center { return center }
        let coach = CoachCenter(runner: Runner(), interval: .seconds(3600))
        coach.show(workbench: 3, period: .week)
        let deadline = Date().addingTimeInterval(5)
        while coach.status[3]?.value == nil || coach.proposals?.value == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(coach.status[3]?.value, "the coach status loaded")
        XCTAssertNotNil(coach.proposals?.value, "the coach proposals loaded")
        center = coach
        return coach
    }

    nonisolated private static func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = tests.appendingPathComponent("Core/Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    nonisolated private static let status = """
    {"ok":true,"period":{"since":"2026-10-21T00:00:00Z","until":"2026-10-28T00:00:00Z"},\
    "metrics":{"corrections":{"value":2.1,"n":8,"known":true,"previous":3.0},\
    "task_hours":{"value":1.667,"n":6,"known":true,"previous":1.53},\
    "task_cost_usd":{"value":14.2,"n":6,"known":true,"previous":12.0},\
    "owner_loop":{"value":0.22,"n":6,"known":true,"previous":0.31},\
    "spec_findings":{"value":7.4,"n":4,"known":true,"previous":7.6},\
    "review_comments":{"value":2.0,"n":2,"known":true,"previous":2.0}},"open":2,"last_run":"2026-10-26T09:10:00Z"}
    """

    private struct Row {
        var id: Int
        var title: String
        var destination: String
        var metric: String
        var change: (before: String, after: String) = ("", "")
        var status = "accepted"
        var decided: String?
        var verdict = ""
        var numbers: (baseline: String, value: String) = ("null", "null")
        var why = "Seen in several sessions."
        var budget = 0
        var evidence = "[]"
        var workbench = 0

        var json: String {
            let decidedJSON = decided.map { "\"\($0)\"" } ?? "null"
            return """
            {"id":\(id),"title":"\(title)","why":"\(why)","destination":"\(destination)","workbench_id":\(workbench),\
            "prompt_id":"","kind":"add","metric":"\(metric)","before":"\(change.before)","after":"\(change.after)",\
            "evidence":\(evidence),"sources":3,"status":"\(status)","created_at":"2026-10-2\(id % 10)T09:00:00Z",\
            "decided_at":\(decidedJSON),"baseline":\(numbers.baseline),"verdict":"\(verdict)",\
            "verdict_value":\(numbers.value),"verdict_at":null,"reverts_id":0,"budget":\(budget)}
            """
        }
    }

    nonisolated private static let nonGoals = "Every spec has a Non-goals section: what the feature deliberately does not do."
    nonisolated private static let specEvidence = (581...585)
        .map { #"{"kind":"ask","ref":"ask:\#($0)#a"}"# }
        .joined(separator: ",")

    nonisolated private static var proposals: String {
        let rows = [
            Row(id: 7, title: "Every spec has a Non-goals section", destination: "session", metric: "spec_findings",
                change: ("Specs and plans in English.", "Specs and plans in English.\\n" + nonGoals),
                status: "open", why: "Spec review found this 6 times in 5 specs over 28 days.", budget: 1000,
                evidence: "[" + specEvidence + "]"),
            Row(id: 8, title: "Allow go test without asking", destination: "claude_settings_allow",
                metric: "task_hours", change: ("", "Bash(go test:*)"), status: "open",
                why: "The agent waited for permission 41 times in 11 sessions.",
                evidence: #"[{"kind":"session","ref":"s12"}]"#, workbench: 3),
            Row(id: 2, title: "Quick asks when there are 2-3 options", destination: "chat", metric: "owner_loop",
                change: ("", "Prefer quick asks."), decided: "2026-10-12T09:00:00Z", verdict: "works",
                numbers: ("31", "22")),
            Row(id: 3, title: "Do not re-read files", destination: "session", metric: "corrections",
                change: ("", "Do not re-read files."), decided: "2026-10-18T09:00:00Z", verdict: "no_effect"),
            Row(id: 4, title: "Spec reviewer: skip naming nits", destination: "prompt_addition",
                metric: "spec_findings", change: ("", "Skip naming nits."), decided: "2026-10-24T09:00:00Z"),
            Row(id: 5, title: "Allow go vet", destination: "claude_settings_allow", metric: "task_hours",
                change: ("", "Bash(go vet:*)"), status: "rolled_back", decided: "2026-10-09T09:00:00Z", workbench: 3)
        ]
        return #"{"ok":true,"proposals":["# + rows.map(\.json).joined(separator: ",") + "]}"
    }

    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        func run(args: [String]) async throws -> Data {
            Data((args.dropFirst().first == "status" ? CoachShotFixtures.status : CoachShotFixtures.proposals).utf8)
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
    }
}

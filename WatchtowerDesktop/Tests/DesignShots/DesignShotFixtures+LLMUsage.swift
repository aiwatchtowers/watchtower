import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// Usage → Watchtower (LLM usage ledger) on the shared `usage llm --json`
/// fixture (`Tests/Core/Fixtures/llm-usage-report.json`, every gap line on):
/// the filled tab, the empty ledger and a failed read. Also the run log and
/// the Progress tab, which point to it for tokens and cost.
@MainActor
enum LLMUsageShotFixtures {
    static func report() -> LLMUsageReport {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/DesignShots/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/llm-usage-report.json")
        guard let data = try? Data(contentsOf: url),
              let report = try? JSONDecoder().decode(LLMUsageReport.self, from: data)
        else { preconditionFailure("llm-usage-report.json is missing or no longer decodes") }
        return report
    }

    static func screen(_ screen: LLMUsageScreen) -> AnyView {
        AnyView(WatchtowerUsageContent(screen: screen, period: .constant(.sevenDays)) {})
    }

    static func filled() -> AnyView {
        screen(.report(report(), recordingSince: "Recording since Oct 20, 2026 at 07:12", refreshFailedAt: nil))
    }

    /// A day of `pipeline_runs` (fixed date; the token columns are filled
    /// so a shot would show them if a screen still drew them).
    static func runLog() -> AnyView {
        AnyView(UsageRunLogContent(viewModel: historyModel()) {}.detailBackground())
    }

    /// The Progress tab with the first run open: its details, steps and the pointer.
    static func progress() -> AnyView {
        AnyView(ScrollView {
            ProgressDetailContent(historyVM: historyModel(), expandedRuns: [2])
                .padding(Spacing.page)
        }
        .detailBackground()
        .environment(AppState.isolated()))
    }

    private static func historyModel() -> PipelineHistoryViewModel {
        let model = PipelineHistoryViewModel()
        model.selectedDate = Date(timeIntervalSince1970: 1_793_145_600)  // 2026-10-28
        model.runs = decode([
            run(id: 2, pipeline: "briefing", items: 1, duration: 42, started: "2026-10-28T07:29:00Z", steps: 2),
            run(id: 1, pipeline: "digests", items: 6, duration: 18, started: "2026-10-28T07:20:00Z", steps: 0)
        ])
        model.steps = [2: decode([step(id: 1, run: 2, step: 1, status: "gathering"),
                                  step(id: 2, run: 2, step: 2, status: "writing")])]
        return model
    }

    private static func run(
        id: Int, pipeline: String, items: Int, duration: Double, started: String, steps: Int
    ) -> [String: Any] {
        ["id": id, "pipeline": pipeline, "source": "daemon", "model": "claude-sonnet", "status": "done",
         "error_msg": "", "items_found": items, "input_tokens": 12000, "output_tokens": 3400, "cost_usd": 0.42,
         "total_api_tokens": 98000, "started_at": started, "finished_at": started,
         "duration_seconds": duration, "step_count": steps]
    }

    private static func step(id: Int, run: Int, step: Int, status: String) -> [String: Any] {
        ["id": id, "run_id": run, "step": step, "total": 2, "status": status, "channel_id": "",
         "channel_name": "", "input_tokens": 6000, "output_tokens": 1700, "cost_usd": 0.21,
         "total_api_tokens": 49000, "message_count": 0, "duration_seconds": 21, "created_at": "2026-10-28T07:29:00Z"]
    }

    private static func decode<T: Decodable>(_ rows: [[String: Any]]) -> [T] {
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let decoded = try? JSONDecoder().decode([T].self, from: data)
        else { preconditionFailure("run log fixture no longer decodes") }
        return decoded
    }
}

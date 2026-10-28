import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// Usage → Watchtower (LLM usage ledger) on the shared `usage llm --json`
/// fixture (`Tests/Core/Fixtures/llm-usage-report.json`, every gap line on):
/// the filled tab, the empty ledger and a failed read.
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
}

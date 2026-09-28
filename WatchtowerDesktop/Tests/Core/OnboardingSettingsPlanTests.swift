import XCTest
@testable import WatchtowerCore

/// Onboarding's Fast/Quality presets wrote the claude-only aliases
/// `haiku`/`opus` into `ai.models.strong` whatever the configured provider,
/// so a codex or ollama owner re-running onboarding broke every strong-tier
/// call. The presets now apply only to claude.
final class OnboardingSettingsPlanTests: XCTestCase {
    private func keys(provider: String?, override: String?) -> [(key: String, value: String)] {
        OnboardingSettingsPlan.configSets(
            language: "English", initialHistoryDays: 3, pollInterval: "15m",
            provider: provider, strongModelOverride: override
        )
    }

    func testClaudeWithAPresetWritesTheAlias() {
        let sets = keys(provider: "claude", override: "opus")
        XCTAssertEqual(sets.map(\.key), [
            "digest.language", "sync.initial_history_days", "sync.poll_interval", "ai.models.strong"
        ])
        XCTAssertEqual(sets.last?.value, "opus")
    }

    func testAbsentProviderIsClaude() {
        XCTAssertTrue(OnboardingSettingsPlan.offersModelPresets(provider: nil))
        XCTAssertTrue(OnboardingSettingsPlan.offersModelPresets(provider: ""))
        XCTAssertEqual(keys(provider: nil, override: "haiku").last?.value, "haiku")
    }

    func testClaudeBalancedWritesNoModelKey() {
        XCTAssertFalse(keys(provider: "claude", override: nil).contains { $0.key.hasPrefix("ai.model") })
    }

    func testNonClaudeProvidersWriteNoModelKey() {
        for provider in ["codex", "ollama"] {
            XCTAssertFalse(OnboardingSettingsPlan.offersModelPresets(provider: provider))
            let sets = keys(provider: provider, override: "opus")
            XCTAssertEqual(sets.map(\.key), ["digest.language", "sync.initial_history_days", "sync.poll_interval"])
        }
    }
}

/// The `watchtower config set` pairs the onboarding Settings step writes.
///
/// The Fast/Balanced/Quality model presets map to claude CLI aliases, and
/// config overrides apply to whichever provider is configured — so the presets
/// (and any `ai.models.*` write) exist only when that provider is claude. For
/// codex and ollama the step writes no model key and the Go registry
/// (`internal/providers`) resolves that provider's own defaults.
package enum OnboardingSettingsPlan {
    /// Mirrors Go's `DefaultAIProvider`: an absent or empty `ai.provider`
    /// means claude.
    package static let defaultProvider = "claude"

    /// Whether the model-preset picker applies to `provider` (the configured
    /// `ai.provider`, nil/empty = the default).
    package static func offersModelPresets(provider: String?) -> Bool {
        let resolved = (provider ?? "").isEmpty ? defaultProvider : provider
        return resolved == "claude"
    }

    package static func configSets(
        language: String,
        initialHistoryDays: Int,
        pollInterval: String,
        provider: String?,
        strongModelOverride: String?
    ) -> [(key: String, value: String)] {
        var sets: [(key: String, value: String)] = [
            ("digest.language", language),
            ("sync.initial_history_days", "\(initialHistoryDays)"),
            ("sync.poll_interval", pollInterval)
        ]
        if offersModelPresets(provider: provider), let strongModelOverride {
            sets.append(("ai.models.strong", strongModelOverride))
        }
        return sets
    }
}

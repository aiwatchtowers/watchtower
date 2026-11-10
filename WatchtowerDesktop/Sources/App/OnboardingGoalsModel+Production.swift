import Foundation
import WatchtowerCore

extension OnboardingGoalsModel {
    /// The Goals step wired to the real CLI: `ai test` for the check (the
    /// old Claude step's health check, with the Codex fallback), `workspace init` / `config set` /
    /// the Feature Manager for Continue.
    static func production(defaults: UserDefaults, featureManager: FeatureManagerService) -> OnboardingGoalsModel {
        // Resolved per call, not once here: AppState is built before the CLI
        // binary store sync, which may still move the binary.
        func run(_ args: [String]) async throws {
            guard let runner = ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
            _ = try await runner.run(args: args)
        }
        return OnboardingGoalsModel(
            defaults: defaults,
            checkAgents: {
                // Task 3 wires the real probes
                OnboardingAgentCheckResult(statuses: [.claude: .notInstalled, .codex: .notInstalled])
            },
            configuredProvider: { ConfigService().aiProvider },
            actions: OnboardingGoalsActions(
                initWorkspace: { try await run(["workspace", "init", "--json"]) },
                setLanguage: { try await run(["config", "set", "digest.language", $0]) },
                applyFeatures: { selection in
                    let applied = await featureManager.applySelection(
                        enabled: selection.enabledFeatureIDs,
                        managed: OnboardingFeaturePlan.managedFeatureIDs
                    )
                    let changed = featureManager.lastSelectionChangeCount > 0
                    return (applied ? nil : (featureManager.loadError ?? "Could not apply the feature selection."), changed)
                },
                historyDepthUnset: { ConfigService().initialHistoryDays == nil },
                setHistoryDepth: { try await run(["config", "set", "sync.initial_history_days", "\($0)"]) },
                saveAgent: { provider in
                    // Workbench sessions start the same agent. ai.provider
                    // goes last, so a failed write leaves it unset.
                    if ConfigService.readWorkbenchDefaultAgent().rawValue != provider {
                        try await run(["config", "set", "workbench.default_agent", provider])
                    }
                    try await run(["config", "set", "ai.provider", provider])
                }
            )
        )
    }
}

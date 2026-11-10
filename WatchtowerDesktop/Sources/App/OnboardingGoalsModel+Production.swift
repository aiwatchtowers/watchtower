import Foundation
import WatchtowerCore

extension OnboardingGoalsModel {
    /// The Goals step wired to the real CLI: the per-agent check (`ai which` + `ai test`), `workspace init` / `config set` /
    /// the Feature Manager for Continue.
    static func production(
        defaults: UserDefaults,
        featureManager: FeatureManagerService,
        policy: @escaping @MainActor () -> ManagedPolicy
    ) -> OnboardingGoalsModel {
        // Resolved per call, not once here: AppState is built before the CLI
        // binary store sync, which may still move the binary.
        func run(_ args: [String]) async throws {
            guard let runner = ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
            _ = try await runner.run(args: args)
        }
        return OnboardingGoalsModel(
            defaults: defaults,
            checkAgents: {
                // Config and policy are read per check, so a Re-check sees a
                // Choose-the-executable save and a changed profile.
                let probes = await MainActor.run {
                    OnboardingAgentProbes.production(config: ConfigService(), policy: policy())
                }
                return await OnboardingAgentCheck.run(probes)
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

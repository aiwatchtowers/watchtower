import AppKit
import WatchtowerCore

/// Background AI consent (#1886, spec §3.3): the owner's answer in
/// config.yaml resolved with the organization policy.
extension AppState {
    /// Recomputed whenever the answer (`sharedConfig.backgroundRuns`) or the
    /// forced `AllowBackgroundAI` changes; both are observed. A config.yaml
    /// that cannot be read reads paused, as in Go.
    var backgroundAI: BackgroundAIConsent.State {
        BackgroundAIConsent.resolve(
            answer: sharedConfig.backgroundRuns,
            readFailed: sharedConfig.backgroundRunsUnreadable,
            policy: managedPolicy.policy.allowBackgroundAI
        )
    }

    /// config.yaml is there but cannot be read, so the answer is unknown and
    /// `backgroundAI` reads paused. Answering cannot be saved then (the
    /// writers refuse a file they cannot parse), so the consent sheet stays
    /// closed for this state.
    var backgroundAIConfigUnreadable: Bool { sharedConfig.backgroundRunsUnreadable }

    /// Re-reads the answer from config.yaml: on app activation and after the
    /// Desktop's own `ai background allow|pause` call. Unsaved Settings
    /// edits stay.
    func reloadBackgroundAI() {
        sharedConfig.reloadBackgroundRuns()
    }

    func makeBackgroundAIRefresher() -> BackgroundAIConsentRefresher {
        BackgroundAIConsentRefresher(center: .default, activation: NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.reloadBackgroundAI()
        }
    }

    /// The managed policy and the background AI answer both re-read on app
    /// activation, so an answer or a profile change made outside the app
    /// shows when the owner comes back.
    func startPolicyAndConsentRefresh() {
        managedPolicy.start(activation: NSApplication.didBecomeActiveNotification)
        backgroundAIRefresher.start()
    }
}

// MARK: - The consent screen (#1886, spec §5, §7)

extension AppState {
    /// The route onboarding follows: the goals of the last Continue, and the
    /// consent step while the answer is still due.
    var onboardingRoute: OnboardingRoute {
        OnboardingRoute(goals: onboardingGoals.route.goals, consentPrompt: backgroundAI.prompt)
    }

    var isBackgroundAIConsentPresented: Bool { backgroundAIConsentSheet.opened != nil }

    /// The entry point Settings, Home, the empty states and Automations call
    /// (D9). While config.yaml cannot be read the answer cannot be saved, so
    /// the config error shows instead of the sheet.
    func presentBackgroundAIConsent() {
        bringMainWindowForward()
        backgroundAIConsentSheet.present(configUnreadable: backgroundAIConfigUnreadable)
    }

    /// The upgrade sheet, once per launch while the answer is due, never over
    /// the release notes window (it comes up once that closes); and an open
    /// sheet closes once it was answered elsewhere (Decision 12). Called by
    /// the main window whenever an input changes.
    func syncBackgroundAIConsentSheet() {
        backgroundAIConsentSheet.follow(backgroundAI)
        let wasOpen = isBackgroundAIConsentPresented
        backgroundAIConsentSheet.presentIfDue(
            onboardingDone: onboarding.currentStep == .complete,
            state: backgroundAI,
            configUnreadable: backgroundAIConfigUnreadable,
            releaseNotesOpen: updateService.installedRelease != nil
        )
        if !wasOpen, isBackgroundAIConsentPresented { bringMainWindowForward() }
    }

    /// The sheet's answer was saved: re-read it, then close.
    func backgroundAIConsentSheetAnswered() {
        reloadBackgroundAI()
        backgroundAIConsentSheet.close()
    }

    /// Onboarding's consent step was answered: re-read it (so the route
    /// skips the step), then finish onboarding.
    func answerBackgroundAIConsentStep(onRetry: () -> Void) async {
        reloadBackgroundAI()
        await leaveOnboardingStep(.aiConsent, route: onboardingRoute, onRetry: onRetry)
    }

    /// A model for one showing of the screen: the configured agent and
    /// reserve, the sync cadence for the "what runs" rows.
    func makeBackgroundAIConsentModel() -> BackgroundAIConsentModel {
        let config = sharedConfig
        let provider = config.aiProvider ?? "claude"
        let agent = { (id: String) in
            BackgroundAIConsentCopy.Agent(provider: id, displayName: AIModelCatalog.shared.displayName(id))
        }
        let reserve = config.aiFallbackEnabled ? (config.aiFallbackProvider ?? config.reservePeer) : nil
        return BackgroundAIConsentModel(
            runner: ProcessCLIRunner.makeDefault() ?? UnresolvedCLIRunner(),
            configPath: config.connectionConfigPath,
            agent: agent(provider),
            reserve: reserve.map(agent),
            pollMinutes: FeatureReadiness.parsePollInterval(config.syncInterval),
            backfillDays: config.backfillDays ?? BackgroundAIConsentModel.defaultBackfillDays
        )
    }
}

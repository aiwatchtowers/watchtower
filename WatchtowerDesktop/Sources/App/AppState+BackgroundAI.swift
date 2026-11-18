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
        if let shown = backgroundAIConsentSheet.opened, !backgroundAIConfigUnreadable {
            // Already marked open: re-assert it, in case another sheet held
            // the window when it was set and SwiftUI never put it up.
            backgroundAIConsentSheet.close()
            Task { @MainActor [weak self] in self?.backgroundAIConsentSheet.reopen(shown) }
            return
        }
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
            releaseNotesPending: !updateService.isWhatsNewSettled || updateService.installedRelease != nil
        )
        if !wasOpen, isBackgroundAIConsentPresented { bringMainWindowForward() }
    }

    /// The sheet's answer was saved: re-read it, then close.
    func backgroundAIConsentSheetAnswered() -> Bool {
        reloadBackgroundAI()
        backgroundAIConsentSheet.close()
        return true
    }

    /// Onboarding's consent step was answered: re-read it (so the route
    /// skips the step), then finish onboarding. False when the finish
    /// failed (`onboardingStepError` says why); calling it again retries the
    /// finish only, the answer is already saved.
    func answerBackgroundAIConsentStep(onRetry: () -> Void) async -> Bool {
        reloadBackgroundAI()
        await leaveOnboardingStep(.aiConsent, route: onboardingRoute, onRetry: onRetry)
        return onboarding.currentStep == .complete
    }

    /// A model for one showing of the screen. The agent, reserve and sync
    /// cadence it discloses are read from config.yaml as saved, now: never
    /// Settings' unsaved edits, and after Goals switched the provider.
    func makeBackgroundAIConsentModel(
        runner: any CLIRunnerProtocol = ProcessCLIRunner.makeDefault() ?? UnresolvedCLIRunner()
    ) -> BackgroundAIConsentModel {
        let path = sharedConfig.connectionConfigPath
        var yaml: [String: Any] = [:]
        if case .mapping(let read) = ConfigService.readConfig(atPath: path) { yaml = read }
        let catalog = AIModelCatalog.shared
        let setup = BackgroundAIConsentSetup.read(
            yaml, displayName: catalog.displayName, reservePeer: catalog.reservePeer(of:)
        )
        return BackgroundAIConsentModel(runner: runner, configPath: path, setup: setup)
    }
}

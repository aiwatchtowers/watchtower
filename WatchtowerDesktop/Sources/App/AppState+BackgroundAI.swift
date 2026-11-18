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

    /// The readiness inputs read `backgroundAI` under observation, so an
    /// answer or a profile change re-evaluates the AI features' states at once.
    func makeLiveReadinessEnvironment() -> LiveReadinessEnvironment {
        LiveReadinessEnvironment(
            daemon: daemonManager, visibility: featureVisibility,
            // An AppState gone has no screen left to show a state on.
            backgroundAI: { [weak self] in self?.backgroundAI ?? .allowedByOwner },
            workspaceDir: { Constants.activeWorkspaceDir() }
        )
    }

    func makeBackgroundAIRefresher() -> BackgroundAIConsentRefresher {
        BackgroundAIConsentRefresher(center: .default, activation: NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.reloadBackgroundAI()
        }
    }

    /// The managed policy and the background AI answer both re-read on app
    /// activation, so an answer or a profile change made outside the app
    /// shows when the owner comes back. FileVault status (#1769) starts here
    /// too, outside XCTest.
    func startPolicyAndConsentRefresh() {
        managedPolicy.start(activation: NSApplication.didBecomeActiveNotification)
        backgroundAIRefresher.start()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { fileVault.start() }
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
    /// the config error shows instead of the sheet. A sheet already on
    /// screen is only brought forward, never replaced (it may be saving);
    /// one that was wanted but never mounted is re-asserted with its model.
    func presentBackgroundAIConsent() {
        bringMainWindowForward()
        backgroundAIConsentSheet.dismissCatalogRetry()
        let outcome = backgroundAIConsentSheet.present(
            configUnreadable: backgroundAIConfigUnreadable, catalogLoaded: aiModelCatalog.isLoaded
        ) { makeBackgroundAIConsentModel() }
        switch outcome {
        case let .retry(kind, model):
            backgroundAIConsentSheet.close()
            Task { @MainActor [weak self] in self?.backgroundAIConsentSheet.reopen(kind, model: model) }
        case .needsCatalog:
            // The plan and usage-limit lines come from the provider catalog:
            // read it first; a read that fails shows Try again instead of a
            // disclosure without them.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.readCatalogForConsent() {
                    self.presentBackgroundAIConsent()
                } else {
                    self.backgroundAIConsentSheet.showCatalogRetry()
                }
            }
        case .opened, .configError, .alreadyVisible:
            break
        }
    }

    /// One provider catalog read when none finished yet; whether the
    /// catalog is read now.
    func readCatalogForConsent() async -> Bool {
        if !aiModelCatalog.isLoaded { await aiModelCatalog.load() }
        return aiModelCatalog.isLoaded
    }

    /// The upgrade sheet, once per launch while the answer is due, never over
    /// the release notes window (it comes up once that closes); and an open
    /// sheet closes once it was answered elsewhere (Decision 12). Called by
    /// the main window whenever an input changes.
    func syncBackgroundAIConsentSheet() {
        backgroundAIConsentSheet.follow(backgroundAI)
        let wasOpen = isBackgroundAIConsentPresented
        let onboardingDone = onboarding.currentStep == .complete
        backgroundAIConsentSheet.presentIfDue(
            onboardingDone: onboardingDone,
            state: backgroundAI,
            configUnreadable: backgroundAIConfigUnreadable,
            releaseNotesPending: !updateService.isWhatsNewSettled || updateService.installedRelease != nil,
            catalogLoaded: aiModelCatalog.isLoaded
        ) { makeBackgroundAIConsentModel() }
        if !wasOpen, isBackgroundAIConsentPresented { bringMainWindowForward() }
        // Due, but the provider catalog is not read: read it, then look
        // again; a read that fails offers Try again (never a disclosure
        // without the plan lines).
        if !aiModelCatalog.isLoaded, !isBackgroundAIConsentPresented,
           BackgroundAIConsentPrompt.shouldPresent(onboardingDone: onboardingDone, state: backgroundAI) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.readCatalogForConsent() {
                    self.syncBackgroundAIConsentSheet()
                } else if !self.isBackgroundAIConsentPresented {
                    self.backgroundAIConsentSheet.showCatalogRetry()
                }
            }
        }
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
    /// Settings' unsaved edits, and after Goals switched the provider. Nil
    /// when the file is there but cannot be read: the host shows the config
    /// error instead (defaults stand only for a missing or empty file).
    func makeBackgroundAIConsentModel(
        runner: any CLIRunnerProtocol = ProcessCLIRunner.makeDefault() ?? UnresolvedCLIRunner()
    ) -> BackgroundAIConsentModel? {
        let path = sharedConfig.connectionConfigPath
        let yaml: [String: Any]
        switch ConfigService.readConfig(atPath: path) {
        case .absent, .empty: yaml = [:]
        case .mapping(let read): yaml = read
        case .unreadable: return nil
        }
        let catalog = AIModelCatalog.shared
        // A key set twice in different case reads as unreadable (fail closed).
        guard let setup = try? BackgroundAIConsentSetup.read(
            yaml, displayName: catalog.displayName, subscription: catalog.subscription, reservePeer: catalog.reservePeer(of:)
        ) else { return nil }
        return BackgroundAIConsentModel(runner: runner, configPath: path, setup: setup)
    }
}

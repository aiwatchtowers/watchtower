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

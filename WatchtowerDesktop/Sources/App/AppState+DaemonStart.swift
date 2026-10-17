import Foundation
import WatchtowerCore

extension AppState {
    /// Runs `operation` after every earlier daemon start or restart: one
    /// chain for launch, onboarding, the banner, the Calendar tab and
    /// Settings, so two never overlap (an overlap reads as a failed start, or
    /// leaves two daemons). Enqueued synchronously; await `.value` for the result.
    @discardableResult
    func enqueueDaemonStart<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = daemonStartChain
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        daemonStartChain = Task { _ = await task.value }
        return task
    }

    /// Starts (or, with `startOnly` false, restarts) the daemon in the
    /// background, on the start chain.
    func bringUpDaemonInBackground(startOnly: Bool) {
        let daemon = daemonControl
        enqueueDaemonStart { [weak self] in
            let up = startOnly && daemon.daemonIsRunning()
                ? true
                : await OnboardingFinishPlan.bringUpDaemon(daemon)
            guard let self else { return }
            daemonStartFailure = up ? nil : Self.daemonStartFailureText(daemonManager.errorMessage)
        }
    }

    /// The banner's Start and Retry: a daemon already running is not a
    /// failure; a start that exits non-zero, or a daemon gone again
    /// `daemonStartVerifyDelay` later, shows the failure banner.
    func startDaemonFromBanner() {
        let daemon = daemonControl
        let delay = daemonStartVerifyDelay
        enqueueDaemonStart { [weak self] in
            guard !daemon.daemonIsRunning() else {
                self?.daemonStartFailure = nil
                return
            }
            guard await daemon.startDetached() else {
                guard let self else { return }
                daemonStartFailure = Self.daemonStartFailureText(daemonManager.errorMessage)
                return
            }
            try? await Task.sleep(for: delay)
            self?.daemonStartFailure = daemon.daemonIsRunning() ? nil : Self.daemonDiedAfterStartText
        }
    }

    func dismissDaemonStartFailure() {
        daemonStartFailure = nil
    }

    static func daemonStartFailureText(_ detail: String?) -> String {
        let reason = detail.map { ": \($0)." } ?? "."
        return "The background sync did not start\(reason)"
    }

    static let daemonDiedAfterStartText = "The background sync started but stopped again. The logs say why."

    /// What the app-wide banner shows: a failure first (it carries the
    /// reason), else "isn't running" once readiness saw the daemon down past
    /// the grace.
    var daemonBanner: DaemonBanner? {
        DaemonBanner.current(failure: daemonStartFailure, daemonDown: readinessCenter.daemonDown)
    }
}

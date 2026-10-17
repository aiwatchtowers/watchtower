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

    /// Dismiss: a failure goes; "isn't running" stays hidden for this down
    /// stretch only (a start, then a new stop, brings it back).
    func dismissDaemonBanner() {
        if daemonStartFailure != nil {
            daemonStartFailure = nil
        } else {
            stoppedBannerDismissedFor = daemonManager.notRunningSince
        }
    }

    /// The restart a Turn on or a feature offer needs, on the start chain:
    /// never in the middle of a banner Start's alive check.
    func restartOnChain(_ daemon: any DaemonControl) async throws {
        try await enqueueDaemonStart { () -> Result<Void, any Error> in
            do {
                try await daemon.restartWaiting()
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value.get()
    }

    /// The account view models' Add/Remove/re-login restarts, on the start chain.
    var chainedAccountRestarter: any DaemonRestarting {
        ChainedDaemonRestarter(inner: LiveDaemonRestarter()) { [weak self] operation in
            await self?.enqueueDaemonStart { await operation() }.value
        }
    }

    static func daemonStartFailureText(_ detail: String?) -> String {
        let reason = detail.map { ": \($0)." } ?? "."
        return "The background sync did not start\(reason)"
    }

    static let daemonDiedAfterStartText = "The background sync started but stopped again. The logs say why."

    /// What the app-wide banner shows: a failure first (it carries the
    /// reason), else "isn't running" once readiness saw the daemon down past
    /// the grace — unless the app stopped it on purpose, or the owner
    /// dismissed this down stretch.
    var daemonBanner: DaemonBanner? {
        let manager = daemonManager
        let dismissed = manager.notRunningSince != nil && manager.notRunningSince == stoppedBannerDismissedFor
        let quiet = manager.stoppedOnPurpose || dismissed
        return DaemonBanner.current(failure: daemonStartFailure, daemonDown: readinessCenter.daemonDown && !quiet)
    }
}

/// A `DaemonRestarting` that runs the restart on `AppState`'s start chain.
struct ChainedDaemonRestarter: DaemonRestarting {
    let inner: any DaemonRestarting
    let enqueue: @Sendable @MainActor (@escaping @Sendable () async -> Void) async -> Void

    func restartLogging() async {
        let inner = inner
        await enqueue { await inner.restartLogging() }
    }
}

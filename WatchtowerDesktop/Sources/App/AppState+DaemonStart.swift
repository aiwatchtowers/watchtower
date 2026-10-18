import Foundation
import WatchtowerCore

extension AppState {
    /// The daemon start chain's last item, for tests to await.
    var daemonStartChain: Task<Void, Never>? { daemonStartQueue.tail }

    /// A start or restart's failure: the app-wide banner shows it with Retry.
    /// Lives on the queue, so restarts made outside AppState (account and
    /// grant changes, Settings) land in the same banner.
    var daemonStartFailure: String? {
        get { daemonStartQueue.failure }
        set { daemonStartQueue.failure = newValue }
    }

    /// Runs `operation` on the one daemon start queue (`DaemonStartQueue`),
    /// after every earlier start or restart: the entry point for every
    /// start, restart and stop-then-start the app makes. Enqueued
    /// synchronously; await `.value` for the result.
    @discardableResult
    func enqueueDaemonStart<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> Task<T, Never> {
        daemonStartQueue.enqueue(operation)
    }

    /// A successful start or restart, on any path that reports it to the
    /// queue (`DaemonStartQueue.succeeded`), also drops the empty states'
    /// failed-restart errors: that daemon picked their feature up (#575).
    func wireDaemonStartQueue() {
        daemonStartQueue.onSuccess = { [weak self] in self?.clearRestartFailedTurnOnErrors() }
    }

    /// Starts (or, with `startOnly` false, restarts) the daemon in the
    /// background, on the start queue.
    func bringUpDaemonInBackground(startOnly: Bool) {
        guard !daemonStartBlocked("bringUpDaemonInBackground") else { return }
        let daemon = daemonControl
        enqueueDaemonStart { [weak self] in
            let up = startOnly && daemon.daemonIsRunning()
                ? true
                : await OnboardingFinishPlan.bringUpDaemon(daemon)
            guard let self else { return }
            if up {
                daemonStartQueue.succeeded()
            } else {
                daemonStartFailure = Self.daemonStartFailureText(daemonManager.errorMessage)
            }
        }
    }

    /// The banner's Start and Retry. With a daemon running, a failure on the
    /// banner means a restart did not take (the old daemon kept running, so
    /// a new account or feature is not wired in): Retry restarts it for real
    /// and clears only on success. A running daemon with nothing on the
    /// banner needs nothing. Otherwise it starts one and, after a detach that
    /// exited 0, waits (up to `daemonStartWaitBound`) for it to show up; only
    /// a daemon still absent then reads "started but stopped again". The
    /// banner says "Starting…" meanwhile, and a second Start is ignored.
    func startDaemonFromBanner() {
        guard !isStartingDaemon, !daemonStartBlocked("startDaemonFromBanner") else { return }
        isStartingDaemon = true
        let daemon = daemonControl
        let bound = daemonStartWaitBound
        let interval = daemonStartPollInterval
        enqueueDaemonStart { [weak self] in
            defer { self?.isStartingDaemon = false }
            if daemon.daemonIsRunning() {
                guard self?.daemonStartFailure != nil else { return }
                do {
                    // Inside this item: never `restartOnChain`, which would
                    // enqueue behind it.
                    try await daemon.restartWaiting()
                    self?.daemonStartQueue.succeeded()
                } catch {
                    self?.daemonStartFailure = Self.daemonRestartFailureText(error)
                }
                return
            }
            guard await daemon.startDetached() else {
                guard let self else { return }
                daemonStartFailure = Self.daemonStartFailureText(daemonManager.errorMessage)
                return
            }
            let up = await Self.waitUntilRunning(daemon, bound: bound, interval: interval)
            if up {
                self?.daemonStartQueue.succeeded()
            } else {
                self?.daemonStartFailure = Self.daemonDiedAfterStartText
            }
        }
    }

    private static func waitUntilRunning(
        _ daemon: any DaemonControl, bound: Duration, interval: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + bound
        while !daemon.daemonIsRunning() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }

    /// Dismiss hides both: the failure, and "isn't running" for this down
    /// stretch (a start, then a new stop, brings it back).
    func dismissDaemonBanner() {
        daemonStartFailure = nil
        stoppedBannerDismissedFor = daemonManager.notRunningSince
    }

    /// A restart on the start queue (a Turn on, the feature offer, Settings,
    /// the Inbox action strip): never in the middle of a banner Start's
    /// wait. A success clears the banner's failure. During the compaction
    /// step it returns without restarting.
    func restartOnChain(_ daemon: any DaemonControl) async throws {
        guard !daemonStartBlocked("restartOnChain") else { return }
        try await daemonStartQueue.restart { try await daemon.restartWaiting() }
    }

    /// Settings → Slack disconnect as one item: stop, disconnect, start, so
    /// no other start lands between them. Whether the disconnect went through.
    /// The start is skipped during the compaction step.
    func disconnectSlackOnQueue(
        stop: @escaping @MainActor () async -> Void,
        disconnect: @escaping @MainActor () async -> Bool,
        start: @escaping @MainActor () async -> Void
    ) async -> Bool {
        await enqueueDaemonStart { () -> Bool in
            await stop()
            let done = await disconnect()
            if !self.daemonStartBlocked("Slack disconnect") { await start() }
            return done
        }.value
    }

    static func daemonRestartFailureText(_ error: any Error) -> String {
        "The background sync did not restart: \(error.localizedDescription)"
    }

    /// Settings → Data's full reset: stop the daemon, wait until it is really
    /// gone, and only then `remove` everything — one start-queue item, so no
    /// start lands in between. False: it did not stop and nothing was removed.
    func stopDaemonAndRemoveEverything(_ remove: @escaping @MainActor () -> Void) async -> Bool {
        let daemon = daemonControl
        return await enqueueDaemonStart { () -> Bool in
            if daemon.daemonIsRunning() {
                await daemon.stopDaemonNow()
            }
            do {
                try await daemon.waitUntilStopped()
            } catch {
                return false
            }
            remove()
            return true
        }.value
    }

    /// The launch start failed while a daemon is still running (the old one,
    /// still exiting or not stopped): Retry restarts it.
    static func daemonOldStillRunningText(_ detail: String?) -> String {
        let reason = detail.map { " (\($0))" } ?? ""
        return "The background sync did not restart: the previous one is still running\(reason)."
    }

    static let resetDaemonDidNotStopText = "The background sync did not stop, so nothing was deleted. Try again."

    static func daemonStartFailureText(_ detail: String?) -> String {
        let reason = detail.map { ": \($0)." } ?? "."
        return "The background sync did not start\(reason)"
    }

    static let daemonDiedAfterStartText = "The background sync started but stopped again. The logs say why."

    /// What the app-wide banner shows: "Starting…" while the banner's Start
    /// waits, a failure (it carries the reason), else "isn't running" once
    /// readiness saw the daemon down past the grace — unless the owner
    /// dismissed this down stretch.
    var daemonBanner: DaemonBanner? {
        let since = daemonManager.notRunningSince
        let dismissed = since != nil && since == stoppedBannerDismissedFor
        return DaemonBanner.current(
            failure: daemonStartFailure,
            daemonDown: readinessCenter.daemonDown && !dismissed,
            starting: isStartingDaemon)
    }
}

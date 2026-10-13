import GRDB
import os
import UIKit

/// The replica lives in the shared app-group container: iOS kills an app
/// suspended while it holds a lock on a file there (0xdead10cc). The live
/// replica observes GRDB's suspension notifications
/// (`ReplicaStore(path:observesSuspension:)`), and this gate posts them:
/// suspended while the app is in the background with no work held, resumed
/// as soon as the app is on screen or some work (a silent push's fetch, a
/// running capture) holds it. A suspension interrupts and rolls back an open
/// transaction, so nothing holds a lock when iOS suspends the app.
@MainActor
final class DatabaseSuspension {
    static let shared = DatabaseSuspension { name in
        NotificationCenter.default.post(name: name, object: nil)
    }

    private let post: @MainActor (Notification.Name) -> Void
    private var inBackground = false
    private var holds = 0
    /// Whether the last notification posted was the suspension.
    private(set) var isSuspended = false
    private let logger = Logger(subsystem: "WatchtowerMobile", category: "DatabaseSuspension")

    init(post: @escaping @MainActor (Notification.Name) -> Void) {
        self.post = post
    }

    /// The scene phase (`.background` or not), and the background state a
    /// push's work leaves behind.
    func setBackground(_ background: Bool) {
        inBackground = background
        apply()
    }

    /// Keeps the database usable until the returned release runs (once;
    /// later calls do nothing).
    func hold() -> @MainActor () -> Void {
        holds += 1
        apply()
        var released = false
        return { [weak self] in
            guard !released, let self else { return }
            released = true
            self.holds = max(0, self.holds - 1)
            self.apply()
        }
    }

    /// iOS is about to suspend the app (a background task expired): suspend
    /// now, whatever still holds it.
    func suspendNow() {
        inBackground = true
        holds = 0
        apply()
    }

    private func apply() {
        let suspend = inBackground && holds == 0
        guard suspend != isSuspended else { return }
        isSuspended = suspend
        logger.debug("replica \(suspend ? "suspended" : "resumed", privacy: .public)")
        post(suspend ? Database.suspendNotification : Database.resumeNotification)
    }
}

/// The `UIApplication` background-task calls, behind a seam for tests.
@MainActor
protocol BackgroundTaskRunning: AnyObject {
    /// Begins a task; `expiration` runs when iOS ends the extra time.
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ task: UIBackgroundTaskIdentifier)
}

/// The real background tasks.
@MainActor
final class UIKitBackgroundTasks: BackgroundTaskRunning {
    static let shared = UIKitBackgroundTasks()

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() }
        }
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// One silent push's work, bracketed: a background task keeps the app
/// running until the fetch serving the push returns — even after the push's
/// completion went out at the deadline (`PushCompletion`) — and the replica
/// stays usable meanwhile. When the fetch returns the task ends and the
/// replica is suspended again if the app is still in the background; if
/// iOS expires the task first, the replica is suspended (its open
/// transaction rolled back) before the task ends, so no lock outlives it.
@MainActor
final class PushWork {
    private let runner: any BackgroundTaskRunning
    private let suspension: DatabaseSuspension
    private let isInBackground: @MainActor () -> Bool
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var release: (@MainActor () -> Void)?

    init(
        runner: any BackgroundTaskRunning = UIKitBackgroundTasks.shared,
        suspension: DatabaseSuspension = .shared,
        isInBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }
    ) {
        self.runner = runner
        self.suspension = suspension
        self.isInBackground = isInBackground
    }

    /// Begins the task and holds the replica.
    func begin() {
        guard task == .invalid else { return }
        task = runner.begin(name: "silent-push-fetch") { [weak self] in self?.expire() }
        release = suspension.hold()
    }

    /// The fetch returned: releases the replica (suspended again when the
    /// app is in the background) and ends the task. Once only.
    func end() {
        guard task != .invalid else { return }
        release?()
        release = nil
        if isInBackground() {
            suspension.setBackground(true)
        }
        runner.end(task)
        task = .invalid
    }

    private func expire() {
        guard task != .invalid else { return }
        release = nil
        suspension.suspendNow()
        runner.end(task)
        task = .invalid
    }
}

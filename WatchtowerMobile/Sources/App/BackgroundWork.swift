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

/// One piece of work that must finish even if the app leaves the
/// foreground — a silent push's fetch (`silent-push-fetch`), a recording's
/// save (`recording-save`), the boot (`app-boot`) — bracketed: a background
/// task keeps the app running until the work ends — for a push, even after
/// its completion went out at the deadline (`PushCompletion`) — and the
/// replica stays usable meanwhile. When the work ends the task ends and the
/// replica is suspended again if the app is still in the background; if
/// iOS expires the task first, the work's hold is released and the replica
/// rests in the background before the task ends: suspended (its open
/// transaction rolled back) unless other work holds it — a running capture
/// keeps the app alive on its own and keeps its hold.
@MainActor
final class BackgroundWork {
    /// Begins one piece of work named `name` and returns its end, which
    /// runs once (later calls do nothing).
    typealias Starter = @MainActor (_ name: String) -> @MainActor () -> Void

    private let name: String
    private let runner: any BackgroundTaskRunning
    private let suspension: DatabaseSuspension
    private let isInBackground: @MainActor () -> Bool
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var release: (@MainActor () -> Void)?
    /// Begun and not yet ended or expired — tracked apart from `task`, which
    /// stays `.invalid` when iOS grants no extra time but the hold is taken.
    private var isRunning = false
    private let logger = Logger(subsystem: "WatchtowerMobile", category: "BackgroundWork")

    /// The app's work goes through `starter()`; tests build one directly.
    init(
        name: String,
        runner: any BackgroundTaskRunning,
        suspension: DatabaseSuspension,
        isInBackground: @escaping @MainActor () -> Bool
    ) {
        self.name = name
        self.runner = runner
        self.suspension = suspension
        self.isInBackground = isInBackground
    }

    /// A starter over these seams (nil: the app's own): each call begins a
    /// new piece of work.
    static func starter(
        runner: (any BackgroundTaskRunning)? = nil,
        suspension: DatabaseSuspension? = nil,
        isInBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }
    ) -> Starter {
        let runner = runner ?? UIKitBackgroundTasks.shared
        let suspension = suspension ?? .shared
        return { name in
            let work = BackgroundWork(name: name, runner: runner, suspension: suspension, isInBackground: isInBackground)
            work.begin()
            return { work.end() }
        }
    }

    /// Begins the task and holds the replica. When iOS grants no extra time
    /// (`.invalid`) the hold is still taken, so the work can finish while
    /// the app runs, and released at the end like any other.
    func begin() {
        guard !isRunning else { return }
        isRunning = true
        task = runner.begin(name: name) { [weak self] in self?.expire() }
        if task == .invalid {
            logger.notice("\(self.name, privacy: .public): iOS granted no background time")
        }
        release = suspension.hold()
    }

    /// The work is done: releases the replica (suspended again when the
    /// app is in the background) and ends the task. Once only.
    func end() {
        guard finish() else { return }
        if isInBackground() {
            suspension.setBackground(true)
        }
        endTask()
    }

    /// iOS ends the extra time: the work's own hold goes and the replica
    /// rests in the background — suspended unless other work (a running
    /// capture) still holds it — before the task ends.
    private func expire() {
        guard finish() else { return }
        suspension.setBackground(true)
        endTask()
    }

    /// Releases the hold once; false when the work already finished.
    private func finish() -> Bool {
        guard isRunning else { return false }
        isRunning = false
        release?()
        release = nil
        return true
    }

    private func endTask() {
        if task != .invalid {
            runner.end(task)
        }
        task = .invalid
    }
}

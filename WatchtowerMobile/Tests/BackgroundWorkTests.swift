import GRDB
import UIKit
import XCTest
@testable import WatchtowerMobile

/// A silent push's work runs inside a background task and holds the
/// app-group replica usable; the replica is suspended (GRDB's suspension
/// notifications) whenever the app rests in the background with nothing
/// holding it, and at once when iOS expires the task (0xdead10cc).
@MainActor
final class BackgroundWorkTests: XCTestCase {
    /// Records the background tasks begun and ended; `expire()` runs the
    /// expiration handler the way iOS does.
    private final class FakeTasks: BackgroundTaskRunning {
        private(set) var begun: [String] = []
        private(set) var ended: [UIBackgroundTaskIdentifier] = []
        private var expiration: (@MainActor () -> Void)?

        func begin(name: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
            begun.append(name)
            self.expiration = expiration
            return UIBackgroundTaskIdentifier(rawValue: begun.count)
        }

        func end(_ task: UIBackgroundTaskIdentifier) {
            ended.append(task)
        }

        func expire() {
            expiration?()
        }
    }

    private final class Posts {
        private(set) var names: [Notification.Name] = []
        func record(_ name: Notification.Name) { names.append(name) }
    }

    private func makeSuspension() -> (DatabaseSuspension, Posts) {
        let posts = Posts()
        return (DatabaseSuspension { posts.record($0) }, posts)
    }

    func testTheReplicaRestsInTheBackgroundUnlessHeld() {
        let (suspension, posts) = makeSuspension()
        suspension.setBackground(true)
        XCTAssertEqual(posts.names, [Database.suspendNotification])

        let release = suspension.hold()
        XCTAssertEqual(posts.names.last, Database.resumeNotification, "work resumes it")
        release()
        release()
        XCTAssertEqual(posts.names, [Database.suspendNotification, Database.resumeNotification, Database.suspendNotification],
                       "a release runs once")

        suspension.setBackground(false)
        XCTAssertEqual(posts.names.last, Database.resumeNotification)
        XCTAssertFalse(suspension.isSuspended)
    }

    /// The task spans the fetch: begun before it, ended when it returns
    /// (after a deadline completion too), once; the replica is suspended
    /// again when the app is still in the background.
    func testAPushTaskEndsWhenTheFetchReturns() async throws {
        let tasks = FakeTasks()
        let (suspension, posts) = makeSuspension()
        suspension.setBackground(true)
        let work = PushWork(runner: tasks, suspension: suspension) { true }

        let sleeper = TickSleeper()
        var completed: [FetchOutcome] = []
        var fetchReturned = false
        work.begin()
        XCTAssertEqual(tasks.begun, ["silent-push-fetch"])
        XCTAssertFalse(suspension.isSuspended, "the push holds the replica")
        let release = AsyncGate()
        PushCompletion.race(
            sleep: { try await sleeper.sleep($0) },
            fetch: {
                await release.wait()
                work.end()
                fetchReturned = true
                return .newData
            },
            outcomeAtDeadline: { .noData },
            completion: { completed.append($0) }
        )
        try await poll({ sleeper.waitingCount == 1 }, "the deadline never started")
        sleeper.tick()
        try await poll({ completed == [.noData] }, "the deadline did not complete the push")
        XCTAssertTrue(tasks.ended.isEmpty, "the task outlives the completion while the fetch runs")
        XCTAssertFalse(suspension.isSuspended)

        release.open()
        try await poll({ fetchReturned }, "the fetch never returned")
        XCTAssertEqual(tasks.ended.count, 1)
        XCTAssertTrue(suspension.isSuspended, "back to rest in the background")
        XCTAssertEqual(posts.names.last, Database.suspendNotification)
        work.end()
        XCTAssertEqual(tasks.ended.count, 1, "ended once")
    }

    /// iOS expires the task: the push's own hold goes and the replica rests
    /// in the background before the task ends — suspended when nothing else
    /// holds it; the fetch's own end later is a no-op.
    func testAnExpiredTaskSuspendsTheReplicaFirst() {
        let tasks = FakeTasks()
        let (suspension, posts) = makeSuspension()
        let work = PushWork(runner: tasks, suspension: suspension) { true }
        work.begin()
        XCTAssertFalse(suspension.isSuspended)

        tasks.expire()
        XCTAssertTrue(suspension.isSuspended, "nothing else holds it: suspended")
        XCTAssertEqual(posts.names.last, Database.suspendNotification)
        XCTAssertEqual(tasks.ended.count, 1)

        work.end()
        XCTAssertEqual(tasks.ended.count, 1, "no second end")
        XCTAssertTrue(suspension.isSuspended)
    }

    /// A running capture's hold survives the push's expiration: the replica
    /// stays usable for the rest of the capture, and rests once it releases.
    func testAnExpiredTaskKeepsACaptureHold() {
        let tasks = FakeTasks()
        let (suspension, posts) = makeSuspension()
        suspension.setBackground(true)
        let capture = suspension.hold()
        let work = PushWork(runner: tasks, suspension: suspension) { true }
        work.begin()

        tasks.expire()
        XCTAssertFalse(suspension.isSuspended, "the capture still holds it")
        XCTAssertEqual(tasks.ended.count, 1)

        work.end()
        XCTAssertFalse(suspension.isSuspended, "the push's late end takes nothing from the capture")
        capture()
        XCTAssertTrue(suspension.isSuspended)
        XCTAssertEqual(posts.names.last, Database.suspendNotification)
    }

    /// In the foreground the end of the push leaves the replica as it was.
    func testAForegroundPushNeverSuspends() {
        let tasks = FakeTasks()
        let (suspension, posts) = makeSuspension()
        let work = PushWork(runner: tasks, suspension: suspension) { false }
        work.begin()
        work.end()
        XCTAssertTrue(posts.names.isEmpty)
        XCTAssertEqual(tasks.ended.count, 1)
    }
}

/// A one-shot gate a test opens by hand.
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

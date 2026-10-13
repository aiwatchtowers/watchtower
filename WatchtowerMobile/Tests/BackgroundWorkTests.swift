import GRDB
import UIKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A silent push's work runs inside a background task and holds the
/// app-group replica usable; the replica is suspended (GRDB's suspension
/// notifications) whenever the app rests in the background with nothing
/// holding it, and at once when iOS expires the task (0xdead10cc).
@MainActor
final class BackgroundWorkTests: XCTestCase {
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
        let tasks = FakeBackgroundTasks()
        let (suspension, posts) = makeSuspension()
        suspension.setBackground(true)
        let work = BackgroundWork(name: "silent-push-fetch", runner: tasks, suspension: suspension) { true }

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
        let tasks = FakeBackgroundTasks()
        let (suspension, posts) = makeSuspension()
        let work = BackgroundWork(name: "silent-push-fetch", runner: tasks, suspension: suspension) { true }
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
        let tasks = FakeBackgroundTasks()
        let (suspension, posts) = makeSuspension()
        suspension.setBackground(true)
        let capture = suspension.hold()
        let work = BackgroundWork(name: "silent-push-fetch", runner: tasks, suspension: suspension) { true }
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

    /// An environment over a held CloudKit reach, launched into the
    /// background: its boot runs as `app-boot` work.
    private func makeBootingEnvironment(
        tasks: FakeBackgroundTasks,
        suspension: DatabaseSuspension
    ) throws -> (AppEnvironment, RemoteFetchRecorder) {
        let remote = RemoteFetchRecorder()
        remote.holding = true
        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            uploadRetriesAllowed: false,
            remoteFetch: { try await remote.fetch($0) },
            sleep: { _ in try await Task.sleep(for: .seconds(86_400)) },
            startWork: BackgroundWork.starter(runner: tasks, suspension: suspension) { true }
        )
        addTeardownBlock { @MainActor in
            env.stop()
            remote.release()
        }
        return (env, remote)
    }

    /// A launch into the background (a silent push): the boot holds the
    /// replica and runs in a background task from the environment's init
    /// until the boot is done, then the replica rests again.
    func testTheBootHoldsTheReplicaUntilItEnds() async throws {
        let tasks = FakeBackgroundTasks()
        let (suspension, posts) = makeSuspension()
        suspension.setBackground(true)
        let (env, remote) = try makeBootingEnvironment(tasks: tasks, suspension: suspension)
        XCTAssertEqual(tasks.begun, ["app-boot"])
        XCTAssertFalse(suspension.isSuspended, "the boot holds the replica")

        try await poll({ remote.heldCount == 1 }, "the launch fetch never began")
        XCTAssertTrue(tasks.ended.isEmpty, "held while the launch fetch runs")
        XCTAssertFalse(suspension.isSuspended)

        remote.release()
        await env.waitForBoot()
        XCTAssertTrue(env.isBootstrapped)
        try await poll({ tasks.ended.count == 1 }, "the boot's work never ended")
        XCTAssertTrue(suspension.isSuspended, "back to rest in the background")
        XCTAssertEqual(posts.names.last, Database.suspendNotification)
        env.stop()
        XCTAssertEqual(tasks.ended.count, 1, "ended once")
    }

    /// A stop during the boot ends its work at once, and the boot's own end
    /// later is a no-op.
    func testAStoppedBootEndsItsWorkOnce() async throws {
        let tasks = FakeBackgroundTasks()
        let (suspension, _) = makeSuspension()
        suspension.setBackground(true)
        let (env, remote) = try makeBootingEnvironment(tasks: tasks, suspension: suspension)
        try await poll({ remote.heldCount == 1 }, "the launch fetch never began")

        env.stop()
        XCTAssertEqual(tasks.ended.count, 1)
        XCTAssertTrue(suspension.isSuspended)

        remote.release()
        await env.waitForBoot()
        XCTAssertEqual(tasks.ended.count, 1, "no second end")
    }

    /// iOS grants no extra time (`.invalid`) in the background: no hold is
    /// taken (no expiration would ever suspend the replica again), so it
    /// stays at rest; the end changes nothing and ends no task.
    func testAnUngrantedTaskInTheBackgroundTakesNoHold() {
        let tasks = FakeBackgroundTasks()
        tasks.grantsTime = false
        let (suspension, posts) = makeSuspension()
        suspension.setBackground(true)
        let work = BackgroundWork(name: "silent-push-fetch", runner: tasks, suspension: suspension) { true }
        work.begin()
        XCTAssertEqual(tasks.begun, ["silent-push-fetch"])
        XCTAssertTrue(suspension.isSuspended, "no hold: the replica stays at rest")
        XCTAssertEqual(posts.names, [Database.suspendNotification])

        work.end()
        work.end()
        XCTAssertTrue(suspension.isSuspended)
        XCTAssertEqual(posts.names, [Database.suspendNotification], "nothing resumed, nothing posted again")
        XCTAssertTrue(tasks.ended.isEmpty, "no end for an invalid task")

        let other = suspension.hold()
        work.end()
        XCTAssertFalse(suspension.isSuspended, "an end takes nothing from another hold")
        other()
        XCTAssertTrue(suspension.isSuspended)
    }

    /// iOS grants no extra time (`.invalid`) in the foreground: the hold is
    /// still taken, so the work can finish while the app runs, and released
    /// exactly once at the end; no task is ended for the invalid id.
    func testAnUngrantedTaskInTheForegroundStillHoldsAndReleases() {
        let tasks = FakeBackgroundTasks()
        tasks.grantsTime = false
        let (suspension, posts) = makeSuspension()
        var inBackground = false
        let work = BackgroundWork(name: "recording-save", runner: tasks, suspension: suspension) { inBackground }
        work.begin()
        XCTAssertEqual(tasks.begun, ["recording-save"])

        // The app leaves the foreground while the work runs: it holds.
        inBackground = true
        suspension.setBackground(true)
        XCTAssertFalse(suspension.isSuspended, "the work holds the replica")
        XCTAssertTrue(posts.names.isEmpty)

        work.end()
        XCTAssertTrue(suspension.isSuspended, "the hold is released: back to rest")
        XCTAssertEqual(posts.names, [Database.suspendNotification])
        XCTAssertTrue(tasks.ended.isEmpty, "no end for an invalid task")

        let other = suspension.hold()
        work.end()
        XCTAssertFalse(suspension.isSuspended, "a second end takes nothing from another hold")
        other()
        XCTAssertTrue(suspension.isSuspended)
    }

    /// In the foreground the end of the push leaves the replica as it was.
    func testAForegroundPushNeverSuspends() {
        let tasks = FakeBackgroundTasks()
        let (suspension, posts) = makeSuspension()
        let work = BackgroundWork(name: "silent-push-fetch", runner: tasks, suspension: suspension) { false }
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

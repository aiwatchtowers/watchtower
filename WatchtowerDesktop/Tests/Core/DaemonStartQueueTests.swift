import XCTest
@testable import WatchtowerCore

/// #577: every daemon start or restart the app makes runs on one queue, one
/// at a time, and a hung CLI call cannot stall it or overlap the next item.
@MainActor
final class DaemonStartQueueTests: XCTestCase {
    private var cleanup: [String] = []

    override func tearDown() {
        cleanup.forEach { try? FileManager.default.removeItem(atPath: $0) }
        cleanup = []
        super.tearDown()
    }

    /// #575: a successful restart (or a reported start) clears `failure`
    /// and tells `onSuccess`; a failed one tells nothing.
    func testSuccessTellsOnSuccess() async {
        let queue = DaemonStartQueue()
        var told = 0
        queue.onSuccess = { told += 1 }
        queue.failure = "old"
        try? await queue.restart { throw CocoaError(.fileNoSuchFile) }
        XCTAssertEqual(told, 0)
        XCTAssertEqual(queue.failure, "old")
        try? await queue.restart {}
        XCTAssertEqual(told, 1)
        XCTAssertNil(queue.failure)
        queue.succeeded()
        XCTAssertEqual(told, 2)
    }

    func testItemsRunOneAfterTheOther() async {
        let queue = DaemonStartQueue()
        var log: [String] = []
        queue.enqueue {
            log.append("a-start")
            try? await Task.sleep(for: .milliseconds(30))
            log.append("a-end")
        }
        let second = queue.enqueue { () -> Int in
            log.append("b")
            return 7
        }
        let value = await second.value
        XCTAssertEqual(value, 7)
        XCTAssertEqual(log, ["a-start", "a-end", "b"])
    }

    /// A hung CLI call is stopped and reaped inside its item: the item ends
    /// with `.timedOut`, and the next item starts only after the child is gone.
    func testHungCLICallEndsItsItemBeforeTheNext() async throws {
        let pidPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-queue-pid-\(UUID().uuidString)").path
        cleanup.append(pidPath)
        // /bin/sh, not a fresh script file (a first exec of a new file can
        // wait on the system's scan); `exec` keeps the pid, so the recorded
        // one IS the sleeper.
        let command = "echo $$ > \(pidPath); exec sleep 100"
        addTeardownBlock {
            // Reap the sleeper even when the bound is broken.
            if let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        }
        let queue = DaemonStartQueue()
        var log: [String] = []
        queue.enqueue {
            do {
                _ = try await DaemonManager.runProcess(path: "/bin/sh", arguments: ["-c", command], timeout: .seconds(1))
                log.append("hung-finished")
            } catch {
                log.append(error as? DaemonRestartError == .timedOut ? "hung-timedOut" : "hung-other")
            }
        }
        let childAliveWhenNextStarted = await queue.enqueue { () -> Bool in
            log.append("next")
            guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
                  let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
            return kill(pid, 0) == 0
        }.value
        XCTAssertEqual(log, ["hung-timedOut", "next"])
        XCTAssertFalse(childAliveWhenNextStarted, "no overlap: the child was reaped first")
    }

    /// The account view models' restarter runs on the queue, behind an item
    /// already there; its success clears the banner failure.
    func testLiveDaemonRestarterGoesThroughTheQueue() async {
        let queue = DaemonStartQueue()
        queue.failure = "old"
        let gate = Gate()
        let held = queue.enqueue { await gate.wait() }
        let restarted = Flag()
        let restarter = LiveDaemonRestarter(queue: queue) { await restarted.set() }
        let account = Task { await restarter.restartLogging() }
        for _ in 0..<200 { await Task.yield() }
        let early = await restarted.value
        XCTAssertFalse(early, "waits for the item ahead of it")
        gate.open()
        await held.value
        await account.value
        let late = await restarted.value
        XCTAssertTrue(late)
        XCTAssertNil(queue.failure)
    }

    func testFailedBackgroundRestartStaysOnTheBanner() async {
        let queue = DaemonStartQueue()
        await queue.restartLogging { throw DaemonRestartError.cliNotFound }
        XCTAssertEqual(queue.failure, "The background sync did not restart: watchtower binary not found in PATH")
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

/// A suspension that ends only when opened.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

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

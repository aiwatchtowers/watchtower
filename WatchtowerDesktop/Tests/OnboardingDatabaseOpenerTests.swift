import XCTest
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// The onboarding DB open runs the CLI migrations (up to 30 s): it must run
/// off the main actor, show that it is running, and open once however many
/// steps ask for it at the same time.
@MainActor
final class OnboardingDatabaseOpenerTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        super.tearDown()
    }

    private func makeManager() throws -> DatabaseManager {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        paths.append(path)
        return manager
    }

    func testOpensOffTheMainThreadAndShowsProgress() async throws {
        let manager = try makeManager()
        let gate = DispatchSemaphore(value: 0)
        let ranOnMain = Flag()
        let opener = OnboardingDatabaseOpener {
            ranOnMain.set(Thread.isMainThread)
            gate.wait()
            return manager
        }

        let open = Task { await opener.open() }
        await waitUntil { opener.isOpening }
        // The main actor is free while the open is blocked.
        XCTAssertTrue(opener.isOpening, "the progress state is visible while the open runs")
        gate.signal()
        let result = await open.value

        XCTAssertNotNil(try? result.get())
        XCTAssertFalse(ranOnMain.value)
        XCTAssertFalse(opener.isOpening)
    }

    func testConcurrentCallersShareOneOpen() async throws {
        let manager = try makeManager()
        let gate = DispatchSemaphore(value: 0)
        let calls = Counter()
        let opener = OnboardingDatabaseOpener {
            calls.increment()
            gate.wait()
            return manager
        }

        let first = Task { await opener.open() }
        await waitUntil { opener.isOpening }
        let second = Task { await opener.open() }
        gate.signal()
        gate.signal() // a regression's second open must fail the count, not hang
        let firstManager = try await first.value.get()
        let secondManager = try await second.value.get()
        let later = try await opener.open().get()

        XCTAssertEqual(calls.value, 1, "asking meanwhile or afterwards reuses the one open")
        XCTAssertTrue(firstManager === secondManager && secondManager === later)
    }

    func testFailureIsReturnedAndRetried() async throws {
        struct Boom: Error {}
        let manager = try makeManager()
        let calls = Counter()
        let opener = OnboardingDatabaseOpener {
            calls.increment()
            if calls.value == 1 { throw Boom() }
            return manager
        }

        let failed = await opener.open()
        XCTAssertThrowsError(try failed.get())
        XCTAssertFalse(opener.isOpening)
        let retried = await opener.open()
        XCTAssertNotNil(try? retried.get(), "a failure is not cached: Retry opens again")
        XCTAssertEqual(calls.value, 2)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set(_ value: Bool) { lock.withLock { stored = value } }
    var value: Bool { lock.withLock { stored } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.withLock { stored += 1 } }
    var value: Int { lock.withLock { stored } }
}

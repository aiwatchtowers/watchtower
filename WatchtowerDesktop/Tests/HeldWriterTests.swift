import GRDB
import WatchtowerTestSupport
import XCTest

/// The test helpers that guard against a hang are themselves bounded: a task
/// that never finishes yields nil after its turns, and a second hold of an
/// already held writer fails by name instead of blocking the main thread.
@MainActor
final class HeldWriterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    func testBoundedValueGivesUpOnATaskThatNeverFinishes() async {
        let (never, _) = AsyncStream<Int>.makeStream()
        let stuck = Task { () -> Int in
            for await value in never { return value }
            return -1 // reached only once the bound cancels the task
        }
        let value = await boundedValue(stuck, turns: 100)
        XCTAssertNil(value, "past its turns the wait gives up instead of hanging")
        let afterCancel = await stuck.value
        XCTAssertEqual(afterCancel, -1, "the stuck task was cancelled, not left running")
    }

    func testBoundedValueReturnsAFinishedTasksValue() async {
        let value = await boundedValue(Task { 42 })
        XCTAssertEqual(value, 42)
    }

    func testBoundedValueGivesUpOnAWriteStuckBehindTheHeldWriter() async {
        let held = HeldWriter(pool)
        defer { held.release() }
        let writing = Task { () -> Bool in
            (try? await self.pool.write { db in try db.execute(sql: "CREATE TABLE IF NOT EXISTS held_probe (id INTEGER)") }) != nil
        }
        let value = await boundedValue(writing, turns: 100)
        XCTAssertNil(value, "a write waiting on the held writer does not hang the test")
    }

    func testASecondHoldOfTheSameWriterFailsAtOnce() {
        let first = HeldWriter(pool)
        defer { first.release() }
        XCTAssertTrue(first.isHolding)
        var failures: [String] = []
        let second = HeldWriter(pool, fail: { message, _, _ in failures.append(message) })
        second.release() // a no-op: it never held the writer, and must not free the first's claim
        XCTAssertFalse(second.isHolding)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("already held") ?? false)

        var stillRefused: [String] = []
        let third = HeldWriter(pool, fail: { message, _, _ in stillRefused.append(message) })
        XCTAssertFalse(third.isHolding, "the first hold still owns the writer after the refused one's release")
        XCTAssertEqual(stillRefused.count, 1)
    }

    func testAReleasedWriterCanBeHeldAgain() async throws {
        let first = HeldWriter(pool)
        first.release()
        let second = HeldWriter(pool)
        defer { second.release() }
        XCTAssertTrue(second.isHolding)
    }
}

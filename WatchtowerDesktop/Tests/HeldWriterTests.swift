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
        let second = HeldWriter(pool) { message, _, _ in failures.append(message) }
        second.release() // a no-op: it never held the writer, and must not free the first's claim
        XCTAssertFalse(second.isHolding)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("already held") ?? false)

        var stillRefused: [String] = []
        let third = HeldWriter(pool) { message, _, _ in stillRefused.append(message) }
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
    /// A writer that cannot be taken (a closed pool) fails by name, drops
    /// its claim at once and counts as released: its later release() cannot
    /// clear a claim another helper made on the same pool meanwhile.
    func testAFailedHoldDropsItsClaimAndItsReleaseClearsNoOtherClaim() throws {
        let (closed, closedPath) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: closedPath) }
        try closed.close()
        var failures: [String] = []
        let failed = HeldWriter(closed) { message, _, _ in failures.append(message) }
        XCTAssertFalse(failed.isHolding)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("could not take the writer") ?? false, "\(failures)")
        XCTAssertFalse(HeldWriter.isClaimed(closed), "the failed hold dropped its claim")

        HeldWriter.claimForTest(closed) // another helper's claim
        defer { HeldWriter.unclaimForTest(closed) }
        failed.release()
        XCTAssertTrue(HeldWriter.isClaimed(closed), "the failed helper's release clears no other claim")
    }

    /// A helper dropped without release() frees the writer and its claim.
    func testADroppedHelperReleasesItsWriterAndClaim() async throws {
        do {
            let dropped = HeldWriter(pool)
            XCTAssertTrue(dropped.isHolding)
        }
        XCTAssertFalse(HeldWriter.isClaimed(pool))
        let written = await boundedValue(Task { () -> Bool in
            (try? await self.pool.write { db in try db.execute(sql: "CREATE TABLE IF NOT EXISTS dropped_probe (id INTEGER)") }) != nil
        })
        XCTAssertEqual(written, true, "the writer is free again")
    }
}

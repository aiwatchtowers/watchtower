import Foundation
import GRDB
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A replica observation ends for good on its first error (GRDB); the phone's
/// `ResilientObservation` starts a fresh one after a growing wait and reports
/// the failure to `ObservationHealth` (Settings shows it).
@MainActor
final class ResilientObservationTests: XCTestCase {
    private struct ProbeError: LocalizedError {
        var errorDescription: String? { "probe read failed" }
    }

    /// The tracking closure runs on a database queue, so the switch is locked.
    private final class FailSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isOn: Bool {
            get { lock.withLock { on } }
            set { lock.withLock { on = newValue } }
        }
    }

    @MainActor
    private final class Received {
        var values: [Int] = []
    }

    private struct Fixture {
        let pool: DatabasePool
        let failing: FailSwitch
        let health: ObservationHealth
        let sleeper: TickSleeper
        let received: Received
    }

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-resilient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("probe.sqlite").path)
        try pool.write { try $0.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY)") }
        return Fixture(pool: pool, failing: FailSwitch(), health: ObservationHealth(), sleeper: TickSleeper(), received: Received())
    }

    /// Counts the probe rows, or throws while the switch is on.
    private func start(_ fixture: Fixture, name: String = "probe") -> ResilientObservation {
        let failing = fixture.failing
        let received = fixture.received
        let sleeper = fixture.sleeper
        return ResilientObservation(
            name: name,
            reader: fixture.pool,
            health: fixture.health,
            sleep: { try await sleeper.sleep($0) },
            observation: {
                ValueObservation.tracking { db in
                    if failing.isOn { throw ProbeError() }
                    return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe") ?? 0
                }
            },
            onChange: { received.values.append($0) }
        )
    }

    private func insertRow(_ fixture: Fixture) throws {
        try fixture.pool.write { try $0.execute(sql: "INSERT INTO probe DEFAULT VALUES") }
    }

    /// Ticks the parked sleep and waits until the next one is requested.
    private func tickAndWait(_ sleeper: TickSleeper, requested count: Int) async throws {
        sleeper.tick()
        try await poll({ sleeper.requested.count == count && sleeper.waitingCount == 1 }, "no sleep number \(count)")
    }

    func testNextValueArrivesAfterOneError() async throws {
        let fixture = try makeFixture()
        let observation = start(fixture)
        try await poll({ fixture.received.values == [0] }, "the initial value is missing")

        fixture.failing.isOn = true
        try insertRow(fixture)
        try await poll({ fixture.sleeper.waitingCount == 1 }, "the failure did not schedule a retry")
        XCTAssertEqual(fixture.health.failures["probe"]?.count, 1)
        XCTAssertEqual(fixture.health.failures["probe"]?.recovered, false)

        fixture.failing.isOn = false
        fixture.sleeper.tick()
        try await poll({ fixture.received.values == [0, 1] }, "the restarted observation did not deliver")
        try insertRow(fixture)
        try await poll({ fixture.received.values == [0, 1, 2] }, "the restarted observation stopped following writes")

        let failure = try XCTUnwrap(fixture.health.failures["probe"])
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(failure.lastMessage, "probe read failed")
        XCTAssertTrue(failure.recovered)
        withExtendedLifetime(observation) {}
    }

    func testRepeatedErrorsBackOffToThirtySeconds() async throws {
        let fixture = try makeFixture()
        fixture.failing.isOn = true
        let observation = start(fixture)
        try await poll({ fixture.sleeper.requested.count == 1 && fixture.sleeper.waitingCount == 1 }, "no first retry")
        for next in 2...7 {
            try await tickAndWait(fixture.sleeper, requested: next)
        }

        XCTAssertEqual(fixture.sleeper.requested, [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        XCTAssertEqual(fixture.health.failures["probe"]?.count, 7)
        XCTAssertEqual(fixture.health.failures["probe"]?.recovered, false)
        withExtendedLifetime(observation) {}
    }

    func testTheDelayResetsAfterAValue() async throws {
        let fixture = try makeFixture()
        fixture.failing.isOn = true
        let observation = start(fixture)
        try await poll({ fixture.sleeper.requested.count == 1 && fixture.sleeper.waitingCount == 1 }, "no first retry")
        try await tickAndWait(fixture.sleeper, requested: 2)

        fixture.failing.isOn = false
        fixture.sleeper.tick()
        try await poll({ fixture.received.values == [0] }, "the value after the errors is missing")

        fixture.failing.isOn = true
        try insertRow(fixture)
        try await poll({ fixture.sleeper.requested.count == 3 && fixture.sleeper.waitingCount == 1 }, "no retry after the new error")
        XCTAssertEqual(fixture.sleeper.requested, [1, 2, 1].map { Duration.seconds($0) })
        withExtendedLifetime(observation) {}
    }

    func testCancelDuringAPendingRetryStartsNothing() async throws {
        let fixture = try makeFixture()
        fixture.failing.isOn = true
        let observation = start(fixture)
        try await poll({ fixture.sleeper.waitingCount == 1 }, "no pending retry")

        observation.cancel()
        fixture.failing.isOn = false
        fixture.sleeper.tick()
        try insertRow(fixture)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(fixture.received.values, [], "a cancelled observation must not restart")
        XCTAssertEqual(fixture.sleeper.requested.count, 1)
    }

    func testReleasingTheObservationDuringAPendingRetryStartsNothing() async throws {
        let fixture = try makeFixture()
        fixture.failing.isOn = true
        var observation: ResilientObservation? = start(fixture)
        try await poll({ fixture.sleeper.waitingCount == 1 }, "no pending retry")

        observation = nil
        fixture.failing.isOn = false
        fixture.sleeper.tick()
        try insertRow(fixture)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(observation)
        XCTAssertEqual(fixture.received.values, [], "a released observation must not restart")
    }

    func testNoFailureLeavesTheHealthEmpty() async throws {
        let fixture = try makeFixture()
        let observation = start(fixture)
        try await poll({ fixture.received.values == [0] }, "the initial value is missing")
        try insertRow(fixture)
        try await poll({ fixture.received.values == [0, 1] }, "the write did not arrive")

        XCTAssertTrue(fixture.health.failures.isEmpty)
        XCTAssertEqual(fixture.sleeper.requested, [])
        withExtendedLifetime(observation) {}
    }

    /// The Calendar screen is the reported case: after a failed read it must
    /// keep following replica writes. The read fails while the table is gone.
    func testCalendarModelKeepsFollowingWritesAfterAFailedRead() async throws {
        let store = try makePoolStore()
        let pool = try XCTUnwrap(store.reader as? DatabasePool)
        let transport = InMemoryCloudTransport()
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        let now = Date()
        try await transport.save(try DemoSeed.calendarRecords(now: now))
        _ = try await hydrator.hydrateOnce()
        let model = CalendarReplicaModel()
        model.start(store: store)
        try await poll({ !model.snapshot.events.isEmpty }, "the model did not load the events")
        let failuresBefore = ObservationHealth.shared.failures["calendar"]?.count ?? 0

        // A write the model observes, after which its read fails: the real
        // table swapped for one without the payload column.
        try await pool.write { db in
            try db.execute(sql: "ALTER TABLE slice_records RENAME TO slice_records_away")
            try db.execute(sql: "CREATE TABLE slice_records (record_name TEXT, kind TEXT)")
            try db.execute(sql: "INSERT INTO slice_records VALUES ('x', 'x')")
        }
        try await poll({ (ObservationHealth.shared.failures["calendar"]?.count ?? 0) > failuresBefore }, "the failed read was not reported")
        try await pool.write { db in
            try db.execute(sql: "DROP TABLE slice_records")
            try db.execute(sql: "ALTER TABLE slice_records_away RENAME TO slice_records")
        }

        let later = now.addingTimeInterval(3_600)
        let before = model.snapshot.events.map(\.startTime)
        try await transport.save(try DemoSeed.calendarRecords(now: later))
        _ = try await hydrator.hydrateOnce()
        try await poll({ model.snapshot.events.map(\.startTime) != before }, "the calendar froze after the failed read")
        XCTAssertEqual(ObservationHealth.shared.failures["calendar"]?.recovered, true)
    }
}

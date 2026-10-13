import Foundation
import XCTest
@testable import WatchtowerSync

/// The phone's per-day energy counters (board #724): day rollover on an
/// injected clock and calendar, retention, thread safety, and the counting
/// seams in the transport and the uploader. Dates are seeded from now.
final class EnergyCounterTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "energy-counter-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func counter(clock: TestClock) -> EnergyCounter {
        EnergyCounter(defaults: defaults, calendar: utc) { clock.now }
    }

    private var storedCountKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("energy.") && $0 != "energy.days" }
    }

    func testCountsAddUpPerEvent() {
        let counter = counter(clock: TestClock())

        counter.record(.silentPush)
        counter.record(.silentPush)
        counter.record(.dataZonePoll)

        let today = counter.counts(daysAgo: 0)
        XCTAssertEqual(today[.silentPush], 2)
        XCTAssertEqual(today[.dataZonePoll], 1)
        XCTAssertEqual(today[.relayZonePoll], 0, "an event never recorded reads 0")
        XCTAssertEqual(today.day, utc.startOfDay(for: Date()))
    }

    func testAFreshCounterReadsZeroEverywhere() {
        let counter = counter(clock: TestClock())

        XCTAssertEqual(counter.counts(daysAgo: 0).counts, [:])
        XCTAssertEqual(counter.counts(daysAgo: 1).counts, [:])
    }

    func testMidnightStartsANewDayAndYesterdayKeepsItsCounts() {
        // One minute before the next UTC midnight.
        let midnight = utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: Date()))?
            .addingTimeInterval(-60) ?? Date()
        let clock = TestClock(midnight)
        let counter = counter(clock: clock)

        counter.record(.fetchLoop)
        counter.record(.fetchLoop)
        clock.advance(120)
        counter.record(.fetchLoop)

        XCTAssertEqual(counter.counts(daysAgo: 0)[.fetchLoop], 1)
        XCTAssertEqual(counter.counts(daysAgo: 1)[.fetchLoop], 2)
        XCTAssertEqual(counter.counts(daysAgo: 1).day, utc.startOfDay(for: midnight))
    }

    func testTheCountsSurviveANewCounterOnTheSameDefaults() {
        let clock = TestClock()
        counter(clock: clock).record(.coldLaunchBackground)

        XCTAssertEqual(counter(clock: clock).counts(daysAgo: 0)[.coldLaunchBackground], 1)
    }

    func testOnlyTheRetainedDaysAreKept() {
        let clock = TestClock()
        let counter = counter(clock: clock)

        for _ in 0 ..< EnergyCounter.retainedDays + 6 {
            counter.record(.sendBatch)
            clock.advance(86_400)
        }

        let days = defaults.stringArray(forKey: "energy.days") ?? []
        XCTAssertEqual(days.count, EnergyCounter.retainedDays)
        XCTAssertEqual(days, days.sorted())
        XCTAssertEqual(storedCountKeys.count, EnergyCounter.retainedDays, "pruned days lose their keys")
        XCTAssertEqual(counter.counts(daysAgo: 1)[.sendBatch], 1)
        XCTAssertEqual(counter.counts(daysAgo: EnergyCounter.retainedDays + 1)[.sendBatch], 0)
    }

    func testAClockMovedBackwardsCountsInItsOwnDay() {
        let clock = TestClock()
        let counter = counter(clock: clock)

        counter.record(.uploadAttempt)
        clock.advance(-86_400)
        counter.record(.uploadAttempt)
        clock.advance(86_400)

        XCTAssertEqual(counter.counts(daysAgo: 0)[.uploadAttempt], 1)
        XCTAssertEqual(counter.counts(daysAgo: 1)[.uploadAttempt], 1)
    }

    func testAClockSetBackPastTheRetainedWindowWritesNoLeakingKey() {
        let clock = TestClock()
        let counter = counter(clock: clock)

        for _ in 0 ..< EnergyCounter.retainedDays {
            counter.record(.silentPush)
            clock.advance(86_400)
        }
        clock.advance(-86_400 * Double(EnergyCounter.retainedDays + 5))
        counter.record(.silentPush)
        counter.record(.silentPush)

        XCTAssertEqual(defaults.stringArray(forKey: "energy.days")?.count, EnergyCounter.retainedDays)
        XCTAssertEqual(storedCountKeys.count, EnergyCounter.retainedDays, "a day pruned on arrival stores no count")
        XCTAssertEqual(counter.counts(daysAgo: 0)[.silentPush], 0)
    }

    func testConcurrentRecordsLoseNoCount() {
        let counter = counter(clock: TestClock())

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            counter.record(index.isMultiple(of: 2) ? .engineFetch : .engineFetchRun)
            _ = counter.counts(daysAgo: 0)
        }

        let today = counter.counts(daysAgo: 0)
        XCTAssertEqual(today[.engineFetch], 500)
        XCTAssertEqual(today[.engineFetchRun], 500)
    }

    // MARK: - Counting seams

    func testAPullCountsTheEngineFetchAndBothZonePolls() async throws {
        let counter = counter(clock: TestClock())
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: FakeSyncEngine(), energy: counter)

        try await transport.pull()
        try await transport.pull()

        let today = counter.counts(daysAgo: 0)
        XCTAssertEqual(today[.engineFetch], 2)
        XCTAssertEqual(today[.dataZonePoll], 2)
        XCTAssertEqual(today[.relayZonePoll], 2)
    }

    func testABuiltSendBatchCountsAndAnEmptyQueueDoesNot() async throws {
        let counter = counter(clock: TestClock())
        let transport = await CloudKitTransport.testing(store: try .inMemory(), energy: counter)

        let empty = await transport.nextEngineBatch()
        XCTAssertNil(empty)
        XCTAssertEqual(counter.counts(daysAgo: 0)[.sendBatch], 0, "an empty queue sends nothing")

        try await transport.save([
            CloudRecord(recordName: "action-1", zone: .relay, kind: "action", modifiedAt: Date(), payload: Data("{}".utf8))
        ])
        let batch = await transport.nextEngineBatch()

        XCTAssertNotNil(batch)
        XCTAssertEqual(counter.counts(daysAgo: 0)[.sendBatch], 1)
    }

    func testEachUploadAttemptCounts() async throws {
        let counter = counter(clock: TestClock())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("energy-uploader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("capture.m4a")
        try Data(repeating: 0xAB, count: 64).write(to: file)
        let uploader = RecordingUploader(
            transport: InMemoryCloudTransport(),
            store: try ReplicaStore.inMemory(),
            directory: directory,
            deviceID: "device-a",
            energy: counter
        )
        let ended = Date()
        _ = try await uploader.register(fileURL: file, startedAt: ended.addingTimeInterval(-30), endedAt: ended, titleHint: nil)

        let sent = try await uploader.uploadPending()

        XCTAssertEqual(sent, 1)
        XCTAssertEqual(counter.counts(daysAgo: 0)[.uploadAttempt], 1)
    }
}

import GRDB
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The replica observations decode only what changed (board #724): each
/// tracks its kinds' change stamps, so a heartbeat write decodes the
/// heartbeat and nothing else, a calendar write never decodes the board;
/// and while the app is in the background they rest, then deliver the
/// latest value once on the return.
@MainActor
final class ReplicaKindTrackingTests: XCTestCase {
    /// Whole seconds: the heartbeat's date survives its JSON round trip.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private let workbenchKinds: [SliceKind] = [.workbench, .workbenchTarget, .terminalSession, .ownerAsk, .workbenchComment]

    private struct Seeded {
        let store: ReplicaStore
        let transport: InMemoryCloudTransport
        let hydrator: ReplicaHydrator
    }

    /// A pool replica hydrated with the demo seed.
    private func makeSeeded() async throws -> Seeded {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        try await transport.save(try DemoSeed.records(now: now))
        _ = try await hydrator.hydrateOnce()
        return Seeded(store: store, transport: transport, hydrator: hydrator)
    }

    private func write(_ records: [CloudRecord], to seeded: Seeded) async throws {
        try await seeded.transport.save(records)
        _ = try await seeded.hydrator.hydrateOnce()
    }

    /// The demo heartbeat stamped `at`.
    private func heartbeat(at date: Date) throws -> CloudRecord {
        try XCTUnwrap(DemoSeed.records(now: date).first { $0.kind == SliceKind.heartbeat.rawValue })
    }

    private func decodes(_ cache: ReplicaDecodeCache, _ kinds: [SliceKind]) -> [Int] {
        kinds.map { cache.decodes($0.rawValue) }
    }

    func testAHeartbeatWriteDecodesOnlyTheHeartbeat() async throws {
        let seeded = try await makeSeeded()
        let gate = ReplicaObservationGate()
        let workbench = WorkbenchReplicaModel()
        let calendar = CalendarReplicaModel()
        let settings = SettingsViewModel()
        let recordings = PhoneRecordingsModel()
        workbench.start(store: seeded.store, gate: gate)
        calendar.start(store: seeded.store, gate: gate)
        settings.start(store: seeded.store, deviceID: DemoSeed.device.deviceID, gate: gate)
        recordings.start(store: seeded.store, gate: gate)
        try await poll({
            workbench.snapshot.workbenches.count == 3 && !calendar.snapshot.events.isEmpty
                && settings.snapshot.heartbeat != nil && recordings.snapshot.heartbeat != nil
        }, "the models never loaded")
        let boardBefore = decodes(workbench.decodeCache, workbenchKinds)
        let calendarBefore = decodes(calendar.decodeCache, CalendarReplicaSnapshot.kinds)
        let heartbeatBefore = workbench.decodeCache.decodes(HeartbeatPayload.recordName)
        XCTAssertEqual(boardBefore, [1, 1, 1, 1, 1], "each kind decoded once to load")

        let later = now.addingTimeInterval(900)
        try await write([try heartbeat(at: later)], to: seeded)
        try await poll({
            workbench.snapshot.heartbeat?.updatedAt == later && settings.snapshot.heartbeat?.updatedAt == later
                && recordings.snapshot.heartbeat?.updatedAt == later
        }, "the heartbeat never reached the models")
        // The calendar's fetch may not have run yet: one more read through
        // its cache decides deterministically.
        let calendarRead = try await seeded.store.reader.read { [cache = calendar.decodeCache, store = seeded.store] db in
            try CalendarReplicaSnapshot.read(from: db, store: store, cache: cache)
        }

        XCTAssertEqual(decodes(workbench.decodeCache, workbenchKinds), boardBefore, "the board is not decoded again")
        XCTAssertEqual(workbench.decodeCache.decodes(HeartbeatPayload.recordName), heartbeatBefore + 1)
        XCTAssertEqual(decodes(calendar.decodeCache, CalendarReplicaSnapshot.kinds), calendarBefore, "nor the calendar")
        XCTAssertEqual(calendarRead, calendar.snapshot)
        XCTAssertEqual(recordings.decodeCache.decodes(SliceKind.recordingJob.rawValue), 1)
    }

    func testACalendarWriteNeverDecodesTheBoardAndABoardWriteNeverTheCalendar() async throws {
        let seeded = try await makeSeeded()
        let gate = ReplicaObservationGate()
        let workbench = WorkbenchReplicaModel()
        let calendar = CalendarReplicaModel()
        workbench.start(store: seeded.store, gate: gate)
        calendar.start(store: seeded.store, gate: gate)
        try await poll({ workbench.snapshot.workbenches.count == 3 && !calendar.snapshot.events.isEmpty }, "not loaded")
        let boardBefore = decodes(workbench.decodeCache, workbenchKinds)

        let event = try XCTUnwrap(DemoSeed.calendarRecords(now: now).first { $0.kind == SliceKind.calendarEvent.rawValue })
        try await write([event], to: seeded)
        try await poll({ calendar.decodeCache.decodes(SliceKind.calendarEvent.rawValue) == 2 }, "the calendar never re-read")
        let boardRead = try await seeded.store.reader.read { [cache = workbench.decodeCache, store = seeded.store] db in
            try WorkbenchReplicaSnapshot.read(from: db, store: store, cache: cache)
        }
        XCTAssertEqual(decodes(workbench.decodeCache, workbenchKinds), boardBefore, "a calendar write decodes no board kind")
        XCTAssertEqual(boardRead.workbenches.count, 3)
        XCTAssertEqual(calendar.decodeCache.decodes(SliceKind.meetingTranscript.rawValue), 1, "nor the transcripts")

        try await write([try DemoSeed.record(kind: .workbench, id: 98, json: DemoSeed.JSON.workbench(98), modifiedAt: now)], to: seeded)
        try await poll({ workbench.snapshot.workbenches.count == 4 }, "the board never re-read")
        XCTAssertEqual(workbench.decodeCache.decodes(SliceKind.workbench.rawValue), boardBefore[0] + 1)
        XCTAssertEqual(workbench.decodeCache.decodes(SliceKind.ownerAsk.rawValue), boardBefore[3], "only the written kind")
        _ = try await seeded.store.reader.read { [cache = calendar.decodeCache, store = seeded.store] db in
            try CalendarReplicaSnapshot.read(from: db, store: store, cache: cache)
        }
        XCTAssertEqual(calendar.decodeCache.decodes(SliceKind.calendarEvent.rawValue), 2, "a board write decodes no calendar kind")
    }

    func testASuspendedObservationRestsAndResumesWithTheLatestValueOnce() async throws {
        let seeded = try await makeSeeded()
        let gate = ReplicaObservationGate()
        let workbench = WorkbenchReplicaModel()
        workbench.start(store: seeded.store, gate: gate)
        try await poll({ workbench.snapshot.workbenches.count == 3 }, "not loaded")
        let sets = ObservedSetCounter { _ = workbench.snapshot }

        gate.setSuspended(true)
        try await write([try DemoSeed.record(kind: .workbench, id: 98, json: DemoSeed.JSON.workbench(98), modifiedAt: now)], to: seeded)
        try await write([try DemoSeed.record(kind: .workbench, id: 99, json: DemoSeed.JSON.workbench(99), modifiedAt: now)], to: seeded)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workbench.snapshot.workbenches.count, 3, "nothing delivered while suspended")
        XCTAssertEqual(workbench.decodeCache.decodes(SliceKind.workbench.rawValue), 1, "nothing decoded while suspended")
        XCTAssertEqual(sets.count, 0)

        gate.setSuspended(false)
        try await poll({ workbench.snapshot.workbenches.count == 5 }, "the resume did not deliver the latest value")
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sets.count, 1, "one delivery on the resume")
        XCTAssertEqual(workbench.decodeCache.decodes(SliceKind.workbench.rawValue), 2, "both writes in one decode")
        XCTAssertEqual(workbench.decodeCache.decodes(SliceKind.ownerAsk.rawValue), 1, "unchanged kinds stay cached")
    }

    func testAnObservationStartedWhileSuspendedWaitsForTheResume() async throws {
        let seeded = try await makeSeeded()
        let gate = ReplicaObservationGate()
        gate.setSuspended(true)
        let calendar = CalendarReplicaModel()
        calendar.start(store: seeded.store, gate: gate)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(calendar.snapshot.events.isEmpty, "a suspended gate starts nothing")

        let event = try XCTUnwrap(DemoSeed.calendarRecords(now: now).first { $0.kind == SliceKind.calendarEvent.rawValue })
        try await write([event], to: seeded)
        gate.setSuspended(false)

        try await poll({ !calendar.snapshot.events.isEmpty }, "the resume never started it")
        XCTAssertEqual(calendar.decodeCache.decodes(SliceKind.calendarEvent.rawValue), 1)
    }
}

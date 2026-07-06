import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

final class MobileHubServiceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        sidecar = try HubSyncState.inMemory()
        // start() guards on this key; enable it globally for tests that exercise
        // the normal start path, and let individual tests override as needed.
        UserDefaults.standard.set(true, forKey: "mobileSyncEnabled")
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "mobileSyncEnabled")
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    @MainActor
    private func makeService(transport: StubHubTransport) -> MobileHubService {
        let publisher = SlicePublisher(dbPool: dbPool, state: sidecar, transport: transport)
        let processor = RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: MockClaudeService()
        )
        return MobileHubService(
            transport: transport,
            publisher: publisher,
            processor: processor,
            publishInterval: .milliseconds(20),
            relayIdleInterval: .milliseconds(20),
            relayActiveInterval: .milliseconds(20),
            heartbeatInterval: .milliseconds(20),
            appVersion: "9.9.9-test"
        )
    }

    /// Polls `check` until it holds or the deadline passes, then fails.
    private func eventually(
        _ message: String,
        timeout: TimeInterval = 3,
        check: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }

    // MARK: - Tests

    @MainActor
    func testStartRunsHeartbeatAndDailyHygiene() async throws {
        let transport = StubHubTransport()
        // Stale relay records that the daily hygiene pass must remove …
        let staleAction = try staleActionRecord(id: "old-1", age: 8 * 86_400)
        let staleChunk = try staleChunkRecord(messageID: "old-m", age: 31 * 86_400)
        // … and a fresh one it must keep.
        let freshAction = try staleActionRecord(id: "new-1", age: 60)
        try await transport.save([staleAction, staleChunk, freshAction])

        let service = makeService(transport: transport)
        await service.start()
        defer { service.stop() }

        XCTAssertEqual(service.status, .running)
        XCTAssertTrue(transport.started, "start() must start the transport before probing availability")

        try await eventually("heartbeat record must appear in the relay zone") {
            let batch = try await transport.changes(in: .relay, since: nil)
            guard let record = batch.changed.first(where: { $0.kind == RelayRecordKind.heartbeat.rawValue }) else {
                return false
            }
            let payload = try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: record.payload)
            return payload.appVersion == "9.9.9-test"
        }

        try await eventually("hygiene must delete stale relay records and keep fresh ones") {
            let batch = try await transport.changes(in: .relay, since: nil)
            let names = Set(batch.changed.map(\.recordName))
            return !names.contains(staleAction.recordName)
                && !names.contains(staleChunk.recordName)
                && names.contains(freshAction.recordName)
        }
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.hygieneStampKey))
    }

    @MainActor
    func testStopHaltsLoops() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()

        try await eventually("first heartbeat must land before stop()") {
            let batch = try await transport.changes(in: .relay, since: nil)
            return batch.changed.contains { $0.kind == RelayRecordKind.heartbeat.rawValue }
        }

        service.stop()
        XCTAssertEqual(service.status, .off)

        // Let any in-flight save drain, then verify the event log is frozen.
        try await Task.sleep(for: .milliseconds(100))
        let settled = try await transport.changes(in: .relay, since: nil).newToken
        try await Task.sleep(for: .milliseconds(200))
        let after = try await transport.changes(in: .relay, since: nil).newToken
        XCTAssertEqual(settled, after, "no heartbeat may be written after stop()")
    }

    @MainActor
    func testQueuedStartAfterStopDoesNotRun() async throws {
        // Simulate AppState.stopMobileHub() beating the queued Task { await hub.start() }:
        // set the toggle to false so start() bails out immediately at the guard.
        UserDefaults.standard.set(false, forKey: "mobileSyncEnabled")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "mobileSyncEnabled") }

        let transport = StubHubTransport()
        let service = makeService(transport: transport)

        // Call start() directly (same as the queued Task would) without setting
        // the toggle — it must return without touching status or spawning loops.
        await service.start()

        XCTAssertEqual(service.status, .off, "start() with toggle off must not advance status")
        XCTAssertFalse(transport.started, "start() with toggle off must not start the transport")

        // Give any erroneously spawned loop time to write a heartbeat.
        try await Task.sleep(for: .milliseconds(100))
        let relay = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(relay.changed.isEmpty, "no heartbeat may appear when start() was rejected")
    }

    @MainActor
    func testUnavailableTransportGatesAllLoops() async throws {
        let transport = StubHubTransport(availability: .noAccount)
        let service = makeService(transport: transport)
        await service.start()

        guard case .unavailable(let reason) = service.status else {
            return XCTFail("expected .unavailable, got \(service.status)")
        }
        XCTAssertFalse(reason.isEmpty)

        // No loop may have started: both zones stay empty well past the intervals.
        try await Task.sleep(for: .milliseconds(200))
        let relay = try await transport.changes(in: .relay, since: nil)
        let data = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(relay.changed.isEmpty, "no heartbeat/relay writes while unavailable")
        XCTAssertTrue(data.changed.isEmpty, "no slice publishing while unavailable")
    }

    // MARK: - Fixtures

    /// An already-applied action echo, `age` seconds old.
    private func staleActionRecord(id: String, age: TimeInterval) throws -> CloudRecord {
        var action = ActionRequestPayload(id: id, kind: .targetDone, entityID: "1", createdAt: Date())
        action.status = .applied
        return try CloudRecordFactory.record(for: action, modifiedAt: Date().addingTimeInterval(-age))
    }

    /// A chat response chunk, `age` seconds old (the processor never replays chunks).
    private func staleChunkRecord(messageID: String, age: TimeInterval) throws -> CloudRecord {
        let chunk = ChatChunkPayload(sessionID: "s", messageID: messageID, seq: 0, text: "old", done: true)
        return try CloudRecordFactory.record(for: chunk, modifiedAt: Date().addingTimeInterval(-age))
    }
}

/// HubTransport stub: InMemoryCloudTransport record I/O plus canned
/// availability, so the gate is trivially steerable per test.
private final class StubHubTransport: HubTransport, @unchecked Sendable {
    private let inner = InMemoryCloudTransport()
    private let availabilityResult: CloudAvailability
    private let lock = NSLock()
    private var _started = false
    var started: Bool { lock.withLock { _started } }

    init(availability: CloudAvailability = .available) {
        availabilityResult = availability
    }

    func start() async { lock.withLock { _started = true } }
    func pull() async throws {}
    func availability() async -> CloudAvailability { availabilityResult }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }
}

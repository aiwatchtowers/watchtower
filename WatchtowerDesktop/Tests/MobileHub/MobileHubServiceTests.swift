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
    }

    override func tearDownWithError() throws {
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    @MainActor
    private func makeService(
        transport: any HubTransport,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> MobileHubService {
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
            sidecar: sidecar,
            publishInterval: .milliseconds(20),
            relayIdleInterval: .milliseconds(20),
            relayActiveInterval: .milliseconds(20),
            heartbeatInterval: .milliseconds(20),
            availabilityReprobeInterval: .milliseconds(20),
            appVersion: "9.9.9-test",
            isEnabled: isEnabled
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
        // the injected enablement already reads false, so start() bails at the guard.
        let transport = StubHubTransport()
        let service = makeService(transport: transport) { false }

        // Call start() directly (same as the queued Task would) — it must
        // return without touching status or spawning loops.
        await service.start()

        XCTAssertEqual(service.status, .off, "start() while disabled must not advance status")
        XCTAssertFalse(transport.started, "start() while disabled must not start the transport")

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
        defer { service.stop() }

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

    @MainActor
    func testReprobeRecoversWhenICloudReturns() async throws {
        let transport = StubHubTransport(availability: .noAccount)
        let service = makeService(transport: transport)
        await service.start()
        defer { service.stop() }
        guard case .unavailable = service.status else {
            return XCTFail("expected .unavailable, got \(service.status)")
        }

        // iCloud comes back — the re-probe loop must notice and start the hub.
        transport.setAvailability(.available)
        try await eventually("hub must auto-recover once availability returns") {
            service.status == .running
        }
        try await eventually("recovered hub must run its loops (heartbeat lands)") {
            let batch = try await transport.changes(in: .relay, since: nil)
            return batch.changed.contains { $0.kind == RelayRecordKind.heartbeat.rawValue }
        }
    }

    @MainActor
    func testStopWhileUnavailableCancelsReprobe() async throws {
        let transport = StubHubTransport(availability: .noAccount)
        let service = makeService(transport: transport)
        await service.start()
        guard case .unavailable = service.status else {
            return XCTFail("expected .unavailable, got \(service.status)")
        }

        service.stop()
        XCTAssertEqual(service.status, .off)

        // Availability returning after stop() must not resurrect the hub —
        // the re-probe loop died with stop().
        transport.setAvailability(.available)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(service.status, .off, "re-probe loop must not outlive stop()")
        let relay = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(relay.changed.isEmpty, "no loop may start after stop()")
    }

    @MainActor
    func testStopDuringInFlightStartLeavesHubOff() async throws {
        // The epoch race: stop() lands while start() is suspended inside
        // transport.start(). The resumed start() must detect it lost and
        // never flip status or spin up loops.
        let transport = GatedHubTransport()
        let service = makeService(transport: transport)

        let startTask = Task { await service.start() }
        try await eventually("start() must reach the gated transport.start()") {
            transport.startEntered
        }
        XCTAssertEqual(service.status, .starting)

        service.stop()
        transport.releaseStart()
        await startTask.value

        XCTAssertEqual(service.status, .off, "a start() that lost to stop() must not advance status")
        try await Task.sleep(for: .milliseconds(100))
        let relay = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(relay.changed.isEmpty, "no heartbeat may appear from the lost start()")
    }

    /// The Settings status source: an init failure surfaces as .unavailable,
    /// a live hub wins over a stale error, and no hub + no error is .off.
    @MainActor
    func testAppStateHubStatusSurfacesInitFailure() {
        XCTAssertEqual(AppState.hubStatus(hub: nil, initError: nil), .off)
        XCTAssertEqual(
            AppState.hubStatus(hub: nil, initError: "cannot create MobileHub directory"),
            .unavailable("cannot create MobileHub directory")
        )
        let service = makeService(transport: StubHubTransport())
        XCTAssertEqual(AppState.hubStatus(hub: service, initError: nil), .off, "a built hub reports its own status")
    }

    @MainActor
    func testAccountResetWipesSyncStateSoNextPublishRepushes() async throws {
        // Seed the sidecar as if a full sync had already happened under the old account.
        try sidecar.setHash("hash", for: "target-1")
        try sidecar.setMetaValue("token-blob", forKey: RelayProcessor.relayTokenKey)
        try sidecar.markRelayProcessed("action-1", at: Date())

        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        await service.start()
        defer { service.stop() }
        XCTAssertEqual(service.status, .running)

        // The transport reports an account switch: the handler the hub registered
        // before start() must clear the sync state.
        transport.fireAccountReset()

        try await eventually("account reset must wipe the hub sync state") {
            try sidecar.hashes(forKind: .target).isEmpty
                && (try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey)) == nil
                && !(try sidecar.isRelayProcessed("action-1"))
        }
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

/// HubTransport stub: InMemoryCloudTransport record I/O plus mutable
/// availability, so the gate (and its re-probe recovery) is steerable per test.
private final class StubHubTransport: HubTransport, @unchecked Sendable {
    private let inner = InMemoryCloudTransport()
    private let lock = NSLock()
    private var _availability: CloudAvailability
    private var _started = false
    private var _accountResetHandler: (@Sendable () -> Void)?
    var started: Bool { lock.withLock { _started } }

    init(availability: CloudAvailability = .available) {
        _availability = availability
    }

    func start() async { lock.withLock { _started = true } }
    func pull() async throws {}
    func availability() async -> CloudAvailability { lock.withLock { _availability } }

    /// Simulates iCloud availability changing under the running service.
    func setAvailability(_ value: CloudAvailability) {
        lock.withLock { _availability = value }
    }

    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async {
        lock.withLock { _accountResetHandler = handler }
    }

    /// Simulates the transport observing a CloudKit account switch.
    func fireAccountReset() {
        let handler = lock.withLock { _accountResetHandler }
        handler?()
    }

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

/// HubTransport whose start() blocks on a gate until the test releases it —
/// pins the stop-during-start epoch race.
private final class GatedHubTransport: HubTransport, @unchecked Sendable {
    private let inner = InMemoryCloudTransport()
    private let lock = NSLock()
    private var _startEntered = false
    private var released = false
    private var gate: CheckedContinuation<Void, Never>?
    var startEntered: Bool { lock.withLock { _startEntered } }

    func start() async {
        lock.withLock { _startEntered = true }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }

    func pull() async throws {}
    func availability() async -> CloudAvailability { .available }
    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async {}

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

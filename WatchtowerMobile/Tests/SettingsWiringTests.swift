import GRDB
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Settings → Your Mac, Workbench and Notifications (mobile POC spec §13 A4).
@MainActor
final class SettingsWiringTests: XCTestCase {
    private let device = LinkedDevice(
        deviceID: "device-acme-1",
        name: "Colleague A's iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_user-acme"
    )

    private func heartbeat(updatedAt: Date, macName: String = "Acme Mac") -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: updatedAt,
            appVersion: "1.0",
            hubID: "hub-acme",
            macName: macName,
            flavor: .default,
            lastPublishAt: updatedAt,
            lastRelayAt: updatedAt,
            relayBacklog: 0,
            accounts: [HeartbeatAccount(kind: .slack, label: "acme", status: "ok")],
            enabledAt: updatedAt.addingTimeInterval(-86_400),
            ownerUser: "_user-acme",
            sharing: .none
        )
    }

    // MARK: - Your Mac: online / offline / never connected

    func testHeartbeat719SecondsOldIsOnline() {
        let now = Date()
        let status = MacStatus(heartbeat: heartbeat(updatedAt: now.addingTimeInterval(-719)), now: now)
        XCTAssertEqual(status, .online(macName: "Acme Mac"))
        XCTAssertEqual(status.title, "Online")
    }

    func testHeartbeat720SecondsOldIsOffline() {
        let now = Date()
        let stamp = now.addingTimeInterval(-720)
        let status = MacStatus(heartbeat: heartbeat(updatedAt: stamp), now: now)
        XCTAssertEqual(status, .offline(macName: "Acme Mac", lastSeen: stamp))
        XCTAssertEqual(status.title, "Offline")
    }

    func testNoHeartbeatShowsNotConnectedYet() {
        let status = MacStatus(heartbeat: nil, now: Date())
        XCTAssertEqual(status, .notConnected)
        XCTAssertEqual(status.title, "Your Mac has not connected yet")
    }

    /// The snapshot reads the DataZone heartbeat the hydrator stored, with
    /// its name and read-only accounts.
    func testSnapshotReadsTheHydratedHeartbeat() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        let now = Date()
        try await transport.save([
            try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)
        ])
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        let snapshot = try await store.reader.read { db in try SettingsSnapshot.read(from: db, deviceID: nil) }
        XCTAssertEqual(snapshot.heartbeat?.macName, "Acme Mac")
        XCTAssertEqual(snapshot.heartbeat?.accounts.map(\.label), ["acme"])
        XCTAssertNil(snapshot.grant, "no linked device, so no grant to read")
    }

    // MARK: - Your Mac: queued

    func testQueuedCountEqualsPendingOutboxRows() async throws {
        for expected in [0, 1, 25] {
            let store = try makePoolStore()
            let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store, deviceID: device.deviceID)
            for _ in 0..<expected {
                try await outbox.enqueue(kind: .probe, entityRecordName: nil)
            }
            let snapshot = try await store.reader.read { db in
                try SettingsSnapshot.read(from: db, deviceID: device.deviceID)
            }
            XCTAssertEqual(snapshot.queuedCount, expected, "queued count for \(expected) pending rows")
        }
    }

    /// The live view model sees a new queued row without a manual refresh.
    func testViewModelObservesTheQueuedCount() async throws {
        let store = try makePoolStore()
        let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store, deviceID: device.deviceID)
        let model = SettingsViewModel()
        model.start(store: store, deviceID: device.deviceID)
        try await poll { model.snapshot.queuedCount == 0 }

        try await outbox.enqueue(kind: .probe, entityRecordName: nil)
        try await poll({ model.snapshot.queuedCount == 1 }, "the observation did not re-fire on a new pending row")
    }

    // MARK: - Workbench toggles

    func testTogglesDefaultToTypingOffStartSessionsOnNewAsksOn() throws {
        let settings = DeviceSettings(transport: InMemoryCloudTransport(), defaults: try makeDefaults())
        XCTAssertFalse(settings.typingRequested)
        XCTAssertTrue(settings.startSessions)
        XCTAssertTrue(settings.newAskAlerts)
    }

    func testTypeIntoSessionsWritesTypingRequestedOnceOnARepeatedToggle() async throws {
        let transport = InMemoryCloudTransport()
        let settings = DeviceSettings(transport: transport, defaults: try makeDefaults())
        settings.linkedDevice = device

        await settings.setTypingRequested(true)
        await settings.setTypingRequested(true)

        let devices = try await deviceRecords(in: transport)
        XCTAssertEqual(devices.count, 1, "a repeated toggle to the same value must not write again")
        let written = try XCTUnwrap(devices.first)
        XCTAssertTrue(written.typingRequested)
        XCTAssertTrue(written.startSessions)
        XCTAssertEqual(written.deviceID, device.deviceID)
        XCTAssertTrue(settings.typingRequested)
        XCTAssertNil(settings.lastError)
    }

    func testStartSessionsToggleWritesTheDeviceRecord() async throws {
        let transport = InMemoryCloudTransport()
        let settings = DeviceSettings(transport: transport, defaults: try makeDefaults())
        settings.linkedDevice = device

        await settings.setStartSessions(false)

        let records = try await deviceRecords(in: transport)
        let written = try XCTUnwrap(records.first)
        XCTAssertFalse(written.startSessions)
        XCTAssertFalse(written.typingRequested)
    }

    /// Before linking there is no device record to write: the choice is kept
    /// and the link flow sends it with the link record.
    func testToggleWhileUnlinkedKeepsTheChoiceAndWritesNothing() async throws {
        let transport = InMemoryCloudTransport()
        let defaults = try makeDefaults()
        let settings = DeviceSettings(transport: transport, defaults: defaults)

        await settings.setTypingRequested(true)

        let records = try await deviceRecords(in: transport)
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(settings.typingRequested)
        XCTAssertTrue(
            DeviceSettings(transport: transport, defaults: defaults).typingRequested,
            "the choice must survive a relaunch"
        )
    }

    /// A failed write leaves the toggle where it was and says why.
    func testFailedWriteRevertsTheToggle() async throws {
        let settings = DeviceSettings(transport: FailingTransport(), defaults: try makeDefaults())
        settings.linkedDevice = device

        await settings.setTypingRequested(true)

        XCTAssertFalse(settings.typingRequested)
        XCTAssertNotNil(settings.lastError)
    }

    /// Settings reads the hub's grant for this phone.
    func testSnapshotReadsThisDevicesGrant() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: Date())
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        let mine = try await store.reader.read { db in
            try SettingsSnapshot.read(from: db, deviceID: DemoSeed.device.deviceID)
        }
        XCTAssertEqual(mine.grant?.deviceID, DemoSeed.device.deviceID)
        let other = try await store.reader.read { db in
            try SettingsSnapshot.read(from: db, deviceID: device.deviceID)
        }
        XCTAssertNil(other.grant, "another device's grant must not show")
    }

    // MARK: - Helpers

    private func deviceRecords(in transport: InMemoryCloudTransport) async throws -> [DevicePayload] {
        let batch = try await transport.changes(in: .relay, since: nil)
        return try batch.changed
            .filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }
}

/// A transport whose every call fails.
private struct FailingTransport: CloudSyncTransport {
    struct Failure: Error {}

    func save(_ records: [CloudRecord]) async throws { throw Failure() }
    func delete(recordNames: [String], in zone: CloudZoneID) async throws { throw Failure() }
    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        throw Failure()
    }
}

import GRDB
import SwiftUI
import UIKit
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

    /// Bug 10 (design pass spec §3): the Mac's name on the left, its state
    /// on the right, in one row; green only while online.
    func testTheMacRowIsOneRowForEveryStatus() {
        let now = Date()
        let english = Locale(identifier: "en_US")
        let online = MacStatusRow(status: .online(macName: "Acme Mac"), now: now, locale: english)
        XCTAssertEqual([online.label, online.value], ["Acme Mac", "Online"])
        XCTAssertEqual(online.tone, .green)
        let offline = MacStatusRow(
            status: .offline(macName: "Acme Mac", lastSeen: now.addingTimeInterval(-180)), now: now, locale: english
        )
        XCTAssertEqual([offline.label, offline.value], ["Acme Mac", "Offline · seen 3 min. ago"])
        XCTAssertEqual(offline.tone, .secondary)
        let never = MacStatusRow(status: .notConnected, now: now, locale: english)
        XCTAssertEqual([never.label, never.value], ["Mac", "Not connected"])
        XCTAssertEqual(never.tone, .secondary)
        XCTAssertEqual(MacStatusRow(status: .online(macName: ""), now: now).label, "Mac", "an empty name reads Mac")
        XCTAssertEqual(online.toneUse.role, .mac)
    }

    /// Phases 1–2 review: a Mac name too long to share its row with
    /// "Offline · seen …" puts the status on a second line under it instead
    /// of truncating either.
    func testALongMacNameWrapsTheStatusUnderTheName() {
        let now = Date()
        func height(_ name: String) -> CGFloat {
            let row = MacStatusRow(status: .offline(macName: name, lastSeen: now.addingTimeInterval(-180)), now: now)
            return UIHostingController(rootView: MacStatusRowView(row: row))
                .sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
        }
        XCTAssertGreaterThan(height("Acme Mac in the second-floor meeting room"), height("Acme Mac") + 10)
    }

    /// Design pass SET2: "3 min. ago", not a ticking "2 min, 39 sec".
    func testLastSyncSaysHowLongAgoInWords() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(LastSyncText.string(Date().addingTimeInterval(-159), locale: english), "3 min. ago")
        XCTAssertEqual(LastSyncText.string(nil), "Never")
        let now = Date()
        XCTAssertEqual(LastSyncText.string(now.addingTimeInterval(-8), now: now, locale: english), "Just now")
        XCTAssertEqual(LastSyncText.string(now.addingTimeInterval(-59), now: now, locale: english), "Just now")
        XCTAssertEqual(LastSyncText.string(now.addingTimeInterval(-60), now: now, locale: english), "1 min. ago")
    }

    /// Design pass SET3: "ok" a green dot and OK, "error" a red mark and a
    /// red Error, anything else (a newer Mac's status) its own text in
    /// secondary. Role info; never orange.
    func testAnAccountStatusIsADotAMarkOrItsText() {
        let ok = AccountStatusStyle(status: "ok")
        XCTAssertEqual(ok.mark, .dot)
        XCTAssertEqual(ok.text, "OK")
        XCTAssertEqual([ok.tone, ok.textTone], [.green, .secondary])
        let error = AccountStatusStyle(status: "error")
        XCTAssertEqual(error.mark, .symbol("exclamationmark.circle.fill"))
        XCTAssertEqual(error.text, "Error")
        XCTAssertEqual([error.tone, error.textTone], [.red, .red])
        // Final review I1: the Mac writes "revoked" for a token it lost (the
        // ErrAuthRevoked writers); it needs the owner like an error does.
        let revoked = AccountStatusStyle(status: "revoked")
        XCTAssertEqual(revoked.mark, .symbol("exclamationmark.circle.fill"))
        XCTAssertEqual(revoked.text, "Revoked")
        XCTAssertEqual([revoked.tone, revoked.textTone], [.red, .red])
        let newer = AccountStatusStyle(status: "expired")
        XCTAssertEqual(newer.mark, .textOnly)
        XCTAssertEqual(newer.text, "expired")
        XCTAssertEqual([newer.tone, newer.textTone], [.secondary, .secondary])
        XCTAssertTrue(error.toneUses.allSatisfy { $0.role == .info })
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

        let snapshot = try await store.reader.read { db in try SettingsSnapshot.read(from: db, store: store, deviceID: nil) }
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
                try SettingsSnapshot.read(from: db, store: store, deviceID: device.deviceID)
            }
            XCTAssertEqual(snapshot.queuedCount, expected, "queued count for \(expected) pending rows")
        }
    }

    /// The live view model sees a new queued row without a manual refresh.
    func testViewModelObservesTheQueuedCount() async throws {
        let store = try makePoolStore()
        let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store, deviceID: device.deviceID)
        try await outbox.enqueue(kind: .probe, entityRecordName: nil)
        let model = SettingsViewModel()
        model.start(store: store, deviceID: device.deviceID)
        try await poll({ model.snapshot.queuedCount == 1 }, "the observation's first value is missing")

        try await outbox.enqueue(kind: .probe, entityRecordName: nil)
        try await poll({ model.snapshot.queuedCount == 2 }, "the observation did not re-fire on a new pending row")
    }

    // MARK: - Diagnostics

    func testNoFailedObservationShowsNoDiagnosticRows() {
        let model = SettingsViewModel(health: ObservationHealth())
        XCTAssertEqual(model.diagnostics(now: Date()), [])
    }

    func testDiagnosticsListEachFailedObservationAndMarkRecovery() {
        struct ReadError: LocalizedError {
            var errorDescription: String? { "database is locked" }
        }
        let now = Date()
        let health = ObservationHealth()
        health.recordFailure("calendar", error: ReadError(), at: now.addingTimeInterval(-120))
        health.recordFailure("calendar", error: ReadError(), at: now.addingTimeInterval(-60))
        health.recordFailure("recordings", error: ReadError(), at: now.addingTimeInterval(-300))
        health.recordValue("recordings")

        let rows = SettingsViewModel(health: health).diagnostics(now: now)

        XCTAssertEqual(rows.map(\.name), ["calendar", "recordings"])
        XCTAssertEqual(rows[0].text, "calendar updates: failed 2×, last 1 min. ago: database is locked")
        XCTAssertEqual(rows[1].text, "recordings updates: failed 1×, last 5 min. ago: database is locked (recovered)")
    }

    // MARK: - Workbench toggles

    func testTogglesDefaultToTypingOffStartSessionsOnNewAsksOn() throws {
        let settings = DeviceSettings(transport: InMemoryCloudTransport(), defaults: try makeDefaults())
        XCTAssertFalse(settings.typingRequested)
        XCTAssertTrue(settings.startSessions)
        XCTAssertTrue(settings.newAskAlerts)
    }

    /// The spy counts every save call: the in-memory transport collapses
    /// repeated saves of one record name, so it could not see a double write.
    func testTypeIntoSessionsWritesTypingRequestedOnceOnARepeatedToggle() async throws {
        let transport = SpyTransport()
        let settings = DeviceSettings(transport: transport, defaults: try makeDefaults())
        settings.linkedDevice = device

        await settings.setTypingRequested(true)
        await settings.setTypingRequested(true)

        let saves = await transport.saves
        XCTAssertEqual(saves.count, 1, "a repeated toggle to the same value must not write again")
        XCTAssertEqual(saves.first?.count, 1)
        let payloads = try await transport.devicePayloads()
        let written = try XCTUnwrap(payloads.first)
        XCTAssertTrue(written.typingRequested)
        XCTAssertTrue(written.startSessions)
        XCTAssertEqual(written.deviceID, device.deviceID)
        XCTAssertTrue(settings.typingRequested)
        XCTAssertNil(settings.lastError)
    }

    func testStartSessionsToggleWritesTheDeviceRecord() async throws {
        let transport = SpyTransport()
        let settings = DeviceSettings(transport: transport, defaults: try makeDefaults())
        settings.linkedDevice = device

        await settings.setStartSessions(false)

        let payloads = try await transport.devicePayloads()
        let written = try XCTUnwrap(payloads.first)
        XCTAssertFalse(written.startSessions)
        XCTAssertFalse(written.typingRequested)
    }

    /// Before linking there is no device record to write: the choice is kept
    /// and the link flow sends it with the link record.
    func testToggleWhileUnlinkedKeepsTheChoiceAndWritesNothing() async throws {
        let transport = SpyTransport()
        let defaults = try makeDefaults()
        let settings = DeviceSettings(transport: transport, defaults: defaults)

        await settings.setTypingRequested(true)

        let saves = await transport.saves
        XCTAssertTrue(saves.isEmpty)
        XCTAssertTrue(settings.typingRequested)
        XCTAssertTrue(
            DeviceSettings(transport: transport, defaults: defaults).typingRequested,
            "the choice must survive a relaunch"
        )
    }

    /// A failed write leaves the toggle where it was and says why.
    func testFailedWriteRevertsTheToggle() async throws {
        let transport = SpyTransport(failingSaves: [0])
        let settings = DeviceSettings(transport: transport, defaults: try makeDefaults())
        settings.linkedDevice = device

        await settings.setTypingRequested(true)

        XCTAssertFalse(settings.typingRequested)
        XCTAssertNotNil(settings.lastError)
    }

    /// Two quick toggles: the writes never overlap, run in toggle order, and
    /// the first one's failure reverts only its own change before the second
    /// write reads the choices.
    func testQuickTogglesWriteOneAtATimeAndAFailedFirstWriteCannotOverwriteTheSecond() async throws {
        let transport = SpyTransport(failingSaves: [0], holdSaves: true)
        let settings = DeviceSettings(transport: transport, defaults: try makeDefaults())
        settings.linkedDevice = device
        defer { Task { await transport.release(0, 1) } }

        let first = Task { await settings.setTypingRequested(true) }
        // The second toggle comes while the first write is held in flight.
        try await pollSaves(transport, 1)
        let second = Task { await settings.setStartSessions(false) }
        try await poll { !settings.startSessions }
        let held = await transport.saves.count
        XCTAssertEqual(held, 1, "the second write waits behind the first")
        await transport.release(0)
        await first.value
        try await pollSaves(transport, 2)
        await transport.release(1)
        await second.value

        let maxInFlight = await transport.maxInFlight
        XCTAssertEqual(maxInFlight, 1, "device-record writes must not overlap")
        let payloads = try await transport.devicePayloads()
        XCTAssertEqual(payloads.map(\.typingRequested), [true, false], "the second write sends the reverted typing choice")
        XCTAssertEqual(payloads.map(\.startSessions), [true, false])
        XCTAssertFalse(settings.typingRequested, "the failed typing write is reverted")
        XCTAssertFalse(settings.startSessions, "the second toggle keeps its value")
    }

    /// A-T11 N3: the newest toggle of a setting wins. On, off, on, the last
    /// two queued behind the first write: that write's failure must not
    /// revert the third toggle (the value matches it again, ABA).
    func testAFailedWriteNeverRevertsANewerToggleOfTheSameSetting() async throws {
        let transport = SpyTransport(failingSaves: [0], holdSaves: true)
        let defaults = try makeDefaults()
        let settings = DeviceSettings(transport: transport, defaults: defaults)
        settings.linkedDevice = device
        // Released on every path, so a failing assertion leaks no waiter.
        defer { Task { await transport.release(0, 1, 2) } }

        let first = Task { await settings.setTypingRequested(true) }
        try await pollSaves(transport, 1)
        let second = Task { await settings.setTypingRequested(false) }
        try await poll { !settings.typingRequested }
        let third = Task { await settings.setTypingRequested(true) }
        try await poll { settings.typingRequested }

        await transport.release(0, 1, 2)
        _ = await (first.value, second.value, third.value)
        XCTAssertTrue(settings.typingRequested, "the newest toggle keeps its value")
        let payloads = try await transport.devicePayloads()
        XCTAssertEqual(payloads.map(\.typingRequested), [true, true, true], "no write sends the stale revert")
        XCTAssertTrue(DeviceSettings(transport: transport, defaults: defaults).typingRequested)
    }

    /// A-T11 N3: a reverted toggle says why until that setting saves, even
    /// when the other setting's write succeeds right behind it.
    func testARevertedToggleKeepsItsErrorUntilThatSettingSaves() async throws {
        let transport = SpyTransport(failingSaves: [0], holdSaves: true)
        let settings = DeviceSettings(transport: transport, defaults: try makeDefaults())
        settings.linkedDevice = device
        defer { Task { await transport.release(0, 1, 2) } }

        let first = Task { await settings.setTypingRequested(true) }
        try await pollSaves(transport, 1)
        let second = Task { await settings.setStartSessions(false) }
        try await poll { !settings.startSessions }
        await transport.release(0, 1)
        _ = await (first.value, second.value)
        XCTAssertFalse(settings.typingRequested, "the failed typing write is reverted")
        XCTAssertFalse(settings.startSessions)
        XCTAssertNotNil(settings.lastError, "the start-sessions save must not hide why typing went back")

        await transport.release(2)
        await settings.setTypingRequested(true)
        XCTAssertNil(settings.lastError, "a typing save clears it")
    }

    /// Waits (bounded) until the spy has seen `count` save calls.
    private func pollSaves(_ transport: SpyTransport, _ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await transport.saves.count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let seen = await transport.saves.count
        XCTAssertEqual(seen, count, "the spy did not see the save in time")
    }

    /// Settings reads the hub's grant for this phone.
    func testSnapshotReadsThisDevicesGrant() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: Date())
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()

        let mine = try await store.reader.read { db in
            try SettingsSnapshot.read(from: db, store: store, deviceID: DemoSeed.device.deviceID)
        }
        XCTAssertEqual(mine.grant?.deviceID, DemoSeed.device.deviceID)
        let other = try await store.reader.read { db in
            try SettingsSnapshot.read(from: db, store: store, deviceID: device.deviceID)
        }
        XCTAssertNil(other.grant, "another device's grant must not show")
    }

}

/// Records every `save` call (one entry per call), fails the calls whose
/// index is in `failingSaves`, and tracks how many saves overlap.
private actor SpyTransport: CloudSyncTransport {
    struct Failure: Error {}

    private(set) var saves: [[CloudRecord]] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private let failingSaves: Set<Int>
    /// With `holdSaves`, each save waits for `release(index)` (sticky: a
    /// release before the save arrives lets it straight through).
    private let holdSaves: Bool
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(failingSaves: Set<Int> = [], holdSaves: Bool = false) {
        self.failingSaves = failingSaves
        self.holdSaves = holdSaves
    }

    func save(_ records: [CloudRecord]) async throws {
        let index = saves.count
        saves.append(records)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if holdSaves, !released.contains(index) {
            await withCheckedContinuation { waiters[index] = $0 }
        }
        if failingSaves.contains(index) { throw Failure() }
    }

    func release(_ indexes: Int...) {
        for index in indexes {
            released.insert(index)
            waiters.removeValue(forKey: index)?.resume()
        }
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {}

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: CloudChangeToken(value: 0))
    }

    func devicePayloads() throws -> [DevicePayload] {
        try saves.flatMap { $0 }
            .filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }
}

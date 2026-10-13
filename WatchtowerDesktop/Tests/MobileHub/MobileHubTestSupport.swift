import CloudKit
import CryptoKit
import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerE2ETesting
import WatchtowerSync

/// HubTransport stub: InMemoryCloudTransport record I/O plus steerable
/// availability, a log of every saved record (with the instant it was
/// saved) and counters for the lifecycle calls.
final class StubHubTransport: HubTransport, @unchecked Sendable {
    struct Saved {
        let record: CloudRecord
        let at: ContinuousClock.Instant
    }

    private let inner: InMemoryCloudTransport
    private let lock = NSLock()
    private var currentAvailability: CloudAvailability
    private var startCount = 0
    private var stopCount = 0
    private var lifecycleLog: [String] = []
    private var appliedIDs: [String] = []
    private var savedLog: [Saved] = []
    private var sendNowCount = 0
    private var resetHandler: (@Sendable () -> Void)?
    private var dataZoneResetHandler: (@Sendable () -> Void)?
    private var rejectedHandler: (@Sendable (String, CloudZoneID) -> Void)?
    private var failingSaves = 0
    private var saveGate: (gate: SaveGate, matches: @Sendable (CloudRecord) -> Bool)?
    private var resetHandlerGate: SaveGate?
    private var throttleStart: Date?

    /// The single-hub build's fixed-name zones, as `removeLegacyZones` sees them.
    enum LegacyZones { case none, present(heartbeat: Data?) }
    private var legacy: LegacyZones = .none
    private var legacyChecks = 0
    private var legacyFails = false
    private var zoneDeleteError: (any Error)?
    private var zoneDeletesPartial = false
    private var zoneDeleteCount = 0
    /// Like CloudKitTransport: a delete while one runs joins it, and
    /// `start()` waits for the running one.
    private let zoneDeleteSlot = ZoneDeleteSlot()
    private var zoneDeleteDelay: Duration?

    init(
        availability: CloudAvailability = .available,
        cloud: InMemoryCloudTransport = InMemoryCloudTransport()
    ) {
        currentAvailability = availability
        inner = cloud
    }

    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    private var pullCount = 0
    var pulls: Int { lock.withLock { pullCount } }
    /// "start" / "stop" / "deleteZones", in call order.
    var lifecycle: [String] { lock.withLock { lifecycleLog } }
    /// Ids of every `applied` action echo saved, in order — counted here, on
    /// save, so a test polls an O(1) value instead of re-decoding the log.
    var appliedEchoIDs: [String] { lock.withLock { appliedIDs } }
    var saved: [Saved] { lock.withLock { savedLog } }
    /// How many times the hub asked for an immediate send.
    var sendNowCalls: Int { lock.withLock { sendNowCount } }

    /// The next `count` saves throw before writing anything (a transient
    /// CloudKit or network error).
    func failNextSaves(_ count: Int) {
        lock.withLock { failingSaves = count }
    }

    /// The next save carrying a record that `matches` parks on `gate`
    /// before it writes anything (a slow CloudKit save); later saves pass.
    func gateNextSave(on gate: SaveGate, where matches: @escaping @Sendable (CloudRecord) -> Bool) {
        lock.withLock { saveGate = (gate, matches) }
    }

    /// The next `setAccountResetHandler` parks on `gate` before it installs
    /// anything (a slow transport actor hop during start).
    func gateNextResetHandlerInstall(on gate: SaveGate) {
        lock.withLock { resetHandlerGate = gate }
    }

    func setAvailability(_ value: CloudAvailability) {
        lock.withLock { currentAvailability = value }
    }

    /// The start of a throttling stretch (nil: sends go through).
    func setThrottledSince(_ value: Date?) {
        lock.withLock { throttleStart = value }
    }

    var throttledSince: Date? { lock.withLock { throttleStart } }

    func setLegacyZones(_ value: LegacyZones) { lock.withLock { legacy = value } }
    func setLegacyCheckFails(_ value: Bool) { lock.withLock { legacyFails = value } }
    /// Deletes fail with a refusal CloudKit sends before applying anything.
    func setZoneDeletesFail(_ value: Bool) { setZoneDeleteError(value ? CKError(.networkUnavailable) : nil) }
    /// Deletes throw `error` without deleting anything (nil: they go through).
    func setZoneDeleteError(_ error: (any Error)?) { lock.withLock { zoneDeleteError = error } }
    /// Deletes throw `HubZoneError.partlyDeleted` (one zone gone, or the
    /// store wipe failed after the server delete).
    func setZoneDeletesPartial(_ value: Bool) { lock.withLock { zoneDeletesPartial = value } }
    /// The next `deleteHubZones` sleeps this long (uncancellable, like a
    /// CloudKit call that outlives its bound), then goes through.
    func delayNextZoneDelete(_ value: Duration) { lock.withLock { zoneDeleteDelay = value } }
    var legacyCheckCount: Int { lock.withLock { legacyChecks } }
    var zoneDeletes: Int { lock.withLock { zoneDeleteCount } }
    var legacyZonesPresent: Bool {
        lock.withLock {
            if case .present = legacy { return true }
            return false
        }
    }

    func deleteHubZones() async throws {
        let failure = await zoneDeleteSlot.run { [self] () -> (any Error)? in
            let (failure, partial, delay) = lock.withLock { () -> ((any Error)?, Bool, Duration?) in
                lifecycleLog.append("deleteZones")
                defer { zoneDeleteDelay = nil }
                return (zoneDeleteError, zoneDeletesPartial, zoneDeleteDelay)
            }
            if let delay { try? await Task.sleep(for: delay) }
            if let failure { return failure }
            lock.withLock { zoneDeleteCount += 1 }
            return partial ? HubZoneError.partlyDeleted : nil
        }
        if let failure { throw failure }
    }

    func removeLegacyZones(deleteIf: @Sendable (Data?) -> Bool) async throws -> LegacyZoneCleanup {
        let (state, fails) = lock.withLock { () -> (LegacyZones, Bool) in
            legacyChecks += 1
            return (legacy, legacyFails)
        }
        if fails { throw URLError(.notConnectedToInternet) }
        guard case .present(let heartbeat) = state else { return .noneFound }
        guard deleteIf(heartbeat) else { return .kept }
        lock.withLock { legacy = .none }
        return .deleted
    }

    func fireAccountReset() {
        let handler = lock.withLock { resetHandler }
        handler?()
    }

    func fireDataZoneReset() {
        let handler = lock.withLock { dataZoneResetHandler }
        handler?()
    }

    func fireRecordRejected(_ recordName: String, zone: CloudZoneID) {
        let handler = lock.withLock { rejectedHandler }
        handler?(recordName, zone)
    }

    func start() async {
        await zoneDeleteSlot.settle()
        lock.withLock {
            startCount += 1
            lifecycleLog.append("start")
        }
    }

    func stop() async {
        lock.withLock {
            stopCount += 1
            lifecycleLog.append("stop")
        }
    }
    func sendNow() async {
        lock.withLock { sendNowCount += 1 }
    }

    func pull() async throws {
        lock.withLock { pullCount += 1 }
    }
    func availability() async -> CloudAvailability { lock.withLock { currentAvailability } }

    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async {
        let gate = lock.withLock { () -> SaveGate? in
            defer { resetHandlerGate = nil }
            return resetHandlerGate
        }
        if let gate { await gate.park() }
        lock.withLock { resetHandler = handler }
    }

    func setDataZoneResetHandler(_ handler: (@Sendable () -> Void)?) async {
        lock.withLock { dataZoneResetHandler = handler }
    }

    func setRecordRejectedHandler(_ handler: (@Sendable (String, CloudZoneID) -> Void)?) async {
        lock.withLock { rejectedHandler = handler }
    }

    func save(_ records: [CloudRecord]) async throws {
        let gate = lock.withLock { () -> SaveGate? in
            guard let pending = saveGate, records.contains(where: pending.matches) else { return nil }
            saveGate = nil
            return pending.gate
        }
        if let gate { await gate.park() }
        let fails = lock.withLock {
            guard failingSaves > 0 else { return false }
            failingSaves -= 1
            return true
        }
        if fails { throw URLError(.networkConnectionLost) }
        try await inner.save(records)
        let now = ContinuousClock.now
        let applied = records.compactMap { record -> String? in
            guard record.zone == .relay, let action = try? decodeAction(record), action.status == .applied else { return nil }
            return action.id
        }
        lock.withLock {
            savedLog.append(contentsOf: records.map { Saved(record: $0, at: now) })
            appliedIDs.append(contentsOf: applied)
        }
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }
}

/// One zone delete at a time: a call while one runs gets its outcome
/// (CloudKitTransport's join); `settle()` waits for the running one.
actor ZoneDeleteSlot {
    private var running: Task<(any Error)?, Never>?

    func run(_ operation: @escaping @Sendable () async -> (any Error)?) async -> (any Error)? {
        if let running { return await running.value }
        let work = Task { await operation() }
        running = work
        let failure = await work.value
        running = nil
        return failure
    }

    func settle() async {
        _ = await running?.value
    }
}

extension HubSyncState {
    /// A per-hub sidecar on a temp file, plus a second handle on the file
    /// through which a test installs a trigger that fails a write. The
    /// caller removes `dir`.
    static func onDiskPerHub() throws -> (state: HubSyncState, raw: DatabaseQueue, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hubstate.db").path
        let state = try HubSyncState(path: path)
        try state.setMetaValue("1", forKey: HubIdentity.perHubZonesKey)
        // The raw handle waits for the running hub's locks like the sidecar does; without a busy timeout its
        // COMMIT fails at once whenever a hub pass holds the file (a flake, seen 1 in 3 runs).
        var config = Configuration()
        config.busyMode = .timeout(5)
        return (state, try DatabaseQueue(path: path, configuration: config), dir)
    }

    /// A sidecar the per-hub zone adoption already ran on (most tests seed
    /// sync state before `start()` and must keep it).
    static func inMemoryPerHub() throws -> HubSyncState {
        let state = try inMemory()
        try state.setMetaValue("1", forKey: HubIdentity.perHubZonesKey)
        return state
    }
}

/// A relay buffer like CloudKitTransport's: it holds only what the phone
/// saved (`phone`), never the hub's own saves, which land in `echoes`. After
/// a pass, the latest buffered event of each record is still the phone's
/// `pending` write.
actor PhoneOnlyBuffer: CloudSyncTransport {
    let phone = InMemoryCloudTransport()
    private(set) var echoes: [CloudRecord] = []
    func save(_ records: [CloudRecord]) async throws { echoes += records }
    func delete(recordNames: [String], in zone: CloudZoneID) async throws {}
    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await phone.changes(in: zone, since: token)
    }
}

/// A sticky gate for a stub call: `park()` fulfils `arrived`, then waits
/// for `release()`, which lets a park that comes before or after it through.
final class SaveGate: @unchecked Sendable {
    let arrived = XCTestExpectation(description: "a gated save parked")
    private let lock = NSLock()
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func park() async {
        arrived.fulfill()
        await withCheckedContinuation { continuation in
            let open = lock.withLock {
                if !isOpen { parked.append(continuation) }
                return isOpen
            }
            if open { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock {
            isOpen = true
            defer { parked = [] }
            return parked
        }
        waiting.forEach { $0.resume() }
    }
}

/// Host facts for a test hub: no host lookup, no main DB, no CloudKit.
func testHostInfo(
    macName: String = "Mac acme",
    flavor: HubFlavor = .default,
    accounts: @escaping @Sendable () async throws -> [HeartbeatAccount] = { [] },
    ownerUser: String? = "_owner-acme"
) -> HubHostInfo {
    HubHostInfo(macName: macName, appVersion: "0.0.0-test", flavor: flavor, accounts: accounts) { ownerUser }
}

/// A slice source whose records the test sets; counts its reads.
final class StubSliceSource: SliceSource, @unchecked Sendable {
    let kind: SliceKind
    private let lock = NSLock()
    private var current: [SliceRecord] = []
    private var readCount = 0

    init(kind: SliceKind) {
        self.kind = kind
    }

    var reads: Int { lock.withLock { readCount } }

    func setRecords(_ records: [SliceRecord]) {
        lock.withLock { current = records }
    }

    /// One record `<kind>-<id>` whose payload is `payload`.
    func setPayload(_ payload: Data, id: String = "1") {
        setRecords([SliceRecord(kind: kind, id: id, modifiedAt: Date(), payload: payload)])
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        lock.withLock {
            readCount += 1
            return current
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes, then fails.
func awaitHubCondition(
    _ message: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async throws -> Bool
) async rethrows {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail(message, file: file, line: line)
}

/// The paired test phone's id (`TestE2E.deviceID`) as payloads and the sidecar spell it.
let testPhoneID = TestE2E.deviceID.uuidString

/// A pending phone action record, `createdAt` = `age` seconds before `now`, sealed by the paired test phone
/// (`TestRelayPhone.seal`): the wire record a phone's outbox saves. `deviceID` is the payload's `device_id`.
func pendingActionRecord(
    id: String = UUID().uuidString,
    kind: ActionKind,
    entityID: String? = nil,
    params: [String: JSONValue] = [:],
    age: TimeInterval = 0,
    now: Date = Date(),
    hubID: String? = nil,
    deviceID: String? = testPhoneID,
    sender: DeviceIdentityKeys = TestE2E.deviceIdentity
) throws -> CloudRecord {
    let created = now.addingTimeInterval(-age)
    let action = ActionRequestPayload(
        id: id, kind: kind, entityID: entityID, params: params, createdAt: created, deviceID: deviceID, hubID: hubID
    )
    return try TestRelayPhone.seal(try CloudRecordFactory.record(for: action, modifiedAt: created), as: sender)
}

/// A relay record's action: a sealed one opened as a test phone would (an h2p echo, or a phone's own p2h save),
/// a plain one decoded as it is.
func decodeAction(_ record: CloudRecord) throws -> ActionRequestPayload {
    let plain = record.kind == WireKind.envelope ? try TestRelayPhone.openAny(record) : record
    return try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: plain.payload)
}

/// The test phones' half of RelayZone (F25: `TestE2E` keys, no copies): sealing a plain relay record `.relayToHub`
/// under a phone's pairwise key, exactly as `SecureTransport` does on the phone, and opening the hub's
/// `.relayToPhone` echoes. Synchronous, so it works inside handler closures and `map`s.
enum TestRelayPhone {
    /// Envelope seqs for records sealed without an explicit one; above any seq a test passes.
    private static let seqs = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000)
    /// Wire → plain names of every record sealed here (`CloudRecord.plainName`).
    private static let plainNames = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// One provider per test phone (its relay keys are derived once and cached).
    private static let providers = OSAllocatedUnfairLock<[UUID: PhoneKeyProvider]>(initialState: [:])

    static func keys(_ identity: DeviceIdentityKeys) throws -> PhoneKeyProvider {
        if let cached = providers.withLock({ $0[identity.deviceID] }) { return cached }
        let made = try TestE2E.phone(store: TestE2E.phoneStore(identity: identity))
        providers.withLock { $0[identity.deviceID] = made }
        return made
    }

    /// The opaque RelayZone name of a plain record name (`K_meta`, shared by every test phone and the test hub).
    static func wireName(_ plain: String) throws -> String {
        try TestE2E.hubTransport().wireName(plain: plain, zone: .relay)
    }

    /// `plain` sealed by `identity`'s phone at `epoch`/`seq`: kind `wt`, the opaque name, the asset file and the
    /// creator kept (the creator is server metadata the in-memory fake carries as given).
    static func seal(
        _ plain: CloudRecord,
        as identity: DeviceIdentityKeys = TestE2E.deviceIdentity,
        epoch: UInt32 = 1,
        seq: UInt64? = nil
    ) throws -> CloudRecord {
        let keys = try keys(identity)
        let wire = try wireName(plain.recordName)
        let frame = InnerFrame(kind: plain.kind, id: plain.recordName, asset: plain.asset, payload: plain.payload)
        let envelope = try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: .relayToHub,
            key: try keys.relayKey(.phoneToHub, deviceID: identity.deviceID, epoch: epoch),
            hubID: TestE2E.hubID, senderID: identity.deviceID, epoch: epoch,
            seq: seq ?? seqs.withLock { next in
                defer { next += 1 }
                return next
            },
            context: EnvelopeContext(zone: .relay, wireName: wire), signer: nil)
        plainNames.withLock { $0[wire] = plain.recordName }
        return CloudRecord(
            recordName: wire, zone: .relay, kind: WireKind.envelope, modifiedAt: plain.modifiedAt, payload: envelope,
            assetFileURL: plain.assetFileURL, creatorUserRecordName: plain.creatorUserRecordName)
    }

    /// A hub echo opened by `identity`'s phone; throws (`EnvelopeError.authenticationFailed`) when it was not
    /// sealed to that phone.
    static func open(_ wire: CloudRecord, as identity: DeviceIdentityKeys = TestE2E.deviceIdentity) throws -> CloudRecord {
        try open(wire, direction: .hubToPhone, as: identity)
    }

    /// A sealed relay record opened by whichever test phone can: a hub echo to either phone, or either phone's own
    /// p2h save.
    static func openAny(_ wire: CloudRecord) throws -> CloudRecord {
        var lastError: (any Error)?
        for identity in [TestE2E.deviceIdentity, TestE2E.strangerIdentity] {
            for direction in [RelayDirection.hubToPhone, .phoneToHub] {
                do { return try open(wire, direction: direction, as: identity) } catch { lastError = error }
            }
        }
        throw lastError ?? TestOpeningError.notAnEnvelope(wire.recordName)
    }

    private static func open(
        _ wire: CloudRecord, direction: RelayDirection, as identity: DeviceIdentityKeys
    ) throws -> CloudRecord {
        let keys = try keys(identity)
        let opened = try EnvelopeSealer.openSymmetric(
            wire.payload, accepting: [direction == .hubToPhone ? .relayToPhone : .relayToHub],
            context: EnvelopeContext(zone: .relay, wireName: wire.recordName), verifier: nil
        ) { header in try keys.relayKey(direction, deviceID: identity.deviceID, epoch: header.epoch) }
        return CloudRecord(
            recordName: opened.frame.id, zone: .relay, kind: opened.frame.kind, modifiedAt: wire.modifiedAt,
            payload: opened.frame.payload, assetFileURL: wire.assetFileURL, asset: opened.frame.asset,
            sealed: SealedInfo(
                wireName: wire.recordName, senderID: opened.header.senderID, epoch: opened.header.epoch,
                seq: opened.header.seq, envelopeClass: opened.header.envelopeClass))
    }

    static func plainName(forWire wire: String) -> String? {
        plainNames.withLock { $0[wire] }
    }
}

extension CloudRecord {
    /// The plain record name the exactly-once ledger keys on: a record sealed by `TestRelayPhone` maps back to
    /// the name it was sealed under; a plain record is its own name.
    var plainName: String { TestRelayPhone.plainName(forWire: recordName) ?? recordName }
}

extension StubHubTransport {
    /// The hub's echoes the paired phone (or `identity`) can open, in save order, opened.
    func openedEchoes(as identity: DeviceIdentityKeys = TestE2E.deviceIdentity) -> [CloudRecord] {
        saved.compactMap { entry in
            guard entry.record.zone == .relay, entry.record.kind == WireKind.envelope else { return nil }
            return try? TestRelayPhone.open(entry.record, as: identity)
        }
    }
}

/// Parks a handler until the test releases it; counts entries per action.
@MainActor
final class HandlerLatch {
    private(set) var calls: [String: Int] = [:]
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    var entries: Int { calls.values.reduce(0, +) }

    /// Called by the handler: records the action, then waits while closed.
    func enter(_ action: ActionRequestPayload) async {
        calls[action.id, default: 0] += 1
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func release() {
        isOpen = true
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }
}

extension HubSyncState {
    /// Seeds a linked phone past the device gate (spec §5.2 rule 4), as if
    /// it had scanned a code: tests of the relay's own rules start here.
    func linkTestDevice(
        _ deviceID: String = testPhoneID,
        scope: DeviceScope = .private,
        userRecordName: String = "_owner-acme",
        at date: Date = Date()
    ) throws {
        let nonce = "test-nonce-\(deviceID)"
        try addLinkCode(nonce: nonce, issuedAt: date, exp: date.addingTimeInterval(600), keeping: MobileLinkCenter.keptCodes)
        let device = LinkedDevice(deviceID: deviceID, name: "iPhone", scope: scope, userRecordName: userRecordName, linkedAt: date)
        _ = try linkDevice(device, nonce: nonce, now: date)
    }
}

// MARK: - E2E (F25: the Kit's test pairing, never a copy)

/// The test hub's sealing transport over `inner`: `TestE2E`'s fixed keys, so `TestE2E.opener()` (the paired phone)
/// opens what it seals. `names` is the persisted wire → plain map (the sidecar, F19).
func testSecureTransport(
    _ inner: any CloudSyncTransport & Sendable,
    names: (any WireNameIndex)? = nil,
    keys: TestHubKeyProvider = TestE2E.hub(),
    onRejected: (@Sendable (_ wireName: String, _ reason: String) -> Void)? = nil
) -> SecureTransport {
    SecureTransport(inner: inner, keys: keys, rollback: InMemoryRollbackGuard(), names: names, onRejected: onRejected)
}

/// What the hub publishes, read the way the paired phone reads it.
enum TestOpening {
    /// A DataZone wire record opened by the paired phone (signature verified): plain name, kind, payload, notify
    /// level and asset descriptor; the wire record's `modifiedAt` and asset file. A signal passes as it is.
    static func open(_ record: CloudRecord) throws -> CloudRecord {
        if record.kind == WireKind.signal { return record }
        guard record.kind == WireKind.envelope else {
            throw TestOpeningError.notAnEnvelope(record.recordName)
        }
        let frame = try TestE2E.opener().open(wireName: record.recordName, envelope: record.payload)
        return CloudRecord(
            recordName: frame.id, zone: record.zone, kind: frame.kind, modifiedAt: record.modifiedAt,
            payload: frame.payload, notifyLevel: frame.notifyLevel, assetFileURL: record.assetFileURL,
            asset: frame.asset
        )
    }

    /// The asset file of an opened record, decrypted with its descriptor.
    static func assetPlaintext(_ opened: CloudRecord) throws -> Data {
        let file = try XCTUnwrap(opened.assetFileURL, "no asset file")
        let descriptor = try XCTUnwrap(opened.asset, "no asset descriptor in the frame")
        return try ChunkedAssetCipher.decrypt(try Data(contentsOf: file), descriptor: descriptor)
    }
}

enum TestOpeningError: Error {
    case notAnEnvelope(String)
}

/// The DataZone records `transport` currently holds, opened as the paired phone opens them (signals included as
/// they are).
func openedRecords(in transport: any CloudSyncTransport) async throws -> [CloudRecord] {
    try await transport.changes(in: .data, since: nil).changed.map(TestOpening.open)
}

extension StubHubTransport {
    /// The saved log with every DataZone envelope opened (relay records and signals as saved).
    func openedSaves() throws -> [Saved] {
        try saved.map { entry in
            guard entry.record.zone == .data else { return entry }
            return Saved(record: try TestOpening.open(entry.record), at: entry.at)
        }
    }

    /// The hub's sealing transport over this stub (`TestE2E` keys).
    func sealing(names: (any WireNameIndex)? = nil) -> SecureTransport {
        testSecureTransport(self, names: names)
    }
}

// MARK: - Hellos (Task 13)

extension HubSyncState {
    /// The hub's keyring over this sidecar (an in-memory Keychain), its K_meta and first epoch made; `now` stamps
    /// its epochs and removals.
    func testKeyring(now: @escaping @Sendable () -> Date = { Date() }) throws -> HubKeyring {
        let keyring = try HubKeyring(hubID: try ensureHubID(), sidecar: self, store: InMemoryHubKeyStore(), now: now)
        try keyring.ensureGroupKeys()
        return keyring
    }
}

/// A test phone's side of linking: its hello sealed to the hub's agreement key under a code's nonce, exactly as the
/// phone's `SecureTransport` seals it, and its keybox opened with its own key and checked against the hub's signing key.
enum TestHello {
    /// A fresh phone identity (random keys; its device id is the hash of its signing key).
    static func newPhone() -> DeviceIdentityKeys {
        DeviceIdentityKeys(signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey())
    }

    /// `device` (whose `device_id` names the record) as a hello sealed by `phone` under `nonce`. `signer` and
    /// `senderID` override the phone's own (forgeries); `wire` gives the CloudKit form (kind `wt`) the relay reads,
    /// otherwise the form `SecureTransport` hands over (kind `hello`, still sealed).
    static func record(
        _ device: DevicePayload,
        from phone: DeviceIdentityKeys,
        to keyring: HubKeyring,
        nonce: String,
        signer: Curve25519.Signing.PrivateKey? = nil,
        senderID: UUID? = nil,
        creator: String? = nil,
        wire: Bool = false
    ) throws -> CloudRecord {
        let hello = DeviceHello(
            device: device, signingKey: WireBytes.base64URL(phone.signing.publicKey.rawRepresentation),
            agreementKey: WireBytes.base64URL(phone.agreement.publicKey.rawRepresentation))
        let plain = try CloudRecordFactory.record(for: hello, modifiedAt: device.updatedAt)
        guard case .hub(let hubID) = keyring.role else { throw TestOpeningError.notAnEnvelope("not a hub keyring") }
        let envelope = try SealedBox.seal(
            InnerFrame(kind: plain.kind, id: plain.recordName, payload: plain.payload), envelopeClass: .hello,
            to: keyring.agreementPublicKey,
            info: SealedBox.helloInfo(hubID: hubID, linkNonce: try XCTUnwrap(WireBytes.fromBase64URL(nonce))),
            hubID: hubID, senderID: senderID ?? phone.deviceID, epoch: 0, seq: 1,
            context: EnvelopeContext(zone: .relay, wireName: plain.recordName), signer: signer ?? phone.signing)
        return CloudRecord(
            recordName: plain.recordName, zone: .relay, kind: wire ? WireKind.envelope : plain.kind,
            modifiedAt: plain.modifiedAt, payload: envelope, creatorUserRecordName: creator)
    }

    /// `phone`'s keybox among `records` (the `device_grant` slice), sealed by the hub's transport and opened with the
    /// phone's agreement key, its signature checked with the hub's public signing key; nil when there is none.
    static func keybox(for phone: DeviceIdentityKeys, in records: [SliceRecord], keyring: HubKeyring) async throws -> Keybox? {
        guard let record = records.first(where: { $0.id == phone.deviceID.uuidString }) else { return nil }
        guard case .hub(let hubID) = keyring.role else { return nil }
        let secure = SecureTransport(inner: InMemoryCloudTransport(), keys: keyring, rollback: keyring)
        let wire = try await secure.seal(CloudRecordFactory.record(for: record))
        let opened = try SealedBox.open(
            wire.payload, envelopeClass: .keybox, recipient: phone.agreement,
            info: SealedBox.keyboxInfo(hubID: hubID, deviceID: phone.deviceID),
            context: EnvelopeContext(zone: .data, wireName: wire.recordName), verifier: keyring.signingPublicKey)
        return try RelayCoder.makeDecoder().decode(Keybox.self, from: opened.frame.payload)
    }
}

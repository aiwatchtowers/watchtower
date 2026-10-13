import CloudKit
import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
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
            guard record.kind == RelayRecordKind.action.rawValue,
                  let action = try? decodeAction(record), action.status == .applied else { return nil }
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
        // The hub writes the same file from its own queue; without a busy
        // timeout a test's raw write can fail with "database is locked".
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

/// A pending phone action record, `createdAt` = `age` seconds before `now`.
func pendingActionRecord(
    id: String = UUID().uuidString,
    kind: ActionKind,
    entityID: String? = nil,
    params: [String: JSONValue] = [:],
    age: TimeInterval = 0,
    now: Date = Date(),
    hubID: String? = nil
) throws -> CloudRecord {
    let created = now.addingTimeInterval(-age)
    let action = ActionRequestPayload(
        id: id, kind: kind, entityID: entityID, params: params, createdAt: created, deviceID: "device-a", hubID: hubID
    )
    return try CloudRecordFactory.record(for: action, modifiedAt: created)
}

func decodeAction(_ record: CloudRecord) throws -> ActionRequestPayload {
    try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
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
        _ deviceID: String = "device-a",
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

import CloudKit
import Foundation
@testable import WatchtowerSync

/// Records what the transport asks of its CKSyncEngine, so scope and error
/// handling are testable without the iCloud entitlement or a network.
///
/// It does not drive the real event plumbing: `sendChanges(scope:)` never calls
/// `nextEngineBatch()` and nothing delivers `CKSyncEngine.Event`s, so
/// `handleEngineEvent`'s mapping is untested here. Tests call the
/// transport's internal entry points (`handleSentChanges`,
/// `handleFetchEventError`, …) directly; `onNextFetch` lets a test deliver an
/// event-path error while a fetch is in flight.
final class FakeSyncEngine: SyncEngineDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _databaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
    private var _recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
    private var _fetchCount = 0
    private var _sendCount = 0
    private var _cancelCount = 0
    private var fetchErrors: [Error]
    private let zones: Set<String>
    private var zoneQueryErrors: [Error]
    private var _zoneQueryCount = 0
    private var _onFetch: (@Sendable () async -> Void)?
    private var _fetchScopes: [[CKRecordZone.ID]] = []
    private var _sendScopes: [[CKRecordZone.ID]] = []

    init(
        existingZones: Set<String> = Set(CloudZoneID.allCases.map(\.rawValue)),
        fetchErrors: [Error] = [],
        zoneQueryErrors: [Error] = []
    ) {
        zones = existingZones
        self.fetchErrors = fetchErrors
        self.zoneQueryErrors = zoneQueryErrors
    }

    var zoneQueryCount: Int { lock.withLock { _zoneQueryCount } }

    /// Runs once, inside the next `fetchChanges(scope:)`, before it returns or throws.
    func onNextFetch(_ hook: @escaping @Sendable () async -> Void) {
        lock.withLock { _onFetch = hook }
    }

    /// Every registered database change is a zone save or delete.
    var databaseChanges: [CKSyncEngine.PendingDatabaseChange] { lock.withLock { _databaseChanges } }
    var recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { lock.withLock { _recordZoneChanges } }
    var fetchCount: Int { lock.withLock { _fetchCount } }
    var sendCount: Int { lock.withLock { _sendCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    /// The zone scope of each `fetchChanges(scope:)` / `sendChanges(scope:)` call.
    var fetchScopes: [[CKRecordZone.ID]] { lock.withLock { _fetchScopes } }
    var sendScopes: [[CKRecordZone.ID]] { lock.withLock { _sendScopes } }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        lock.withLock { _databaseChanges += changes }
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        lock.withLock { _recordZoneChanges += changes }
    }

    func fetchChanges(scope zoneIDs: [CKRecordZone.ID]) async throws {
        let (error, hook): (Error?, (@Sendable () async -> Void)?) = lock.withLock {
            _fetchCount += 1
            _fetchScopes.append(zoneIDs)
            let hook = _onFetch
            _onFetch = nil
            return (fetchErrors.isEmpty ? nil : fetchErrors.removeFirst(), hook)
        }
        if let hook { await hook() }
        if let error { throw error }
    }

    /// One `fetchZoneChanges` call: the zone and the token it passed.
    struct ZoneFetch: Equatable {
        let zoneID: CKRecordZone.ID
        let token: Data?
    }

    private var _zoneFetches: [ZoneFetch] = []
    private var zonePages: [String: [Result<PolledZoneChanges, Error>]] = [:]

    var zoneFetches: [ZoneFetch] { lock.withLock { _zoneFetches } }

    /// Queues the next page (or error) `fetchZoneChanges` returns for the
    /// zone named `zoneName`; with none queued it returns an empty page
    /// whose token is `"<zoneName>-<call number>"`.
    func enqueueZonePage(_ page: Result<PolledZoneChanges, Error>, zoneName: String) {
        lock.withLock { zonePages[zoneName, default: []].append(page) }
    }

    func fetchZoneChanges(_ zoneID: CKRecordZone.ID, since token: Data?) async throws -> PolledZoneChanges {
        let next: Result<PolledZoneChanges, Error> = lock.withLock {
            _zoneFetches.append(ZoneFetch(zoneID: zoneID, token: token))
            if var queued = zonePages[zoneID.zoneName], !queued.isEmpty {
                let page = queued.removeFirst()
                zonePages[zoneID.zoneName] = queued
                return page
            }
            let call = _zoneFetches.filter { $0.zoneID == zoneID }.count
            return .success(PolledZoneChanges(
                modifications: [], deletions: [],
                changeToken: Data("\(zoneID.zoneName)-\(call)".utf8), moreComing: false
            ))
        }
        return try next.get()
    }

    func sendChanges(scope zoneIDs: [CKRecordZone.ID]) async throws {
        lock.withLock {
            _sendCount += 1
            _sendScopes.append(zoneIDs)
        }
    }

    func cancelOperations() async {
        lock.withLock { _cancelCount += 1 }
    }

    func existingZoneNames() async throws -> Set<String> {
        let error: Error? = lock.withLock {
            _zoneQueryCount += 1
            return zoneQueryErrors.isEmpty ? nil : zoneQueryErrors.removeFirst()
        }
        if let error { throw error }
        return zones
    }
}

/// Sendable collector for the transport's @Sendable callbacks.
final class Collector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    func append(_ value: Value) { lock.withLock { _values.append(value) } }
    var values: [Value] { lock.withLock { _values } }
}

/// Holds waiters until `open()` (a sleeper the test releases).
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A controllable clock for throttle timestamps.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date = Date()) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
}

extension HubZones {
    static let testHubID = "hub-test"
    static func test(_ scope: CloudDatabaseScope = .private) -> HubZones { HubZones(scope: scope, hubID: testHubID) }
    static let testDataZoneName = zoneName(.data, hubID: testHubID)
    static let testRelayZoneName = zoneName(.relay, hubID: testHubID)
}

extension CloudKitTransport {
    /// A transport wired to a fake engine, an instant sleeper that records
    /// the requested waits, and a test clock. Started, so the fake is live.
    /// `role` defaults to the scope's usual side: private → hub, shared → phone.
    static func testing(
        store: TransportStore,
        scope: CloudDatabaseScope = .private,
        hubID: String = HubZones.testHubID,
        role: TransportRole? = nil,
        engine: FakeSyncEngine = FakeSyncEngine(),
        zoneAdmin: FakeZoneAdmin = FakeZoneAdmin(),
        clock: TestClock = TestClock(),
        sleeps: Collector<TimeInterval> = Collector(),
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) async -> CloudKitTransport {
        let transport = CloudKitTransport(
            store: store,
            scope: scope,
            hubID: hubID,
            role: role ?? (scope == .private ? .hub : .phone),
            entitlementPresent: { true },
            zoneAdmin: zoneAdmin,
            engineFactory: { _, _ in engine },
            now: { clock.now },
            sleep: sleep ?? { sleeps.append($0) }
        )
        await transport.start()
        return transport
    }
}

/// Zones and records on a fake server, for the hub's zone deletions.
/// `failure` fails every call; `deleteFailure` only `deleteZones` (the
/// zones stay); `deleteGate` runs at the start of each `deleteZones`, so a
/// test can hold a delete in flight.
final class FakeZoneAdmin: CloudZoneAdministering, @unchecked Sendable {
    private let lock = NSLock()
    private var zones: [CKRecordZone.ID]
    private var records: [CKRecord.ID: CKRecord]
    private var _deleted: [[CKRecordZone.ID]] = []
    private var failure: Error?
    private var deleteFailure: Error?
    private let deleteGate: (@Sendable () async -> Void)?

    init(
        zones: [CKRecordZone.ID] = [],
        records: [CKRecord] = [],
        failure: Error? = nil,
        deleteFailure: Error? = nil,
        deleteGate: (@Sendable () async -> Void)? = nil
    ) {
        self.zones = zones
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) })
        self.failure = failure
        self.deleteFailure = deleteFailure
        self.deleteGate = deleteGate
    }

    var deleted: [[CKRecordZone.ID]] { lock.withLock { _deleted } }

    func setDeleteFailure(_ error: Error?) {
        lock.withLock { deleteFailure = error }
    }

    func zoneIDs() async throws -> [CKRecordZone.ID] {
        try lock.withLock { if let failure { throw failure }; return zones }
    }

    func record(_ id: CKRecord.ID) async throws -> CKRecord? {
        lock.withLock { records[id] }
    }

    func deleteZones(_ ids: [CKRecordZone.ID]) async throws {
        await deleteGate?()
        try lock.withLock {
            if let error = failure ?? deleteFailure { throw error }
            _deleted.append(ids)
            zones.removeAll(where: ids.contains)
        }
    }
}

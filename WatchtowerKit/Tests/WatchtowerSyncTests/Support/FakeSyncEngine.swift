import CloudKit
import Foundation
@testable import WatchtowerSync

/// Records what the transport asks of its CKSyncEngine, so scope and error
/// handling are testable without the iCloud entitlement or a network.
///
/// It does not drive the real event plumbing: `sendChanges()` never calls
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

    /// Runs once, inside the next `fetchChanges()`, before it returns or throws.
    func onNextFetch(_ hook: @escaping @Sendable () async -> Void) {
        lock.withLock { _onFetch = hook }
    }

    /// Every registered database change is a zone save or delete.
    var databaseChanges: [CKSyncEngine.PendingDatabaseChange] { lock.withLock { _databaseChanges } }
    var recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { lock.withLock { _recordZoneChanges } }
    var fetchCount: Int { lock.withLock { _fetchCount } }
    var sendCount: Int { lock.withLock { _sendCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        lock.withLock { _databaseChanges += changes }
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        lock.withLock { _recordZoneChanges += changes }
    }

    func fetchChanges() async throws {
        let (error, hook): (Error?, (@Sendable () async -> Void)?) = lock.withLock {
            _fetchCount += 1
            let hook = _onFetch
            _onFetch = nil
            return (fetchErrors.isEmpty ? nil : fetchErrors.removeFirst(), hook)
        }
        if let hook { await hook() }
        if let error { throw error }
    }

    func sendChanges() async throws {
        lock.withLock { _sendCount += 1 }
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

extension CloudKitTransport {
    /// A transport wired to a fake engine, an instant sleeper that records
    /// the requested waits, and a test clock. Started, so the fake is live.
    static func testing(
        store: TransportStore,
        scope: CloudDatabaseScope = .private,
        engine: FakeSyncEngine = FakeSyncEngine(),
        clock: TestClock = TestClock(),
        sleeps: Collector<TimeInterval> = Collector(),
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil
    ) async -> CloudKitTransport {
        let transport = CloudKitTransport(
            store: store,
            scope: scope,
            entitlementPresent: { true },
            engineFactory: { _, _ in engine },
            now: { clock.now },
            sleep: sleep ?? { sleeps.append($0) }
        )
        await transport.start()
        return transport
    }
}

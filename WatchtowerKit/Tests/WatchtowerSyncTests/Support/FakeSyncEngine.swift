import CloudKit
import Foundation
@testable import WatchtowerSync

/// Records what the transport asks of its CKSyncEngine, so scope and error
/// handling are testable without the iCloud entitlement or a network.
final class FakeSyncEngine: SyncEngineDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _databaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
    private var _recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
    private var _fetchCount = 0
    private var _sendCount = 0
    private var fetchErrors: [Error]
    private let zones: Set<String>

    init(existingZones: Set<String> = Set(CloudZoneID.allCases.map(\.rawValue)), fetchErrors: [Error] = []) {
        zones = existingZones
        self.fetchErrors = fetchErrors
    }

    /// Every registered database change is a zone save or delete.
    var databaseChanges: [CKSyncEngine.PendingDatabaseChange] { lock.withLock { _databaseChanges } }
    var recordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { lock.withLock { _recordZoneChanges } }
    var fetchCount: Int { lock.withLock { _fetchCount } }
    var sendCount: Int { lock.withLock { _sendCount } }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        lock.withLock { _databaseChanges += changes }
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        lock.withLock { _recordZoneChanges += changes }
    }

    func fetchChanges() async throws {
        let error: Error? = lock.withLock {
            _fetchCount += 1
            return fetchErrors.isEmpty ? nil : fetchErrors.removeFirst()
        }
        if let error { throw error }
    }

    func sendChanges() async throws {
        lock.withLock { _sendCount += 1 }
    }

    func existingZoneNames() async throws -> Set<String> {
        zones
    }
}

/// Sendable collector for the transport's @Sendable callbacks.
final class Collector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    func append(_ value: Value) { lock.withLock { _values.append(value) } }
    var values: [Value] { lock.withLock { _values } }
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

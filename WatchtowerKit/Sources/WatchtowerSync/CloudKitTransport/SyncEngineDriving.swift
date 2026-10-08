import CloudKit

/// The slice of CKSyncEngine the transport drives. A seam so the scope and
/// error handling are testable without the iCloud entitlement: CloudKit
/// raises an uncatchable exception when touched unentitled, so tests inject
/// a fake through `CloudKitTransport`'s internal initializer.
protocol SyncEngineDriving: AnyObject, Sendable {
    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange])
    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange])
    func fetchChanges() async throws
    func sendChanges() async throws
    /// Names of this scope's zones that exist on the server (in `shared`
    /// scope: the zones of the owner shared with this participant).
    func existingZoneNames() async throws -> Set<String>
}

/// The production driver: a CKSyncEngine on the scope's database.
final class CKSyncEngineDriver: SyncEngineDriving, @unchecked Sendable {
    private let engine: CKSyncEngine
    private let database: CKDatabase
    private let scope: CloudDatabaseScope

    init(
        containerID: String,
        scope: CloudDatabaseScope,
        stateSerialization: CKSyncEngine.State.Serialization?,
        delegate: any CKSyncEngineDelegate
    ) {
        let database = scope.database(in: CKContainer(identifier: containerID))
        self.database = database
        self.scope = scope
        engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: database,
            stateSerialization: stateSerialization,
            delegate: delegate
        ))
    }

    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange]) {
        engine.state.add(pendingDatabaseChanges: changes)
    }

    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]) {
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    func fetchChanges() async throws {
        try await engine.fetchChanges()
    }

    func sendChanges() async throws {
        try await engine.sendChanges()
    }

    func existingZoneNames() async throws -> Set<String> {
        let zones = try await database.allRecordZones()
        return Set(zones.compactMap { scope.cloudZone(for: $0.zoneID)?.rawValue })
    }
}

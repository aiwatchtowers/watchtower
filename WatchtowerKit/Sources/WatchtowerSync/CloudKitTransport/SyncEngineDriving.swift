import CloudKit
import os

/// The slice of CKSyncEngine the transport drives. A seam so the scope and
/// error handling are testable without the iCloud entitlement: CloudKit
/// raises an uncatchable exception when touched unentitled, so tests inject
/// a fake through `CloudKitTransport`'s internal initializer.
protocol SyncEngineDriving: AnyObject, Sendable {
    func add(pendingDatabaseChanges changes: [CKSyncEngine.PendingDatabaseChange])
    func add(pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange])
    /// Fetches the engine's known changes of `zoneIDs` only (multi-hub
    /// spec §4.2: another hub's zones are never downloaded).
    func fetchChanges(scope zoneIDs: [CKRecordZone.ID]) async throws
    /// One page of a zone's changes straight from the server since `token`
    /// (nil: from the start), bypassing the engine. CKSyncEngine's
    /// `fetchChanges(scope:)` only fetches zones its push-fed "unfetched server
    /// changes" set names (an explicit zone scope filters that set, it does
    /// not force a fetch), so without a delivered push a manual fetch sends
    /// nothing; this is the poll that reaches the server regardless.
    /// Tokens are opaque archived `CKServerChangeToken`s.
    func fetchZoneChanges(_ zoneID: CKRecordZone.ID, since token: Data?) async throws -> PolledZoneChanges
    /// Sends the pending changes of `zoneIDs` only.
    func sendChanges(scope zoneIDs: [CKRecordZone.ID]) async throws
    /// Kind names (`CloudZoneID.rawValue`) of this hub's zones that exist on
    /// the server (in `shared` scope: of the owner shared with this participant).
    func existingZoneNames() async throws -> Set<String>
    /// Cancels the engine's in-flight and scheduled operations (the owner
    /// stopped the transport).
    func cancelOperations() async
}

/// One page of `SyncEngineDriving.fetchZoneChanges`.
struct PolledZoneChanges: Sendable {
    var modifications: [CKRecord]
    var deletions: [CKRecord.ID]
    /// The archived token to pass as `since` for the next page.
    var changeToken: Data
    /// The server has more changes after this page.
    var moreComing: Bool
}

/// The production driver: a CKSyncEngine on the hub zones' database.
final class CKSyncEngineDriver: SyncEngineDriving, @unchecked Sendable {
    private let engine: CKSyncEngine
    private let database: CKDatabase
    private let zones: HubZones
    private static let logger = Logger(subsystem: "WatchtowerKit", category: "CKSyncEngineDriver")

    init(
        containerID: String,
        zones: HubZones,
        stateSerialization: CKSyncEngine.State.Serialization?,
        delegate: any CKSyncEngineDelegate
    ) {
        let database = zones.scope.database(in: CKContainer(identifier: containerID))
        self.database = database
        self.zones = zones
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

    func fetchChanges(scope zoneIDs: [CKRecordZone.ID]) async throws {
        try await engine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(zoneIDs)))
    }

    func fetchZoneChanges(_ zoneID: CKRecordZone.ID, since token: Data?) async throws -> PolledZoneChanges {
        // An undecodable token restarts the zone from the beginning: the
        // transport skips records it already knows by their change tag.
        let since = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: since)
        var modifications: [CKRecord] = []
        for (id, result) in page.modificationResultsByID {
            switch result {
            case .success(let modification):
                modifications.append(modification.record)
            case .failure(let error):
                Self.logger.warning(
                    "polled record \(id.recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return PolledZoneChanges(
            modifications: modifications,
            deletions: page.deletions.map(\.recordID),
            changeToken: try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true),
            moreComing: page.moreComing
        )
    }

    func sendChanges(scope zoneIDs: [CKRecordZone.ID]) async throws {
        try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .zoneIDs(zoneIDs)))
    }

    func cancelOperations() async {
        await engine.cancelOperations()
    }

    func existingZoneNames() async throws -> Set<String> {
        let all = try await database.allRecordZones()
        return Set(all.compactMap { zones.cloudZone(for: $0.zoneID)?.rawValue })
    }
}

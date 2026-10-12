import CloudKit

/// Zone administration outside the engine (multi-hub spec §3.3, §3.6): the
/// hub's own zones when it is turned off, and the single-hub build's
/// leftovers. A seam like `SyncEngineDriving`, so it is testable unentitled.
protocol CloudZoneAdministering: Sendable {
    func zoneIDs() async throws -> [CKRecordZone.ID]
    /// nil when the record (or its zone) does not exist.
    func record(_ id: CKRecord.ID) async throws -> CKRecord?
    /// A zone that is already gone counts as deleted. Throws
    /// `PartialZoneDeleteError` when some zone failed while another is gone,
    /// any other error when nothing was deleted.
    func deleteZones(_ ids: [CKRecordZone.ID]) async throws
}

/// Some zones of a `deleteZones` call are gone (deleted now, or already
/// missing) while another's delete failed with `underlying`.
struct PartialZoneDeleteError: Error {
    let underlying: any Error
}

/// The CloudKit implementation. It reaches `CKContainer` only per call, and
/// the transport calls it only after its entitlement check.
struct CKDatabaseZoneAdmin: CloudZoneAdministering {
    let containerID: String
    let scope: CloudDatabaseScope

    private var database: CKDatabase { scope.database(in: CKContainer(identifier: containerID)) }

    func zoneIDs() async throws -> [CKRecordZone.ID] {
        try await database.allRecordZones().map(\.zoneID)
    }

    func record(_ id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    func deleteZones(_ ids: [CKRecordZone.ID]) async throws {
        let (_, results) = try await database.modifyRecordZones(saving: [], deleting: ids)
        try Self.checkDeleteResults(Array(results.values))
    }

    /// Per-zone delete results: nothing when every zone is gone, a
    /// `PartialZoneDeleteError` when one failed while another is gone, the
    /// failure itself when none is.
    static func checkDeleteResults(_ results: [Result<Void, any Error>]) throws {
        var failure: (any Error)?
        var anyGone = false
        for result in results {
            switch result {
            case .success:
                anyGone = true
            case .failure(let error) where (error as? CKError)?.code == .zoneNotFound:
                anyGone = true
            case .failure(let error):
                failure = failure ?? error
            }
        }
        guard let failure else { return }
        throw anyGone ? PartialZoneDeleteError(underlying: failure) : failure
    }
}

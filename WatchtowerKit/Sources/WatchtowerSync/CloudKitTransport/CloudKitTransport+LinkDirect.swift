import CloudKit
import Foundation

/// Why a direct call (`serverRecord`, `saveDirectly(_:)`) made no request, or read nothing usable.
public enum DirectCallRefusal: Error, Equatable, Sendable {
    /// CloudKit asked this transport to wait (`throttledUntil`): no request went out.
    case throttled
    /// The hub's zones are gone (`isUnlinked`): no request went out.
    case unlinked
    /// The server holds the record, but not as one this build reads (another record type, no payload).
    case unreadableRecord
}

/// The phone's link flow outside `CKSyncEngine` (#2189): its keybox read by name and its hello saved at once, so
/// neither waits behind the full download of the Mac's zones a fresh replica starts with. Both honour the throttle
/// and the unlink as `pull()` does, and a CloudKit failure throttles or unlinks as a fetch's does. Nothing is
/// buffered or stored here: the engine fetches the saved record, and the one read, later like any other change.
extension CloudKitTransport {
    /// The server's current copy of one record by its wire name: one `record(for:)`. nil only when the server has no
    /// such record; one it holds that does not map throws `DirectCallRefusal.unreadableRecord` (as `serverCopy`'s
    /// `unreadableRecord`), never nil. Throws `DirectCallRefusal.throttled`/`.unlinked` without a request, and what
    /// CloudKit threw.
    public func serverRecord(named recordName: String, in zone: CloudZoneID) async throws -> CloudRecord? {
        try checkDirectCallAllowed()
        let id = CKRecord.ID(recordName: recordName, zoneID: zones.zoneID(for: zone))
        let server: CKRecord?
        do {
            server = try await conditionalDatabase().fetchRecord(id)
        } catch let error as CKError {
            applyDirectCallFailure(error)
            throw error
        }
        clearThrottle()
        guard let server else { return nil }
        guard let record = Self.cloudRecord(from: server, zone: zone) else { throw DirectCallRefusal.unreadableRecord }
        return record
    }

    /// Saves one already sealed record now, outside the engine's queue, as the kept farewell's direct save does (a
    /// fresh record, then once over the server copy it collided with). Throws `DirectCallRefusal.throttled`/
    /// `.unlinked` without a request, and what CloudKit threw.
    public func saveDirectly(_ record: CloudRecord) async throws {
        try checkDirectCallAllowed()
        let database = conditionalDatabase()
        do {
            try await Self.saveDirectly(record, scope: scope, hubID: zones.hubID) { ck in
                let (saves, _) = try await database.modify(saving: [ck], deleting: [])
                _ = try saves[ck.recordID]?.get()
            }
        } catch let error as CKError {
            applyDirectCallFailure(error)
            throw error
        }
        clearThrottle()
    }

    private func checkDirectCallAllowed() throws {
        if isUnlinked { throw DirectCallRefusal.unlinked }
        if let throttledUntil, now() < throttledUntil { throw DirectCallRefusal.throttled }
    }
}
